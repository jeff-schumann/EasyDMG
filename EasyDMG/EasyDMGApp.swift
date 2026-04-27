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

@main
struct EasyDMGApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Settings window - shown when launched directly
        WindowGroup("EasyDMG") {
            SettingsView()
                .environmentObject(appDelegate.updaterViewModel)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            // Remove file menu commands
            CommandGroup(replacing: .newItem) { }
        }
    }
}

// AppDelegate to handle file opening events
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let dmgProcessor = DMGProcessor()
    private var launchedWithFiles = false
    private let updaterController: SPUStandardUpdaterController
    private var isWaitingForUpdateCheck = false

    // Update check interval (24 hours)
    private let updateCheckInterval: TimeInterval = 24 * 60 * 60

    // View model for Sparkle updates UI
    let updaterViewModel: CheckForUpdatesViewModel

    override init() {
        // Initialize Sparkle updater (start it so canCheckForUpdates works)
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        updaterViewModel = CheckForUpdatesViewModel(updater: updaterController.updater)
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
        diagnostic("applicationWillFinishLaunching")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        diagnostic(
            "applicationDidFinishLaunching diagnosticLogging=\(DiagnosticLogger.shared.isDiagnosticEnabled)"
        )

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

        // Check if launched with files by seeing if application(_:open:) was called
        // We'll set launchedWithFiles in that method

        // Small delay to let file opening happen first
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if !self.launchedWithFiles {
                // Launched directly - show settings window with dock icon
                self.diagnostic("✅ Launched directly - showing settings window")
                self.support(event: "launch_mode", details: ["mode": "direct"])
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)

                // Always check for updates when settings window is opened
                self.diagnostic("✅ Checking for updates (settings window)")
                self.updater.checkForUpdatesInBackground()
                self.lastUpdateCheck = Date()
            } else {
                // Launched with DMG - stay in background
                self.diagnostic("✅ Launched with DMG - staying in background")
                self.support(event: "launch_mode", details: ["mode": "file_open"])
                NSApp.setActivationPolicy(.accessory)
                self.hideSettingsWindow()

                // Only check for updates if 24+ hours have passed
                if self.shouldCheckForUpdates() {
                    self.diagnostic("✅ Checking for updates (24+ hours since last check)")
                    self.isWaitingForUpdateCheck = true
                    self.updater.checkForUpdatesInBackground()
                    self.lastUpdateCheck = Date()

                    // Give the update check time to complete before allowing quit
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                        self.diagnostic("✅ Update check timeout reached, allowing quit")
                        self.isWaitingForUpdateCheck = false
                    }
                } else {
                    self.diagnostic("ℹ️ Skipping update check (checked recently)")
                }
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        diagnostic("✅ application(_:open:) called with \(urls.count) file(s): \(urls)")
        launchedWithFiles = true

        // Hide settings window if it's visible (but not progress window)
        hideSettingsWindow()

        // Stay in background mode when processing DMG
        NSApp.setActivationPolicy(.accessory)

        let dmgURLs = urls.filter { url in
            diagnostic("✅ Checking file: \(url.path)")
            if url.pathExtension.lowercased() == "dmg" {
                diagnostic("✅ Queueing DMG file: \(url.lastPathComponent)")
                return true
            } else {
                diagnostic("⚠️ Not a DMG file, ignoring: \(url.path)")
                return false
            }
        }

        diagnostic("Filtered DMG count: \(dmgURLs.count)")
        support(
            event: "open_request",
            details: [
                "dmg_count": String(dmgURLs.count),
                "dmg_names": joinedFileNames(dmgURLs),
                "file_count": String(urls.count)
            ]
        )

        dmgProcessor.enqueueDMGs(dmgURLs)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Quit when settings window is closed
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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

        diagnostic("✅ Allowing termination")
        support(event: "termination_decision", details: ["action": "allow"])
        return .terminateNow
    }

    private func hideSettingsWindow() {
        // Only hide settings windows, not the progress window
        for window in NSApp.windows {
            // Don't hide the progress window (it has .floating level)
            if window.level != .floating {
                window.orderOut(nil)
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show notifications even when app is in foreground/active
        completionHandler([.banner, .sound])
    }
}
