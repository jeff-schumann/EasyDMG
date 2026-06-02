//
//  DMGProcessor.swift
//  EasyDMG
//
//  Main class for processing DMG files
//  Replicates the logic from easyDMG.sh v1.03
//

import Foundation
import AppKit
import Combine
import UserNotifications
import Darwin

fileprivate extension String {
    /// Strips a trailing `.app` for display in user-facing copy.
    /// Use only for presentation — filesystem paths must keep the suffix.
    var strippingAppSuffix: String {
        hasSuffix(".app") ? String(dropLast(4)) : self
    }

    /// Strips a trailing `.dmg` for display in user-facing copy.
    /// Use only for presentation — filesystem paths must keep the suffix.
    var strippingDMGSuffix: String {
        lowercased().hasSuffix(".dmg") ? String(dropLast(4)) : self
    }
}

fileprivate enum AppManagementDecision {
    case retry
    case cancel
}

fileprivate enum ExistingAppModificationPreflightResult {
    case allowed
    case blocked(reason: String)
}

fileprivate struct AppPermissionTargetDiagnostics {
    let path: String
    let ownerName: String?
    let ownerID: Int?
    let groupName: String?
    let groupID: Int?
    let posixPermissions: Int?
    let extendedAttributes: [String]
    let appStoreReceiptExists: Bool

    static func unknown(path: String) -> AppPermissionTargetDiagnostics {
        AppPermissionTargetDiagnostics(
            path: path,
            ownerName: nil,
            ownerID: nil,
            groupName: nil,
            groupID: nil,
            posixPermissions: nil,
            extendedAttributes: [],
            appStoreReceiptExists: false
        )
    }

    var isRootOwned: Bool {
        ownerID == 0 || ownerName == "root"
    }

    var hasAppStoreMarkers: Bool {
        appStoreReceiptExists ||
            extendedAttributes.contains { $0.hasPrefix("com.apple.appstore") }
    }

    var probableRestriction: String? {
        if isRootOwned && hasAppStoreMarkers {
            return "root_owned_app_store_managed"
        } else if isRootOwned {
            return "root_owned"
        } else if hasAppStoreMarkers {
            return "app_store_managed"
        }
        return nil
    }

    var automaticReplacementBlockReason: String? {
        guard hasAppStoreMarkers else {
            return nil
        }

        return probableRestriction ?? "app_store_managed"
    }

    var supportDetails: [String: String] {
        var details = [
            "target_app_store_markers": hasAppStoreMarkers ? "true" : "false",
            "target_group": groupDescription,
            "target_owner": ownerDescription,
            "target_path": path,
            "target_permissions": permissionsDescription,
            "target_xattrs": extendedAttributes.isEmpty ? "none" : extendedAttributes.joined(separator: "|")
        ]

        if let probableRestriction {
            details["probable_restriction"] = probableRestriction
        }

        return details
    }

    var diagnosticSummary: String {
        [
            "owner=\(ownerDescription)",
            "group=\(groupDescription)",
            "mode=\(permissionsDescription)",
            "appStoreMarkers=\(hasAppStoreMarkers ? "true" : "false")",
            "xattrs=\(extendedAttributes.isEmpty ? "none" : extendedAttributes.joined(separator: "|"))",
            "probableRestriction=\(probableRestriction ?? "none")"
        ].joined(separator: " ")
    }

    private var ownerDescription: String {
        if let ownerName, let ownerID {
            return "\(ownerName)(\(ownerID))"
        } else if let ownerName {
            return ownerName
        } else if let ownerID {
            return String(ownerID)
        }
        return "unknown"
    }

    private var groupDescription: String {
        if let groupName, let groupID {
            return "\(groupName)(\(groupID))"
        } else if let groupName {
            return groupName
        } else if let groupID {
            return String(groupID)
        }
        return "unknown"
    }

    private var permissionsDescription: String {
        guard let posixPermissions else {
            return "unknown"
        }
        return String(format: "%03o", posixPermissions & 0o777)
    }
}

fileprivate struct AppManagementProbeResult {
    let granted: Bool
    let errorDomain: String?
    let errorCode: Int?
    let target: AppPermissionTargetDiagnostics

    static func granted(target: AppPermissionTargetDiagnostics) -> AppManagementProbeResult {
        AppManagementProbeResult(
            granted: true,
            errorDomain: nil,
            errorCode: nil,
            target: target
        )
    }

    static func denied(error: NSError, target: AppPermissionTargetDiagnostics) -> AppManagementProbeResult {
        AppManagementProbeResult(
            granted: false,
            errorDomain: error.domain,
            errorCode: error.code,
            target: target
        )
    }

    static func unavailable(path: String) -> AppManagementProbeResult {
        denied(
            error: NSError(domain: "EasyDMG", code: -1),
            target: .unknown(path: path)
        )
    }

    var supportDetails: [String: String] {
        var details = target.supportDetails
        if let errorDomain {
            details["error_domain"] = errorDomain
        }
        if let errorCode {
            details["error_code"] = String(errorCode)
        }
        return details
    }

    var retryFailureMessage: String {
        if target.probableRestriction == "root_owned" {
            return "Still blocked. This app is root-owned; App Management may not be enough."
        }
        return "Still waiting for permission. Enable EasyDMG in System Settings, then try again."
    }
}

/// Invisible always-on-top host window used as the parent for sheet-modal
/// alerts. A standalone NSAlert in an `.accessory` app gets torn down on
/// deactivation; a sheet is owned by its parent, so as long as we keep the
/// parent alive, the sheet survives the user clicking away.
@MainActor
fileprivate final class AlertHostWindowController {
    static let shared = AlertHostWindowController()

    let window: NSWindow

    private init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        // `.floating` is load-bearing here. At `.normal` level the host (and
        // its sheet) get torn out of the window server when the `.accessory`
        // app deactivates — gone from Mission Control entirely, even with
        // `hidesOnDeactivate = false`. `.floating` exempts the window from
        // that behavior. Don't lower this without a way to recover the alert.
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.hidesOnDeactivate = false
        // Hide the host outright. Sheets are child windows that render
        // independently, so they remain fully visible.
        window.alphaValue = 0
    }

    func show() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let visible = screen?.visibleFrame {
            let width: CGFloat = 500
            let height: CGFloat = 1
            let x = visible.midX - width / 2
            // Sheet hangs down from the parent's top edge. Anchor the parent
            // ~22% down from the visible-area top so the alert lands near the
            // upper-middle of the screen, matching standard NSAlert placement.
            let topY = visible.maxY - visible.height * 0.22
            window.setFrame(
                NSRect(x: x, y: topY - height, width: width, height: height),
                display: false
            )
        }
        window.orderFront(nil)
    }

    func hide() {
        window.orderOut(nil)
    }
}

/// Present an NSAlert as a sheet on an invisible always-on-top host window.
/// See `AlertHostWindowController` for why this is needed.
@MainActor
fileprivate func presentHostedAlert(
    _ alert: NSAlert,
    completion: @escaping (NSApplication.ModalResponse) -> Void
) {
    let host = AlertHostWindowController.shared
    host.show()
    NSApp.activate(ignoringOtherApps: true)
    alert.beginSheetModal(for: host.window) { response in
        host.hide()
        completion(response)
    }
}

@MainActor
fileprivate final class AppManagementPermissionWindowController: NSWindowController, NSWindowDelegate {
    private let appName: String
    private let permissionProbe: () -> AppManagementProbeResult
    private let openSettings: () -> Void
    private let permissionReady: (String) -> Void
    private let completion: (AppManagementDecision) -> Void

    private let statusLabel = NSTextField(labelWithString: "Waiting for App Management permission.")
    private let openSettingsButton = NSButton(title: "Open System Settings", target: nil, action: nil)
    private let tryAgainButton = NSButton(title: "Try Again", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    private var didFinish = false
    private var isPermissionReady = false

    init(
        appName: String,
        permissionProbe: @escaping () -> AppManagementProbeResult,
        openSettings: @escaping () -> Void,
        permissionReady: @escaping (String) -> Void,
        completion: @escaping (AppManagementDecision) -> Void
    ) {
        self.appName = appName
        self.permissionProbe = permissionProbe
        self.openSettings = openSettings
        self.permissionReady = permissionReady
        self.completion = completion

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "EasyDMG"
        panel.identifier = NSUserInterfaceItemIdentifier("AppManagementPermissionWindow")
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .normal

        super.init(window: panel)

        panel.delegate = self
        buildContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        guard let window else { return }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func handleSystemSettingsRestartRequest() {
        if continueIfPermissionReady(reason: "system_settings_restart") {
            return
        } else {
            statusLabel.stringValue = "EasyDMG noticed the restart request, but permission is not available yet. Try again in a moment."
        }
        present()
    }

    @discardableResult
    func continueIfPermissionReady(reason: String) -> Bool {
        if refreshPermissionStatus(reason: reason) {
            finish(.retry)
            return true
        }

        return false
    }

    @discardableResult
    func refreshPermissionStatus(reason: String) -> Bool {
        guard !didFinish else { return false }

        let probe = permissionProbe()
        if probe.granted {
            markPermissionReady(reason: reason)
            return true
        } else if isPermissionReady {
            isPermissionReady = false
            statusLabel.stringValue = "Waiting for App Management permission."
            tryAgainButton.title = "Try Again"
            tryAgainButton.keyEquivalent = ""
            tryAgainButton.bezelColor = nil
            openSettingsButton.keyEquivalent = "\r"
            openSettingsButton.bezelColor = .controlAccentColor
        }

        return false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(.cancel)
        return false
    }

    private func buildContent() {
        guard let window else { return }

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = contentView

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = Bundle.main.path(forResource: "wizardhamster", ofType: "icns")
            .flatMap { NSImage(contentsOfFile: $0) }
            ?? NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown

        let titleLabel = NSTextField(labelWithString: "EasyDMG needs permission")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .boldSystemFont(ofSize: 17)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center

        let subtitleLabel = NSTextField(labelWithString: "to replace \(appName.strippingAppSuffix)")
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.maximumNumberOfLines = 1

        let stepsLabel = NSTextField(wrappingLabelWithString: "")
        stepsLabel.translatesAutoresizingMaskIntoConstraints = false
        stepsLabel.attributedStringValue = Self.makeStepsAttributedString()
        stepsLabel.lineBreakMode = .byWordWrapping
        stepsLabel.maximumNumberOfLines = 0
        stepsLabel.isSelectable = false
        stepsLabel.drawsBackground = false

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 0

        let headerStack = NSStackView(views: [titleLabel, subtitleLabel])
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.orientation = .vertical
        headerStack.alignment = .centerX
        headerStack.spacing = 4

        let contentStack = NSStackView(views: [iconView, headerStack, stepsLabel, statusLabel])
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .centerX
        contentStack.spacing = 16
        contentStack.setCustomSpacing(20, after: headerStack)
        contentStack.setCustomSpacing(18, after: stepsLabel)

        openSettingsButton.target = self
        openSettingsButton.action = #selector(openSettingsClicked)
        openSettingsButton.bezelStyle = .rounded
        openSettingsButton.controlSize = .large
        openSettingsButton.keyEquivalent = "\r"
        openSettingsButton.bezelColor = .controlAccentColor

        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        tryAgainButton.target = self
        tryAgainButton.action = #selector(tryAgainClicked)
        tryAgainButton.bezelStyle = .rounded
        tryAgainButton.keyEquivalent = ""

        let buttonStack = NSStackView(views: [openSettingsButton, cancelButton, tryAgainButton])
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 8

        contentView.addSubview(contentStack)
        contentView.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),

            contentStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            contentStack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 32),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -32),

            buttonStack.topAnchor.constraint(greaterThanOrEqualTo: contentStack.bottomAnchor, constant: 20),
            buttonStack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            buttonStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),

            titleLabel.widthAnchor.constraint(equalToConstant: 410),
            subtitleLabel.widthAnchor.constraint(equalToConstant: 410),
            stepsLabel.widthAnchor.constraint(equalToConstant: 380),
            statusLabel.widthAnchor.constraint(equalToConstant: 410)
        ])
    }

    private static func makeStepsAttributedString() -> NSAttributedString {
        let steps = [
            "Click Open System Settings.",
            "Enable EasyDMG under App Management.",
            "If macOS asks to quit EasyDMG, choose Quit & Reopen — installation continues automatically."
        ]

        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 6
        paragraph.headIndent = 22
        paragraph.firstLineHeadIndent = 0
        paragraph.lineBreakMode = .byWordWrapping

        let result = NSMutableAttributedString()
        let numberFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let textFont = NSFont.systemFont(ofSize: 13)

        for (index, step) in steps.enumerated() {
            let isLast = index == steps.count - 1
            result.append(NSAttributedString(string: "\(index + 1).  ", attributes: [
                .font: numberFont,
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph
            ]))
            result.append(NSAttributedString(string: step + (isLast ? "" : "\n"), attributes: [
                .font: textFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]))
        }

        return result
    }

    private func markPermissionReady(reason: String) {
        guard !isPermissionReady else { return }

        isPermissionReady = true
        statusLabel.stringValue = "Permission granted. Continuing..."
        tryAgainButton.title = "Continue"
        tryAgainButton.keyEquivalent = "\r"
        tryAgainButton.bezelColor = .controlAccentColor
        openSettingsButton.keyEquivalent = ""
        openSettingsButton.bezelColor = nil
        permissionReady(reason)
    }

    private func finish(_ decision: AppManagementDecision) {
        guard !didFinish else { return }

        didFinish = true
        window?.delegate = nil
        window?.close()
        completion(decision)
    }

    @objc private func openSettingsClicked() {
        openSettings()
        statusLabel.stringValue = "Waiting for permission..."
        NSApp.deactivate()
    }

    @objc private func tryAgainClicked() {
        let probe = permissionProbe()
        if probe.granted {
            markPermissionReady(reason: "try_again")
            finish(.retry)
        } else {
            statusLabel.stringValue = probe.retryFailureMessage
            NSSound.beep()
        }
    }

    @objc private func cancelClicked() {
        finish(.cancel)
    }
}

@MainActor
class DMGProcessor: ObservableObject {
    private enum ManualFallbackReason: String, Sendable {
        case genericMountFailure = "generic_mount_failure"
        case invalidAppBundle = "invalid_app_bundle"
        case packageInstaller = "package_installer"
        case installerOrAuxiliaryApp = "installer_or_auxiliary_app"
        case passwordProtected = "password_protected"
        case noAppFound = "no_app_found"
        case multipleAppsFound = "multiple_apps_found"
        case licenseRequired = "license_required"
        case securityAssessmentUnverified = "security_assessment_unverified"
        case securityAssessmentBlocked = "security_assessment_blocked"

        func notificationTitle(appName: String) -> String {
            switch self {
            case .invalidAppBundle, .genericMountFailure:
                return "Finish installing \(appName)"
            case .packageInstaller:
                return "\(appName) uses a .pkg installer"
            case .installerOrAuxiliaryApp:
                return "\(appName) uses an installer"
            case .passwordProtected:
                return "\(appName) is password-protected"
            case .noAppFound:
                return "No app found"
            case .multipleAppsFound:
                return "\(appName) has more than one app"
            case .licenseRequired:
                return "\(appName) has a license to accept"
            case .securityAssessmentUnverified, .securityAssessmentBlocked:
                return "EasyDMG needs manual install"
            }
        }

        func notificationMessage(appName: String) -> String? {
            switch self {
            case .genericMountFailure:
                return "Failure during mount — switching to manual mode."
            case .invalidAppBundle:
                return "Invalid app bundle — switching to manual mode."
            case .packageInstaller:
                return "Open the installer in the window and follow the steps."
            case .installerOrAuxiliaryApp:
                return "Open it in the window and follow the steps to finish."
            case .passwordProtected:
                return "Enter its password, then drag the app into Applications."
            case .noAppFound:
                return "EasyDMG opened it so you can take a look."
            case .multipleAppsFound:
                return "Choose which app to drag into your Applications folder."
            case .licenseRequired:
                return "Review and accept the agreement in the window to continue."
            case .securityAssessmentUnverified, .securityAssessmentBlocked:
                // Security cases already showed a prompt to the user, so no follow-up notification.
                return nil
            }
        }
    }

    private enum MountResult: Sendable {
        case mounted(mountPoint: String, exitStatus: Int32)
        case passwordProtected(exitStatus: Int32)
        case failed(exitStatus: Int32?)
    }

    /// Outcome of an attempt to mount an encrypted DMG with a supplied passphrase.
    private enum AuthenticatedMountResult: Sendable {
        case mounted(mountPoint: String)
        case wrongPassword
        case failed
    }

    /// Outcome of checking encrypted DMG metadata with a supplied passphrase.
    private enum AuthenticatedLicenseCheckResult: Sendable {
        case noLicense
        case licenseRequired
        case wrongPassword
        case failed
    }

    /// Outcome of the password prompt + unlock loop for an encrypted DMG.
    private enum EncryptedUnlockOutcome: Sendable {
        case unlocked(mountPoint: String)
        case cancelled        // user dismissed the prompt — abort, don't re-prompt
        case useSystemPrompt  // user opted into the macOS password prompt — hand off to manual
        case licenseRequired  // metadata says a license agreement needs manual handling
        case failed           // non-authentication mount failure — route to manual
    }

    /// What the user chose at our passphrase prompt.
    private enum PasswordPromptChoice: Sendable {
        case password(String)
        case useSystemPrompt  // "Use macOS Password Prompt…"
        case cancelled
    }

    private enum UnmountResult: Sendable {
        case clean
        case retrySuccess
        case forceSuccess
        case timedOut(stage: String)
        case failed(exitStatus: Int32?)

        var supportValue: String {
            switch self {
            case .clean:
                return "clean"
            case .retrySuccess:
                return "retry_success"
            case .forceSuccess:
                return "force_success"
            case .timedOut:
                return "timed_out"
            case .failed:
                return "failed"
            }
        }

        var exitStatus: Int32? {
            switch self {
            case .clean, .retrySuccess, .forceSuccess:
                return 0
            case .timedOut:
                return nil
            case let .failed(status):
                return status
            }
        }

        var timedOutStage: String? {
            switch self {
            case let .timedOut(stage):
                return stage
            case .clean, .retrySuccess, .forceSuccess, .failed:
                return nil
            }
        }
    }

    private enum ReplacementVersionComparison {
        case older
        case same
        case newer
        case unknown
    }

    private struct ParsedAppVersion {
        let components: [Int]
        let prerelease: String?
    }

    private struct ProcessRunResult: Sendable {
        let exitStatus: Int32?
        let standardError: String
        let timedOut: Bool
    }

    private enum AppSecurityAssessmentResult: String, Sendable {
        case passed
        case unverified
        case blocked
    }

    private enum QuarantineDecision: String, Sendable {
        case removeQuarantine = "remove_quarantine"
        case handleManually = "handle_manually"
        case cancel
    }

    private struct AssessmentProcessResult: Sendable {
        let exitStatus: Int32?
        let standardOutput: String
        let standardError: String
        let timedOut: Bool

        nonisolated var combinedOutput: String {
            [standardOutput, standardError]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
    }

    private nonisolated final class ProcessPipeCollector: @unchecked Sendable {
        private let pipe: Pipe
        private let lock = NSLock()
        private let readGroup = DispatchGroup()
        private var collectedData = Data()

        init(pipe: Pipe) {
            self.pipe = pipe
        }

        func startReading() {
            readGroup.enter()
            DispatchQueue.global(qos: .utility).async { [self] in
                while true {
                    let data = pipe.fileHandleForReading.availableData
                    if data.isEmpty {
                        break
                    }

                    lock.lock()
                    collectedData.append(data)
                    lock.unlock()
                }

                readGroup.leave()
            }
        }

        func data(waitForEOF: Bool) -> Data {
            if waitForEOF {
                readGroup.wait()
            }

            lock.lock()
            defer { lock.unlock() }
            return collectedData
        }
    }

    private nonisolated final class ProcessTerminationObserver: @unchecked Sendable {
        private let lock = NSLock()
        private var didTerminate = false
        private var nextWaiterID = 0
        private var waiters: [Int: CheckedContinuation<Bool, Never>] = [:]

        func processTerminated() {
            lock.lock()
            didTerminate = true
            let continuations = Array(waiters.values)
            waiters.removeAll()
            lock.unlock()

            continuations.forEach { $0.resume(returning: true) }
        }

        func wait(timeout: TimeInterval) async -> Bool {
            await withCheckedContinuation { continuation in
                let waiterID: Int

                lock.lock()
                if didTerminate {
                    lock.unlock()
                    continuation.resume(returning: true)
                    return
                }

                waiterID = nextWaiterID
                nextWaiterID += 1
                waiters[waiterID] = continuation
                lock.unlock()

                Task.detached { [self] in
                    try? await Task.sleep(nanoseconds: Self.nanoseconds(for: timeout))
                    resumeWaiter(id: waiterID, didTerminate: false)
                }
            }
        }

        private func resumeWaiter(id: Int, didTerminate: Bool) {
            lock.lock()
            let continuation = waiters.removeValue(forKey: id)
            lock.unlock()

            continuation?.resume(returning: didTerminate)
        }

        private static func nanoseconds(for timeout: TimeInterval) -> UInt64 {
            UInt64(max(0, timeout) * 1_000_000_000)
        }
    }

    private struct AppSecurityAssessment: Sendable {
        let result: AppSecurityAssessmentResult
        let tool: String
        let refinementTool: String?
        let reason: String
        let summary: String
        let exitStatus: Int32?
        let refinementExitStatus: Int32?
        let timedOut: Bool

        nonisolated init(
            result: AppSecurityAssessmentResult,
            tool: String,
            refinementTool: String?,
            reason: String,
            summary: String,
            exitStatus: Int32?,
            refinementExitStatus: Int32?,
            timedOut: Bool
        ) {
            self.result = result
            self.tool = tool
            self.refinementTool = refinementTool
            self.reason = reason
            self.summary = summary
            self.exitStatus = exitStatus
            self.refinementExitStatus = refinementExitStatus
            self.timedOut = timedOut
        }

        var manualFallbackReason: ManualFallbackReason {
            result == .blocked ? .securityAssessmentBlocked : .securityAssessmentUnverified
        }

        var supportDetails: [String: String] {
            var details = [
                "assessment_tool": tool,
                "assessment_result": result.rawValue,
                "assessment_reason": reason,
                "assessment_timeout": timedOut ? "true" : "false"
            ]

            if let refinementTool {
                details["assessment_refinement_tool"] = refinementTool
            }

            if let exitStatus {
                details["assessment_exit_status"] = String(exitStatus)
            }

            if let refinementExitStatus {
                details["assessment_refinement_exit_status"] = String(refinementExitStatus)
            }

            if !summary.isEmpty {
                details["assessment_summary"] = summary
            }

            return details
        }
    }

    private enum ApplicationsFolderIssue: String {
        case missing = "applications_missing"
        case notDirectory = "applications_not_directory"
        case notWritable = "applications_not_writable"

        var message: String {
            switch self {
            case .missing:
                return "/Applications folder does not exist"
            case .notDirectory:
                return "/Applications is not a directory"
            case .notWritable:
                return "/Applications folder is not writable"
            }
        }
    }

    private enum AppBundleValidationIssue: String {
        case missingInfoPlist = "missing_info_plist"
        case unreadableInfoPlist = "unreadable_info_plist"
        case notApplicationBundle = "not_application_bundle"
        case missingExecutableFile = "missing_executable_file"
        case executableNotExecutable = "executable_not_executable"
    }

    @Published var isProcessing = false
    private var currentFeedbackMode: FeedbackMode = .progressBar
    private var pendingDMGURLs: [URL] = []
    private var isDrainingQueue = false
    private var appManagementPermissionWindowController: AppManagementPermissionWindowController?
    private var didHandleAppManagementRestartRequest = false
    private var usedMagicMessages = Set<String>()

    // Progressive messages shown if an operation takes too long.
    private let magicMessageInterval: UInt64 = 4_000_000_000
    private let magicMessages = [
        "🪄 Invoking ancient hamster magic...",
        "Opening a high capacity portal 🎩...",
        "🐹 Hamster is strong, but app is big...",
        "I found a very interesting seed. One moment... 🌻",
        "Regenerating mana... 💧",
        "Trying to fit the whole app in one cheek... 🐹",
        "Doing laps on the wheel to power the CPU... 🎡",
        "The wizard is deep in trance. Do not startle! 🧘‍♂️",
        "Rearranging the nest for optimal performance... 🏠",
        "Consulting the Forbidden Scrolls... 📜",
        "One sec. Gotta wiggle my nose.",
        "Whispering the secret password to the Gatekeeper... 🔑",
        "Locating buried stash of magic beans... 🫘"
    ]

    private func diagnostic(_ message: @autoclosure () -> String) {
        DiagnosticLogger.shared.diagnostic(message())
    }

    private func support(event: String, details: [String: String] = [:]) {
        DiagnosticLogger.shared.support(event: event, details: details)
    }

    private func volumeName(from mountPoint: String) -> String {
        URL(fileURLWithPath: mountPoint).lastPathComponent
    }

    private func appName(from path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    private func appNames(from paths: [String]) -> [String] {
        paths.map(appName(from:))
    }

    private func joinedNames(_ names: [String]) -> String {
        names.joined(separator: "|")
    }

    private func boolString(_ value: Bool) -> String {
        value ? "true" : "false"
    }

    private func errorDetails(_ error: Error) -> [String: String] {
        let nsError = error as NSError
        return [
            "error_code": String(nsError.code),
            "error_domain": nsError.domain
        ]
    }

    private func recordCompletion(
        dmgName: String,
        outcome: String,
        details: [String: String] = [:]
    ) {
        var mergedDetails = details
        mergedDetails["dmg"] = dmgName
        mergedDetails["outcome"] = outcome
        support(event: "processing_complete", details: mergedDetails)
    }

    private func showProgress(_ message: String, progress: Double) {
        diagnostic("📝 \(message) (\(Int(progress * 100))%)")

        // Only show progress window if feedback mode is progress bar
        if currentFeedbackMode == .progressBar {
            ProgressWindowController.shared.update(message: message, progress: progress)
        }
    }

    private func resetMagicMessageSession() {
        usedMagicMessages.removeAll()
    }

    private func randomMagicMessage() -> String {
        if usedMagicMessages.count >= magicMessages.count {
            usedMagicMessages.removeAll()
        }

        let availableMessages = magicMessages.filter { !usedMagicMessages.contains($0) }
        let magicMessage = availableMessages.randomElement() ?? "Still working..."
        usedMagicMessages.insert(magicMessage)
        return magicMessage
    }

    private func startMagicFallbackTimer(progress: Double) -> Task<Void, Never> {
        Task { @MainActor [currentFeedbackMode] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: magicMessageInterval)
                guard !Task.isCancelled else { return }
                guard currentFeedbackMode == .progressBar else { continue }

                let magicMessage = randomMagicMessage()
                ProgressWindowController.shared.update(message: magicMessage, progress: progress)
                DiagnosticLogger.shared.diagnostic("📝 \(magicMessage) (\(Int(progress * 100))%)")
            }
        }
    }

    /// Runs a potentially slow operation with progressive fallback messages if it takes too long.
    /// Shows a random message at regular intervals to indicate the app is still working.
    private func withMagicFallback<T: Sendable>(
        message: String,
        progress: Double,
        operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        showProgress(message, progress: progress)

        // Run the operation on a background thread so timers can fire
        let operationTask = Task.detached(priority: .userInitiated) {
            try operation()
        }

        let timerTask = startMagicFallbackTimer(progress: progress)
        defer { timerTask.cancel() }

        return try await operationTask.value
    }

    /// Non-throwing version for operations that don't throw
    private func withMagicFallback<T: Sendable>(
        message: String,
        progress: Double,
        operation: @escaping @Sendable () -> T
    ) async -> T {
        showProgress(message, progress: progress)

        let operationTask = Task.detached(priority: .userInitiated) {
            operation()
        }

        let timerTask = startMagicFallbackTimer(progress: progress)
        defer { timerTask.cancel() }

        return await operationTask.value
    }

    /// Async version for operations that suspend while work continues elsewhere.
    private func withMagicFallback<T: Sendable>(
        message: String,
        progress: Double,
        operation: @escaping @Sendable () async -> T
    ) async -> T {
        showProgress(message, progress: progress)

        let operationTask = Task.detached(priority: .userInitiated) {
            await operation()
        }

        let timerTask = startMagicFallbackTimer(progress: progress)
        defer { timerTask.cancel() }

        return await operationTask.value
    }

    private func sendNotification(title: String, message: String) async {
        let notificationCenter = UNUserNotificationCenter.current()
        let settings = await notificationCenter.notificationSettings()
        diagnostic("Notification settings before send: \(settings.diagnosticDescription)")
        guard settings.canShowVisibleAlerts else {
            diagnostic("Skipping notification because visible alerts are unavailable")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = .default

        let identifier = UUID().uuidString
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)

        do {
            try await notificationCenter.add(request)
            diagnostic("✅ Notification scheduled immediately: \(identifier)")
            try? await Task.sleep(nanoseconds: 500_000_000)

            let deliveredNotifications = await notificationCenter.deliveredNotifications()
            if deliveredNotifications.contains(where: { $0.request.identifier == identifier }) {
                diagnostic("✅ Notification delivered: \(identifier)")
            } else {
                diagnostic("ℹ️ Notification not listed as delivered yet: \(identifier)")
            }
        } catch {
            diagnostic("❌ Notification error: \(error)")
        }
    }

    private func sendFailureNotificationIfAvailable(message: String) async {
        guard UserPreferences.shared.feedbackMode != .silent else {
            return
        }

        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.canShowVisibleAlerts else {
            diagnostic("Failure notification unavailable: \(settings.diagnosticDescription)")
            return
        }

        await sendNotification(title: "EasyDMG install failed", message: message)
    }

    private func sendManualFallbackNotificationIfAvailable(
        dmgName: String,
        appName: String? = nil,
        reason: ManualFallbackReason
    ) async {
        guard UserPreferences.shared.feedbackMode != .silent else {
            return
        }

        let resolvedName = manualFallbackAppName(explicit: appName, dmgName: dmgName)
        guard let message = reason.notificationMessage(appName: resolvedName) else {
            return
        }

        await sendNotification(
            title: reason.notificationTitle(appName: resolvedName),
            message: message
        )
    }

    /// Prefers the real bundle name when we have one (stripping `.app`), and otherwise
    /// falls back to the DMG's filename (stripping `.dmg`).
    private func manualFallbackAppName(explicit: String?, dmgName: String) -> String {
        if let explicit {
            let trimmed = (explicit as NSString)
                .deletingPathExtension
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        let strippedName = (dmgName as NSString)
            .deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return strippedName.isEmpty ? dmgName : strippedName
    }

    private func requestNotificationPermissionsIfNeeded() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()

        if settings.authorizationStatus == .notDetermined {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
    }

    // Get the effective feedback mode (fallback to progress bar if notifications cannot show banners)
    private func effectiveFeedbackMode() async -> FeedbackMode {
        let userMode = UserPreferences.shared.feedbackMode

        if userMode == .notification {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            if !settings.canShowVisibleAlerts {
                diagnostic("Notification feedback unavailable, falling back to progress bar: \(settings.diagnosticDescription)")
                return .progressBar
            }
        }

        return userMode
    }

    func enqueueDMGs(_ urls: [URL]) {
        guard !urls.isEmpty else {
            diagnostic("enqueueDMGs called with no DMG URLs")
            return
        }

        diagnostic("enqueueDMGs adding \(urls.count) URL(s); pending before add=\(pendingDMGURLs.count)")
        support(
            event: "queue_enqueue",
            details: [
                "dmg_count": String(urls.count),
                "dmg_names": joinedNames(urls.map(\.lastPathComponent)),
                "pending_before": String(pendingDMGURLs.count)
            ]
        )
        pendingDMGURLs.append(contentsOf: urls)

        guard !isDrainingQueue else {
            diagnostic("DMG queue already active; appended URL(s) for existing drain")
            return
        }

        isProcessing = true
        Task { @MainActor in
            await drainQueueIfNeeded()
        }
    }

    private func drainQueueIfNeeded() async {
        guard !isDrainingQueue else {
            return
        }

        isDrainingQueue = true
        isProcessing = true
        diagnostic("DMG queue started with \(pendingDMGURLs.count) pending URL(s)")
        support(event: "queue_start", details: ["pending_count": String(pendingDMGURLs.count)])

        while !pendingDMGURLs.isEmpty {
            let nextURL = pendingDMGURLs.removeFirst()
            diagnostic("Processing next DMG: \(nextURL.path); remaining after dequeue=\(pendingDMGURLs.count)")
            await processNextDMG(at: nextURL)
        }

        if didHandleAppManagementRestartRequest {
            diagnostic("Waiting briefly before quit after App Management restart request")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            didHandleAppManagementRestartRequest = false
        }

        isProcessing = false
        isDrainingQueue = false
        ProgressWindowController.shared.hide()

        diagnostic("✅ Processing queue complete, quitting app")
        NSApp.terminate(nil)
    }

    // Process a DMG file (main entry point)
    func processDMG(at url: URL) async {
        enqueueDMGs([url])
    }

    private func processNextDMG(at url: URL) async {
        let currentDMGName = url.lastPathComponent
        resetMagicMessageSession()
        diagnostic("processNextDMG started path=\(url.path)")
        support(event: "dmg_begin", details: ["dmg": currentDMGName])

        await requestNotificationPermissionsIfNeeded()

        currentFeedbackMode = await effectiveFeedbackMode()
        diagnostic("Effective feedback mode: \(currentFeedbackMode.rawValue)")
        support(
            event: "feedback_mode",
            details: ["dmg": currentDMGName, "mode": currentFeedbackMode.rawValue]
        )

        if currentFeedbackMode == .progressBar {
            ProgressWindowController.shared.show(message: "Preparing...", progress: 0.0)
        } else {
            ProgressWindowController.shared.hide()
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            diagnostic("DMG file missing before processing: \(url.path)")
            support(event: "processing_error", details: ["dmg": currentDMGName, "reason": "file_not_found"])
            recordCompletion(dmgName: currentDMGName, outcome: "error", details: ["reason": "file_not_found"])
            await handleError("File not found: \(url.lastPathComponent)")
            return
        }

        let mountPoint: String

        // Encrypted DMGs need special handling: a plain `hdiutil attach` — and even
        // the `imageinfo` license preflight — would surface the macOS SecurityAgent
        // password prompt and block on it, racing against our own progress flow.
        // Detect encryption up front with the header-only `isencrypted` check, then
        // gate the entire flow on our own password prompt so nothing (Gatekeeper
        // check, dialogs) proceeds until the user has entered the passphrase. The
        // license preflight is skipped for encrypted images — its metadata can't be
        // read without the passphrase anyway, and the post-mount guards still apply.
        if await isDMGEncrypted(at: url.path, dmgName: currentDMGName) {
            // resolveEncryptedMount handles cancel (abort), the macOS-prompt
            // handoff and genuine mount failures (manual) itself; nil means
            // processing should stop.
            guard let unlockedMountPoint = await resolveEncryptedMount(
                dmgPath: url.path,
                dmgName: currentDMGName
            ) else {
                return
            }
            mountPoint = unlockedMountPoint
        } else {
            if await hasLicenseAgreement(dmgPath: url.path, dmgName: currentDMGName) {
                await openForManualInstallation(
                    dmgPath: url.path,
                    dmgName: currentDMGName,
                    reason: .licenseRequired
                )
                return
            }

            switch await mountDMG(at: url.path, dmgName: currentDMGName, progress: 0.0) {
            case let .mounted(resolvedMountPoint, _):
                mountPoint = resolvedMountPoint

            case .passwordProtected:
                // Safety net: `isencrypted` didn't flag it, but the mount still
                // reported an authentication/passphrase failure. Route through our
                // own prompt (which also handles cancel/abort) rather than dropping
                // straight to manual.
                guard let resolvedMountPoint = await resolveEncryptedMount(
                    dmgPath: url.path,
                    dmgName: currentDMGName
                ) else {
                    return
                }
                mountPoint = resolvedMountPoint

            case .failed:
                await openForManualInstallation(
                    dmgPath: url.path,
                    dmgName: currentDMGName,
                    reason: .genericMountFailure
                )
                return
            }
        }

        showProgress("Scanning for apps...", progress: 0.2)
        let appFiles = findAppFiles(in: mountPoint)
        let packageFiles = findPackageFiles(in: mountPoint)

        if !packageFiles.isEmpty {
            let packageNames = appNames(from: packageFiles)
            diagnostic("Manual fallback: package installer(s) found: \(packageNames)")
            await openForManualInstallation(
                mountPoint: mountPoint,
                dmgName: currentDMGName,
                reason: .packageInstaller,
                details: [
                    "app_count": String(appFiles.count),
                    "package_count": String(packageFiles.count),
                    "package_names": joinedNames(packageNames),
                    "volume": volumeName(from: mountPoint)
                ]
            )
            return
        }

        let mainApps = appFiles.filter { path in
            !isInstallerLikeApp(at: path)
        }

        let finalAppFiles = mainApps.count == 1 ? mainApps : appFiles
        let finalAppNames = appNames(from: finalAppFiles)
        support(
            event: "app_scan_result",
            details: [
                "app_count": String(finalAppFiles.count),
                "app_names": joinedNames(finalAppNames),
                "dmg": currentDMGName,
                "package_count": String(packageFiles.count),
                "raw_app_count": String(appFiles.count),
                "volume": volumeName(from: mountPoint)
            ]
        )

        switch finalAppFiles.count {
        case 0:
            diagnostic("Manual fallback: no .app files found at \(mountPoint)")
            await openForManualInstallation(
                mountPoint: mountPoint,
                dmgName: currentDMGName,
                reason: .noAppFound,
                details: [
                    "app_count": "0",
                    "volume": volumeName(from: mountPoint)
                ]
            )
            return

        case 1:
            let appPath = finalAppFiles[0]
            if isInstallerLikeApp(at: appPath) {
                let candidateName = appName(from: appPath)
                diagnostic("Manual fallback: single app looks like an installer or auxiliary app: \(candidateName)")
                await openForManualInstallation(
                    mountPoint: mountPoint,
                    dmgName: currentDMGName,
                    reason: .installerOrAuxiliaryApp,
                    appName: candidateName,
                    details: [
                        "app": candidateName,
                        "app_count": "1",
                        "volume": volumeName(from: mountPoint)
                    ]
                )
                return
            }

            if let issue = appBundleValidationIssue(for: appPath) {
                let candidateName = appName(from: appPath)
                diagnostic("Manual fallback: invalid app bundle (\(issue.rawValue)): \(candidateName)")
                await openForManualInstallation(
                    mountPoint: mountPoint,
                    dmgName: currentDMGName,
                    reason: .invalidAppBundle,
                    appName: candidateName,
                    details: [
                        "app": candidateName,
                        "app_count": "1",
                        "validation_issue": issue.rawValue,
                        "volume": volumeName(from: mountPoint)
                    ]
                )
                return
            }

            diagnostic("Installing: \(appName(from: appPath)) from \(appPath)")
            await installApp(from: appPath, mountPoint: mountPoint, dmgPath: url.path, dmgName: currentDMGName)

        default:
            diagnostic("Manual fallback: multiple .app files found (\(finalAppFiles.count)): \(finalAppNames)")
            await openForManualInstallation(
                mountPoint: mountPoint,
                dmgName: currentDMGName,
                reason: .multipleAppsFound,
                details: [
                    "app_count": String(finalAppFiles.count),
                    "app_names": joinedNames(finalAppNames),
                    "volume": volumeName(from: mountPoint)
                ]
            )
            return
        }
    }

    /// Returns true if the DMG is encrypted (password-protected). Uses
    /// `hdiutil isencrypted`, which reads only the image header — it never needs
    /// the passphrase and never raises a prompt (unlike `attach`/`imageinfo`, which
    /// surface the macOS SecurityAgent prompt on an encrypted image). On any error
    /// we default to `false` so a DMG we can't classify falls through to the normal
    /// mount path rather than wrongly demanding a password.
    private func isDMGEncrypted(at path: String, dmgName: String) async -> Bool {
        let result: AssessmentProcessResult
        do {
            result = try await runAssessmentProcess(
                executableURL: URL(fileURLWithPath: "/usr/bin/hdiutil"),
                arguments: ["isencrypted", path],
                timeout: 10
            )
        } catch {
            diagnostic("Error checking DMG encryption: \(error)")
            support(event: "encryption_preflight", details: ["dmg": dmgName, "result": "error"])
            return false
        }

        guard !result.timedOut, result.exitStatus == 0 else {
            let outcome = result.timedOut ? "timeout" : "failed"
            diagnostic(
                "Encryption check \(outcome): \(DiagnosticLogger.compact(result.standardError))"
            )
            support(event: "encryption_preflight", details: ["dmg": dmgName, "result": outcome])
            return false
        }

        let encrypted = result.standardOutput.lowercased().contains("encrypted: yes")
        diagnostic("Encryption check result: \(encrypted ? "encrypted" : "not_encrypted")")
        support(
            event: "encryption_preflight",
            details: ["dmg": dmgName, "result": encrypted ? "encrypted" : "not_encrypted"]
        )
        return encrypted
    }

    private func hasLicenseAgreement(dmgPath: String, dmgName: String) async -> Bool {
        diagnostic("Checking disk image metadata for license agreement: \(dmgPath)")

        let result: AssessmentProcessResult
        do {
            result = try await runAssessmentProcess(
                executableURL: URL(fileURLWithPath: "/usr/bin/hdiutil"),
                arguments: ["imageinfo", dmgPath, "-plist"],
                timeout: 10
            )
        } catch {
            diagnostic("Error checking for license: \(error)")
            support(
                event: "license_preflight",
                details: ["dmg": dmgName, "result": "error"]
            )
            return false
        }

        guard !result.timedOut, result.exitStatus == 0 else {
            let outcome = result.timedOut ? "imageinfo_timeout" : "imageinfo_failed"
            let exitStatus = result.exitStatus.map { String($0) } ?? "none"
            diagnostic(
                "License metadata check \(outcome) (status \(exitStatus)): "
                + DiagnosticLogger.compact(result.standardError)
            )
            support(
                event: "license_preflight",
                details: [
                    "dmg": dmgName,
                    "result": outcome,
                    "exit_status": exitStatus
                ]
            )
            return false
        }

        do {
            let data = Data(result.standardOutput.utf8)
            let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            let hasLicense = Self.plistContainsLicenseAgreement(plist)
            diagnostic("License metadata check result: \(hasLicense ? "license_required" : "none")")
            support(
                event: "license_preflight",
                details: [
                    "dmg": dmgName,
                    "result": hasLicense ? "license_required" : "none"
                ]
            )
            return hasLicense
        } catch {
            diagnostic("Error parsing license metadata: \(error)")
            support(
                event: "license_preflight",
                details: ["dmg": dmgName, "result": "parse_error"]
            )
            return false
        }
    }

    private nonisolated static func plistContainsLicenseAgreement(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            for (key, childValue) in dictionary {
                let normalizedKey = key
                    .lowercased()
                    .filter { $0.isLetter || $0.isNumber }

                if normalizedKey == "softwarelicenseagreement" &&
                    plistValueIsTrue(childValue) {
                    return true
                }

                if plistContainsLicenseAgreement(childValue) {
                    return true
                }
            }
        } else if let array = value as? [Any] {
            for childValue in array where plistContainsLicenseAgreement(childValue) {
                return true
            }
        }

        return false
    }

    private nonisolated static func plistValueIsTrue(_ value: Any) -> Bool {
        if let boolValue = value as? Bool {
            return boolValue
        }

        if let numberValue = value as? NSNumber {
            return numberValue.boolValue
        }

        return false
    }

    private nonisolated static func parseMountPoint(fromAttachPlist data: Data) -> String? {
        do {
            let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            guard let root = plist as? [String: Any],
                  let systemEntities = root["system-entities"] as? [[String: Any]] else {
                DiagnosticLogger.shared.diagnostic("hdiutil plist missing expected system-entities structure")
                return nil
            }

            for entity in systemEntities {
                if let mountPoint = entity["mount-point"] as? String, !mountPoint.isEmpty {
                    DiagnosticLogger.shared.diagnostic("Parsed mount point from plist: \(mountPoint)")
                    return mountPoint
                }
            }

            DiagnosticLogger.shared.diagnostic("No mount-point found in hdiutil plist output")
            return nil
        } catch {
            DiagnosticLogger.shared.diagnostic("Failed to parse hdiutil plist output: \(error)")
            return nil
        }
    }

    private func mountDMG(at path: String, dmgName: String, progress: Double) async -> MountResult {
        diagnostic("Mounting DMG: \(path)")
        support(event: "mount_start", details: ["dmg": dmgName])

        let result = await withMagicFallback(
            message: "Mounting disk image...",
            progress: progress
        ) {
            let processResult: AssessmentProcessResult
            do {
                processResult = try await self.runAssessmentProcess(
                    executableURL: URL(fileURLWithPath: "/usr/bin/hdiutil"),
                    arguments: ["attach", path, "-nobrowse", "-readonly", "-noautoopen", "-plist"],
                    timeout: 60
                )
            } catch {
                DiagnosticLogger.shared.diagnostic("Error mounting DMG: \(error)")
                return MountResult.failed(exitStatus: nil)
            }

            guard !processResult.timedOut, processResult.exitStatus == 0 else {
                let rawErrorOutput = processResult.standardError
                let errorOutput = rawErrorOutput.lowercased()
                let resultLabel = processResult.timedOut
                    ? "timeout"
                    : "status \(processResult.exitStatus.map { String($0) } ?? "unknown")"
                DiagnosticLogger.shared.diagnostic("Mount failed with \(resultLabel)")
                if !rawErrorOutput.isEmpty {
                    DiagnosticLogger.shared.diagnostic(
                        "hdiutil attach stderr: \(DiagnosticLogger.compact(rawErrorOutput))"
                    )
                }

                if errorOutput.contains("authentication") ||
                    errorOutput.contains("passphrase") ||
                    errorOutput.contains("encrypted") {
                    DiagnosticLogger.shared.diagnostic(
                        "Manual fallback classification: password protected or encrypted DMG"
                    )
                    return MountResult.passwordProtected(exitStatus: processResult.exitStatus ?? -1)
                }

                return MountResult.failed(exitStatus: processResult.exitStatus)
            }

            DiagnosticLogger.shared.diagnostic("hdiutil attach succeeded")
            if !processResult.standardOutput.isEmpty {
                DiagnosticLogger.shared.diagnostic(
                    "hdiutil stdout: \(DiagnosticLogger.compact(processResult.standardOutput))"
                )
            }

            let data = Data(processResult.standardOutput.utf8)
            guard let mountPoint = Self.parseMountPoint(fromAttachPlist: data) else {
                return MountResult.failed(exitStatus: processResult.exitStatus)
            }

            return MountResult.mounted(mountPoint: mountPoint, exitStatus: processResult.exitStatus ?? 0)
        }

        var details = ["dmg": dmgName]
        switch result {
        case let .mounted(mountPoint, exitStatus):
            details["exit_status"] = String(exitStatus)
            details["result"] = "success"
            details["volume"] = volumeName(from: mountPoint)

        case let .passwordProtected(exitStatus):
            details["exit_status"] = String(exitStatus)
            details["result"] = "password_protected"

        case let .failed(exitStatus):
            if let exitStatus {
                details["exit_status"] = String(exitStatus)
            }
            details["result"] = "failed"
        }
        support(event: "mount_result", details: details)

        return result
    }

    /// Prompt for the DMG passphrase and attempt an authenticated mount, retrying
    /// on a wrong password as many times as the user wants. The distinct outcomes
    /// let the caller honor the user's intent: a cancel aborts the install rather
    /// than dropping to the manual flow (which would only re-show a password prompt
    /// the user just dismissed), while opting into the macOS prompt hands the DMG
    /// to DiskImageMounter. After two failed attempts the prompt offers that escape
    /// hatch in case our own field can't unlock an image macOS itself could.
    private func unlockEncryptedDMG(dmgPath: String, dmgName: String) async -> EncryptedUnlockOutcome {
        // Number of wrong-password attempts after which we surface the "Use macOS
        // Password Prompt…" button on the dialog.
        let attemptsBeforeSystemFallback = 2
        var attempt = 1
        while true {
            let offerSystemPrompt = attempt > attemptsBeforeSystemFallback
            // Keep one steady message behind the prompt across every attempt rather
            // than flipping between "Preparing…" and "Unlocking disk image…".
            showProgress("Enter password to continue...", progress: 0.0)
            switch await promptForDMGPassword(
                dmgName: dmgName,
                isRetry: attempt > 1,
                offerSystemPrompt: offerSystemPrompt
            ) {
            case .cancelled:
                diagnostic("Password entry cancelled (attempt \(attempt))")
                support(event: "password_unlock", details: ["dmg": dmgName, "result": "cancelled", "attempt": String(attempt)])
                return .cancelled

            case .useSystemPrompt:
                diagnostic("User chose the macOS password prompt (attempt \(attempt))")
                support(event: "password_unlock", details: ["dmg": dmgName, "result": "use_system_prompt", "attempt": String(attempt)])
                return .useSystemPrompt

            case let .password(password):
                switch await checkEncryptedLicenseAgreement(dmgPath: dmgPath, dmgName: dmgName, password: password) {
                case .noLicense:
                    break

                case .licenseRequired:
                    support(event: "password_unlock", details: ["dmg": dmgName, "result": "license_required", "attempt": String(attempt)])
                    return .licenseRequired

                case .wrongPassword:
                    diagnostic("Incorrect DMG password during metadata check (attempt \(attempt))")
                    support(event: "password_unlock", details: ["dmg": dmgName, "result": "wrong_password", "attempt": String(attempt)])
                    attempt += 1
                    continue

                case .failed:
                    // Match the unencrypted path: a metadata hiccup alone should not
                    // block an otherwise valid quick install.
                    support(event: "password_unlock", details: ["dmg": dmgName, "result": "license_preflight_failed_continue", "attempt": String(attempt)])
                    break
                }

                switch await mountEncryptedDMG(at: dmgPath, dmgName: dmgName, password: password) {
                case let .mounted(mountPoint):
                    support(event: "password_unlock", details: ["dmg": dmgName, "result": "success", "attempt": String(attempt)])
                    return .unlocked(mountPoint: mountPoint)
                case .wrongPassword:
                    diagnostic("Incorrect DMG password (attempt \(attempt))")
                    support(event: "password_unlock", details: ["dmg": dmgName, "result": "wrong_password", "attempt": String(attempt)])
                    attempt += 1
                    continue
                case .failed:
                    support(event: "password_unlock", details: ["dmg": dmgName, "result": "mount_failed", "attempt": String(attempt)])
                    return .failed
                }
            }
        }
    }

    /// Resolve an encrypted DMG to a mount point, handling each unlock outcome.
    /// Returns the mount point to continue installing, or `nil` if processing
    /// should stop because the outcome was already handled (aborted on cancel,
    /// handed to the macOS prompt, or routed to manual on a genuine mount failure).
    private func resolveEncryptedMount(dmgPath: String, dmgName: String) async -> String? {
        switch await unlockEncryptedDMG(dmgPath: dmgPath, dmgName: dmgName) {
        case let .unlocked(mountPoint):
            return mountPoint

        case .cancelled:
            abortEncryptedInstall(dmgName: dmgName, reason: "password_canceled")
            return nil

        case .useSystemPrompt:
            // The user asked to let macOS handle the passphrase: hand the DMG to
            // DiskImageMounter, which surfaces the system SecurityAgent prompt. No
            // notification — the user made this choice deliberately and the handoff
            // is self-evident.
            await openForManualInstallation(
                dmgPath: dmgPath,
                dmgName: dmgName,
                reason: .passwordProtected,
                notify: false
            )
            return nil

        case .licenseRequired:
            await openForManualInstallation(
                dmgPath: dmgPath,
                dmgName: dmgName,
                reason: .licenseRequired
            )
            return nil

        case .failed:
            // A genuine (non-authentication) mount failure isn't a password
            // problem, so the manual flow is the right place to land.
            await openForManualInstallation(
                dmgPath: dmgPath,
                dmgName: dmgName,
                reason: .genericMountFailure
            )
            return nil
        }
    }

    /// Stop processing an encrypted DMG without falling back to manual. Used when
    /// the user cancels the password prompt: re-opening the DMG would just surface
    /// another password prompt, ignoring their intent.
    private func abortEncryptedInstall(dmgName: String, reason: String) {
        diagnostic("Encrypted DMG install aborted (\(reason)); stopping without manual fallback")
        ProgressWindowController.shared.hide()
        recordCompletion(dmgName: dmgName, outcome: "canceled", details: ["reason": reason])
    }

    /// Check encrypted DMG metadata using the passphrase the user just entered.
    /// This preserves the license-agreement guard without invoking the system
    /// password prompt before EasyDMG's own retry loop has made progress.
    private func checkEncryptedLicenseAgreement(
        dmgPath: String,
        dmgName: String,
        password: String
    ) async -> AuthenticatedLicenseCheckResult {
        diagnostic("Checking encrypted disk image metadata for license agreement: \(dmgPath)")

        var passphrase = Data(password.utf8)
        passphrase.append(0)

        let result: AssessmentProcessResult
        do {
            result = try await runAssessmentProcess(
                executableURL: URL(fileURLWithPath: "/usr/bin/hdiutil"),
                arguments: ["imageinfo", dmgPath, "-stdinpass", "-plist"],
                timeout: 10,
                standardInput: passphrase
            )
        } catch {
            diagnostic("Error checking encrypted DMG metadata for license: \(error)")
            support(
                event: "license_preflight",
                details: ["dmg": dmgName, "result": "encrypted_error"]
            )
            return .failed
        }

        guard !result.timedOut, result.exitStatus == 0 else {
            let stderrLower = result.standardError.lowercased()
            let looksLikeAuthFailure = stderrLower.contains("authentication")
                || stderrLower.contains("passphrase")
                || stderrLower.contains("password")
            let outcome = result.timedOut
                ? "encrypted_imageinfo_timeout"
                : (looksLikeAuthFailure ? "wrong_password" : "encrypted_imageinfo_failed")
            let exitStatus = result.exitStatus.map { String($0) } ?? "none"
            diagnostic(
                "Encrypted license metadata check \(outcome): "
                    + DiagnosticLogger.compact(result.standardError)
            )
            support(
                event: "license_preflight",
                details: [
                    "dmg": dmgName,
                    "result": outcome,
                    "exit_status": exitStatus
                ]
            )
            return looksLikeAuthFailure ? .wrongPassword : .failed
        }

        do {
            let data = Data(result.standardOutput.utf8)
            let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            let hasLicense = Self.plistContainsLicenseAgreement(plist)
            diagnostic("Encrypted license metadata check result: \(hasLicense ? "license_required" : "none")")
            support(
                event: "license_preflight",
                details: [
                    "dmg": dmgName,
                    "result": hasLicense ? "license_required" : "none",
                    "encrypted": "true"
                ]
            )
            return hasLicense ? .licenseRequired : .noLicense
        } catch {
            diagnostic("Error parsing encrypted license metadata plist: \(error)")
            support(
                event: "license_preflight",
                details: ["dmg": dmgName, "result": "encrypted_parse_error"]
            )
            return .failed
        }
    }

    /// Mount an encrypted DMG using a passphrase supplied over stdin
    /// (`hdiutil -stdinpass`). The passphrase never touches argv — where it would
    /// be visible in `ps` — and is never written to the diagnostic log.
    private func mountEncryptedDMG(at path: String, dmgName: String, password: String) async -> AuthenticatedMountResult {
        diagnostic("Attempting authenticated mount for \(dmgName)...")
        support(event: "authenticated_mount_start", details: ["dmg": dmgName])

        // hdiutil -stdinpass expects a null-terminated passphrase.
        var passphrase = Data(password.utf8)
        passphrase.append(0)

        let result: AssessmentProcessResult
        do {
            result = try await runAssessmentProcess(
                executableURL: URL(fileURLWithPath: "/usr/bin/hdiutil"),
                arguments: ["attach", path, "-stdinpass", "-nobrowse", "-readonly", "-noautoopen", "-plist"],
                timeout: 60,
                standardInput: passphrase
            )
        } catch {
            diagnostic("Authenticated mount error: \(error)")
            support(event: "authenticated_mount_result", details: ["dmg": dmgName, "result": "error"])
            return .failed
        }

        guard !result.timedOut, result.exitStatus == 0 else {
            let stderrLower = result.standardError.lowercased()
            // A wrong passphrase makes hdiutil exit with an "Authentication error";
            // treat auth-flavored failures as retryable and anything else (corrupt
            // image, I/O failure) as a hard failure that drops to manual.
            let looksLikeAuthFailure = stderrLower.contains("authentication")
                || stderrLower.contains("passphrase")
                || stderrLower.contains("password")
            let resultLabel = result.timedOut
                ? "timeout"
                : (looksLikeAuthFailure ? "wrong_password" : "failed")
            diagnostic("Authenticated mount did not succeed: \(resultLabel)")
            if !result.standardError.isEmpty {
                diagnostic("hdiutil -stdinpass stderr: \(DiagnosticLogger.compact(result.standardError))")
            }
            support(event: "authenticated_mount_result", details: ["dmg": dmgName, "result": resultLabel])
            return looksLikeAuthFailure ? .wrongPassword : .failed
        }

        guard let mountPoint = Self.parseMountPoint(fromAttachPlist: Data(result.standardOutput.utf8)) else {
            diagnostic("Authenticated mount succeeded but no mount point was found")
            support(event: "authenticated_mount_result", details: ["dmg": dmgName, "result": "no_mount_point"])
            return .failed
        }

        diagnostic("Authenticated mount succeeded")
        support(
            event: "authenticated_mount_result",
            details: ["dmg": dmgName, "result": "success", "volume": volumeName(from: mountPoint)]
        )
        return .mounted(mountPoint: mountPoint)
    }

    /// Ask the user for an encrypted DMG's passphrase. Returns the entered string,
    /// a request to hand off to the macOS prompt, or a cancel. The entry field masks
    /// input and the value is never logged. Presented as a hosted sheet so it survives
    /// the background `.accessory` activation state (see `presentHostedAlert`).
    ///
    /// When `offerSystemPrompt` is true the dialog gains a "Use macOS Password Prompt…"
    /// button — an escape hatch after repeated wrong passwords that lets the system
    /// SecurityAgent take over via DiskImageMounter.
    private func promptForDMGPassword(
        dmgName: String,
        isRetry: Bool,
        offerSystemPrompt: Bool
    ) async -> PasswordPromptChoice {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let displayName = dmgName.strippingDMGSuffix
                let alert = NSAlert()
                alert.alertStyle = isRetry ? .warning : .informational
                alert.messageText = "“\(displayName)” is password-protected"
                alert.informativeText = isRetry
                    ? "Incorrect password. Enter the password to unlock this disk image."
                    : "Enter the password to unlock this disk image."

                if let iconPath = Bundle.main.path(forResource: "wizardhamster", ofType: "icns"),
                   let icon = NSImage(contentsOfFile: iconPath) {
                    alert.icon = icon
                }

                let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
                passwordField.placeholderString = "Password"
                alert.accessoryView = passwordField
                // Focus the field as soon as the sheet appears so the user can type
                // immediately and press Return to submit.
                alert.window.initialFirstResponder = passwordField

                // Buttons map to responses by add order: first = .alertFirstButtonReturn,
                // and so on. The optional system-prompt button sits between Unlock and
                // Cancel so Cancel stays the last (and Escape-mapped) button.
                alert.addButton(withTitle: "Unlock")
                if offerSystemPrompt {
                    alert.addButton(withTitle: "Use macOS Password Prompt…")
                }
                alert.addButton(withTitle: "Cancel")

                presentHostedAlert(alert) { response in
                    switch response {
                    case .alertFirstButtonReturn:
                        continuation.resume(returning: .password(passwordField.stringValue))
                    case .alertSecondButtonReturn where offerSystemPrompt:
                        continuation.resume(returning: .useSystemPrompt)
                    default:
                        continuation.resume(returning: .cancelled)
                    }
                }
            }
        }
    }

    private func calculateAppSize(at path: String) -> UInt64 {
        guard let enumerator = FileManager.default.enumerator(atPath: path) else {
            return 0
        }

        var totalSize: UInt64 = 0
        for case let file as String in enumerator {
            let filePath = (path as NSString).appendingPathComponent(file)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
               let fileSize = attrs[.size] as? UInt64 {
                totalSize += fileSize
            }
        }
        return totalSize
    }

    private func hasEnoughDiskSpace(requiredBytes: UInt64) -> Bool {
        let appFolderPath = "/Applications"
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: appFolderPath),
              let freeSpace = attrs[.systemFreeSize] as? UInt64 else {
            return true
        }

        let bufferSize: UInt64 = 500 * 1024 * 1024
        return freeSpace > (requiredBytes + bufferSize)
    }

    private func validateApplicationsFolder() -> ApplicationsFolderIssue? {
        let appFolder = "/Applications"

        guard FileManager.default.fileExists(atPath: appFolder) else {
            return .missing
        }

        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: appFolder, isDirectory: &isDirectory)
        guard isDirectory.boolValue else {
            return .notDirectory
        }

        guard FileManager.default.isWritableFile(atPath: appFolder) else {
            return .notWritable
        }

        return nil
    }

    private func stagedAppURL(for appName: String) -> URL {
        let stagedName = ".easydmg-\(UUID().uuidString)-\(appName)"
        return URL(fileURLWithPath: "/Applications").appendingPathComponent(stagedName)
    }

    private func cleanupStagedAppIfNeeded(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            diagnostic("Warning: Failed to clean up staged app: \(error)")
        }
    }

    @discardableResult
    private func trashDMGIfNeeded(at dmgPath: String, shouldTrash: Bool, dmgName: String) -> Bool {
        guard shouldTrash else {
            support(event: "trash_result", details: ["dmg": dmgName, "result": "kept"])
            return false
        }

        let dmgURL = URL(fileURLWithPath: dmgPath)
        do {
            try FileManager.default.trashItem(at: dmgURL, resultingItemURL: nil)
            diagnostic("Moved DMG to Trash: \(dmgPath)")
            support(event: "trash_result", details: ["dmg": dmgName, "result": "trashed"])
            return true
        } catch {
            diagnostic("Warning: Failed to move DMG to trash: \(error)")
            support(
                event: "trash_result",
                details: errorDetails(error).merging([
                    "dmg": dmgName,
                    "result": "failed"
                ]) { current, _ in current }
            )
            return false
        }
    }

    private func findAppFiles(in mountPoint: String) -> [String] {
        let fileManager = FileManager.default
        var appFiles: [String] = []

        do {
            let contents = try fileManager.contentsOfDirectory(atPath: mountPoint)
            diagnostic("Mount point contents: \(contents)")
            for item in contents where (item as NSString).pathExtension.lowercased() == "app" && !item.hasPrefix(".") {
                let fullPath = (mountPoint as NSString).appendingPathComponent(item)
                appFiles.append(fullPath)
            }
        } catch {
            diagnostic("Error scanning mount point: \(error)")
        }

        diagnostic("Found \(appFiles.count) .app file(s): \(appFiles)")
        return appFiles
    }

    private func findPackageFiles(in mountPoint: String) -> [String] {
        let fileManager = FileManager.default
        var packageFiles: [String] = []

        do {
            let contents = try fileManager.contentsOfDirectory(atPath: mountPoint)
            for item in contents where !item.hasPrefix(".") {
                let pathExtension = (item as NSString).pathExtension.lowercased()
                if pathExtension == "pkg" || pathExtension == "mpkg" {
                    let fullPath = (mountPoint as NSString).appendingPathComponent(item)
                    packageFiles.append(fullPath)
                }
            }
        } catch {
            diagnostic("Error scanning mount point for packages: \(error)")
        }

        diagnostic("Found \(packageFiles.count) package installer file(s): \(packageFiles)")
        return packageFiles
    }

    private func isInstallerLikeApp(at path: String) -> Bool {
        let normalizedName = URL(fileURLWithPath: path)
            .deletingPathExtension()
            .lastPathComponent
            .lowercased()
        let words = Set(
            normalizedName
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )
        let compactName = normalizedName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()

        return words.contains("install") ||
            words.contains("installer") ||
            words.contains("setup") ||
            words.contains("uninstall") ||
            words.contains("uninstaller") ||
            words.contains("helper") ||
            words.contains("readme") ||
            (words.contains("read") && words.contains("me")) ||
            compactName.hasSuffix("installer") ||
            compactName.hasSuffix("uninstaller") ||
            compactName.hasSuffix("setup") ||
            compactName.hasSuffix("helper") ||
            compactName.hasSuffix("readme")
    }

    private func appBundleValidationIssue(for path: String) -> AppBundleValidationIssue? {
        let appURL = URL(fileURLWithPath: path)
        let infoPlistURL = appURL.appendingPathComponent("Contents/Info.plist")

        guard FileManager.default.fileExists(atPath: infoPlistURL.path) else {
            return .missingInfoPlist
        }

        guard let data = try? Data(contentsOf: infoPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let info = plist as? [String: Any] else {
            return .unreadableInfoPlist
        }

        // CFBundlePackageType is optional; macOS treats a `.app` as an application even
        // when it is absent. Only reject a deliberate non-application type (e.g. FMWK or
        // BNDL), never a missing/blank value. Trim first so a stray " APPL " still counts.
        if let rawPackageType = info["CFBundlePackageType"] as? String {
            let packageType = rawPackageType.trimmingCharacters(in: .whitespacesAndNewlines)
            if !packageType.isEmpty, packageType != "APPL" {
                return .notApplicationBundle
            }
        }

        // CFBundleExecutable is also optional. When it is missing or blank, macOS falls
        // back to the bundle's base name (ScreenKite.app -> Contents/MacOS/ScreenKite).
        let declaredExecutable = (info["CFBundleExecutable"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleBaseName = appURL.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let executableName: String
        if let declaredExecutable, !declaredExecutable.isEmpty {
            executableName = declaredExecutable
        } else {
            executableName = bundleBaseName
        }

        let executableURL = appURL
            .appendingPathComponent("Contents/MacOS")
            .appendingPathComponent(executableName)
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: executableURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return .missingExecutableFile
        }

        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return .executableNotExecutable
        }

        return nil
    }

    private func installApp(from appPath: String, mountPoint: String, dmgPath: String, dmgName: String) async {
        let resolvedAppName = appName(from: appPath)
        let destinationURL = URL(fileURLWithPath: "/Applications/\(resolvedAppName)")
        let destinationPath = destinationURL.path
        let stagedURL = stagedAppURL(for: resolvedAppName)
        var shouldReplaceExistingApp = false

        if let issue = validateApplicationsFolder() {
            diagnostic("Applications folder validation failed: \(issue.message)")
            support(
                event: "install_result",
                details: [
                    "app": resolvedAppName,
                    "dmg": dmgName,
                    "reason": issue.rawValue,
                    "result": "failed"
                ]
            )
            recordCompletion(
                dmgName: dmgName,
                outcome: "error",
                details: ["app": resolvedAppName, "reason": issue.rawValue]
            )
            await handleError(issue.message)
            _ = await unmountDMG(at: mountPoint, dmgName: dmgName)
            return
        }

        if FileManager.default.fileExists(atPath: destinationPath) {
            diagnostic("Destination app already exists: \(destinationPath)")
            support(event: "destination_exists", details: ["app": resolvedAppName, "dmg": dmgName])
            let installedVersion = appVersion(at: destinationPath)
            let newVersion = appVersion(at: appPath)
            let versionComparison = replacementVersionComparison(
                installedVersion: installedVersion,
                newVersion: newVersion
            )

            let shouldReplace: Bool
            if versionComparison == .newer && UserPreferences.shared.autoInstallNewerVersions {
                diagnostic("Auto-installing newer version of \(resolvedAppName): v\(installedVersion ?? "?") -> v\(newVersion ?? "?")")
                support(
                    event: "auto_install_newer",
                    details: [
                        "app": resolvedAppName,
                        "dmg": dmgName,
                        "installed_version": installedVersion ?? "",
                        "new_version": newVersion ?? ""
                    ]
                )
                shouldReplace = true
            } else {
                shouldReplace = await showSkipReplaceDialog(
                    appName: resolvedAppName,
                    installedVersion: installedVersion,
                    newVersion: newVersion
                )
            }

            if !shouldReplace {
                diagnostic("Installation canceled by user")
                support(
                    event: "install_decision",
                    details: ["action": "cancel", "app": resolvedAppName, "dmg": dmgName]
                )
                let didTrashDMG = await unmountAndCleanup(
                    mountPoint: mountPoint,
                    dmgPath: dmgPath,
                    dmgName: dmgName,
                    shouldTrashDMG: UserPreferences.shared.autoTrashDMG
                )

                if currentFeedbackMode == .notification && didTrashDMG {
                    await sendNotification(
                        title: "EasyDMG",
                        message: "\(resolvedAppName.strippingAppSuffix) install canceled; disk image moved to Trash"
                    )
                }

                ProgressWindowController.shared.hide()
                recordCompletion(
                    dmgName: dmgName,
                    outcome: "canceled",
                    details: [
                        "app": resolvedAppName,
                        "trashed_dmg": boolString(didTrashDMG)
                    ]
                )
                return
            }

            shouldReplaceExistingApp = true
            diagnostic("User chose to replace existing app")
            support(
                event: "install_decision",
                details: ["action": "replace", "app": resolvedAppName, "dmg": dmgName]
            )

            if currentFeedbackMode == .progressBar {
                ProgressWindowController.shared.show(message: "Preparing replacement...", progress: 0.2)
            }
        }

        // Quit any running instance before installing — otherwise the OS keeps the running
        // process bound to the old bundle and "Open after install" activates the stale copy.
        if let bundleID = bundleIdentifier(at: appPath) {
            let canProceed = await quitIfRunning(
                appName: resolvedAppName,
                bundleID: bundleID,
                dmgName: dmgName
            )
            if !canProceed {
                diagnostic("Installation canceled at running-app prompt for \(resolvedAppName)")
                let didTrashDMG = await unmountAndCleanup(
                    mountPoint: mountPoint,
                    dmgPath: dmgPath,
                    dmgName: dmgName,
                    shouldTrashDMG: UserPreferences.shared.autoTrashDMG
                )

                if currentFeedbackMode == .notification && didTrashDMG {
                    await sendNotification(
                        title: "EasyDMG",
                        message: "\(resolvedAppName.strippingAppSuffix) install canceled; disk image moved to Trash"
                    )
                }

                ProgressWindowController.shared.hide()
                recordCompletion(
                    dmgName: dmgName,
                    outcome: "skipped",
                    details: [
                        "app": resolvedAppName,
                        "reason": "running_app_canceled",
                        "trashed_dmg": boolString(didTrashDMG)
                    ]
                )
                return
            }
        }

        // Pre-flight App Management TCC check before modifying an existing app bundle —
        // without this permission, replacing an app in /Applications fails mid-install and
        // the user just sees a generic "install failed". Probe non-destructively first.
        if shouldReplaceExistingApp {
            let modificationPreflight = await ensureAppManagementPermission(
                forExistingAppAt: destinationPath,
                appName: resolvedAppName,
                dmgName: dmgName
            )
            if case let .blocked(reason) = modificationPreflight {
                diagnostic("Installation canceled before replacing \(resolvedAppName): \(reason)")
                let didTrashDMG = await unmountAndCleanup(
                    mountPoint: mountPoint,
                    dmgPath: dmgPath,
                    dmgName: dmgName,
                    shouldTrashDMG: UserPreferences.shared.autoTrashDMG
                )

                if currentFeedbackMode == .notification && didTrashDMG {
                    await sendNotification(
                        title: "EasyDMG",
                        message: "\(resolvedAppName.strippingAppSuffix) install canceled; disk image moved to Trash"
                    )
                }

                ProgressWindowController.shared.hide()
                recordCompletion(
                    dmgName: dmgName,
                    outcome: "skipped",
                    details: [
                        "app": resolvedAppName,
                        "reason": reason,
                        "trashed_dmg": boolString(didTrashDMG)
                    ]
                )
                return
            }
        }

        showProgress("Checking disk space...", progress: 0.15)
        let appSize = calculateAppSize(at: appPath)
        diagnostic("Calculated app size: \(appSize) bytes for \(appPath)")
        if !hasEnoughDiskSpace(requiredBytes: appSize) {
            let sizeInGB = Double(appSize) / (1024 * 1024 * 1024)
            diagnostic("Insufficient disk space for app size \(appSize)")
            support(
                event: "install_result",
                details: [
                    "app": resolvedAppName,
                    "dmg": dmgName,
                    "reason": "insufficient_disk_space",
                    "required_bytes": String(appSize),
                    "result": "failed"
                ]
            )
            recordCompletion(
                dmgName: dmgName,
                outcome: "error",
                details: ["app": resolvedAppName, "reason": "insufficient_disk_space"]
            )
            await handleError("Insufficient disk space (need \(String(format: "%.1f", sizeInGB))GB)")
            _ = await unmountDMG(at: mountPoint, dmgName: dmgName)
            return
        }

        cleanupStagedAppIfNeeded(at: stagedURL)
        support(
            event: "install_start",
            details: [
                "app": resolvedAppName,
                "dmg": dmgName,
                "replace_existing": boolString(shouldReplaceExistingApp),
                "volume": volumeName(from: mountPoint)
            ]
        )

        do {
            try await withMagicFallback(
                message: "Installing to Applications...",
                progress: 0.2
            ) {
                DiagnosticLogger.shared.diagnostic(
                    "Copying app from \(appPath) to staging path \(stagedURL.path)"
                )
                try FileManager.default.copyItem(atPath: appPath, toPath: stagedURL.path)
            }

            let assessment = await withMagicFallback(
                message: "Verifying with macOS...",
                progress: 0.25
            ) {
                await self.assessAppSecurity(at: stagedURL.path)
            }

            var assessmentDetails = assessment.supportDetails
            assessmentDetails["app"] = resolvedAppName
            assessmentDetails["dmg"] = dmgName
            support(event: "app_security_assessment", details: assessmentDetails)

            let quarantineDecision = await quarantineDecision(
                for: assessment,
                appName: resolvedAppName
            )
            var quarantineDetails = assessment.supportDetails
            quarantineDetails["app"] = resolvedAppName
            quarantineDetails["dmg"] = dmgName
            quarantineDetails["quarantine_decision"] = quarantineDecision.rawValue
            quarantineDetails["skip_unverified_warning"] = boolString(UserPreferences.shared.skipUnverifiedAppWarning)
            support(event: "quarantine_decision", details: quarantineDetails)

            switch quarantineDecision {
            case .removeQuarantine:
                await removeQuarantineAttributes(from: stagedURL.path)

            case .handleManually:
                cleanupStagedAppIfNeeded(at: stagedURL)
                await openForManualInstallation(
                    mountPoint: mountPoint,
                    dmgName: dmgName,
                    reason: assessment.manualFallbackReason,
                    details: quarantineDetails
                )
                return

            case .cancel:
                cleanupStagedAppIfNeeded(at: stagedURL)
                showProgress("Installation canceled", progress: 0.3)
                _ = await unmountDMG(at: mountPoint, dmgName: dmgName, progress: 0.3)
                ProgressWindowController.shared.hide()
                var completionDetails = quarantineDetails
                completionDetails["reason"] = "security_assessment_canceled"
                recordCompletion(
                    dmgName: dmgName,
                    outcome: "skipped",
                    details: completionDetails
                )
                return
            }

            if shouldReplaceExistingApp && FileManager.default.fileExists(atPath: destinationPath) {
                showProgress("Replacing existing app...", progress: 0.3)
                _ = try FileManager.default.replaceItemAt(
                    destinationURL,
                    withItemAt: stagedURL,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try FileManager.default.moveItem(at: stagedURL, to: destinationURL)
            }
            let destinationExists = FileManager.default.fileExists(atPath: destinationPath)
            diagnostic("Installed app at destination: \(destinationPath); existsAfterMove=\(destinationExists)")
            support(
                event: "install_result",
                details: [
                    "app": resolvedAppName,
                    "destination_exists": boolString(destinationExists),
                    "dmg": dmgName,
                    "replace_existing": boolString(shouldReplaceExistingApp),
                    "result": "success"
                ]
            )

            if currentFeedbackMode == .notification {
                await sendNotification(title: "EasyDMG", message: "\(resolvedAppName.strippingAppSuffix) installed successfully")
            }
        } catch {
            diagnostic("Installation failed while copying/replacing: \(error)")
            cleanupStagedAppIfNeeded(at: stagedURL)
            let permissionDenied = isAppManagementError(error)
            let targetProbe = permissionDenied ? canModifyExistingApp(at: destinationPath) : nil
            let failureReason = targetProbe?.target.automaticReplacementBlockReason
                ?? (permissionDenied ? "app_management_denied" : "copy_or_replace_failed")
            var failureDetails = errorDetails(error).merging([
                "app": resolvedAppName,
                "dmg": dmgName,
                "reason": failureReason,
                "result": "failed"
            ]) { current, _ in current }
            if let targetProbe {
                failureDetails.merge(targetProbe.supportDetails) { _, new in new }
            }
            support(
                event: "install_result",
                details: failureDetails
            )
            recordCompletion(
                dmgName: dmgName,
                outcome: "error",
                details: ["app": resolvedAppName, "reason": failureReason]
            )
            if let targetProbe,
               targetProbe.target.automaticReplacementBlockReason != nil {
                await showManagedAppReplacementBlockedDialog(
                    appName: resolvedAppName,
                    dmgName: dmgName,
                    target: targetProbe.target
                )
            } else {
                let errorMessage = permissionDenied
                    ? (targetProbe?.retryFailureMessage ?? "EasyDMG needs App Management permission. Open System Settings > Privacy & Security > App Management, enable EasyDMG, then try again.")
                    : "Installation failed"
                await handleError(errorMessage)
            }
            _ = await unmountDMG(at: mountPoint, dmgName: dmgName, progress: 0.6)
            return
        }

        if UserPreferences.shared.revealInFinder {
            showProgress("Opening in Finder...", progress: 0.4)
            revealInFinder(path: destinationPath)
        } else {
            showProgress("Finalizing installation...", progress: 0.4)
        }

        _ = await unmountDMG(at: mountPoint, dmgName: dmgName, progress: 0.6)

        let didTrashDMG: Bool
        if UserPreferences.shared.autoTrashDMG {
            showProgress("Moving disk image to trash...", progress: 0.8)
            didTrashDMG = trashDMGIfNeeded(at: dmgPath, shouldTrash: true, dmgName: dmgName)
        } else {
            showProgress("Keeping disk image...", progress: 0.8)
            didTrashDMG = trashDMGIfNeeded(at: dmgPath, shouldTrash: false, dmgName: dmgName)
        }

        let didOpenApp = await openInstalledAppIfNeeded(at: destinationPath)

        if currentFeedbackMode == .progressBar {
            showProgress("Installation complete!", progress: 1.0)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }

        ProgressWindowController.shared.hide()
        diagnostic("✅ Processing complete for \(resolvedAppName)")
        recordCompletion(
            dmgName: dmgName,
            outcome: "installed",
            details: [
                "app": resolvedAppName,
                "opened_app": boolString(didOpenApp),
                "trashed_dmg": boolString(didTrashDMG)
            ]
        )
    }

    private func showSkipReplaceDialog(
        appName: String,
        installedVersion: String?,
        newVersion: String?
    ) async -> Bool {
        let displayName = appName.strippingAppSuffix
        let informative: String
        let comparison = replacementVersionComparison(
            installedVersion: installedVersion,
            newVersion: newVersion
        )
        if comparison != .unknown, let installed = installedVersion, let new = newVersion {
            let installedDisplayVersion = dialogVersionText(from: installed)
            let newDisplayVersion = dialogVersionText(from: new)
            let comparisonText: String

            switch comparison {
            case .same:
                comparisonText = "This appears to be the same version."
            case .newer:
                comparisonText = "This looks like a newer version."
            case .older:
                comparisonText = "This looks like an older version."
            case .unknown:
                comparisonText = ""
            }

            informative = [
                "\(displayName) is already installed in Applications.",
                "",
                "Installed: \(installedDisplayVersion)",
                "New: \(newDisplayVersion)",
                "",
                comparisonText
            ].joined(separator: "\n")
        } else {
            informative = "\(displayName) is already installed in Applications."
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.alertStyle = .informational
                alert.messageText = "Replace \(displayName)?"
                alert.informativeText = informative

                if let iconPath = Bundle.main.path(forResource: "wizardhamster", ofType: "icns"),
                   let icon = NSImage(contentsOfFile: iconPath) {
                    alert.icon = icon
                }

                let suppressCheckbox: NSButton?
                if comparison == .newer {
                    let checkbox = NSButton(
                        checkboxWithTitle: "Always install newer versions without asking",
                        target: nil,
                        action: nil
                    )
                    checkbox.state = .off
                    checkbox.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
                    checkbox.sizeToFit()
                    alert.accessoryView = checkbox
                    suppressCheckbox = checkbox
                } else {
                    suppressCheckbox = nil
                }

                alert.addButton(withTitle: "Replace")
                alert.addButton(withTitle: "Cancel")

                presentHostedAlert(alert) { response in
                    let shouldReplace = response == .alertFirstButtonReturn

                    if shouldReplace, suppressCheckbox?.state == .on {
                        UserPreferences.shared.autoInstallNewerVersions = true
                        self.diagnostic("User enabled auto-install for newer versions via Replace dialog")
                        self.support(
                            event: "preference_change",
                            details: [
                                "preference": "autoInstallNewerVersions",
                                "value": "true",
                                "source": "replace_dialog_suppression"
                            ]
                        )
                    }

                    continuation.resume(returning: shouldReplace)
                }
            }
        }
    }

    private func dialogVersionText(from version: String) -> String {
        var displayVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)

        while displayVersion.first == "v" || displayVersion.first == "V" {
            displayVersion.removeFirst()
        }

        return displayVersion
    }

    private func replacementVersionComparison(
        installedVersion: String?,
        newVersion: String?
    ) -> ReplacementVersionComparison {
        guard let installed = parsedAppVersion(from: installedVersion),
              let new = parsedAppVersion(from: newVersion) else {
            return .unknown
        }

        let componentCount = max(installed.components.count, new.components.count)
        for index in 0..<componentCount {
            let installedComponent = index < installed.components.count ? installed.components[index] : 0
            let newComponent = index < new.components.count ? new.components[index] : 0

            if installedComponent < newComponent {
                return .newer
            }

            if installedComponent > newComponent {
                return .older
            }
        }

        switch (installed.prerelease, new.prerelease) {
        case (nil, nil):
            return .same
        case (nil, .some):
            return .older
        case (.some, nil):
            return .newer
        case let (installedPrerelease?, newPrerelease?):
            switch comparePrerelease(installedPrerelease, newPrerelease) {
            case .orderedAscending:
                return .newer
            case .orderedDescending:
                return .older
            case .orderedSame:
                return .same
            }
        }
    }

    private func parsedAppVersion(from version: String?) -> ParsedAppVersion? {
        guard var core = version?.trimmingCharacters(in: .whitespacesAndNewlines),
              !core.isEmpty else {
            return nil
        }

        while core.first == "v" || core.first == "V" {
            core.removeFirst()
        }

        if let metadataStart = core.firstIndex(of: "+") {
            core = String(core[..<metadataStart])
        }

        let versionParts = core.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let numericCore = versionParts.first,
              numericCore.range(of: #"^\d+(\.\d+)*$"#, options: .regularExpression) != nil else {
            return nil
        }

        var components = numericCore.split(separator: ".").compactMap { Int($0) }
        guard !components.isEmpty else { return nil }

        while components.count > 1 && components.last == 0 {
            components.removeLast()
        }

        let prerelease: String?
        if versionParts.count > 1 {
            let suffix = versionParts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !suffix.isEmpty else { return nil }
            prerelease = suffix.lowercased()
        } else {
            prerelease = nil
        }

        return ParsedAppVersion(components: components, prerelease: prerelease)
    }

    private func comparePrerelease(_ installed: String, _ new: String) -> ComparisonResult {
        let installedIdentifiers = installed.split(separator: ".").map(String.init)
        let newIdentifiers = new.split(separator: ".").map(String.init)
        let identifierCount = max(installedIdentifiers.count, newIdentifiers.count)

        for index in 0..<identifierCount {
            guard index < installedIdentifiers.count else { return .orderedAscending }
            guard index < newIdentifiers.count else { return .orderedDescending }

            let installedIdentifier = installedIdentifiers[index]
            let newIdentifier = newIdentifiers[index]

            if installedIdentifier == newIdentifier {
                continue
            }

            let installedNumber = Int(installedIdentifier)
            let newNumber = Int(newIdentifier)

            switch (installedNumber, newNumber) {
            case let (installedNumber?, newNumber?):
                if installedNumber < newNumber { return .orderedAscending }
                if installedNumber > newNumber { return .orderedDescending }
            case (_?, nil):
                return .orderedAscending
            case (nil, _?):
                return .orderedDescending
            case (nil, nil):
                let comparison = installedIdentifier.compare(newIdentifier)
                if comparison != .orderedSame {
                    return comparison
                }
            }
        }

        return .orderedSame
    }

    private func appVersion(at appPath: String) -> String? {
        let infoPlistURL = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let info = plist as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String,
              !version.isEmpty else {
            return nil
        }
        return version
    }

    private func bundleIdentifier(at appPath: String) -> String? {
        let infoPlistURL = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let info = plist as? [String: Any] else {
            return nil
        }
        return info["CFBundleIdentifier"] as? String
    }

    private func runningInstances(of bundleID: String) -> [NSRunningApplication] {
        let currentPID = NSRunningApplication.current.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != currentPID }
    }

    private func quitRunningInstances(_ apps: [NSRunningApplication]) async -> Bool {
        for app in apps where !app.isTerminated {
            app.terminate()
        }

        let pollIntervalNanos: UInt64 = 250_000_000
        let maxAttempts = 12

        for _ in 0..<maxAttempts {
            if apps.allSatisfy({ $0.isTerminated }) {
                return true
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanos)
        }

        return apps.allSatisfy { $0.isTerminated }
    }

    private func showQuitRunningAppDialog(appName: String) async -> Bool {
        let displayName = appName.strippingAppSuffix
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.alertStyle = .informational
                alert.messageText = "EasyDMG"
                alert.informativeText = "\(displayName) is currently running.\n\nQuit and install the new version?"

                if let iconPath = Bundle.main.path(forResource: "wizardhamster", ofType: "icns"),
                   let icon = NSImage(contentsOfFile: iconPath) {
                    alert.icon = icon
                }

                alert.addButton(withTitle: "Quit & Install")
                alert.addButton(withTitle: "Cancel")

                presentHostedAlert(alert) { response in
                    continuation.resume(returning: response == .alertFirstButtonReturn)
                }
            }
        }
    }

    private func showQuitFailedDialog(appName: String) async -> Bool {
        let displayName = appName.strippingAppSuffix
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "EasyDMG"
                alert.informativeText = "\(displayName) didn't quit. It may have unsaved work or an open dialog.\n\nClose it manually, then try again."

                if let iconPath = Bundle.main.path(forResource: "wizardhamster", ofType: "icns"),
                   let icon = NSImage(contentsOfFile: iconPath) {
                    alert.icon = icon
                }

                alert.addButton(withTitle: "Try Again")
                alert.addButton(withTitle: "Cancel")

                presentHostedAlert(alert) { response in
                    continuation.resume(returning: response == .alertFirstButtonReturn)
                }
            }
        }
    }

    private func quitIfRunning(appName: String, bundleID: String, dmgName: String) async -> Bool {
        var instances = runningInstances(of: bundleID)

        support(
            event: "running_instance_check",
            details: [
                "app": appName,
                "dmg": dmgName,
                "bundle_id": bundleID,
                "running_count": String(instances.count)
            ]
        )

        if instances.isEmpty {
            return true
        }

        diagnostic("Detected \(instances.count) running instance(s) of \(appName) (\(bundleID))")

        let userAgreedToQuit = await showQuitRunningAppDialog(appName: appName)
        support(
            event: "quit_prompt_decision",
            details: [
                "app": appName,
                "dmg": dmgName,
                "action": userAgreedToQuit ? "quit" : "cancel"
            ]
        )

        if !userAgreedToQuit {
            return false
        }

        showProgress("Quitting \(appName.strippingAppSuffix)...", progress: 0.2)

        while true {
            let success = await quitRunningInstances(instances)
            let remaining = instances.filter { !$0.isTerminated }.count

            support(
                event: "terminate_result",
                details: [
                    "app": appName,
                    "dmg": dmgName,
                    "success": boolString(success),
                    "remaining": String(remaining)
                ]
            )

            if success {
                return true
            }

            let retry = await showQuitFailedDialog(appName: appName)
            support(
                event: "quit_retry_decision",
                details: [
                    "app": appName,
                    "dmg": dmgName,
                    "action": retry ? "retry" : "cancel"
                ]
            )

            if !retry {
                return false
            }

            instances = runningInstances(of: bundleID)
            if instances.isEmpty {
                return true
            }
        }
    }

    // Probes App Management TCC by setting the existing bundle's modification date
    // to its current value — a no-op write that still exercises the permission check.
    private func canModifyExistingApp(at path: String) -> AppManagementProbeResult {
        let target = appPermissionTargetDiagnostics(at: path)

        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let originalDate = attrs[.modificationDate] as? Date ?? Date()
            try FileManager.default.setAttributes(
                [.modificationDate: originalDate],
                ofItemAtPath: path
            )
            return .granted(target: target)
        } catch {
            let nsError = error as NSError
            diagnostic(
                "App Management probe failed: domain=\(nsError.domain) code=\(nsError.code) \(target.diagnosticSummary)"
            )
            return .denied(error: nsError, target: target)
        }
    }

    private func appPermissionTargetDiagnostics(at path: String) -> AppPermissionTargetDiagnostics {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let ownerID = (attrs?[.ownerAccountID] as? NSNumber)?.intValue
        let groupID = (attrs?[.groupOwnerAccountID] as? NSNumber)?.intValue
        let posixPermissions = (attrs?[.posixPermissions] as? NSNumber)?.intValue
        let receiptPath = URL(fileURLWithPath: path)
            .appendingPathComponent("Contents/_MASReceipt/receipt")
            .path

        return AppPermissionTargetDiagnostics(
            path: path,
            ownerName: attrs?[.ownerAccountName] as? String,
            ownerID: ownerID,
            groupName: attrs?[.groupOwnerAccountName] as? String,
            groupID: groupID,
            posixPermissions: posixPermissions,
            extendedAttributes: extendedAttributeNames(at: path),
            appStoreReceiptExists: FileManager.default.fileExists(atPath: receiptPath)
        )
    }

    private func extendedAttributeNames(at path: String) -> [String] {
        let url = URL(fileURLWithPath: path)
        let length = url.withUnsafeFileSystemRepresentation { fileSystemPath -> Int in
            guard let fileSystemPath else { return -1 }
            return listxattr(fileSystemPath, nil, 0, XATTR_NOFOLLOW)
        }

        guard length > 0 else { return [] }

        var buffer = [CChar](repeating: 0, count: length)
        let result = buffer.withUnsafeMutableBufferPointer { bufferPointer in
            url.withUnsafeFileSystemRepresentation { fileSystemPath -> Int in
                guard let fileSystemPath, let baseAddress = bufferPointer.baseAddress else { return -1 }
                return listxattr(fileSystemPath, baseAddress, length, XATTR_NOFOLLOW)
            }
        }

        guard result > 0 else { return [] }

        var names: [String] = []
        buffer.withUnsafeBufferPointer { bufferPointer in
            guard let baseAddress = bufferPointer.baseAddress else { return }

            var offset = 0
            while offset < result {
                let namePointer = baseAddress.advanced(by: offset)
                let name = String(cString: namePointer)
                if !name.isEmpty {
                    names.append(name)
                }
                offset += strlen(namePointer) + 1
            }
        }

        return names.sorted()
    }

    private func isAppManagementError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == 513 { return true }
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == 1 { return true }
        return false
    }

    func handleAppManagementTerminationRequest() -> Bool {
        guard let appManagementPermissionWindowController else {
            return false
        }

        diagnostic("Treating termination request as App Management restart request")
        didHandleAppManagementRestartRequest = true
        appManagementPermissionWindowController.handleSystemSettingsRestartRequest()
        return true
    }

    func refreshAppManagementPermissionPanel() {
        appManagementPermissionWindowController?.continueIfPermissionReady(reason: "app_active")
    }

    private func showAppManagementPermissionDialog(
        forExistingAppAt existingAppPath: String,
        appName: String,
        dmgName: String
    ) async -> AppManagementDecision {
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: .cancel)
                    return
                }

                let controller = AppManagementPermissionWindowController(
                    appName: appName,
                    permissionProbe: { [weak self] in
                        guard let self else {
                            return .unavailable(path: existingAppPath)
                        }

                        let probe = self.canModifyExistingApp(at: existingAppPath)
                        var details = [
                            "app": appName,
                            "dmg": dmgName,
                            "result": probe.granted ? "granted" : "denied",
                            "source": "permission_window"
                        ]
                        details.merge(probe.supportDetails) { _, new in new }
                        self.support(event: "app_management_probe", details: details)
                        return probe
                    },
                    openSettings: {
                        DiagnosticLogger.shared.support(
                            event: "app_management_open_settings",
                            details: ["app": appName, "dmg": dmgName]
                        )
                        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")!
                        NSWorkspace.shared.open(url)
                    },
                    permissionReady: { reason in
                        DiagnosticLogger.shared.diagnostic(
                            "App Management permission ready via \(reason)"
                        )
                        DiagnosticLogger.shared.support(
                            event: "app_management_permission_ready",
                            details: ["app": appName, "dmg": dmgName, "reason": reason]
                        )
                    },
                    completion: { [weak self] decision in
                        if let self, self.appManagementPermissionWindowController != nil {
                            self.appManagementPermissionWindowController = nil
                        }
                        continuation.resume(returning: decision)
                    }
                )
                self.appManagementPermissionWindowController = controller
                controller.present()
            }
        }
    }

    private func showManagedAppReplacementBlockedDialog(
        appName: String,
        dmgName: String,
        target: AppPermissionTargetDiagnostics
    ) async {
        ProgressWindowController.shared.hide()

        let response = await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Can't replace \(appName.strippingAppSuffix)"
            alert.informativeText = """
            \(appName.strippingAppSuffix) is managed by the App Store, and macOS doesn't let EasyDMG replace App Store apps.

            To install this version, move \(appName.strippingAppSuffix) from your Applications folder to the Trash to uninstall, then open the DMG again.
            """
            alert.addButton(withTitle: "Show in Finder")
            alert.addButton(withTitle: "Cancel")

            presentHostedAlert(alert) { response in
                continuation.resume(returning: response)
            }
        }

        let action: String
        if response == .alertFirstButtonReturn {
            action = "reveal_existing_app"
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target.path)])
        } else {
            action = "cancel"
        }

        var details = [
            "action": action,
            "app": appName,
            "dmg": dmgName
        ]
        details.merge(target.supportDetails) { _, new in new }
        support(event: "managed_app_replacement_blocked", details: details)
    }

    private func ensureAppManagementPermission(
        forExistingAppAt path: String,
        appName: String,
        dmgName: String
    ) async -> ExistingAppModificationPreflightResult {
        while true {
            let probe = canModifyExistingApp(at: path)
            if probe.granted {
                var grantedDetails = ["app": appName, "dmg": dmgName, "result": "granted"]
                grantedDetails.merge(probe.supportDetails) { _, new in new }
                support(event: "app_management_probe", details: grantedDetails)
                return .allowed
            }

            var deniedDetails: [String: String] = [
                "app": appName,
                "dmg": dmgName,
                "result": "denied"
            ]
            deniedDetails.merge(probe.supportDetails) { _, new in new }
            support(event: "app_management_probe", details: deniedDetails)

            if let reason = probe.target.automaticReplacementBlockReason {
                await showManagedAppReplacementBlockedDialog(
                    appName: appName,
                    dmgName: dmgName,
                    target: probe.target
                )
                return .blocked(reason: reason)
            }

            showProgress("Waiting for App Management permission...", progress: 0.2)

            let decision = await showAppManagementPermissionDialog(
                forExistingAppAt: path,
                appName: appName,
                dmgName: dmgName
            )
            support(
                event: "app_management_decision",
                details: [
                    "app": appName,
                    "dmg": dmgName,
                    "action": {
                        switch decision {
                        case .retry: return "retry"
                        case .cancel: return "cancel"
                        }
                    }()
                ]
            )

            switch decision {
            case .retry:
                continue
            case .cancel:
                return .blocked(reason: "app_management_denied")
            }
        }
    }

    private func unmountDMG(at mountPoint: String, dmgName: String, progress: Double? = nil) async -> UnmountResult {
        diagnostic("Unmounting \(mountPoint)...")
        support(
            event: "unmount_start",
            details: [
                "dmg": dmgName,
                "volume": volumeName(from: mountPoint)
            ]
        )

        let result: UnmountResult
        if let progress {
            result = await withMagicFallback(
                message: "Cleaning up...",
                progress: progress
            ) {
                self.performUnmount(at: mountPoint)
            }
        } else {
            result = performUnmount(at: mountPoint)
        }

        var details = [
            "dmg": dmgName,
            "result": result.supportValue,
            "volume": volumeName(from: mountPoint)
        ]
        if let exitStatus = result.exitStatus {
            details["exit_status"] = String(exitStatus)
        }
        if let timedOutStage = result.timedOutStage {
            details["timed_out_stage"] = timedOutStage
        }
        support(event: "unmount_result", details: details)
        return result
    }

    private nonisolated func runProcessWithTimeout(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> ProcessRunResult {
        let task = Process()
        task.executableURL = executableURL
        task.arguments = arguments

        let errorPipe = Pipe()
        task.standardError = errorPipe
        let errorCollector = ProcessPipeCollector(pipe: errorPipe)

        let semaphore = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in
            semaphore.signal()
        }

        try task.run()
        errorCollector.startReading()

        var timedOut = false
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            DiagnosticLogger.shared.diagnostic(
                "Process timed out after \(timeout)s: \(executableURL.path) \(arguments.joined(separator: " "))"
            )

            let processIdentifier = task.processIdentifier
            task.terminate()
            if semaphore.wait(timeout: .now() + 2.0) == .timedOut {
                if task.isRunning {
                    kill(processIdentifier, SIGKILL)
                    _ = semaphore.wait(timeout: .now() + 1.0)
                } else {
                    DiagnosticLogger.shared.diagnostic(
                        "Process \(processIdentifier) already exited before SIGKILL escalation; skipping kill to avoid pid-reuse race"
                    )
                }
            }
        }

        let errorOutput: String
        let errorData = errorCollector.data(waitForEOF: !task.isRunning)
        errorOutput = String(data: errorData, encoding: .utf8) ?? ""

        return ProcessRunResult(
            exitStatus: task.isRunning ? nil : task.terminationStatus,
            standardError: errorOutput,
            timedOut: timedOut
        )
    }

    private nonisolated func performUnmount(at mountPoint: String) -> UnmountResult {
        do {
            let hdiutilURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            let cleanResult = try runProcessWithTimeout(
                executableURL: hdiutilURL,
                arguments: ["detach", mountPoint],
                timeout: 8.0
            )

            if cleanResult.exitStatus == 0 {
                DiagnosticLogger.shared.diagnostic("✓ Clean detach succeeded")
                return .clean
            }

            if cleanResult.timedOut {
                DiagnosticLogger.shared.diagnostic("Clean detach timed out")
            }

            let errorOutput = cleanResult.standardError
            DiagnosticLogger.shared.diagnostic(
                "Detach failed: \(DiagnosticLogger.compact(errorOutput))"
            )

            if errorOutput.lowercased().contains("resource busy") {
                DiagnosticLogger.shared.diagnostic("Resource busy, waiting 250ms and retrying...")
                Thread.sleep(forTimeInterval: 0.25)

                let retryResult = try runProcessWithTimeout(
                    executableURL: hdiutilURL,
                    arguments: ["detach", mountPoint],
                    timeout: 8.0
                )

                if retryResult.exitStatus == 0 {
                    DiagnosticLogger.shared.diagnostic("✓ Retry detach succeeded")
                    return .retrySuccess
                }

                if retryResult.timedOut {
                    DiagnosticLogger.shared.diagnostic("Retry detach timed out")
                }
            }

            DiagnosticLogger.shared.diagnostic("Using force detach...")
            let forceResult = try runProcessWithTimeout(
                executableURL: hdiutilURL,
                arguments: ["detach", mountPoint, "-force"],
                timeout: 8.0
            )
            if forceResult.exitStatus == 0 {
                DiagnosticLogger.shared.diagnostic("✓ Force detach completed with status 0")
                return .forceSuccess
            }

            if forceResult.timedOut {
                DiagnosticLogger.shared.diagnostic("Force detach timed out")
                return .timedOut(stage: "force_detach")
            }

            DiagnosticLogger.shared.diagnostic(
                "Force detach failed with status \(forceResult.exitStatus.map { String($0) } ?? "unknown")"
            )
            return .failed(exitStatus: forceResult.exitStatus)
        } catch {
            DiagnosticLogger.shared.diagnostic("Error unmounting DMG: \(error)")
            return .failed(exitStatus: nil)
        }
    }

    private func unmountAndCleanup(
        mountPoint: String,
        dmgPath: String,
        dmgName: String,
        shouldTrashDMG: Bool
    ) async -> Bool {
        _ = await unmountDMG(at: mountPoint, dmgName: dmgName)

        if shouldTrashDMG {
            showProgress("Moving disk image to trash...", progress: 0.8)
        } else {
            showProgress("Keeping disk image...", progress: 0.8)
        }

        return trashDMGIfNeeded(at: dmgPath, shouldTrash: shouldTrashDMG, dmgName: dmgName)
    }

    private nonisolated func assessAppSecurity(at appPath: String) async -> AppSecurityAssessment {
        let spctlURL = URL(fileURLWithPath: "/usr/sbin/spctl")
        guard FileManager.default.isExecutableFile(atPath: spctlURL.path) else {
            return AppSecurityAssessment(
                result: .unverified,
                tool: "spctl",
                refinementTool: nil,
                reason: "assessment_tool_unavailable",
                summary: "",
                exitStatus: nil,
                refinementExitStatus: nil,
                timedOut: false
            )
        }

        do {
            let result = try await runAssessmentProcess(
                executableURL: spctlURL,
                arguments: ["-a", "-vvv", "--type", "execute", appPath],
                timeout: 11
            )

            if result.timedOut {
                return AppSecurityAssessment(
                    result: .unverified,
                    tool: "spctl",
                    refinementTool: nil,
                    reason: "assessment_timed_out",
                    summary: compactAssessmentOutput(result.combinedOutput),
                    exitStatus: result.exitStatus,
                    refinementExitStatus: nil,
                    timedOut: true
                )
            }

            if result.exitStatus == 0 {
                return acceptedSpctlAssessment(result)
            }

            return await refineFailedAssessment(
                tool: "spctl",
                result: result,
                appPath: appPath
            )
        } catch {
            return AppSecurityAssessment(
                result: .unverified,
                tool: "spctl",
                refinementTool: nil,
                reason: "assessment_failed_to_run",
                summary: compactAssessmentOutput(String(describing: error)),
                exitStatus: nil,
                refinementExitStatus: nil,
                timedOut: false
            )
        }
    }

    private nonisolated func acceptedSpctlAssessment(_ result: AssessmentProcessResult) -> AppSecurityAssessment {
        let source = spctlAssessmentSource(in: result.combinedOutput)
        let assessmentResult: AppSecurityAssessmentResult
        let reason: String

        if isVerifiedSpctlSource(source) {
            assessmentResult = .passed
            reason = "assessment_passed"
        } else if isDeveloperIDSpctlSource(source) {
            assessmentResult = .unverified
            reason = "accepted_developer_id_without_notarization"
        } else {
            assessmentResult = .unverified
            reason = source == nil ? "accepted_source_unavailable" : "accepted_unknown_source"
        }

        return AppSecurityAssessment(
            result: assessmentResult,
            tool: "spctl",
            refinementTool: nil,
            reason: reason,
            summary: compactAssessmentOutput(result.combinedOutput),
            exitStatus: result.exitStatus,
            refinementExitStatus: nil,
            timedOut: false
        )
    }

    private nonisolated func spctlAssessmentSource(in output: String) -> String? {
        output
            .components(separatedBy: .newlines)
            .lazy
            .compactMap { line -> String? in
                let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmedLine.lowercased().hasPrefix("source=") else {
                    return nil
                }

                return String(trimmedLine.dropFirst("source=".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .first
    }

    private nonisolated func isVerifiedSpctlSource(_ source: String?) -> Bool {
        guard let normalizedSource = source?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }

        return normalizedSource == "notarized developer id"
            || normalizedSource == "apple"
            || normalizedSource == "apple system"
            || normalizedSource == "mac app store"
    }

    private nonisolated func isDeveloperIDSpctlSource(_ source: String?) -> Bool {
        guard let normalizedSource = source?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }

        return normalizedSource == "developer id"
            || (normalizedSource.hasPrefix("developer id") && !normalizedSource.contains("notarized"))
    }

    private nonisolated func refineFailedAssessment(
        tool: String,
        result: AssessmentProcessResult,
        appPath: String
    ) async -> AppSecurityAssessment {
        let codesignURL = URL(fileURLWithPath: "/usr/bin/codesign")
        let primaryOutput = result.combinedOutput

        guard FileManager.default.isExecutableFile(atPath: codesignURL.path) else {
            let blockedReason = blockedSecurityReason(in: primaryOutput, appPath: appPath)
            return AppSecurityAssessment(
                result: blockedReason == nil ? .unverified : .blocked,
                tool: tool,
                refinementTool: nil,
                reason: blockedReason ?? "assessment_rejected_unverified",
                summary: compactAssessmentOutput(primaryOutput),
                exitStatus: result.exitStatus,
                refinementExitStatus: nil,
                timedOut: result.timedOut
            )
        }

        do {
            let codesignResult = try await runAssessmentProcess(
                executableURL: codesignURL,
                arguments: ["--verify", "--deep", "--strict", "--verbose=2", appPath],
                timeout: 8
            )
            let combinedOutput = primaryOutput + "\n" + codesignResult.combinedOutput

            if let reason = blockedSecurityReason(in: combinedOutput, appPath: appPath) {
                return AppSecurityAssessment(
                    result: .blocked,
                    tool: tool,
                    refinementTool: "codesign",
                    reason: reason,
                    summary: compactAssessmentOutput(combinedOutput),
                    exitStatus: result.exitStatus,
                    refinementExitStatus: codesignResult.exitStatus,
                    timedOut: result.timedOut || codesignResult.timedOut
                )
            }

            let reason: String
            if codesignResult.timedOut {
                reason = "codesign_timed_out"
            } else if codesignResult.exitStatus == 0 {
                reason = "gatekeeper_rejected_signature_valid"
            } else if isUnsignedAssessment(combinedOutput, appPath: appPath) {
                reason = "unsigned_or_unnotarized"
            } else {
                reason = "assessment_rejected_unverified"
            }

            return AppSecurityAssessment(
                result: .unverified,
                tool: tool,
                refinementTool: "codesign",
                reason: reason,
                summary: compactAssessmentOutput(combinedOutput),
                exitStatus: result.exitStatus,
                refinementExitStatus: codesignResult.exitStatus,
                timedOut: result.timedOut || codesignResult.timedOut
            )
        } catch {
            let combinedOutput = primaryOutput + "\n" + String(describing: error)
            if let reason = blockedSecurityReason(in: combinedOutput, appPath: appPath) {
                return AppSecurityAssessment(
                    result: .blocked,
                    tool: tool,
                    refinementTool: "codesign",
                    reason: reason,
                    summary: compactAssessmentOutput(combinedOutput),
                    exitStatus: result.exitStatus,
                    refinementExitStatus: nil,
                    timedOut: result.timedOut
                )
            }

            return AppSecurityAssessment(
                result: .unverified,
                tool: tool,
                refinementTool: "codesign",
                reason: "codesign_failed_to_run",
                summary: compactAssessmentOutput(combinedOutput),
                exitStatus: result.exitStatus,
                refinementExitStatus: nil,
                timedOut: result.timedOut
            )
        }
    }

    private nonisolated func blockedSecurityReason(in output: String, appPath: String) -> String? {
        let lowercasedOutput = assessmentDiagnosticsForPatternMatching(output, appPath: appPath)
        let blockedPatterns: [(pattern: String, reason: String)] = [
            ("source=xprotect", "xprotect_blocked"),
            ("xprotectservice", "xprotect_blocked"),
            ("xprotect blocked", "xprotect_blocked"),
            ("malware was detected", "malware_blocked"),
            ("malware detected", "malware_blocked"),
            ("detected malware", "malware_blocked"),
            ("contains malware", "malware_blocked"),
            ("identified as malware", "malware_blocked"),
            ("known malware", "malware_blocked"),
            ("certificate has been revoked", "signature_revoked"),
            ("certificate was revoked", "signature_revoked"),
            ("certificate revoked", "signature_revoked"),
            ("cssmerr_tp_cert_revoked", "signature_revoked"),
            ("code or signature have been modified", "signature_modified"),
            ("invalid signature", "invalid_signature"),
            ("code signature is invalid", "invalid_signature"),
            ("code signature invalid", "invalid_signature"),
            ("a sealed resource is missing or invalid", "sealed_resource_invalid"),
            ("sealed resource is missing or invalid", "sealed_resource_invalid"),
            ("the code has been modified", "signature_modified"),
            ("app is damaged", "app_damaged"),
            ("application is damaged", "app_damaged"),
            ("bundle is damaged", "app_damaged"),
            ("package is damaged", "app_damaged"),
            ("is damaged and can't be opened", "app_damaged")
        ]

        return blockedPatterns.first { lowercasedOutput.contains($0.pattern) }?.reason
    }

    private nonisolated func assessmentDiagnosticsForPatternMatching(_ output: String, appPath: String) -> String {
        let appURL = URL(fileURLWithPath: appPath)
        let appName = appURL.lastPathComponent
        // Assessment tools echo the target path; strip it before matching words that may appear in app names.
        let pathVariants = Set([
            appPath,
            appURL.path,
            appURL.standardizedFileURL.path,
            appURL.resolvingSymlinksInPath().path,
            appName
        ].filter { !$0.isEmpty })

        return output
            .components(separatedBy: .newlines)
            .compactMap { line -> String? in
                let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedLine.isEmpty else {
                    return nil
                }

                let lowercasedLine = trimmedLine.lowercased()
                if lowercasedLine.hasPrefix("origin=") || lowercasedLine.hasPrefix("authority=") {
                    return nil
                }

                return pathVariants
                    .sorted { $0.count > $1.count }
                    .reduce(trimmedLine) { sanitizedLine, pathVariant in
                        sanitizedLine.replacingOccurrences(
                            of: pathVariant,
                            with: "<app>",
                            options: [.caseInsensitive]
                        )
                    }
            }
            .joined(separator: "\n")
            .lowercased()
    }

    private nonisolated func isUnsignedAssessment(_ output: String, appPath: String) -> Bool {
        let sanitizedOutput = assessmentDiagnosticsForPatternMatching(output, appPath: appPath)
        return sanitizedOutput.contains("code object is not signed at all")
            || sanitizedOutput.contains("source=no usable signature")
            || sanitizedOutput.contains("source=unsigned")
            || sanitizedOutput.contains(" is not signed")
            || sanitizedOutput.contains("not notarized")
            || sanitizedOutput.contains("unidentified developer")
            || sanitizedOutput.contains("unknown developer")
            || sanitizedOutput.contains("developer cannot be verified")
    }

    private nonisolated func compactAssessmentOutput(_ output: String) -> String {
        String(DiagnosticLogger.compact(output).prefix(500))
    }

    private nonisolated func runAssessmentProcess(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        standardInput: Data? = nil
    ) async throws -> AssessmentProcessResult {
        let task = Process()
        task.executableURL = executableURL
        task.arguments = arguments

        // Most callers (spctl, codesign, hdiutil imageinfo) never read stdin, so
        // we detach it to ensure a prompt can never wedge the process while we
        // wait on it. The authenticated-mount path is the exception: it supplies
        // a passphrase via stdin (hdiutil -stdinpass), so we attach a pipe and
        // write it below.
        let inputPipe: Pipe? = standardInput == nil ? nil : Pipe()
        task.standardInput = inputPipe ?? FileHandle.nullDevice

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = errorPipe
        let outputCollector = ProcessPipeCollector(pipe: outputPipe)
        let errorCollector = ProcessPipeCollector(pipe: errorPipe)

        let terminationObserver = ProcessTerminationObserver()
        task.terminationHandler = { _ in
            terminationObserver.processTerminated()
        }

        try task.run()
        outputCollector.startReading()
        errorCollector.startReading()

        // Feed stdin (e.g. the DMG passphrase) once the process is running, then
        // close the write end so the tool sees EOF. Best-effort: if the process
        // already exited, the write throws on a broken pipe and we move on.
        if let inputPipe, let standardInput {
            let writeHandle = inputPipe.fileHandleForWriting
            do {
                try writeHandle.write(contentsOf: standardInput)
            } catch {
                DiagnosticLogger.shared.diagnostic("Failed to write process stdin: \(error)")
            }
            try? writeHandle.close()
        }

        var timedOut = false
        if await !terminationObserver.wait(timeout: timeout) {
            timedOut = true
            DiagnosticLogger.shared.diagnostic(
                "Assessment process timed out: \(executableURL.lastPathComponent) \(arguments.joined(separator: " "))"
            )
            let processIdentifier = task.processIdentifier
            task.terminate()
            if await !terminationObserver.wait(timeout: 1) {
                if task.isRunning {
                    kill(processIdentifier, SIGKILL)
                    _ = await terminationObserver.wait(timeout: 1)
                } else {
                    DiagnosticLogger.shared.diagnostic(
                        "Assessment process \(processIdentifier) already exited before SIGKILL escalation; skipping kill to avoid pid-reuse race"
                    )
                }
            }
        }

        let shouldWaitForPipeEOF = !task.isRunning
        let outputData = outputCollector.data(waitForEOF: shouldWaitForPipeEOF)
        let errorData = errorCollector.data(waitForEOF: shouldWaitForPipeEOF)
        let standardOutput = String(data: outputData, encoding: .utf8) ?? ""
        let standardError = String(data: errorData, encoding: .utf8) ?? ""

        return AssessmentProcessResult(
            exitStatus: task.isRunning ? nil : task.terminationStatus,
            standardOutput: standardOutput,
            standardError: standardError,
            timedOut: timedOut
        )
    }

    private func quarantineDecision(
        for assessment: AppSecurityAssessment,
        appName: String
    ) async -> QuarantineDecision {
        switch assessment.result {
        case .passed:
            return .removeQuarantine

        case .unverified:
            if UserPreferences.shared.skipUnverifiedAppWarning {
                return .removeQuarantine
            }
            return await showUnverifiedAppQuarantineDialog(appName: appName)

        case .blocked:
            return await showBlockedAppQuarantineDialog(appName: appName)
        }
    }

    private func showUnverifiedAppQuarantineDialog(appName: String) async -> QuarantineDecision {
        let displayName = appName.strippingAppSuffix
        return await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "macOS can't verify “\(displayName)”"
            alert.informativeText = [
                "macOS can't confirm this app is free of malware. Only continue if you trust the source.",
                "",
                "You can turn off this warning in Settings."
            ].joined(separator: "\n")

            if let iconPath = Bundle.main.path(forResource: "wizardhamster", ofType: "icns"),
               let icon = NSImage(contentsOfFile: iconPath) {
                alert.icon = icon
            }

            alert.addButton(withTitle: "Continue Install")
            alert.addButton(withTitle: "Open in Finder")
            alert.addButton(withTitle: "Cancel")

            presentHostedAlert(alert) { response in
                switch response {
                case .alertFirstButtonReturn:
                    continuation.resume(returning: .removeQuarantine)
                case .alertSecondButtonReturn:
                    continuation.resume(returning: .handleManually)
                default:
                    continuation.resume(returning: .cancel)
                }
            }
        }
    }

    private func showBlockedAppQuarantineDialog(appName: String) async -> QuarantineDecision {
        let displayName = appName.strippingAppSuffix
        return await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "“\(displayName)” may not be safe"
            alert.informativeText = "macOS flagged this app as damaged or potentially unsafe. EasyDMG won't install it automatically."

            if let iconPath = Bundle.main.path(forResource: "wizardhamster", ofType: "icns"),
               let icon = NSImage(contentsOfFile: iconPath) {
                alert.icon = icon
            }

            alert.addButton(withTitle: "Open in Finder")
            alert.addButton(withTitle: "Cancel")

            presentHostedAlert(alert) { response in
                if response == .alertFirstButtonReturn {
                    continuation.resume(returning: .handleManually)
                } else {
                    continuation.resume(returning: .cancel)
                }
            }
        }
    }

    // This prevents apps with auto-update mechanisms from incorrectly detecting
    // "needs update" states that can cause unwanted behavior.
    private func removeQuarantineAttributes(from path: String) async {
        diagnostic("Removing quarantine attributes from \(path)...")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        task.arguments = ["-dr", "com.apple.quarantine", path]

        let errorPipe = Pipe()
        task.standardError = errorPipe

        do {
            try task.run()
            task.waitUntilExit()

            if task.terminationStatus == 0 {
                diagnostic("✓ Quarantine attributes removed")
            } else {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
                diagnostic(
                    "Note: Could not remove quarantine attributes: \(DiagnosticLogger.compact(errorOutput))"
                )
            }
        } catch {
            diagnostic("Note: xattr command failed: \(error)")
        }
    }

    private func openForManualInstallation(
        mountPoint: String,
        dmgName: String,
        reason: ManualFallbackReason,
        appName: String? = nil,
        details: [String: String] = [:]
    ) async {
        var mergedDetails = details
        mergedDetails["dmg"] = dmgName
        mergedDetails["reason"] = reason.rawValue
        mergedDetails["target"] = "mounted_volume"
        mergedDetails["volume"] = volumeName(from: mountPoint)
        support(event: "manual_fallback", details: mergedDetails)

        diagnostic("Manual fallback opening mount point: \(mountPoint); reason=\(reason.rawValue)")
        NSWorkspace.shared.open(URL(fileURLWithPath: mountPoint))
        ProgressWindowController.shared.hide()

        diagnostic("✅ Opened mounted volume for manual installation")
        recordCompletion(
            dmgName: dmgName,
            outcome: "manual_fallback",
            details: ["reason": reason.rawValue]
        )
        await sendManualFallbackNotificationIfAvailable(dmgName: dmgName, appName: appName, reason: reason)
    }

    private func openForManualInstallation(
        dmgPath: String,
        dmgName: String,
        reason: ManualFallbackReason,
        notify: Bool = true,
        details: [String: String] = [:]
    ) async {
        var mergedDetails = details
        mergedDetails["dmg"] = dmgName
        mergedDetails["reason"] = reason.rawValue
        mergedDetails["target"] = "dmg"
        support(event: "manual_fallback", details: mergedDetails)

        diagnostic("Manual fallback opening DMG path: \(dmgPath); reason=\(reason.rawValue)")
        let dmgURL = URL(fileURLWithPath: dmgPath)
        let mounterURL = URL(fileURLWithPath: "/System/Library/CoreServices/DiskImageMounter.app")
        let configuration = NSWorkspace.OpenConfiguration()

        NSWorkspace.shared.open([dmgURL], withApplicationAt: mounterURL, configuration: configuration) { _, error in
            if let error {
                DiagnosticLogger.shared.diagnostic(
                    "❌ Failed to open DMG in DiskImageMounter (\(reason.rawValue)): \(error)"
                )
                DiagnosticLogger.shared.support(
                    event: "manual_fallback_open_error",
                    details: [
                        "dmg": dmgName,
                        "error_domain": (error as NSError).domain,
                        "error_code": String((error as NSError).code),
                        "reason": reason.rawValue
                    ]
                )
            }
        }
        ProgressWindowController.shared.hide()

        diagnostic("✅ Opened DMG in DiskImageMounter for manual installation: \(reason.rawValue)")
        recordCompletion(
            dmgName: dmgName,
            outcome: "manual_fallback",
            details: ["reason": reason.rawValue]
        )
        // Some callers suppress the notification — e.g. when the user explicitly
        // chose the macOS password prompt, the handoff is obvious and a notification
        // would just be noise.
        if notify {
            await sendManualFallbackNotificationIfAvailable(dmgName: dmgName, reason: reason)
        }
    }

    private func revealInFinder(path: String) {
        diagnostic("Revealing app in Finder: \(path)")
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "/Applications")
    }

    private func openInstalledAppIfNeeded(at path: String) async -> Bool {
        guard UserPreferences.shared.openAppAfterInstall else { return false }

        if currentFeedbackMode == .progressBar {
            showProgress("Chewing open the packaging...", progress: 0.9)

            async let didOpenApp = openInstalledApp(at: path)
            async let minimumDwell: Void = waitForOpenAppProgressDwell()

            let result = await didOpenApp
            await minimumDwell
            return result
        }

        return await openInstalledApp(at: path)
    }

    private func openInstalledApp(at path: String) async -> Bool {
        diagnostic("Opening installed app: \(path)")

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: path),
                configuration: configuration
            ) { _, error in
                if let error {
                    let nsError = error as NSError
                    DiagnosticLogger.shared.diagnostic("❌ Failed to open installed app: \(error)")
                    DiagnosticLogger.shared.support(
                        event: "open_installed_app_error",
                        details: [
                            "error_code": String(nsError.code),
                            "error_domain": nsError.domain
                        ]
                    )
                    continuation.resume(returning: false)
                } else {
                    continuation.resume(returning: true)
                }
            }
        }
    }

    private func waitForOpenAppProgressDwell() async {
        try? await Task.sleep(nanoseconds: 800_000_000)
    }

    private func handleError(_ message: String) async {
        diagnostic("Error: \(message)")
        showProgress("Error: \(message)", progress: 0.0)
        await sendFailureNotificationIfAvailable(message: message)

        try? await Task.sleep(nanoseconds: 3_000_000_000)
        ProgressWindowController.shared.hide()

        diagnostic("✅ Error handled, continuing queue if needed")
    }
}
