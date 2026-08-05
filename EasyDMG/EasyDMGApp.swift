//
//  EasyDMGApp.swift
//  EasyDMG
//
//  Created by Jeff Schumann on 10/24/25.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UserNotifications
import Sparkle

extension NSUserInterfaceItemIdentifier {
    static let easyDMGSettingsWindow = NSUserInterfaceItemIdentifier("EasyDMGSettingsWindow")
}

@main
struct EasyDMGApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Settings window - shown when launched directly
        Window("EasyDMG", id: "settings") {
            SettingsView()
                .environmentObject(appDelegate.updaterViewModel)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 550, height: 600)
        .windowResizability(.contentMinSize)
        .commands {
            // Remove file menu commands
            CommandGroup(replacing: .newItem) { }
        }
    }
}

@MainActor
private final class SparklePresentationDelegate: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    var focusPresentedUpdate: (() -> Void)?

    private var userStartedInstall = false

    func standardUserDriverAllowsMinimizableStatusWindow() -> Bool {
        false
    }

    func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard choice == .install else { return }

        userStartedInstall = true
        refocusUpdateUI()
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        guard userStartedInstall else { return }

        refocusUpdateUI()
    }

    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        guard userStartedInstall else { return }

        refocusUpdateUI()
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        userStartedInstall = false
    }

    private func refocusUpdateUI() {
        // Sparkle swaps/reuses status windows during download, extract, and ready-to-install.
        // A few short focus passes catch those transitions without replacing Sparkle's UI.
        for delay in [0.0, 0.25, 0.75, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }

                NSApp.activate(ignoringOtherApps: true)
                self.focusPresentedUpdate?()
            }
        }
    }
}

// AppDelegate to handle file opening events
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let dmgProcessor = DMGProcessor()
    private var launchedWithFiles = false
    private var launchModeResolved = false
    private var launchFallbackWorkItem: DispatchWorkItem?
    private let fileOpenLaunchTimeout: TimeInterval = 2.0
    /// True when this run began as a direct launch (settings window). Such a session
    /// keeps its window and stays alive through DMG installs instead of quitting.
    private var isSettingsSession = false
    private let updaterController: SPUStandardUpdaterController
    // Sparkle holds delegates weakly, so EasyDMG must retain this object.
    private let updaterPresentationDelegate: SparklePresentationDelegate
    private var isWaitingForUpdateCheck = false

    // Update check interval (24 hours)
    private let updateCheckInterval: TimeInterval = 24 * 60 * 60

    // View model for Sparkle updates UI
    let updaterViewModel: CheckForUpdatesViewModel

    override init() {
        // Sparkle marks this launch as soon as its updater starts. Run the startup
        // migrations first so a genuinely new user is not mistaken for someone
        // upgrading from an older EasyDMG release.
        UserPreferences.runStartupMigrations()

        let presentationDelegate = SparklePresentationDelegate()
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: presentationDelegate,
            userDriverDelegate: presentationDelegate
        )

        updaterPresentationDelegate = presentationDelegate
        updaterController = controller
        updaterViewModel = CheckForUpdatesViewModel(updater: controller.updater)

        presentationDelegate.focusPresentedUpdate = { [weak controller] in
            guard let userDriver = controller?.userDriver as? SPUUserDriver else { return }
            userDriver.showUpdateInFocus?()
        }

        super.init()
    }

    // Expose updater for settings UI
    var updater: SPUUpdater {
        updaterController.updater
    }

    // MARK: - Update Check Timing

    private var lastUpdateCheck: Date? {
        get {
            UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "lastUpdateCheck")
        }
    }

    private func shouldCheckForUpdates() -> Bool {
        guard let lastCheck = lastUpdateCheck else {
            // Never checked before
            return true
        }

        let timeSinceLastCheck = Date().timeIntervalSince(lastCheck)
        return timeSinceLastCheck >= updateCheckInterval
    }

    private func support(event: String, details: [String: String] = [:]) {
        DiagnosticLogger.shared.support(event: event, details: details)
    }

    private func diagnostic(_ message: @autoclosure () -> String) {
        DiagnosticLogger.shared.diagnostic(message())
    }

    private func errorDetails(_ error: Error) -> [String: String] {
        let nsError = error as NSError
        return [
            "error_code": String(nsError.code),
            "error_domain": nsError.domain
        ]
    }

    private func joinedFileNames(_ urls: [URL]) -> String {
        urls.map(\.lastPathComponent).joined(separator: "|")
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // This is called before application(_:open:)
        // We use it to detect if files will be opened
        DiagnosticLogger.shared.startSession()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {

        dmgProcessor.onQueueDrained = { [weak self] in
            guard let self else {
                NSApp.terminate(nil)
                return
            }
            self.handleQueueDrained()
        }

        // Set notification delegate to show notifications even when app is active
        UNUserNotificationCenter.current().delegate = self

        // Request notification permissions
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                self.diagnostic("❌ Notification authorization error: \(error)")
                self.support(
                    event: "notification_authorization",
                    details: self.errorDetails(error).merging(["status": "error"]) { current, _ in current }
                )
            } else if granted {
                self.diagnostic("✅ Notification authorization granted")
                self.support(event: "notification_authorization", details: ["status": "granted"])
            } else {
                self.diagnostic("⚠️ Notification authorization denied")
                self.support(event: "notification_authorization", details: ["status": "denied"])
            }
        }

        // A true value conclusively means the user launched EasyDMG normally.
        // A false or missing value can also mean a DMG is on its way, so give the
        // file-open event a proper chance to arrive before falling back to settings.
        let isDefaultLaunch = (
            notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? NSNumber
        )?.boolValue == true

        if isDefaultLaunch {
            resolveSettingsLaunch(reason: "default_launch")
        } else if launchedWithFiles {
            resolveFileOpenLaunch()
        } else {
            diagnostic("ℹ️ Non-default launch detected - waiting briefly for a DMG")
            NSApp.setActivationPolicy(.accessory)
            hideSettingsWindow()

            let fallback = DispatchWorkItem { [weak self] in
                guard let self, !self.launchModeResolved else { return }
                self.diagnostic("ℹ️ No DMG arrived before launch timeout - showing settings window")
                self.resolveSettingsLaunch(reason: "file_open_timeout")
            }
            launchFallbackWorkItem = fallback
            DispatchQueue.main.asyncAfter(
                deadline: .now() + fileOpenLaunchTimeout,
                execute: fallback
            )
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let dmgURLs = urls.filter { url in
            if url.pathExtension.lowercased() == "dmg" {
                return true
            } else {
                return false
            }
        }

        support(
            event: "open_request",
            details: [
                "dmg_count": String(dmgURLs.count),
                "dmg_names": joinedFileNames(dmgURLs),
                "file_count": String(urls.count)
            ]
        )

        guard !dmgURLs.isEmpty else {
            diagnostic("⚠️ Open request contained no DMG files")
            return
        }

        launchedWithFiles = true

        if !launchModeResolved {
            resolveFileOpenLaunch()
        }

        if isSettingsSession {
            // The user opened a DMG while the settings window was up. Leave their
            // window alone; the floating progress window covers the install.
            diagnostic("ℹ️ DMG opened during a settings session - keeping settings window visible")
        } else {
            // Hide settings window if it's visible (but not progress window)
            hideSettingsWindow()

            // Stay in background mode when processing DMG
            NSApp.setActivationPolicy(.accessory)
        }

        dmgProcessor.enqueueDMGs(dmgURLs)
    }

    private func resolveSettingsLaunch(reason: String) {
        guard !launchModeResolved else { return }

        launchModeResolved = true
        launchFallbackWorkItem?.cancel()
        launchFallbackWorkItem = nil
        isSettingsSession = true

        diagnostic("✅ Launched directly - showing settings window")
        support(event: "launch_mode", details: ["mode": "direct", "reason": reason])
        NSApp.setActivationPolicy(.regular)
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Always check for updates when settings window is opened
        diagnostic("✅ Checking for updates (settings window)")
        updater.checkForUpdatesInBackground()
        lastUpdateCheck = Date()
    }

    private func resolveFileOpenLaunch() {
        guard !launchModeResolved else { return }

        launchModeResolved = true
        launchFallbackWorkItem?.cancel()
        launchFallbackWorkItem = nil

        diagnostic("✅ Launched with DMG - staying in background")
        support(event: "launch_mode", details: ["mode": "file_open"])
        NSApp.setActivationPolicy(.accessory)
        hideSettingsWindow()

        // Only check for updates if 24+ hours have passed
        if shouldCheckForUpdates() {
            diagnostic("✅ Checking for updates (24+ hours since last check)")
            isWaitingForUpdateCheck = true
            updater.checkForUpdatesInBackground()
            lastUpdateCheck = Date()

            // Give the update check time to complete before allowing quit
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                self.diagnostic("✅ Update check timeout reached, allowing quit")
                self.isWaitingForUpdateCheck = false
            }
        } else {
            diagnostic("ℹ️ Skipping update check (checked recently)")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        guard launchModeResolved else {
            diagnostic("Last window closed before launch mode resolved; staying alive")
            return false
        }

        // A settings session quits when its window closes, but never mid-install -
        // handleQueueDrained() takes over once processing finishes.
        return (isSettingsSession || !launchedWithFiles) && !dmgProcessor.isProcessing
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if shouldSuppressSettingsWindow {
            hideSettingsWindow()
        }
        dmgProcessor.refreshAppManagementPermissionPanel()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if dmgProcessor.handleAppManagementTerminationRequest() {
            hideSettingsWindow()
            diagnostic("⚠️ Cancelling termination after App Management restart request")
            support(event: "termination_decision", details: ["action": "cancel", "reason": "app_management_restart_request"])
            return .terminateCancel
        }

        // Prevent quit while actively processing
        if dmgProcessor.isProcessing {
            diagnostic("⚠️ Still processing, preventing quit")
            support(event: "termination_decision", details: ["action": "cancel", "reason": "processing"])
            return .terminateCancel
        }

        // Prevent quit while waiting for update check to complete
        if isWaitingForUpdateCheck {
            diagnostic("⚠️ Waiting for update check, preventing quit")
            support(event: "termination_decision", details: ["action": "cancel", "reason": "update_check"])
            return .terminateCancel
        }

        support(event: "termination_decision", details: ["action": "allow"])
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if shouldSuppressSettingsWindow {
            hideSettingsWindow()
            dmgProcessor.refreshAppManagementPermissionPanel()
            return false
        }

        return true
    }

    private var shouldSuppressSettingsWindow: Bool {
        guard !isSettingsSession else { return false }

        return !launchModeResolved || launchedWithFiles || dmgProcessor.isProcessing
    }

    /// The single settings window, identified when SwiftUI attaches its content.
    private var settingsWindow: NSWindow? {
        if let identifiedWindow = NSApp.windows.first(where: { window in
            window.identifier == .easyDMGSettingsWindow
        }) {
            return identifiedWindow
        }

        // SwiftUI assigns our identifier one main-loop turn after creating the
        // window. The title lets file-open launches hide it during that brief gap.
        return NSApp.windows.first { window in
            window.title == "EasyDMG"
        }
    }

    private func hideSettingsWindow() {
        settingsWindow?.orderOut(nil)
    }

    /// Called when the DMG queue empties. Quits as usual, unless the user still has
    /// the settings window open - then the install just hands control back to them.
    private func handleQueueDrained() {
        // A minimized window counts as open. Reactivation usually deminiaturizes it
        // before we get here, but not on every route a DMG can arrive by.
        let settingsWindowIsOpen = settingsWindow.map { $0.isVisible || $0.isMiniaturized } == true

        guard isSettingsSession && settingsWindowIsOpen else {
            diagnostic("✅ Processing queue complete, quitting app")
            support(event: "queue_complete", details: ["action": "quit"])
            NSApp.terminate(nil)
            return
        }

        diagnostic("✅ Processing queue complete, returning to open settings window")
        support(event: "queue_complete", details: ["action": "return_to_settings"])
        launchedWithFiles = false
        // Deliberately no activate() here: "open app after install" and "reveal in
        // Finder" hand focus elsewhere, and stealing it back would be worse.
        NSApp.setActivationPolicy(.regular)
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show notifications even when app is in foreground/active
        completionHandler([.banner, .list, .sound])
    }
}
