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
    let posixErrorCode: Int?
    let target: AppPermissionTargetDiagnostics

    static func granted(target: AppPermissionTargetDiagnostics) -> AppManagementProbeResult {
        AppManagementProbeResult(
            granted: true,
            errorDomain: nil,
            errorCode: nil,
            posixErrorCode: nil,
            target: target
        )
    }

    static func denied(error: NSError, target: AppPermissionTargetDiagnostics) -> AppManagementProbeResult {
        AppManagementProbeResult(
            granted: false,
            errorDomain: error.domain,
            errorCode: error.code,
            posixErrorCode: posixCode(in: error),
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

    private static func posixCode(in error: NSError) -> Int? {
        if error.domain == NSPOSIXErrorDomain { return error.code }
        guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else { return nil }
        return posixCode(in: underlying)
    }

    // EPERM on an otherwise writable, user-owned bundle is consistent with TCC.
    // Cocoa's generic permission error alone cannot distinguish TCC from filesystem access.
    var isLikelyAppManagementDenial: Bool {
        !granted && posixErrorCode == Int(EPERM)
            && target.ownerID == Int(geteuid())
            && !target.isRootOwned && !target.hasAppStoreMarkers
            && (target.posixPermissions.map { $0 & 0o200 != 0 } ?? false)
    }

    var retryFailureMessage: String {
        "Still waiting for permission. Enable EasyDMG in System Settings, then try again."
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
        } else if !probe.isLikelyAppManagementDenial {
            // Re-enter preflight so a changed target or unrelated failure uses normal recovery.
            finish(.retry)
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
        iconView.image = AlertIcon.image ?? NSApp.applicationIconImage
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
        } else if !probe.isLikelyAppManagementDenial {
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
        case manualInstallReady = "manual_install_ready"
        case securityAssessmentUnverified = "security_assessment_unverified"
        case securityAssessmentBlocked = "security_assessment_blocked"
        case installLocationDeclined = "install_location_declined"
        case installLocationUnavailable = "install_location_unavailable"
        case requiresSystemLocation = "requires_system_location"
        case appManagementDenied = "app_management_denied"
        case rootOwnedReplacementDenied = "root_owned_replacement_denied"
        case copyFailed = "copy_or_replace_failed"

        var isInstallationFailure: Bool {
            switch self {
            case .genericMountFailure, .invalidAppBundle, .appManagementDenied,
                 .rootOwnedReplacementDenied, .copyFailed:
                return true
            default:
                return false
            }
        }

        func notificationTitle(appName: String) -> String {
            switch self {
            case .genericMountFailure:
                return "Couldn't Open DMG"
            case .invalidAppBundle:
                return "Couldn't Install App"
            case .packageInstaller, .installerOrAuxiliaryApp:
                return "Run the Installer"
            // Dead copy as of the new password flow: every password path now exits
            // through resolveEncryptedMount, which either auto-installs, uses our own
            // dialog, or hands off to the macOS prompt with notify:false — so this
            // title is never shown. Kept for this release as a safety net until the
            // new flow has proven stable in the wild. (Note the message below is also
            // stale and describes the old behavior.)
            case .passwordProtected:
                return "\(appName) is password-protected"
            case .noAppFound:
                return "No App Found"
            case .multipleAppsFound:
                return "Multiple Apps Found"
            case .licenseRequired:
                return "Review License Agreement"
            case .manualInstallReady:
                return "Finish Installing"
            case .securityAssessmentUnverified, .securityAssessmentBlocked:
                return "EasyDMG needs manual install"
            case .installLocationDeclined, .installLocationUnavailable, .requiresSystemLocation:
                return "EasyDMG needs manual install"
            case .appManagementDenied:
                return "Permission Needed"
            case .rootOwnedReplacementDenied:
                return "Password Required"
            case .copyFailed:
                return "Couldn't Install App"
            }
        }

        func notificationMessage(appName: String) -> String? {
            switch self {
            case .genericMountFailure:
                return "Handing off \(appName) to Finder so you can install manually."
            case .invalidAppBundle:
                return "Invalid app bundle; switching to manual install."
            case .packageInstaller:
                return "\(appName) installs with a .pkg - open it in the Finder window and follow the steps."
            case .installerOrAuxiliaryApp:
                return "\(appName) comes with its own installer. Open it in the Finder window and follow the steps."
            // Dead + stale copy — see the note on .passwordProtected in
            // notificationTitle. Not shown by the current flow; left in for this
            // release pending confidence in the new password flow's stability.
            case .passwordProtected:
                return "Enter its password, then drag the app into Applications."
            case .noAppFound:
                return "Nothing to install automatically. Opened in Finder so you can take a look."
            case .multipleAppsFound:
                return "This DMG contains multiple apps. Choose which ones to move to Applications."
            case .licenseRequired:
                return "Review \(appName)'s license agreement in the window to continue."
            case .manualInstallReady:
                return "Drag \(appName) into Applications from the open Finder window."
            case .securityAssessmentUnverified, .securityAssessmentBlocked:
                // Security cases already showed a prompt to the user, so no follow-up notification.
                return nil
            case .installLocationDeclined, .installLocationUnavailable, .requiresSystemLocation:
                // The user just dismissed a dialog about this, so the notification would
                // be redundant — the opened window is the answer.
                return nil
            case .appManagementDenied:
                return "Drag \(appName) into Applications. To avoid this next time, enable EasyDMG in System Settings > Privacy & Security > App Management."
            case .rootOwnedReplacementDenied:
                // App Management can't grant ownership, so don't point the user at it.
                return "Drag \(appName) into Applications. Your Mac may ask for your password."
            case .copyFailed:
                return "Copy failed. Drag \(appName) into Applications from the open Finder window."
            }
        }
    }

    private enum MountResult: Sendable {
        case mounted(mountPoint: String, exitStatus: Int32)
        case passwordProtected(exitStatus: Int32)
        case failed(exitStatus: Int32?)
    }

    /// One mount attempt's outcome. `timedOut` lets the retry loop avoid
    /// re-running a 60s hang while still retrying a fast, transient failure.
    private struct MountAttemptOutcome: Sendable {
        let result: MountResult
        let timedOut: Bool
    }

    /// Outcome of an attempt to mount an encrypted DMG with a supplied passphrase.
    private enum AuthenticatedMountResult: Sendable {
        case mounted(mountPoint: String)
        case wrongPassword
        case timedOut
        case failed
    }

    private enum SavedPasswordMountResult: Sendable {
        case mounted(mountPoint: String)
        case dismissed
        case timedOut
        case unavailable
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
        case systemPromptStarted // macOS prompt is already handling the unlock
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

    private enum InstallFolderIssue: String {
        case missing = "applications_missing"
        case notDirectory = "applications_not_directory"
        case notWritable = "applications_not_writable"

        func message(for directory: URL) -> String {
            let display = directory.abbreviatedPath
            switch self {
            case .missing:
                return "\(display) does not exist"
            case .notDirectory:
                return "\(display) is not a folder"
            case .notWritable:
                return "\(display) is not writable"
            }
        }
    }

    /// Outcome of picking where an install should land. There is deliberately no
    /// failure case: an unusable folder always reaches a dialog offering a manual
    /// install, so the user is never left with an error and an unmounted volume.
    private enum InstallDirectoryResolution {
        case resolved(URL)
        case manualFallback(reason: ManualFallbackReason)
        case canceled(reason: String)
    }

    private enum InstallLocationFallbackDecision: Equatable {
        case cancel
        case installOnce
        case installAndRemember
    }

    /// Bundle contents that say something about where an app can be installed.
    ///
    /// Only `systemExtension` is treated as certain, and it is the only one that
    /// reaches the user: macOS refuses to activate a system extension or DriverKit
    /// driver unless its containing app sits in /Applications, so an install anywhere
    /// else is guaranteed broken. The other two are support breadcrumbs only: they
    /// can explain an app's location-sensitive behavior without changing the install.
    private enum SystemLocationMarker: String {
        case systemExtension = "system_extension"
        case launchDaemon = "launch_daemon"
        case privilegedHelper = "privileged_helper"
    }

    private enum SystemLocationDecision: Equatable {
        case installToSystem
        case openInFinder
        case cancel
    }

    private enum AppBundleValidationIssue: String {
        case missingInfoPlist = "missing_info_plist"
        case unreadableInfoPlist = "unreadable_info_plist"
        case notApplicationBundle = "not_application_bundle"
        case missingExecutableFile = "missing_executable_file"
        case executableNotExecutable = "executable_not_executable"
    }

    @Published var isProcessing = false

    /// Called once the DMG queue is empty. The app delegate owns the quit decision;
    /// when unset the processor falls back to quitting on its own.
    var onQueueDrained: (() -> Void)?

    private var currentFeedbackMode: FeedbackMode = .progressBar
    private var pendingDMGURLs: [URL] = []
    private var isDrainingQueue = false
    private var appManagementPermissionWindowController: AppManagementPermissionWindowController?
    private var didHandleAppManagementRestartRequest = false
    private var usedMagicMessages = Set<String>()

    // Progressive messages shown if an operation takes too long.
    private let magicMessageInterval: UInt64 = 3_000_000_000
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

    private func sendFailureNotificationIfAvailable(title: String, message: String) async {
        guard UserPreferences.shared.feedbackMode != .silent
            || UserPreferences.shared.notifyOnFailureInSilentMode else {
            return
        }

        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.canShowVisibleAlerts else {
            diagnostic("Failure notification unavailable: \(settings.diagnosticDescription)")
            return
        }

        await sendNotification(title: title, message: message)
    }

    private func sendManualFallbackNotificationIfAvailable(
        dmgName: String,
        appName: String? = nil,
        reason: ManualFallbackReason
    ) async {
        if reason.isInstallationFailure {
            let resolvedName = manualFallbackAppName(explicit: appName, dmgName: dmgName)
            if let message = reason.notificationMessage(appName: resolvedName) {
                await sendFailureNotificationIfAvailable(
                    title: reason.notificationTitle(appName: resolvedName), message: message
                )
            }
            return
        }
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

        // The app delegate decides what happens next: normally quit, but stay alive
        // when the user still has the settings window open.
        if let onQueueDrained {
            onQueueDrained()
        } else {
            diagnostic("✅ Processing queue complete, quitting app")
            NSApp.terminate(nil)
        }
    }

    // Process a DMG file (main entry point)
    func processDMG(at url: URL) async {
        enqueueDMGs([url])
    }

    private func processNextDMG(at url: URL) async {
        let currentDMGName = url.lastPathComponent
        resetMagicMessageSession()
        support(event: "dmg_begin", details: ["dmg": currentDMGName])

        await requestNotificationPermissionsIfNeeded()

        currentFeedbackMode = await effectiveFeedbackMode()
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
            await handleError(
                title: "Couldn't Install App",
                message: "Couldn't find \(url.lastPathComponent). It may have been moved or deleted."
            )
            return
        }

        // Capture ownership before any mount attempt: hdiutil can also report
        // success for a volume that was already attached before we started.
        let previouslyMountedPoint = await existingMountPoint(
            forDMGPath: url.path,
            dmgName: currentDMGName
        )
        let mountPoint: String

        // Encrypted DMGs need special handling: a plain `hdiutil attach` — and even
        // the `imageinfo` license preflight — would surface the macOS SecurityAgent
        // password prompt and block on it, racing against our own progress flow.
        // Detect encryption up front with the header-only `isencrypted` check, then
        // gate the entire flow on our own password prompt so nothing (Gatekeeper
        // check, dialogs) proceeds until the user has entered the passphrase. The
        // standard passphrase-free license preflight is skipped for encrypted
        // images: the license flag *can* be read without the passphrase, but doing
        // so makes hdiutil raise the SecurityAgent prompt (an extra prompt the user
        // must clear). Instead the license check runs later, inside the unlock loop,
        // reusing the passphrase the user supplies (see checkEncryptedLicenseAgreement).
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
                if let existingMountPoint = await existingMountPoint(
                    forDMGPath: url.path,
                    dmgName: currentDMGName
                ) {
                    await openMountedLicensedDMGForManualInstallation(
                        mountPoint: existingMountPoint,
                        dmgName: currentDMGName
                    )
                } else {
                    await openForManualInstallation(
                        dmgPath: url.path,
                        dmgName: currentDMGName,
                        reason: .licenseRequired
                    )
                }
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
        guard let appPath = await scanMountedContents(
            mountPoint: mountPoint,
            dmgName: currentDMGName
        ) else {
            return
        }

        await installApp(
            from: appPath,
            mountPoint: mountPoint,
            dmgPath: url.path,
            dmgName: currentDMGName,
            preserveMountOnCancel: previouslyMountedPoint == mountPoint
        )
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
        support(
            event: "encryption_preflight",
            details: ["dmg": dmgName, "result": encrypted ? "encrypted" : "not_encrypted"]
        )
        return encrypted
    }

    private func hasLicenseAgreement(dmgPath: String, dmgName: String) async -> Bool {

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

    /// Sorts a mounted volume's top-level contents and opens Finder for every
    /// outcome that needs a manual handoff. Only a single valid app comes back,
    /// so each caller decides what to do with it: the normal flow installs it,
    /// an already-mounted licensed image hands it to the user.
    private func scanMountedContents(
        mountPoint: String,
        dmgName: String,
        licenseAlreadyMounted: Bool = false
    ) async -> String? {
        let appFiles = findAppFiles(in: mountPoint)
        let packageFiles = findPackageFiles(in: mountPoint)
        let logPrefix = licenseAlreadyMounted ? "Manual fallback (license already mounted)" : "Manual fallback"

        func withContext(_ details: [String: String]) -> [String: String] {
            var merged = details
            merged["volume"] = volumeName(from: mountPoint)
            if licenseAlreadyMounted {
                merged["license_already_mounted"] = "true"
            }
            return merged
        }

        if !packageFiles.isEmpty {
            let packageNames = appNames(from: packageFiles)
            diagnostic("\(logPrefix): package installer(s) found: \(packageNames)")
            await openForManualInstallation(
                mountPoint: mountPoint,
                dmgName: dmgName,
                reason: .packageInstaller,
                details: withContext([
                    "app_count": String(appFiles.count),
                    "package_count": String(packageFiles.count),
                    "package_names": joinedNames(packageNames)
                ])
            )
            return nil
        }

        let mainApps = appFiles.filter { path in
            !isInstallerLikeApp(at: path)
        }

        let finalAppFiles = mainApps.count == 1 ? mainApps : appFiles
        let finalAppNames = appNames(from: finalAppFiles)
        support(
            event: "app_scan_result",
            details: withContext([
                "app_count": String(finalAppFiles.count),
                "app_names": joinedNames(finalAppNames),
                "dmg": dmgName,
                "package_count": String(packageFiles.count),
                "raw_app_count": String(appFiles.count)
            ])
        )

        switch finalAppFiles.count {
        case 0:
            diagnostic("\(logPrefix): no .app files found at \(mountPoint)")
            await openForManualInstallation(
                mountPoint: mountPoint,
                dmgName: dmgName,
                reason: .noAppFound,
                details: withContext(["app_count": "0"])
            )
            return nil

        case 1:
            let appPath = finalAppFiles[0]
            let candidateName = appName(from: appPath)

            if isInstallerLikeApp(at: appPath) {
                diagnostic("\(logPrefix): single app looks like an installer or auxiliary app: \(candidateName)")
                await openForManualInstallation(
                    mountPoint: mountPoint,
                    dmgName: dmgName,
                    reason: .installerOrAuxiliaryApp,
                    appName: candidateName,
                    details: withContext([
                        "app": candidateName,
                        "app_count": "1"
                    ])
                )
                return nil
            }

            if let issue = appBundleValidationIssue(for: appPath) {
                diagnostic("\(logPrefix): invalid app bundle (\(issue.rawValue)): \(candidateName)")
                await openForManualInstallation(
                    mountPoint: mountPoint,
                    dmgName: dmgName,
                    reason: .invalidAppBundle,
                    appName: candidateName,
                    details: withContext([
                        "app": candidateName,
                        "app_count": "1",
                        "validation_issue": issue.rawValue
                    ])
                )
                return nil
            }

            return appPath

        default:
            diagnostic("\(logPrefix): multiple .app files found (\(finalAppFiles.count)): \(finalAppNames)")
            await openForManualInstallation(
                mountPoint: mountPoint,
                dmgName: dmgName,
                reason: .multipleAppsFound,
                details: withContext([
                    "app_count": String(finalAppFiles.count),
                    "app_names": joinedNames(finalAppNames)
                ])
            )
            return nil
        }
    }

    /// A licensed image that is already mounted has already passed macOS's
    /// agreement gate for this mount. Keep the install manual, but inspect the
    /// visible top-level contents so the notification explains why EasyDMG is
    /// handing control back to Finder instead of repeating the license prompt.
    private func openMountedLicensedDMGForManualInstallation(
        mountPoint: String,
        dmgName: String
    ) async {
        guard let appPath = await scanMountedContents(
            mountPoint: mountPoint,
            dmgName: dmgName,
            licenseAlreadyMounted: true
        ) else {
            return
        }

        let candidateName = appName(from: appPath)
        diagnostic("Mounted licensed DMG is ready for manual installation: \(candidateName)")
        await openForManualInstallation(
            mountPoint: mountPoint,
            dmgName: dmgName,
            reason: .manualInstallReady,
            appName: candidateName,
            details: [
                "app": candidateName,
                "app_count": "1",
                "license_already_mounted": "true",
                "volume": volumeName(from: mountPoint),
            ]
        )
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

    /// Normalize a path for comparing against `hdiutil info`'s `image-path`, which
    /// reports the fully resolved location. Without this, /Users vs the symlinked
    /// /System/Volumes/Data/Users form (or any other symlink in the path) would
    /// look like two different images.
    private nonisolated static func normalizedImagePath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Scan `hdiutil info -plist` for an already-attached copy of `dmgPath` and
    /// return its mount point, if any. Matching the source image rather than only
    /// the volume name keeps encrypted unlocks and licensed manual handoffs tied
    /// to the exact DMG the user opened.
    private nonisolated static func parseExistingMountPoint(
        fromInfoPlist data: Data,
        matching dmgPath: String
    ) -> String? {
        let target = normalizedImagePath(dmgPath)
        do {
            let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            guard let root = plist as? [String: Any],
                  let images = root["images"] as? [[String: Any]] else {
                return nil
            }

            for image in images {
                guard let imagePath = image["image-path"] as? String,
                      normalizedImagePath(imagePath) == target,
                      let entities = image["system-entities"] as? [[String: Any]] else {
                    continue
                }
                for entity in entities {
                    if let mountPoint = entity["mount-point"] as? String, !mountPoint.isEmpty {
                        return mountPoint
                    }
                }
            }
            return nil
        } catch {
            DiagnosticLogger.shared.diagnostic("Failed to parse hdiutil info plist output: \(error)")
            return nil
        }
    }

    /// Return the mount point of an already-open copy of this DMG, or nil if it
    /// isn't currently attached. Encrypted images use this to skip a redundant
    /// password prompt; licensed images use it to replace a stale agreement
    /// notification with guidance based on the contents already visible in Finder.
    private func existingMountPoint(
        forDMGPath dmgPath: String,
        dmgName: String,
        timeout: TimeInterval = 5,
        logFailure: Bool = true
    ) async -> String? {
        let result: AssessmentProcessResult
        do {
            result = try await runAssessmentProcess(
                executableURL: URL(fileURLWithPath: "/usr/bin/hdiutil"),
                arguments: ["info", "-plist"],
                timeout: timeout
            )
        } catch {
            if logFailure {
                diagnostic("Could not check for an already-mounted copy of \(dmgName): \(error)")
            }
            return nil
        }

        guard !result.timedOut, result.exitStatus == 0 else {
            return nil
        }

        return Self.parseExistingMountPoint(
            fromInfoPlist: Data(result.standardOutput.utf8),
            matching: dmgPath
        )
    }

    /// Keep disk-image discovery off the main actor and stop waiting after five seconds.
    /// An unavailable snapshot disables broad app matching for this install.
    private func mountedImageRootsForDiscovery() async -> [URL]? {
        do {
            let result = try await runAssessmentProcess(
                executableURL: URL(fileURLWithPath: "/usr/bin/hdiutil"),
                arguments: ["info", "-plist"],
                timeout: 5
            )
            guard !result.timedOut, result.exitStatus == 0,
                  let plist = try? PropertyListSerialization.propertyList(
                    from: Data(result.standardOutput.utf8), format: nil
                  ),
                  let info = plist as? [String: Any],
                  let images = info["images"] as? [[String: Any]] else {
                diagnostic("Mounted-image discovery unavailable; using original app filename")
                return nil
            }
            return images.flatMap { $0["system-entities"] as? [[String: Any]] ?? [] }
                .compactMap { $0["mount-point"] as? String }
                .map { URL(fileURLWithPath: $0) }
        } catch {
            diagnostic("Could not list mounted images for app discovery: \(error)")
            return nil
        }
    }

    /// Probe a leftover mount before reusing it. A mount whose backing store is gone
    /// (unplugged drive, dropped network share) can block directory reads
    /// indefinitely, so list it in a separate process that the timeout can kill
    /// instead of reading it directly on the main actor.
    private func isMountPointReadable(_ mountPoint: String, timeout: TimeInterval = 5) async -> Bool {
        do {
            let result = try await runAssessmentProcess(
                executableURL: URL(fileURLWithPath: "/bin/ls"),
                arguments: [mountPoint],
                timeout: timeout
            )
            return !result.timedOut && result.exitStatus == 0
        } catch {
            diagnostic("Could not probe existing mount \(mountPoint): \(error)")
            return false
        }
    }

    /// Ask DiskImageMounter to open the encrypted image, then watch for the mounted
    /// volume. This lets macOS use a saved Keychain passphrase or show its own
    /// password prompt without EasyDMG ever showing a competing prompt.
    private func mountEncryptedDMGWithSavedPasswordIfAvailable(
        at path: String,
        dmgName: String
    ) async -> SavedPasswordMountResult {
        support(event: "saved_password_mount_start", details: ["dmg": dmgName])

        let runningApp = await openDMGInDiskImageMounterForUnlock(path: path, dmgName: dmgName)
        guard let runningApp else {
            support(
                event: "saved_password_mount_result",
                details: ["dmg": dmgName, "result": "open_failed"]
            )
            return .unavailable
        }

        func finishMounted(_ mountPoint: String) -> SavedPasswordMountResult {
            diagnostic("Encrypted DMG unlocked by macOS at \(mountPoint)")
            support(
                event: "saved_password_mount_result",
                details: [
                    "dmg": dmgName,
                    "result": "success",
                    "volume": volumeName(from: mountPoint),
                ]
            )
            return .mounted(mountPoint: mountPoint)
        }

        let deadline = Date().addingTimeInterval(90)
        let earliestDismissalCheck = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            if let mountPoint = await existingMountPoint(
                forDMGPath: path,
                dmgName: dmgName,
                timeout: 2,
                logFailure: false
            ) {
                return finishMounted(mountPoint)
            }

            if Date() >= earliestDismissalCheck && runningApp.isTerminated {
                if let mountPoint = await existingMountPoint(
                    forDMGPath: path,
                    dmgName: dmgName,
                    timeout: 2,
                    logFailure: false
                ) {
                    return finishMounted(mountPoint)
                }

                diagnostic("DiskImageMounter closed without mounting \(dmgName)")
                support(
                    event: "saved_password_mount_result",
                    details: ["dmg": dmgName, "result": "system_prompt_dismissed"]
                )
                return .dismissed
            }

            try? await Task.sleep(nanoseconds: 350_000_000)
        }

        diagnostic("macOS password prompt did not mount \(dmgName) before EasyDMG stopped waiting")
        support(
            event: "saved_password_mount_result",
            details: ["dmg": dmgName, "result": "system_prompt_wait_timeout"]
        )
        return .timedOut
    }

    private func openDMGInDiskImageMounterForUnlock(path: String, dmgName: String) async -> NSRunningApplication? {
        await withCheckedContinuation { continuation in
            let dmgURL = URL(fileURLWithPath: path)
            let mounterURL = URL(fileURLWithPath: "/System/Library/CoreServices/DiskImageMounter.app")
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true

            NSWorkspace.shared.open([dmgURL], withApplicationAt: mounterURL, configuration: configuration) { app, error in
                if let error {
                    DiagnosticLogger.shared.diagnostic(
                        "Failed to open encrypted DMG in DiskImageMounter: \(error)"
                    )
                    DiagnosticLogger.shared.support(
                        event: "saved_password_mount_open_error",
                        details: [
                            "dmg": dmgName,
                            "error_domain": (error as NSError).domain,
                            "error_code": String((error as NSError).code),
                        ]
                    )
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: app)
                }
            }
        }
    }

    private func mountDMG(at path: String, dmgName: String, progress: Double) async -> MountResult {
        // A known-good DMG occasionally fails to mount on the first try and then
        // mounts fine moments later — a transient macOS/hdiutil glitch rather than
        // a bad image. Retry a generic failure a couple of times with a short
        // backoff before giving up to manual. We deliberately do NOT retry:
        //   • a password/encryption failure — it has its own prompt + retry flow, or
        //   • a timeout — a 60s hang shouldn't be multiplied into minutes of waiting.
        let maxAttempts = 3
        let retryBackoff: UInt64 = 600_000_000 // 0.6s

        var lastResult: MountResult = .failed(exitStatus: nil)

        for attempt in 1...maxAttempts {
            support(event: "mount_start", details: ["dmg": dmgName, "attempt": String(attempt)])

            let outcome = await withMagicFallback(
                message: "Mounting disk image...",
                progress: progress
            ) { () -> MountAttemptOutcome in
                let processResult: AssessmentProcessResult
                do {
                    processResult = try await self.runAssessmentProcess(
                        executableURL: URL(fileURLWithPath: "/usr/bin/hdiutil"),
                        arguments: ["attach", path, "-nobrowse", "-readonly", "-noautoopen", "-plist"],
                        timeout: 60
                    )
                } catch {
                    DiagnosticLogger.shared.diagnostic("Error mounting DMG: \(error)")
                    return MountAttemptOutcome(result: .failed(exitStatus: nil), timedOut: false)
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
                        return MountAttemptOutcome(
                            result: .passwordProtected(exitStatus: processResult.exitStatus ?? -1),
                            timedOut: false
                        )
                    }

                    return MountAttemptOutcome(
                        result: .failed(exitStatus: processResult.exitStatus),
                        timedOut: processResult.timedOut
                    )
                }

                let data = Data(processResult.standardOutput.utf8)
                guard let mountPoint = Self.parseMountPoint(fromAttachPlist: data) else {
                    return MountAttemptOutcome(result: .failed(exitStatus: processResult.exitStatus), timedOut: false)
                }

                return MountAttemptOutcome(
                    result: .mounted(mountPoint: mountPoint, exitStatus: processResult.exitStatus ?? 0),
                    timedOut: false
                )
            }

            let result = outcome.result
            lastResult = result

            var details = ["dmg": dmgName, "attempt": String(attempt)]
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

            // Success and password/encryption failures are terminal — hand straight
            // back to the caller. Only a fast, generic failure is worth retrying.
            switch result {
            case .mounted, .passwordProtected:
                return result
            case let .failed(exitStatus):
                // A leftover attachment of this exact image (a prior run, Finder,
                // Quick Look) makes a fresh attach fail with "Resource busy", and
                // retrying can't clear it. Reuse that mount like the encrypted path
                // does. If it's unreadable, retrying won't help either, so stop and
                // let the caller fall back to manual.
                if let existingMountPoint = await existingMountPoint(forDMGPath: path, dmgName: dmgName) {
                    guard await isMountPointReadable(existingMountPoint) else {
                        diagnostic("DMG already mounted at \(existingMountPoint) but it is unreadable; not reusing")
                        support(
                            event: "mount_reuse",
                            details: [
                                "dmg": dmgName,
                                "attempt": String(attempt),
                                "result": "unreadable",
                                "volume": volumeName(from: existingMountPoint),
                            ]
                        )
                        return result
                    }
                    diagnostic("DMG already mounted at \(existingMountPoint); reusing existing mount")
                    support(
                        event: "mount_reuse",
                        details: [
                            "dmg": dmgName,
                            "attempt": String(attempt),
                            "result": "already_mounted",
                            "volume": volumeName(from: existingMountPoint),
                        ]
                    )
                    return .mounted(mountPoint: existingMountPoint, exitStatus: exitStatus ?? -1)
                }
                guard !outcome.timedOut, attempt < maxAttempts else {
                    return result
                }
                DiagnosticLogger.shared.diagnostic(
                    "Mount attempt \(attempt) failed; retrying (attempt \(attempt + 1) of \(maxAttempts))"
                )
                try? await Task.sleep(nanoseconds: retryBackoff)
            }
        }

        return lastResult
    }

    /// Prompt for the DMG passphrase and attempt an authenticated mount, retrying
    /// on a wrong password as many times as the user wants. The distinct outcomes
    /// let the caller honor the user's intent: a cancel aborts the install rather
    /// than dropping to the manual flow (which would only re-show a password prompt
    /// the user just dismissed), while opting into the macOS prompt hands the DMG
    /// to DiskImageMounter. After two failed attempts the prompt offers that escape
    /// hatch in case our own field can't unlock an image macOS itself could.
    private func unlockEncryptedDMG(dmgPath: String, dmgName: String) async -> EncryptedUnlockOutcome {
        // If this DMG is already attached — from a prior run, a leftover mount, or
        // the user having opened it manually — it has already been unlocked with the
        // correct passphrase. Reuse it and skip the prompt entirely: asking again
        // would be pointless (the contents are already exposed) and, worse, hdiutil
        // accepts any passphrase against an already-attached image, so a mistyped
        // password would appear to "work."
        if let mountPoint = await existingMountPoint(forDMGPath: dmgPath, dmgName: dmgName) {
            diagnostic("Encrypted DMG already mounted at \(mountPoint); reusing without prompting")
            support(event: "password_unlock", details: ["dmg": dmgName, "result": "already_mounted"])
            return .unlocked(mountPoint: mountPoint)
        }

        showProgress("Waiting for macOS...", progress: 0.0)
        switch await mountEncryptedDMGWithSavedPasswordIfAvailable(at: dmgPath, dmgName: dmgName) {
        case let .mounted(mountPoint):
            // No license check here. DiskImageMounter enforces any software license
            // agreement natively before it will mount — so holding a mount point means
            // the user has already seen and accepted it. Re-checking with the
            // passphrase-free `imageinfo` would only re-trigger the macOS SecurityAgent
            // password prompt (a second prompt), which is exactly what we're avoiding.
            // The hdiutil-based paths (unencrypted mount, manual passphrase fallback)
            // keep their own checks because hdiutil silently skips the agreement.
            support(event: "password_unlock", details: ["dmg": dmgName, "result": "saved_password"])
            return .unlocked(mountPoint: mountPoint)

        case .dismissed:
            support(event: "password_unlock", details: ["dmg": dmgName, "result": "system_prompt_dismissed"])
            return .cancelled

        case .timedOut:
            support(event: "password_unlock", details: ["dmg": dmgName, "result": "saved_password_timeout"])
            return .systemPromptStarted

        case .unavailable:
            support(event: "password_unlock", details: ["dmg": dmgName, "result": "saved_password_unavailable"])
        }

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
                switch await checkEncryptedLicenseAgreementWithRetry(dmgPath: dmgPath, dmgName: dmgName, password: password) {
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

                switch await mountEncryptedDMGWithRetry(at: dmgPath, dmgName: dmgName, password: password) {
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

                case .timedOut:
                    support(event: "password_unlock", details: ["dmg": dmgName, "result": "mount_timeout", "attempt": String(attempt)])
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

        case .systemPromptStarted:
            diagnostic("Encrypted DMG handed to macOS password prompt; stopping EasyDMG prompt flow")
            support(
                event: "manual_fallback",
                details: [
                    "dmg": dmgName,
                    "reason": ManualFallbackReason.passwordProtected.rawValue,
                    "system_prompt_started": "true",
                    "target": "dmg",
                ]
            )
            ProgressWindowController.shared.hide()
            recordCompletion(
                dmgName: dmgName,
                outcome: "manual_fallback",
                details: ["reason": ManualFallbackReason.passwordProtected.rawValue]
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

    private nonisolated static func looksLikeEncryptedAuthFailure(_ output: String) -> Bool {
        // In the unsandboxed app path, wrong passphrases surface as
        // "Authentication error" across both imageinfo and attach. "Device not
        // configured" is ambiguous and can be introduced by sandboxed hdiutil
        // runs, so it is deliberately excluded: retry/drop to manual, do not
        // call it a wrong password.
        let lowercasedOutput = output.lowercased()
        return lowercasedOutput.contains("authentication")
            || lowercasedOutput.contains("passphrase")
            || lowercasedOutput.contains("password")
    }

    private func checkEncryptedLicenseAgreementWithRetry(
        dmgPath: String,
        dmgName: String,
        password: String
    ) async -> AuthenticatedLicenseCheckResult {
        let maxAttempts = 2
        let retryBackoff: UInt64 = 600_000_000

        for attempt in 1...maxAttempts {
            let result = await checkEncryptedLicenseAgreement(
                dmgPath: dmgPath,
                dmgName: dmgName,
                password: password,
                attempt: attempt
            )

            guard case .failed = result, attempt < maxAttempts else {
                return result
            }

            diagnostic(
                "Encrypted license metadata check failed; retrying (attempt \(attempt + 1) of \(maxAttempts))"
            )
            support(
                event: "license_preflight_retry",
                details: [
                    "dmg": dmgName,
                    "after_attempt": String(attempt),
                    "next_attempt": String(attempt + 1),
                ]
            )
            try? await Task.sleep(nanoseconds: retryBackoff)
        }

        return .failed
    }

    /// Check encrypted DMG metadata using the passphrase the user just entered.
    /// This preserves the license-agreement guard without invoking the system
    /// password prompt before EasyDMG's own retry loop has made progress.
    private func checkEncryptedLicenseAgreement(
        dmgPath: String,
        dmgName: String,
        password: String,
        attempt: Int = 1
    ) async -> AuthenticatedLicenseCheckResult {

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
                details: [
                    "dmg": dmgName,
                    "result": "encrypted_error",
                    "attempt": String(attempt),
                ]
            )
            return .failed
        }

        guard !result.timedOut, result.exitStatus == 0 else {
            let combinedOutput = [result.standardError, result.standardOutput]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let looksLikeAuthFailure = Self.looksLikeEncryptedAuthFailure(combinedOutput)
            let outcome = result.timedOut
                ? "encrypted_imageinfo_timeout"
                : (looksLikeAuthFailure ? "wrong_password" : "encrypted_imageinfo_failed")
            let exitStatus = result.exitStatus.map { String($0) } ?? "none"
            diagnostic(
                "Encrypted license metadata check \(outcome) on attempt \(attempt): "
                    + DiagnosticLogger.compact(combinedOutput)
            )
            support(
                event: "license_preflight",
                details: [
                    "dmg": dmgName,
                    "result": outcome,
                    "exit_status": exitStatus,
                    "attempt": String(attempt),
                ]
            )
            return looksLikeAuthFailure ? .wrongPassword : .failed
        }

        do {
            let data = Data(result.standardOutput.utf8)
            let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            let hasLicense = Self.plistContainsLicenseAgreement(plist)
            support(
                event: "license_preflight",
                details: [
                    "dmg": dmgName,
                    "result": hasLicense ? "license_required" : "none",
                    "encrypted": "true",
                    "attempt": String(attempt),
                ]
            )
            return hasLicense ? .licenseRequired : .noLicense
        } catch {
            diagnostic("Error parsing encrypted license metadata plist: \(error)")
            support(
                event: "license_preflight",
                details: [
                    "dmg": dmgName,
                    "result": "encrypted_parse_error",
                    "attempt": String(attempt),
                ]
            )
            return .failed
        }
    }

    private func mountEncryptedDMGWithRetry(
        at path: String,
        dmgName: String,
        password: String
    ) async -> AuthenticatedMountResult {
        let maxAttempts = 2
        let retryBackoff: UInt64 = 600_000_000

        for attempt in 1...maxAttempts {
            let result = await mountEncryptedDMG(
                at: path,
                dmgName: dmgName,
                password: password,
                attempt: attempt
            )

            switch result {
            case .failed where attempt < maxAttempts:
                diagnostic(
                    "Authenticated mount failed; retrying (attempt \(attempt + 1) of \(maxAttempts))"
                )
                support(
                    event: "authenticated_mount_retry",
                    details: [
                        "dmg": dmgName,
                        "after_attempt": String(attempt),
                        "next_attempt": String(attempt + 1),
                    ]
                )
                try? await Task.sleep(nanoseconds: retryBackoff)
                continue

            // A timeout is not retried here; unlike a near-instant failure, each
            // attempt costs the full hdiutil timeout. Propagate it so the caller
            // can record mount_timeout before dropping to manual.
            default:
                return result
            }
        }

        return .failed
    }

    /// Mount an encrypted DMG using a passphrase supplied over stdin
    /// (`hdiutil -stdinpass`). The passphrase never touches argv — where it would
    /// be visible in `ps` — and is never written to the diagnostic log.
    private func mountEncryptedDMG(at path: String, dmgName: String, password: String, attempt: Int = 1) async -> AuthenticatedMountResult {
        support(
            event: "authenticated_mount_start",
            details: ["dmg": dmgName, "attempt": String(attempt)]
        )

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
            support(
                event: "authenticated_mount_result",
                details: [
                    "dmg": dmgName,
                    "result": "error",
                    "attempt": String(attempt),
                ]
            )
            return .failed
        }

        guard !result.timedOut, result.exitStatus == 0 else {
            // A wrong passphrase makes hdiutil exit with an "Authentication error";
            // treat auth-flavored failures as retryable and anything else (corrupt
            // image, I/O failure) as a hard failure that drops to manual.
            let combinedOutput = [result.standardError, result.standardOutput]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let looksLikeAuthFailure = Self.looksLikeEncryptedAuthFailure(combinedOutput)
            let resultLabel = result.timedOut
                ? "timeout"
                : (looksLikeAuthFailure ? "wrong_password" : "failed")
            diagnostic("Authenticated mount did not succeed: \(resultLabel)")
            if !result.standardError.isEmpty {
                diagnostic("hdiutil -stdinpass output: \(DiagnosticLogger.compact(combinedOutput))")
            }
            support(
                event: "authenticated_mount_result",
                details: [
                    "dmg": dmgName,
                    "result": resultLabel,
                    "attempt": String(attempt),
                ]
            )

            if looksLikeAuthFailure {
                return .wrongPassword
            }

            return result.timedOut ? .timedOut : .failed
        }

        guard let mountPoint = Self.parseMountPoint(fromAttachPlist: Data(result.standardOutput.utf8)) else {
            diagnostic("Authenticated mount succeeded but no mount point was found")
            support(
                event: "authenticated_mount_result",
                details: [
                    "dmg": dmgName,
                    "result": "no_mount_point",
                    "attempt": String(attempt),
                ]
            )
            return .failed
        }

        support(
            event: "authenticated_mount_result",
            details: [
                "dmg": dmgName,
                "result": "success",
                "volume": volumeName(from: mountPoint),
                "attempt": String(attempt),
            ]
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

                alert.icon = AlertIcon.image

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

    /// Returns how many more bytes must be freed before installing, or nil if there's enough room.
    /// Includes a 500MB safety buffer on top of the app's size.
    private func diskSpaceShortfall(requiredBytes: UInt64, in directory: URL) -> UInt64? {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: directory.path),
              let freeSpace = attrs[.systemFreeSize] as? UInt64 else {
            return nil
        }

        let bufferSize: UInt64 = 500 * 1024 * 1024
        let neededSpace = requiredBytes + bufferSize
        return freeSpace > neededSpace ? nil : neededSpace - freeSpace + 1
    }

    private func notEnoughSpaceMessage(shortfall: UInt64) -> String {
        "Free up \(ByteCountFormatter.string(fromByteCount: Int64(shortfall), countStyle: .file)) on your Mac, then try again."
    }

    private struct ExplainedCopyFailure {
        let reason: String
        let title: String
        let message: String
    }

    /// Explains a copy failure only when the cause can be confirmed by looking at
    /// the situation directly, not guessed from an error code. Anything else returns
    /// nil and keeps the manual handoff.
    private func explainCopyFailure(
        _ error: Error,
        appPath: String,
        mountPoint: String,
        installDirectory: URL,
        appSize: UInt64
    ) -> ExplainedCopyFailure? {
        let fileManager = FileManager.default

        // The disk image was ejected, or the drive holding the install folder was
        // unplugged, while the copy was running.
        if !fileManager.fileExists(atPath: mountPoint)
            || !fileManager.fileExists(atPath: appPath)
            || !fileManager.fileExists(atPath: installDirectory.path) {
            return ExplainedCopyFailure(
                reason: "source_or_destination_disconnected",
                title: "Install Interrupted",
                message: "Something was disconnected. Open the DMG again to retry."
            )
        }

        // Disk-full is a documented error, but confirm with a fresh space check so the
        // message can say how much to free up. If space has since freed up, stay generic.
        if isOutOfSpaceError(error),
           let shortfall = diskSpaceShortfall(requiredBytes: appSize, in: installDirectory) {
            return ExplainedCopyFailure(
                reason: "insufficient_disk_space",
                title: "Not Enough Space",
                message: notEnoughSpaceMessage(shortfall: shortfall)
            )
        }

        if InstallLocation.hasIncompatibleMacAppFileSystem(installDirectory) {
            let driveName = (try? installDirectory.resourceValues(forKeys: [.volumeLocalizedNameKey]))?
                .volumeLocalizedName ?? "This drive"
            return ExplainedCopyFailure(
                reason: "incompatible_drive_format",
                title: "Can't Install to Drive",
                message: "\(driveName) can't store Mac apps. Choose another install folder in EasyDMG Settings."
            )
        }

        return nil
    }

    /// macOS often wraps the real cause inside a generic write error, so check the
    /// wrapped errors too.
    private func isOutOfSpaceError(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let nsError = current {
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError { return true }
            if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC) { return true }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    private func validateInstallDirectory(
        _ directory: URL,
        createUserApplicationsIfMissing: Bool = true
    ) -> InstallFolderIssue? {
        var isDirectory: ObjCBool = false

        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            // ~/Applications doesn't exist on a fresh account until something creates
            // it, so create it on demand rather than reporting it as a broken setting.
            guard directory == UserPreferences.shared.userApplicationsDirectory,
                  createUserApplicationsIfMissing else {
                return .missing
            }

            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                diagnostic("Created install folder \(directory.path)")
                return nil
            } catch {
                diagnostic("Failed to create install folder \(directory.path): \(error)")
                return .missing
            }
        }

        guard isDirectory.boolValue else {
            return .notDirectory
        }

        guard FileManager.default.isWritableFile(atPath: directory.path) else {
            return .notWritable
        }

        return nil
    }

    /// Staging sits inside the destination folder so the final step is a same-volume
    /// move rather than a second full copy.
    private func stagedAppURL(for appName: String, in directory: URL) -> URL {
        let stagedName = ".easydmg-\(UUID().uuidString)-\(appName)"
        return directory.appendingPathComponent(stagedName)
    }

    /// TCC's App Management gate only gets in the way for apps in /Applications.
    /// Replacing a bundle in a user-owned folder needs no special permission.
    private func requiresAppManagementPermission(for directory: URL) -> Bool {
        ExistingAppDiscovery.isWithin(directory, root: InstallLocation.systemDirectory)
    }

    private func resolvedInstallLocation(for directory: URL) -> InstallLocation {
        let path = directory.standardizedFileURL.path
        if path == InstallLocation.systemDirectory.standardizedFileURL.path {
            return .system
        }
        if path == UserPreferences.shared.userApplicationsDirectory.standardizedFileURL.path {
            return .userApplications
        }
        return .custom
    }

    /// Picks the folder this install should target. When the chosen folder isn't
    /// writable we offer ~/Applications instead of silently relocating the app — a
    /// standard (non-admin) account can never write to /Applications, and quietly
    /// moving the destination hides that from the user.
    ///
    /// Anything ~/Applications can't answer — a folder that's gone, one that isn't a
    /// folder, or a Personal folder that's broken itself — goes to the recovery
    /// dialog, which hands the mounted volume over for a manual drag.
    ///
    /// `requiresSystemLocation` short-circuits all of that. An app that can only run
    /// from /Applications makes the usual options wrong rather than merely worse: the
    /// Personal fallback below would produce exactly the broken install the check
    /// exists to prevent, so it gets its own dialog before any of this runs.
    private func resolveInstallDirectory(
        appName: String,
        dmgName: String,
        requiresSystemLocation: Bool
    ) async -> InstallDirectoryResolution {
        let preferred = UserPreferences.shared.installDirectory

        if requiresSystemLocation {
            // Only skip the dialog when /Applications is both the destination and
            // usable — otherwise every route from here ends somewhere the app can't run.
            let headingForSystem = resolvedInstallLocation(for: preferred) == .system
            let systemIsUsable = validateInstallDirectory(InstallLocation.systemDirectory) == nil

            if !headingForSystem || !systemIsUsable {
                return await resolveSystemLocationRequirement(
                    appName: appName,
                    dmgName: dmgName,
                    preferred: preferred,
                    systemIsUsable: systemIsUsable
                )
            }
        }

        guard let issue = validateInstallDirectory(preferred) else {
            return .resolved(preferred)
        }

        let message = issue.message(for: preferred)
        diagnostic("Install folder validation failed: \(message)")

        let fallback = UserPreferences.shared.userApplicationsDirectory
        let fallbackIssue = validateInstallDirectory(
            fallback,
            createUserApplicationsIfMissing: false
        )
        let preferredIsFallback = preferred.standardizedFileURL.path == fallback.standardizedFileURL.path

        // Which folder to raise with the user when there is no automatic option
        // left. Nil means Personal is still worth offering as a fallback below.
        let unusable: (directory: URL, issue: InstallFolderIssue)?
        if preferredIsFallback {
            // Personal is the chosen location and it's broken, so there is nothing
            // left to fall back to.
            unusable = (fallback, issue)
        } else if issue != .notWritable {
            // A destination that is missing or isn't a folder is not a permissions
            // problem — a custom folder gets deleted, renamed, or lives on a drive
            // that isn't mounted. Offering Personal would answer a question the user
            // didn't ask; the chosen location is what needs their attention.
            unusable = (preferred, issue)
        } else if let fallbackIssue, fallbackIssue != .missing {
            // Permissions problem, but Personal can't stand in either.
            unusable = (fallback, fallbackIssue)
        } else {
            unusable = nil
        }

        support(
            event: "install_folder_issue",
            details: [
                "app": appName,
                "dmg": dmgName,
                "location": UserPreferences.shared.installLocation.rawValue,
                "offered_fallback": boolString(unusable == nil),
                "reason": issue.rawValue,
                "unusable_folder": unusable?.directory.abbreviatedPath ?? "",
                "unusable_reason": unusable?.issue.rawValue ?? ""
            ]
        )

        // Every unusable destination ends at the recovery dialog rather than an
        // error message. The DMG is still mounted at this point, so handing it over
        // for a manual drag keeps the install possible; failing here would unmount
        // the volume and take the last remaining option away.
        if let unusable {
            let installManually = await showInstallLocationRecoveryDialog(
                appName: appName,
                directory: unusable.directory,
                issue: unusable.issue
            )
            return installManually
                ? .manualFallback(reason: .installLocationUnavailable)
                : .canceled(reason: unusable.issue.rawValue)
        }

        let decision = await showInstallLocationFallbackDialog(
            appName: appName,
            preferred: preferred,
            fallback: fallback
        )
        let accepted = decision != .cancel

        support(
            event: "install_folder_fallback",
            details: [
                "action": accepted ? "use_fallback" : "cancel",
                "app": appName,
                "dmg": dmgName
            ]
        )

        guard accepted else {
            return .manualFallback(reason: .installLocationDeclined)
        }

        if let fallbackIssue = validateInstallDirectory(fallback) {
            let fallbackMessage = fallbackIssue.message(for: fallback)
            diagnostic("Fallback install folder validation failed: \(fallbackMessage)")
            let installManually = await showInstallLocationRecoveryDialog(
                appName: appName,
                directory: fallback,
                issue: fallbackIssue
            )
            return installManually
                ? .manualFallback(reason: .installLocationUnavailable)
                : .canceled(reason: fallbackIssue.rawValue)
        }

        if decision == .installAndRemember {
            UserPreferences.shared.installLocation = .userApplications
            support(
                event: "preference_change",
                details: [
                    "preference": "installLocation",
                    "source": "install_fallback_dialog",
                    "value": InstallLocation.userApplications.rawValue
                ]
            )
        }

        return .resolved(fallback)
    }

    /// Handles an app that can only run from /Applications when the install is
    /// headed somewhere else, or when /Applications itself is closed to this account.
    ///
    /// The install is stopped either way. What differs is whether there's a fix to
    /// offer: an account that can write to /Applications gets a one-time override,
    /// and an account that can't gets the volume handed over, since no folder it can
    /// write to would make the app work.
    private func resolveSystemLocationRequirement(
        appName: String,
        dmgName: String,
        preferred: URL,
        systemIsUsable: Bool
    ) async -> InstallDirectoryResolution {
        diagnostic(
            "\(appName) ships a system extension but is headed for \(preferred.path); "
            + "applications folder usable=\(boolString(systemIsUsable))"
        )

        support(
            event: "install_requires_system_location",
            details: [
                "app": appName,
                "dmg": dmgName,
                "destination": preferred.abbreviatedPath,
                "location": UserPreferences.shared.installLocation.rawValue,
                "system_usable": boolString(systemIsUsable)
            ]
        )

        let decision = await showSystemLocationRequiredDialog(
            appName: appName,
            preferred: preferred,
            canInstallToSystem: systemIsUsable
        )

        support(
            event: "install_requires_system_location_decision",
            details: [
                "action": {
                    switch decision {
                    case .installToSystem: return "install_to_system"
                    case .openInFinder: return "open_in_finder"
                    case .cancel: return "cancel"
                    }
                }(),
                "app": appName,
                "dmg": dmgName
            ]
        )

        switch decision {
        case .installToSystem:
            // A one-time override. The preference stays put: the user picked their
            // install location on purpose, and one unusual app is a poor reason to
            // silently move every future install.
            return .resolved(InstallLocation.systemDirectory)
        case .openInFinder:
            return .manualFallback(reason: .requiresSystemLocation)
        case .cancel:
            return .canceled(reason: ManualFallbackReason.requiresSystemLocation.rawValue)
        }
    }

    private func showSystemLocationRequiredDialog(
        appName: String,
        preferred: URL,
        canInstallToSystem: Bool
    ) async -> SystemLocationDecision {
        let displayName = appName.strippingAppSuffix
        let systemFolder = InstallLocation.systemDirectory

        // "System extension" is the accurate term and appears in the macOS prompts
        // this app will trigger later, so someone searching the phrase finds the
        // right answers. The sentence around it carries the meaning either way.
        let cause = "\(displayName) includes a system extension, which macOS only allows to run from the "
            + "\(systemFolder.lastPathComponent) folder."

        let informative: String
        if canInstallToSystem {
            informative = """
            \(cause)

            EasyDMG is set to install to \(preferred.path), where \(displayName) would install but wouldn't work.
            """
        } else {
            informative = """
            \(cause)

            Your account doesn't have permission to install there, so \(displayName) can't be installed on this account. You may need to ask whoever administers this Mac.
            """
        }

        return await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "\(displayName) needs to install in \(systemFolder.lastPathComponent)"
            alert.informativeText = informative
            alert.icon = AlertIcon.image

            if canInstallToSystem {
                alert.addButton(withTitle: "Install to \(systemFolder.lastPathComponent)")
            } else {
                // Deliberately not "Install Manually": dragging the app anywhere this
                // account can write leaves it just as broken, so the button promises
                // only what it delivers — a look at the app, and the user's own call
                // on what to do with it.
                alert.addButton(withTitle: "Open in Finder")
            }
            alert.addButton(withTitle: "Cancel")

            presentHostedAlert(alert) { response in
                guard response == .alertFirstButtonReturn else {
                    continuation.resume(returning: .cancel)
                    return
                }

                continuation.resume(returning: canInstallToSystem ? .installToSystem : .openInFinder)
            }
        }
    }

    private func showInstallLocationFallbackDialog(
        appName: String,
        preferred: URL,
        fallback: URL
    ) async -> InstallLocationFallbackDecision {
        let displayName = appName.strippingAppSuffix

        return await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.alertStyle = .warning
            // Title names the folder, not the path — a wrapped path makes a poor
            // headline, and the exact location is spelled out in the body below.
            alert.messageText = "Can't install to \(preferred.lastPathComponent)"
            alert.informativeText = """
            Your account doesn't have permission to write to \(preferred.path). Installing there needs an administrator.

            EasyDMG can install \(displayName) to \(fallback.path) instead, where apps are available only to you.
            """
            alert.icon = AlertIcon.image

            // The button and checkbox keep the ~ shorthand: a full path doesn't fit
            // either control, and the body text above has already spelled it out.
            let checkbox = NSButton(
                checkboxWithTitle: "Always install to \(fallback.abbreviatedPath)",
                target: nil,
                action: nil
            )
            checkbox.state = .off
            checkbox.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            checkbox.sizeToFit()

            // NSAlert's text column is ~260pt, which wraps these paths into a ragged
            // stack of short lines. An alert grows to fit its accessory view, so a
            // wider container widens the whole dialog — the usual AppKit lever for
            // this, and the layout stays a standard alert.
            //
            // That accessory is centred on the wider alert, so it starts further left
            // than the message text above it. The inset pulls the checkbox back into
            // the text column so the two share a left edge.
            let checkboxLeadingInset: CGFloat = 8
            let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: checkbox.frame.height))
            checkbox.setFrameOrigin(NSPoint(x: checkboxLeadingInset, y: 0))
            accessory.addSubview(checkbox)
            alert.accessoryView = accessory

            alert.addButton(withTitle: "Install to \(fallback.abbreviatedPath)")
            alert.addButton(withTitle: "Cancel")

            presentHostedAlert(alert) { response in
                let accepted = response == .alertFirstButtonReturn
                let decision: InstallLocationFallbackDecision
                if !accepted {
                    decision = .cancel
                } else if checkbox.state == .on {
                    decision = .installAndRemember
                } else {
                    decision = .installOnce
                }

                continuation.resume(returning: decision)
            }
        }
    }

    private func showInstallLocationRecoveryDialog(
        appName: String,
        directory: URL,
        issue: InstallFolderIssue
    ) async -> Bool {
        let displayName = appName.strippingAppSuffix
        let location = directory.abbreviatedPath
        let explanation: String

        // Personal is the one folder EasyDMG creates on demand. Anywhere else, a
        // missing folder was never something we tried to make.
        let isCreatedOnDemand = directory.standardizedFileURL.path
            == UserPreferences.shared.userApplicationsDirectory.standardizedFileURL.path

        switch issue {
        case .missing where isCreatedOnDemand:
            explanation = "EasyDMG couldn't create \(location), so it can't install \(displayName) there."
        case .missing:
            // "Can't find" rather than "doesn't exist": a folder on a drive that
            // isn't plugged in is missing in exactly the same way as a deleted one,
            // and nothing here can tell the two apart.
            explanation = "EasyDMG can't find \(location), so it can't install \(displayName) there."
        case .notWritable:
            explanation = "Your account doesn't have permission to write to \(location), so EasyDMG can't install \(displayName) there."
        case .notDirectory:
            explanation = "\(location) is a file, not a folder, so EasyDMG can't install \(displayName) there."
        }

        return await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Can't use \(location)"
            alert.informativeText = """
            \(explanation)

            You can choose a different install location in EasyDMG Settings, or install \(displayName) manually.
            """
            alert.icon = AlertIcon.image
            alert.addButton(withTitle: "Install Manually")
            alert.addButton(withTitle: "Cancel")

            presentHostedAlert(alert) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
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

    /// Scans an app bundle for the payloads that tie it to /Applications.
    ///
    /// Deliberately shallow: this reports what the bundle *ships*, not whether the
    /// app actually uses it at runtime, which nothing here can know. Only apps that
    /// carry a hard requirement are worth interrupting, so a marker we can't stand
    /// behind is recorded and otherwise ignored.
    private func systemLocationMarkers(for path: String) -> [SystemLocationMarker] {
        let bundleURL = URL(fileURLWithPath: path)
        var markers: [SystemLocationMarker] = []

        if bundleContainsSystemExtension(at: bundleURL) {
            markers.append(.systemExtension)
        }

        if bundleDirectoryHasContents(at: bundleURL, subpath: "Contents/Library/LaunchDaemons") {
            markers.append(.launchDaemon)
        }

        if declaresPrivilegedHelper(at: bundleURL) {
            markers.append(.privilegedHelper)
        }

        return markers
    }

    /// System Extensions uses two bundle types here: `.systemextension` for system
    /// services and `.dext` for DriverKit drivers. A similarly named loose file or
    /// unrelated folder is not enough to override the user's install preference.
    private func bundleContainsSystemExtension(at bundleURL: URL) -> Bool {
        let directoryURL = bundleURL.appendingPathComponent("Contents/Library/SystemExtensions")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        return entries.contains { entry in
            let pathExtension = entry.pathExtension
            let hasSupportedExtension = pathExtension.caseInsensitiveCompare("systemextension") == .orderedSame
                || pathExtension.caseInsensitiveCompare("dext") == .orderedSame
            guard hasSupportedExtension,
                  let values = try? entry.resourceValues(forKeys: [.isDirectoryKey]) else {
                return false
            }
            return values.isDirectory == true
        }
    }

    /// True when `subpath` is a directory holding at least one real entry. An empty
    /// folder means nothing actually ships there, and a stray dotfile isn't payload.
    private func bundleDirectoryHasContents(at bundleURL: URL, subpath: String) -> Bool {
        let directoryURL = bundleURL.appendingPathComponent(subpath)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let entries = try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path) else {
            return false
        }

        return entries.contains { !$0.hasPrefix(".") }
    }

    private func declaresPrivilegedHelper(at bundleURL: URL) -> Bool {
        let infoPlistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let info = plist as? [String: Any],
              let executables = info["SMPrivilegedExecutables"] as? [String: Any] else {
            return false
        }

        return !executables.isEmpty
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

    private func installApp(
        from appPath: String,
        mountPoint: String,
        dmgPath: String,
        dmgName: String,
        preserveMountOnCancel: Bool
    ) async {
        let resolvedAppName = appName(from: appPath)
        var shouldReplaceExistingApp = false

        // Read the bundle before any destination decision is made: what it ships
        // changes which destinations are worth offering, and resolveInstallDirectory
        // owns that choice.
        let locationMarkers = systemLocationMarkers(for: appPath)
        if !locationMarkers.isEmpty {
            support(
                event: "install_location_markers",
                details: [
                    "app": resolvedAppName,
                    "dmg": dmgName,
                    "location": UserPreferences.shared.installLocation.rawValue,
                    "markers": locationMarkers.map(\.rawValue).sorted().joined(separator: ",")
                ]
            )
        }

        let installDirectory: URL
        switch await resolveInstallDirectory(
            appName: resolvedAppName,
            dmgName: dmgName,
            requiresSystemLocation: locationMarkers.contains(.systemExtension)
        ) {
        case .resolved(let directory):
            installDirectory = directory

        case .manualFallback(let reason):
            // The user still wants the app, just somewhere EasyDMG cannot place it.
            // Leave the volume open so the app can be dragged to a usable location.
            diagnostic("Installation handed off at install-location prompt for \(resolvedAppName)")
            await openForManualInstallation(
                mountPoint: mountPoint,
                dmgName: dmgName,
                reason: reason,
                appName: resolvedAppName
            )
            return

        case .canceled(let reason):
            diagnostic("Installation canceled after install-location recovery for \(resolvedAppName)")
            support(
                event: "install_decision",
                details: [
                    "action": "cancel",
                    "app": resolvedAppName,
                    "dmg": dmgName,
                    "reason": reason
                ]
            )
            recordCompletion(
                dmgName: dmgName,
                outcome: "canceled",
                details: ["app": resolvedAppName, "reason": reason]
            )
            await cleanUpCanceledInstall(
                mountPoint: mountPoint,
                dmgPath: dmgPath,
                dmgName: dmgName,
                preserveMount: preserveMountOnCancel
            )
            ProgressWindowController.shared.hide()
            return
        }

        let imageRoots = await mountedImageRootsForDiscovery()
        let discovery = ExistingAppDiscovery(mountedImageRoots: { imageRoots }).select(
            incoming: URL(fileURLWithPath: appPath),
            directory: installDirectory,
            exactName: resolvedAppName,
            requiresSystemLocation: locationMarkers.contains(.systemExtension)
        )
        let destinationURL = discovery.target
        let destinationPath = destinationURL.path
        let targetDirectory = destinationURL.deletingLastPathComponent()
        let stagedURL = stagedAppURL(for: resolvedAppName, in: targetDirectory)
        diagnostic("Existing app discovery: root=\(discovery.searchRoot.path), candidates=\(discovery.candidates.map(\.path)), target=\(destinationPath), reason=\(discovery.reason)")
        support(event: "existing_app_discovery", details: [
            "app": resolvedAppName,
            "dmg": dmgName,
            "search_root": discovery.searchRoot.path,
            "candidates": discovery.candidates.map(\.path).joined(separator: "\n"),
            "target": destinationPath,
            "reason": discovery.reason
        ])

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
            if versionComparison == .newer && UserPreferences.shared.autoInstallNewerVersions
                && !discovery.requiresConfirmation {
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
                    newVersion: newVersion,
                    installDirectory: installDirectory,
                    relativeLocation: discovery.relativeLocation == resolvedAppName ? nil : discovery.relativeLocation
                )
            }

            if !shouldReplace {
                diagnostic("Installation canceled by user")
                support(
                    event: "install_decision",
                    details: ["action": "cancel", "app": resolvedAppName, "dmg": dmgName]
                )
                await cleanUpCanceledInstall(
                    mountPoint: mountPoint,
                    dmgPath: dmgPath,
                    dmgName: dmgName,
                    preserveMount: preserveMountOnCancel
                )

                ProgressWindowController.shared.hide()
                recordCompletion(
                    dmgName: dmgName,
                    outcome: "canceled",
                    details: [
                        "app": resolvedAppName
                    ]
                )
                return
            }

            shouldReplaceExistingApp = true
            support(
                event: "install_decision",
                details: ["action": "replace", "app": resolvedAppName, "dmg": dmgName]
            )

            if currentFeedbackMode == .progressBar {
                ProgressWindowController.shared.show(message: "Preparing replacement...", progress: 0.2)
            }
        }

        // Resolve replacement safeguards and access before asking the user to quit.
        // App Store protection applies in every folder; TCC probing is limited below.
        if shouldReplaceExistingApp {
            let modificationPreflight = await ensureAppManagementPermission(
                forExistingAppAt: destinationPath,
                appName: resolvedAppName,
                dmgName: dmgName
            )
            if case let .blocked(reason) = modificationPreflight {
                diagnostic("Installation canceled before replacing \(resolvedAppName): \(reason)")
                await cleanUpCanceledInstall(
                    mountPoint: mountPoint,
                    dmgPath: dmgPath,
                    dmgName: dmgName,
                    preserveMount: preserveMountOnCancel
                )

                ProgressWindowController.shared.hide()
                recordCompletion(
                    dmgName: dmgName,
                    outcome: "skipped",
                    details: [
                        "app": resolvedAppName,
                        "reason": reason
                    ]
                )
                return
            }
        }

        // Quit any running instance before installing — otherwise the OS keeps the running
        // process bound to the old bundle and "Open after install" activates the stale copy.
        let affectedBundleIDs = Set([
            bundleIdentifier(at: appPath),
            shouldReplaceExistingApp ? bundleIdentifier(at: destinationPath) : nil
        ].compactMap { $0 }).sorted()
        for bundleID in affectedBundleIDs {
            let canProceed = await quitIfRunning(
                appName: resolvedAppName,
                bundleID: bundleID,
                dmgName: dmgName,
                targetURL: shouldReplaceExistingApp ? destinationURL : nil
            )
            if !canProceed {
                diagnostic("Installation canceled at running-app prompt for \(resolvedAppName)")
                await cleanUpCanceledInstall(
                    mountPoint: mountPoint,
                    dmgPath: dmgPath,
                    dmgName: dmgName,
                    preserveMount: preserveMountOnCancel
                )

                ProgressWindowController.shared.hide()
                recordCompletion(
                    dmgName: dmgName,
                    outcome: "skipped",
                    details: [
                        "app": resolvedAppName,
                        "reason": "running_app_canceled"
                    ]
                )
                return
            }
        }

        showProgress("Checking disk space...", progress: 0.15)
        let appSize = calculateAppSize(at: appPath)
        if let shortfall = diskSpaceShortfall(requiredBytes: appSize, in: targetDirectory) {
            diagnostic("Insufficient disk space for app size \(appSize), short by \(shortfall) bytes")
            support(
                event: "install_result",
                details: [
                    "app": resolvedAppName,
                    "dmg": dmgName,
                    "reason": "insufficient_disk_space",
                    "required_bytes": String(appSize),
                    "shortfall_bytes": String(shortfall),
                    "result": "failed"
                ]
            )
            recordCompletion(
                dmgName: dmgName,
                outcome: "error",
                details: ["app": resolvedAppName, "reason": "insufficient_disk_space"]
            )
            await handleError(
                title: "Not Enough Space",
                message: notEnoughSpaceMessage(shortfall: shortfall)
            )
            await cleanUpCanceledInstall(
                mountPoint: mountPoint,
                dmgPath: dmgPath,
                dmgName: dmgName,
                preserveMount: preserveMountOnCancel
            )
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
                message: "Installing to \(installDirectory.lastPathComponent)...",
                progress: 0.2
            ) {
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
                await cleanUpCanceledInstall(
                    mountPoint: mountPoint,
                    dmgPath: dmgPath,
                    dmgName: dmgName,
                    preserveMount: preserveMountOnCancel,
                    progress: 0.3
                )
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
            support(
                event: "install_result",
                details: [
                    "app": resolvedAppName,
                    "destination_exists": boolString(destinationExists),
                    "dmg": dmgName,
                    "location": resolvedInstallLocation(for: installDirectory).rawValue,
                    "replace_existing": boolString(shouldReplaceExistingApp),
                    "result": "success"
                ]
            )

            if currentFeedbackMode == .notification {
                await sendNotification(
                    title: "App Installed",
                    message: "\(resolvedAppName.strippingAppSuffix) is ready in your \(installDirectory.lastPathComponent) folder."
                )
            }
        } catch {
            diagnostic("Installation failed while copying/replacing: \(error)")
            cleanupStagedAppIfNeeded(at: stagedURL)

            // Causes we can confirm directly end the install with a specific message:
            // a manual drag would fail the same way, so handing off would only
            // postpone the failure.
            if let explained = explainCopyFailure(
                error,
                appPath: appPath,
                mountPoint: mountPoint,
                installDirectory: targetDirectory,
                appSize: appSize
            ) {
                diagnostic("Installation failure explained: \(explained.reason)")
                support(
                    event: "install_result",
                    details: errorDetails(error).merging([
                        "app": resolvedAppName,
                        "dmg": dmgName,
                        "reason": explained.reason,
                        "result": "failed"
                    ]) { _, new in new }
                )
                recordCompletion(
                    dmgName: dmgName,
                    outcome: "error",
                    details: ["app": resolvedAppName, "reason": explained.reason]
                )
                await handleError(title: explained.title, message: explained.message)
                // An ejected volume has nothing left to unmount.
                await cleanUpCanceledInstall(
                    mountPoint: mountPoint,
                    dmgPath: dmgPath,
                    dmgName: dmgName,
                    preserveMount: preserveMountOnCancel
                        || !FileManager.default.fileExists(atPath: mountPoint)
                )
                return
            }

            // Outside /Applications a permission error isn't App Management, so don't
            // send the user to a Privacy setting that wouldn't change anything.
            let targetProbe = shouldReplaceExistingApp
                && FileManager.default.fileExists(atPath: destinationPath)
                && requiresAppManagementPermission(for: targetDirectory)
                && isAppManagementError(error)
                ? canModifyExistingApp(at: destinationPath) : nil
            let permissionDenied = targetProbe?.isLikelyAppManagementDenial == true
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
            if let targetProbe,
               targetProbe.target.automaticReplacementBlockReason != nil {
                recordCompletion(
                    dmgName: dmgName,
                    outcome: "error",
                    details: ["app": resolvedAppName, "reason": failureReason]
                )
                await showManagedAppReplacementBlockedDialog(
                    appName: resolvedAppName,
                    dmgName: dmgName,
                    target: targetProbe.target
                )
                _ = await unmountDMG(at: mountPoint, dmgName: dmgName, progress: 0.6)
                return
            }

            // Neither remaining failure rules out a manual install: Finder needs no
            // App Management permission, and a copy error says nothing bad about the
            // disk image itself. Hand off instead of dead-ending on an error alert.
            // openForManualInstallation records completion and sends the notification,
            // and it deliberately leaves the volume mounted so the user can drag from
            // it, so there is no recordCompletion or unmount on these paths.
            // "result" belongs to install_result; other manual_fallback events don't carry it.
            var fallbackDetails = failureDetails
            fallbackDetails.removeValue(forKey: "result")
            let fallbackReason: ManualFallbackReason
            if let targetProbe, !targetProbe.granted, targetProbe.target.isRootOwned {
                fallbackReason = .rootOwnedReplacementDenied
            } else {
                fallbackReason = permissionDenied ? .appManagementDenied : .copyFailed
            }
            await openForManualInstallation(
                mountPoint: mountPoint,
                dmgName: dmgName,
                reason: fallbackReason,
                appName: resolvedAppName,
                details: fallbackDetails
            )
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
            showProgress("✨ Installation complete!", progress: 1.0)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }

        ProgressWindowController.shared.hide()
        recordCompletion(
            dmgName: dmgName,
            outcome: "installed",
            details: [
                "app": resolvedAppName,
                "installed_path": destinationPath,
                "opened_app": boolString(didOpenApp),
                "trashed_dmg": boolString(didTrashDMG)
            ]
        )
    }

    private func showSkipReplaceDialog(
        appName: String,
        installedVersion: String?,
        newVersion: String?,
        installDirectory: URL,
        relativeLocation: String?
    ) async -> Bool {
        let displayName = appName.strippingAppSuffix
        let locationDescription = installDirectory.abbreviatedPath
        var informative: String
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
                "\(displayName) is already installed in",
                "\(locationDescription).",
                "",
                "Installed: \(installedDisplayVersion)",
                "New: \(newDisplayVersion)",
                "",
                comparisonText
            ].joined(separator: "\n")
        } else {
            // Break before the path rather than letting the alert's narrow text
            // column wrap it wherever it lands — a path split mid-path ("~/" on one
            // line, "Applications." on the next) is harder to read than a short line.
            informative = "\(displayName) is already installed in\n\(locationDescription)."
        }

        if let relativeLocation {
            informative += "\n\nCopy to replace: \(relativeLocation)"
        }
        let dialogText = informative

        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.alertStyle = .informational
                alert.messageText = "Replace \(displayName)?"
                alert.informativeText = dialogText

                alert.icon = AlertIcon.image

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

                alert.icon = AlertIcon.image

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

                alert.icon = AlertIcon.image

                alert.addButton(withTitle: "Try Again")
                alert.addButton(withTitle: "Cancel")

                presentHostedAlert(alert) { response in
                    continuation.resume(returning: response == .alertFirstButtonReturn)
                }
            }
        }
    }

    private func quitIfRunning(appName: String, bundleID: String, dmgName: String, targetURL: URL?) async -> Bool {
        func affectedInstances() -> [NSRunningApplication] {
            runningInstances(of: bundleID).filter { app in
                guard let targetURL else { return true }
                guard let bundleURL = app.bundleURL else { return false }
                return ExistingAppDiscovery.resolved(bundleURL) == ExistingAppDiscovery.resolved(targetURL)
            }
        }
        var instances = affectedInstances()

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

            instances = affectedInstances()
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

            To install this version, move the installed copy of \(appName.strippingAppSuffix) to the Trash to uninstall, then open the DMG again.
            """
            alert.icon = AlertIcon.image
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
            let target = appPermissionTargetDiagnostics(at: path)
            if let reason = target.automaticReplacementBlockReason {
                await showManagedAppReplacementBlockedDialog(
                    appName: appName,
                    dmgName: dmgName,
                    target: target
                )
                return .blocked(reason: reason)
            }
            guard requiresAppManagementPermission(for: URL(fileURLWithPath: path).deletingLastPathComponent()) else {
                return .allowed
            }

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

            // The probe only tests a metadata write, not the actual replacement swap.
            // Anything other than a likely TCC denial gets a real attempt; if that
            // fails, the copy-failure handler already picks the right manual fallback.
            guard probe.isLikelyAppManagementDenial else {
                diagnostic("App Management probe inconclusive for \(appName); attempting replacement anyway")
                return .allowed
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

    /// Keep the DMG on cancellation, and only eject volumes we opened ourselves.
    private func cleanUpCanceledInstall(
        mountPoint: String,
        dmgPath: String,
        dmgName: String,
        preserveMount: Bool,
        progress: Double? = nil
    ) async {
        if preserveMount {
            diagnostic("Installation canceled; leaving pre-existing mount open at \(mountPoint)")
        } else {
            _ = await unmountDMG(at: mountPoint, dmgName: dmgName, progress: progress)
        }
        _ = trashDMGIfNeeded(at: dmgPath, shouldTrash: false, dmgName: dmgName)
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

            alert.icon = AlertIcon.image

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

            alert.icon = AlertIcon.image

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

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        task.arguments = ["-dr", "com.apple.quarantine", path]

        let errorPipe = Pipe()
        task.standardError = errorPipe

        do {
            try task.run()
            task.waitUntilExit()

            if task.terminationStatus != 0 {
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
        let containingFolder = (path as NSString).deletingLastPathComponent
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: containingFolder)
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

    private func handleError(title: String, message: String) async {
        diagnostic("Error: \(title): \(message)")
        showProgress(title, progress: 0.0)
        await sendFailureNotificationIfAvailable(title: title, message: message)

        try? await Task.sleep(nanoseconds: 3_000_000_000)
        ProgressWindowController.shared.hide()

    }
}
