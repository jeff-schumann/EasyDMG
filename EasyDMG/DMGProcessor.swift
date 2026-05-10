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

fileprivate extension String {
    /// Strips a trailing `.app` for display in user-facing copy.
    /// Use only for presentation — filesystem paths must keep the suffix.
    var strippingAppSuffix: String {
        hasSuffix(".app") ? String(dropLast(4)) : self
    }
}

fileprivate enum AppManagementDecision {
    case retry
    case cancel
}

@MainActor
fileprivate final class AppManagementPermissionWindowController: NSWindowController, NSWindowDelegate {
    private let appName: String
    private let permissionProbe: () -> Bool
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
        permissionProbe: @escaping () -> Bool,
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

        if permissionProbe() {
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
        if permissionProbe() {
            markPermissionReady(reason: "try_again")
            finish(.retry)
        } else {
            statusLabel.stringValue = "Still waiting for permission. Enable EasyDMG in System Settings, then try again."
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

        var notificationMessage: String {
            switch self {
            case .genericMountFailure:
                return "EasyDMG could not mount this disk image automatically, so it opened the normal macOS installer."
            case .invalidAppBundle:
                return "The app bundle did not look installable, so EasyDMG opened the disk image for manual installation."
            case .packageInstaller:
                return "This disk image contains a package installer, so EasyDMG opened it for manual installation."
            case .installerOrAuxiliaryApp:
                return "The app looked like an installer or helper, so EasyDMG opened the disk image for manual installation."
            case .passwordProtected:
                return "This disk image is password-protected, so EasyDMG opened it for manual installation."
            case .noAppFound:
                return "EasyDMG did not find an installable app, so it opened the disk image for manual installation."
            case .multipleAppsFound:
                return "EasyDMG found multiple apps, so it opened the disk image for manual installation."
            case .licenseRequired:
                return "This disk image appears to require a license agreement, so EasyDMG opened it for manual installation."
            }
        }
    }

    private enum MountResult: Sendable {
        case mounted(mountPoint: String, exitStatus: Int32)
        case passwordProtected(exitStatus: Int32)
        case failed(exitStatus: Int32?)
    }

    private enum UnmountResult: Sendable {
        case clean
        case retrySuccess
        case forceSuccess
        case failed(exitStatus: Int32?)

        var supportValue: String {
            switch self {
            case .clean:
                return "clean"
            case .retrySuccess:
                return "retry_success"
            case .forceSuccess:
                return "force_success"
            case .failed:
                return "failed"
            }
        }

        var exitStatus: Int32? {
            switch self {
            case .clean, .retrySuccess, .forceSuccess:
                return 0
            case let .failed(status):
                return status
            }
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
        case missingExecutableName = "missing_executable_name"
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
        reason: ManualFallbackReason
    ) async {
        guard UserPreferences.shared.feedbackMode != .silent else {
            return
        }

        await sendNotification(
            title: "EasyDMG needs manual install",
            message: "\(dmgName): \(reason.notificationMessage)"
        )
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

        // TODO: Fix license detection - currently giving false positives without sandbox
        // if await hasLicenseAgreement(dmgPath: url.path) {
        //     await openForManualInstallation(
        //         dmgPath: url.path,
        //         dmgName: currentDMGName,
        //         reason: .licenseRequired
        //     )
        //     return
        // }

        let mountResult = await mountDMG(at: url.path, dmgName: currentDMGName, progress: 0.0)

        let mountPoint: String
        switch mountResult {
        case let .mounted(resolvedMountPoint, _):
            mountPoint = resolvedMountPoint

        case .passwordProtected:
            showProgress("DMG is password-protected, opening for manual install...", progress: 0.0)
            await openForManualInstallation(
                dmgPath: url.path,
                dmgName: currentDMGName,
                reason: .passwordProtected
            )
            return

        case .failed:
            await openForManualInstallation(
                dmgPath: url.path,
                dmgName: currentDMGName,
                reason: .genericMountFailure
            )
            return
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

    private func hasLicenseAgreement(dmgPath: String) async -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        task.arguments = ["imageinfo", dmgPath]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.contains("Software License Agreement") && output.contains("true")
        } catch {
            diagnostic("Error checking for license: \(error)")
            return false
        }
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
        diagnostic("Mounting \(path)...")
        support(event: "mount_start", details: ["dmg": dmgName])

        let result = await withMagicFallback(
            message: "Mounting disk image...",
            progress: progress
        ) {
            DiagnosticLogger.shared.diagnostic("Running hdiutil attach for \(path)")
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            task.arguments = ["attach", path, "-nobrowse", "-readonly", "-noautoopen", "-plist"]

            let pipe = Pipe()
            let errorPipe = Pipe()
            task.standardOutput = pipe
            task.standardError = errorPipe

            do {
                try task.run()
                task.waitUntilExit()

                guard task.terminationStatus == 0 else {
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let rawErrorOutput = String(data: errorData, encoding: .utf8) ?? ""
                    let errorOutput = rawErrorOutput.lowercased()
                    DiagnosticLogger.shared.diagnostic("Mount failed with status \(task.terminationStatus)")
                    if !rawErrorOutput.isEmpty {
                        DiagnosticLogger.shared.diagnostic(
                            "hdiutil attach stderr: \(DiagnosticLogger.compact(rawErrorOutput))"
                        )
                    }
                    if errorOutput.contains("authentication") ||
                        errorOutput.contains("passphrase") ||
                        errorOutput.contains("encrypted")
                    {
                        DiagnosticLogger.shared.diagnostic(
                            "Manual fallback classification: password protected or encrypted DMG"
                        )
                        return MountResult.passwordProtected(exitStatus: task.terminationStatus)
                    }
                    return MountResult.failed(exitStatus: task.terminationStatus)
                }

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                DiagnosticLogger.shared.diagnostic("hdiutil attach succeeded")
                if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                    DiagnosticLogger.shared.diagnostic(
                        "hdiutil attach stdout: \(DiagnosticLogger.compact(output))"
                    )
                }

                guard let mountPoint = Self.parseMountPoint(fromAttachPlist: data) else {
                    return MountResult.failed(exitStatus: task.terminationStatus)
                }

                return MountResult.mounted(mountPoint: mountPoint, exitStatus: task.terminationStatus)

            } catch {
                DiagnosticLogger.shared.diagnostic("Error mounting DMG: \(error)")
                return MountResult.failed(exitStatus: nil)
            }
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

        guard info["CFBundlePackageType"] as? String == "APPL" else {
            return .notApplicationBundle
        }

        guard let executableName = info["CFBundleExecutable"] as? String,
              !executableName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .missingExecutableName
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
            let shouldReplace = await showSkipReplaceDialog(
                appName: resolvedAppName,
                installedVersion: installedVersion,
                newVersion: newVersion
            )

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

        // Pre-flight App Management TCC check before any destructive work — without this
        // permission, replacing an existing bundle in /Applications fails mid-install and
        // the user just sees a generic "install failed". Probe non-destructively first.
        if shouldReplaceExistingApp {
            showProgress("Waiting for App Management permission...", progress: 0.2)
            let hasPermission = await ensureAppManagementPermission(
                forExistingAppAt: destinationPath,
                appName: resolvedAppName,
                dmgName: dmgName
            )
            if !hasPermission {
                diagnostic("Installation canceled at App Management permission prompt for \(resolvedAppName)")
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
                        "reason": "app_management_denied",
                        "trashed_dmg": boolString(didTrashDMG)
                    ]
                )
                return
            }

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

            await removeQuarantineAttributes(from: stagedURL.path)

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
            let failureReason = permissionDenied ? "app_management_denied" : "copy_or_replace_failed"
            support(
                event: "install_result",
                details: errorDetails(error).merging([
                    "app": resolvedAppName,
                    "dmg": dmgName,
                    "reason": failureReason,
                    "result": "failed"
                ]) { current, _ in current }
            )
            recordCompletion(
                dmgName: dmgName,
                outcome: "error",
                details: ["app": resolvedAppName, "reason": failureReason]
            )
            let errorMessage = permissionDenied
                ? "EasyDMG needs App Management permission. Open System Settings → Privacy & Security → App Management, enable EasyDMG, then try again."
                : "Installation failed"
            await handleError(errorMessage)
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
        if let installed = installedVersion, let new = newVersion {
            switch installed.compare(new, options: .numeric) {
            case .orderedSame:
                informative = "\(displayName) is already installed (v\(installed)).\n\nThis DMG contains the same version.\n\nWould you like to replace it anyway?"
            case .orderedAscending:
                informative = "\(displayName) is already installed (v\(installed)).\n\nThis DMG contains a newer version (v\(new)).\n\nWould you like to update the app?"
            case .orderedDescending:
                informative = "\(displayName) is already installed (v\(installed)).\n\nThis DMG contains an older version (v\(new)).\n\nWould you like to replace it anyway?"
            }
        } else {
            informative = "\(displayName) is already installed.\n\nWould you like to replace it?"
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.alertStyle = .informational
                alert.messageText = "EasyDMG"
                alert.informativeText = informative

                if let iconPath = Bundle.main.path(forResource: "wizardhamster", ofType: "icns"),
                   let icon = NSImage(contentsOfFile: iconPath) {
                    alert.icon = icon
                }

                alert.addButton(withTitle: "Replace")
                alert.addButton(withTitle: "Cancel")

                let response = alert.runModal()
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
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

                let response = alert.runModal()
                continuation.resume(returning: response == .alertFirstButtonReturn)
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

                let response = alert.runModal()
                continuation.resume(returning: response == .alertFirstButtonReturn)
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
    private func canModifyExistingApp(at path: String) -> Bool {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let originalDate = attrs[.modificationDate] as? Date ?? Date()
            try FileManager.default.setAttributes(
                [.modificationDate: originalDate],
                ofItemAtPath: path
            )
            return true
        } catch {
            let nsError = error as NSError
            diagnostic(
                "App Management probe failed: domain=\(nsError.domain) code=\(nsError.code)"
            )
            return false
        }
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
                        self?.canModifyExistingApp(at: existingAppPath) ?? false
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

    private func ensureAppManagementPermission(
        forExistingAppAt path: String,
        appName: String,
        dmgName: String
    ) async -> Bool {
        while true {
            if canModifyExistingApp(at: path) {
                support(
                    event: "app_management_probe",
                    details: ["app": appName, "dmg": dmgName, "result": "granted"]
                )
                return true
            }

            support(
                event: "app_management_probe",
                details: ["app": appName, "dmg": dmgName, "result": "denied"]
            )

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
                return false
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
        support(event: "unmount_result", details: details)
        return result
    }

    private nonisolated func performUnmount(at mountPoint: String) -> UnmountResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        task.arguments = ["detach", mountPoint]

        let errorPipe = Pipe()
        task.standardError = errorPipe

        do {
            try task.run()
            task.waitUntilExit()

            if task.terminationStatus == 0 {
                DiagnosticLogger.shared.diagnostic("✓ Clean detach succeeded")
                return .clean
            }

            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
            DiagnosticLogger.shared.diagnostic(
                "Detach failed: \(DiagnosticLogger.compact(errorOutput))"
            )

            if errorOutput.lowercased().contains("resource busy") {
                DiagnosticLogger.shared.diagnostic("Resource busy, waiting 250ms and retrying...")
                Thread.sleep(forTimeInterval: 0.25)

                let retryTask = Process()
                retryTask.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                retryTask.arguments = ["detach", mountPoint]
                try? retryTask.run()
                retryTask.waitUntilExit()

                if retryTask.terminationStatus == 0 {
                    DiagnosticLogger.shared.diagnostic("✓ Retry detach succeeded")
                    return .retrySuccess
                }
            }

            DiagnosticLogger.shared.diagnostic("Using force detach...")
            let forceTask = Process()
            forceTask.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            forceTask.arguments = ["detach", mountPoint, "-force"]
            try? forceTask.run()
            forceTask.waitUntilExit()
            if forceTask.terminationStatus == 0 {
                DiagnosticLogger.shared.diagnostic("✓ Force detach completed with status 0")
                return .forceSuccess
            }

            DiagnosticLogger.shared.diagnostic(
                "Force detach failed with status \(forceTask.terminationStatus)"
            )
            return .failed(exitStatus: forceTask.terminationStatus)
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
        await sendManualFallbackNotificationIfAvailable(dmgName: dmgName, reason: reason)
    }

    private func openForManualInstallation(
        dmgPath: String,
        dmgName: String,
        reason: ManualFallbackReason,
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
        await sendManualFallbackNotificationIfAvailable(dmgName: dmgName, reason: reason)
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
