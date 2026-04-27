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

@MainActor
class DMGProcessor: ObservableObject {
    @Published var isProcessing = false
    private var currentFeedbackMode: FeedbackMode = .progressBar
    private var pendingDMGURLs: [URL] = []
    private var isDrainingQueue = false

    // Progressive messages shown at intervals if operation takes too long
    private let magicMessages: [(delay: UInt64, message: String)] = [
        (4_000_000_000, "🪄 Invoking ancient hamster magic..."),
        (8_000_000_000, "Opening a high capacity portal 🎩..."),
        (12_000_000_000, "🐹 Hamster is strong, but app is big...")
    ]

    private func showProgress(_ message: String, progress: Double) {
        DiagnosticLogger.shared.log("📝 \(message) (\(Int(progress * 100))%)")

        // Only show progress window if feedback mode is progress bar
        if currentFeedbackMode == .progressBar {
            ProgressWindowController.shared.update(message: message, progress: progress)
        }
    }

    /// Runs a potentially slow operation with progressive fallback messages if it takes too long.
    /// Shows different messages at 4s, 8s, and 12s intervals to indicate the app is still working.
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

        // Start timer tasks for each progressive message
        let timerTasks = magicMessages.map { delayNanos, magicMsg in
            Task { @MainActor [currentFeedbackMode] in
                try await Task.sleep(nanoseconds: delayNanos)
                if !Task.isCancelled && currentFeedbackMode == .progressBar {
                    ProgressWindowController.shared.update(message: magicMsg, progress: progress)
                    DiagnosticLogger.shared.log("📝 \(magicMsg) (\(Int(progress * 100))%)")
                }
            }
        }

        // Wait for operation to complete, then cancel all timers
        do {
            let result = try await operationTask.value
            timerTasks.forEach { $0.cancel() }
            return result
        } catch {
            timerTasks.forEach { $0.cancel() }
            throw error
        }
    }

    /// Non-throwing version for operations that don't throw
    private func withMagicFallback<T: Sendable>(
        message: String,
        progress: Double,
        operation: @escaping @Sendable () -> T
    ) async -> T {
        showProgress(message, progress: progress)

        // Run the operation on a background thread so timers can fire
        let operationTask = Task.detached(priority: .userInitiated) {
            operation()
        }

        // Start timer tasks for each progressive message
        let timerTasks = magicMessages.map { delayNanos, magicMsg in
            Task { @MainActor [currentFeedbackMode] in
                try? await Task.sleep(nanoseconds: delayNanos)
                if !Task.isCancelled && currentFeedbackMode == .progressBar {
                    ProgressWindowController.shared.update(message: magicMsg, progress: progress)
                    DiagnosticLogger.shared.log("📝 \(magicMsg) (\(Int(progress * 100))%)")
                }
            }
        }

        // Wait for operation to complete, then cancel all timers
        let result = await operationTask.value
        timerTasks.forEach { $0.cancel() }
        return result
    }

    private func sendNotification(title: String, message: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = .default

        // Use 1-second delay trigger to ensure notification delivers after app quits
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            DiagnosticLogger.shared.log("❌ Notification error: \(error)")
        }
    }

    // Request notification permissions if needed
    private func requestNotificationPermissionsIfNeeded() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()

        if settings.authorizationStatus == .notDetermined {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
    }

    // Get the effective feedback mode (fallback to progress bar if notifications denied)
    private func effectiveFeedbackMode() async -> FeedbackMode {
        let userMode = UserPreferences.shared.feedbackMode

        // If user wants notifications, check if permission is granted
        if userMode == .notification {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            if settings.authorizationStatus == .denied {
                return .progressBar
            }
        }

        return userMode
    }

    func enqueueDMGs(_ urls: [URL]) {
        guard !urls.isEmpty else {
            DiagnosticLogger.shared.log("enqueueDMGs called with no DMG URLs")
            return
        }

        DiagnosticLogger.shared.log("enqueueDMGs adding \(urls.count) URL(s); pending before add=\(pendingDMGURLs.count)")
        pendingDMGURLs.append(contentsOf: urls)

        guard !isDrainingQueue else {
            DiagnosticLogger.shared.log("DMG queue already active; appended URL(s) for existing drain")
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
        DiagnosticLogger.shared.log("DMG queue started with \(pendingDMGURLs.count) pending URL(s)")

        while !pendingDMGURLs.isEmpty {
            let nextURL = pendingDMGURLs.removeFirst()
            DiagnosticLogger.shared.log("Processing next DMG: \(nextURL.path); remaining after dequeue=\(pendingDMGURLs.count)")
            await processNextDMG(at: nextURL)
        }

        isProcessing = false
        isDrainingQueue = false
        ProgressWindowController.shared.hide()

        DiagnosticLogger.shared.log("✅ Processing queue complete, quitting app")
        NSApp.terminate(nil)
    }

    // Process a DMG file (main entry point)
    func processDMG(at url: URL) async {
        enqueueDMGs([url])
    }

    private func processNextDMG(at url: URL) async {
        DiagnosticLogger.shared.log("processNextDMG started path=\(url.path)")

        // Request notification permissions early (before checking effective mode)
        await requestNotificationPermissionsIfNeeded()

        // Determine effective feedback mode (with fallback for denied notifications)
        currentFeedbackMode = await effectiveFeedbackMode()
        DiagnosticLogger.shared.log("Effective feedback mode: \(currentFeedbackMode.rawValue)")

        // Show progress window only in progress bar mode
        if currentFeedbackMode == .progressBar {
            ProgressWindowController.shared.show(message: "Preparing...", progress: 0.0)
        } else {
            ProgressWindowController.shared.hide()
        }

        // Validate the DMG file exists
        guard FileManager.default.fileExists(atPath: url.path) else {
            DiagnosticLogger.shared.log("DMG file missing before processing: \(url.path)")
            await handleError("File not found: \(url.lastPathComponent)")
            return
        }

        // Check for license agreement in DMG
        // TODO: Fix license detection - currently giving false positives without sandbox
        // if await hasLicenseAgreement(dmgPath: url.path) {
        //     await openForManualInstallation(dmgPath: url.path, reason: "DMG requires manual installation")
        //     return
        // }

        // Mount the DMG (Step 1: 0% → 20%)
        guard let mountPoint = await mountDMG(at: url.path, progress: 0.0) else {
            await openForManualInstallation(dmgPath: url.path, reason: "DMG requires manual installation")
            return
        }

        // Password-protected DMGs can't be mounted non-interactively
        if mountPoint == "PASSWORD_PROTECTED" {
            showProgress("DMG is password-protected, opening for manual install...", progress: 0.0)
            await openForManualInstallation(dmgPath: url.path, reason: "DMG is password-protected")
            return
        }

        // Find .app files in the mounted DMG (Step 2 starts: 20%)
        showProgress("Scanning for apps...", progress: 0.2)
        let appFiles = findAppFiles(in: mountPoint)

        // Filter out helper/uninstaller apps if there's a main app
        let mainApps = appFiles.filter { path in
            let name = (path as NSString).lastPathComponent.lowercased()
            return !name.contains("uninstall") &&
                   !name.contains("installer") &&
                   !name.contains("helper") &&
                   !name.contains("readme")
        }

        // Use filtered list if we got exactly 1 main app, otherwise use original list
        let finalAppFiles = mainApps.count == 1 ? mainApps : appFiles

        // Handle different scenarios
        switch finalAppFiles.count {
        case 0:
            DiagnosticLogger.shared.log("Manual fallback: no .app files found at \(mountPoint)")
            await openForManualInstallation(mountPoint: mountPoint, reason: "No .app files found")
            return

        case 1:
            // Single app found - proceed with installation
            let appPath = finalAppFiles[0]
            DiagnosticLogger.shared.log("Installing: \((appPath as NSString).lastPathComponent) from \(appPath)")
            await installApp(from: appPath, mountPoint: mountPoint, dmgPath: url.path)

        default:
            let appNames = finalAppFiles.map { ($0 as NSString).lastPathComponent }
            DiagnosticLogger.shared.log("Manual fallback: multiple .app files found (\(finalAppFiles.count)): \(appNames)")
            await openForManualInstallation(
                mountPoint: mountPoint,
                reason: "Multiple .app files found: \(appNames.joined(separator: ", "))"
            )
            return
        }

    }

    // Check if DMG has a license agreement
    private func hasLicenseAgreement(dmgPath: String) async -> Bool {
        // Use hdiutil imageinfo to check for license
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

            // Check for license agreement in output
            return output.contains("Software License Agreement") && output.contains("true")
        } catch {
            DiagnosticLogger.shared.log("Error checking for license: \(error)")
            return false
        }
    }

    private nonisolated static func parseMountPoint(fromAttachPlist data: Data) -> String? {
        do {
            let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            guard let root = plist as? [String: Any],
                  let systemEntities = root["system-entities"] as? [[String: Any]] else {
                DiagnosticLogger.shared.log("hdiutil plist missing expected system-entities structure")
                return nil
            }

            for entity in systemEntities {
                if let mountPoint = entity["mount-point"] as? String, !mountPoint.isEmpty {
                    DiagnosticLogger.shared.log("Parsed mount point from plist: \(mountPoint)")
                    return mountPoint
                }
            }

            DiagnosticLogger.shared.log("No mount-point found in hdiutil plist output")
            return nil
        } catch {
            DiagnosticLogger.shared.log("Failed to parse hdiutil plist output: \(error)")
            return nil
        }
    }

    // Mount a DMG file and return the mount point
    private func mountDMG(at path: String, progress: Double) async -> String? {
        DiagnosticLogger.shared.log("Mounting \(path)...")

        return await withMagicFallback(
            message: "Mounting disk image...",
            progress: progress
        ) {
            DiagnosticLogger.shared.log("Running hdiutil attach for \(path)")
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
                    DiagnosticLogger.shared.log("Mount failed with status \(task.terminationStatus)")
                    if !rawErrorOutput.isEmpty {
                        DiagnosticLogger.shared.log(
                            "hdiutil attach stderr: \(DiagnosticLogger.compact(rawErrorOutput))"
                        )
                    }
                    if errorOutput.contains("authentication") || errorOutput.contains("passphrase") || errorOutput.contains("encrypted") {
                        DiagnosticLogger.shared.log("Manual fallback classification: password protected or encrypted DMG")
                        return "PASSWORD_PROTECTED"
                    }
                    return nil
                }

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                DiagnosticLogger.shared.log("hdiutil attach succeeded")
                if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                    DiagnosticLogger.shared.log("hdiutil attach stdout: \(DiagnosticLogger.compact(output))")
                }

                return Self.parseMountPoint(fromAttachPlist: data)

            } catch {
                DiagnosticLogger.shared.log("Error mounting DMG: \(error)")
                return nil
            }
        }
    }

    // Calculate app bundle size
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

    // Check if enough disk space available
    private func hasEnoughDiskSpace(requiredBytes: UInt64) -> Bool {
        let appFolderPath = "/Applications"
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: appFolderPath),
              let freeSpace = attrs[.systemFreeSize] as? UInt64 else {
            // If we can't check, proceed anyway (defensive)
            return true
        }

        // Require app size + 500MB buffer
        let bufferSize: UInt64 = 500 * 1024 * 1024
        return freeSpace > (requiredBytes + bufferSize)
    }

    // Validate /Applications folder exists and is writable
    private func validateApplicationsFolder() -> String? {
        let appFolder = "/Applications"

        // Check if /Applications exists
        guard FileManager.default.fileExists(atPath: appFolder) else {
            return "/Applications folder does not exist"
        }

        // Check if it's a directory (not a file)
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: appFolder, isDirectory: &isDirectory)
        guard isDirectory.boolValue else {
            return "/Applications is not a directory"
        }

        // Check if it's writable
        guard FileManager.default.isWritableFile(atPath: appFolder) else {
            return "/Applications folder is not writable"
        }

        return nil  // All checks passed
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
            DiagnosticLogger.shared.log("Warning: Failed to clean up staged app: \(error)")
        }
    }

    @discardableResult
    private func trashDMGIfNeeded(at dmgPath: String, shouldTrash: Bool) -> Bool {
        guard shouldTrash else {
            return false
        }

        let dmgURL = URL(fileURLWithPath: dmgPath)
        do {
            try FileManager.default.trashItem(at: dmgURL, resultingItemURL: nil)
            DiagnosticLogger.shared.log("Moved DMG to Trash: \(dmgPath)")
            return true
        } catch {
            DiagnosticLogger.shared.log("Warning: Failed to move DMG to trash: \(error)")
            return false
        }
    }

    // Find .app files in a directory (root level only)
    private func findAppFiles(in mountPoint: String) -> [String] {
        let fileManager = FileManager.default
        var appFiles: [String] = []

        do {
            let contents = try fileManager.contentsOfDirectory(atPath: mountPoint)
            DiagnosticLogger.shared.log("Mount point contents: \(contents)")
            for item in contents {
                if item.hasSuffix(".app") && !item.hasPrefix(".") {
                    let fullPath = (mountPoint as NSString).appendingPathComponent(item)
                    appFiles.append(fullPath)
                }
            }
        } catch {
            DiagnosticLogger.shared.log("Error scanning mount point: \(error)")
        }

        DiagnosticLogger.shared.log("Found \(appFiles.count) .app file(s): \(appFiles)")
        return appFiles
    }

    // Install an app to /Applications
    private func installApp(from appPath: String, mountPoint: String, dmgPath: String) async {
        let appName = (appPath as NSString).lastPathComponent
        let destinationURL = URL(fileURLWithPath: "/Applications/\(appName)")
        let destinationPath = destinationURL.path
        let stagedURL = stagedAppURL(for: appName)
        var shouldReplaceExistingApp = false

        // Validate /Applications folder first
        if let errorMessage = validateApplicationsFolder() {
            DiagnosticLogger.shared.log("Applications folder validation failed: \(errorMessage)")
            await handleError(errorMessage)
            await unmountDMG(at: mountPoint)
            return
        }

        // Check if app already exists
        if FileManager.default.fileExists(atPath: destinationPath) {
            DiagnosticLogger.shared.log("Destination app already exists: \(destinationPath)")
            // Show Skip/Replace dialog
            let shouldReplace = await showSkipReplaceDialog(appName: appName)

            if !shouldReplace {
                // User chose to skip
                DiagnosticLogger.shared.log("Installation skipped by user")
                let didTrashDMG = await unmountAndCleanup(
                    mountPoint: mountPoint,
                    dmgPath: dmgPath,
                    shouldTrashDMG: UserPreferences.shared.autoTrashDMG
                )

                if currentFeedbackMode == .notification && didTrashDMG {
                    await sendNotification(
                        title: "EasyDMG",
                        message: "\(appName) was skipped; disk image moved to Trash"
                    )
                }

                ProgressWindowController.shared.hide()
                return
            }

            shouldReplaceExistingApp = true
            DiagnosticLogger.shared.log("User chose to replace existing app")

            // User chose to replace - show progress if in progress bar mode
            if currentFeedbackMode == .progressBar {
                ProgressWindowController.shared.show(message: "Preparing replacement...", progress: 0.2)
            }
        }

        // Check disk space before copying
        showProgress("Checking disk space...", progress: 0.15)
        let appSize = calculateAppSize(at: appPath)
        DiagnosticLogger.shared.log("Calculated app size: \(appSize) bytes for \(appPath)")
        if !hasEnoughDiskSpace(requiredBytes: appSize) {
            let sizeInGB = Double(appSize) / (1024 * 1024 * 1024)
            DiagnosticLogger.shared.log("Insufficient disk space for app size \(appSize)")
            await handleError("Insufficient disk space (need \(String(format: "%.1f", sizeInGB))GB)")
            await unmountDMG(at: mountPoint)
            return
        }

        cleanupStagedAppIfNeeded(at: stagedURL)

        // Copy app to /Applications staging location (Step 2: 20% → 40%)
        do {
            try await withMagicFallback(
                message: "Installing to Applications...",
                progress: 0.2
            ) {
                DiagnosticLogger.shared.log("Copying app from \(appPath) to staging path \(stagedURL.path)")
                try FileManager.default.copyItem(atPath: appPath, toPath: stagedURL.path)
            }

            // Remove quarantine attributes to prevent false "needs update" states
            // This replicates the behavior of manual Finder drag-and-drop installation
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
            DiagnosticLogger.shared.log("Installed app at destination: \(destinationPath); existsAfterMove=\(destinationExists)")

            // Send notification if in notification mode
            if currentFeedbackMode == .notification {
                await sendNotification(title: "EasyDMG", message: "\(appName) installed successfully")
            }
        } catch {
            DiagnosticLogger.shared.log("Installation failed while copying/replacing: \(error)")
            cleanupStagedAppIfNeeded(at: stagedURL)
            await handleError("Installation failed")
            await unmountDMG(at: mountPoint, progress: 0.6)
            return
        }

        // Reveal in Finder (Step 3: 40% → 60%)
        if UserPreferences.shared.revealInFinder {
            showProgress("Opening in Finder...", progress: 0.4)
            revealInFinder(path: destinationPath)
        } else {
            showProgress("Finalizing installation...", progress: 0.4)
        }

        // Unmount DMG (Step 4: 60% → 80%)
        await unmountDMG(at: mountPoint, progress: 0.6)

        // Move to Trash (Step 5: 80% → 100%)
        if UserPreferences.shared.autoTrashDMG {
            showProgress("Moving disk image to trash...", progress: 0.8)
            trashDMGIfNeeded(at: dmgPath, shouldTrash: true)
        } else {
            showProgress("Keeping disk image...", progress: 0.8)
        }

        // Handle completion based on feedback mode
        if currentFeedbackMode == .progressBar {
            // Show completion message briefly in progress bar mode
            showProgress("Installation complete!", progress: 1.0)
            try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 seconds
        }

        // Hide the progress window (only visible in progress bar mode)
        ProgressWindowController.shared.hide()
        DiagnosticLogger.shared.log("✅ Processing complete for \(appName)")
    }

    // Show Skip/Replace dialog
    private func showSkipReplaceDialog(appName: String) async -> Bool {
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.alertStyle = .informational
                alert.messageText = "EasyDMG"
                alert.informativeText = "\(appName) already exists in Applications.\n\nWhat would you like to do?"

                // Try to use EasyDMG icon
                if let iconPath = Bundle.main.path(forResource: "wizardhamster", ofType: "icns"),
                   let icon = NSImage(contentsOfFile: iconPath) {
                    alert.icon = icon
                }

                alert.addButton(withTitle: "Replace")
                alert.addButton(withTitle: "Skip")

                let response = alert.runModal()
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }

    // Unmount DMG
    private func unmountDMG(at mountPoint: String, progress: Double? = nil) async {
        DiagnosticLogger.shared.log("Unmounting \(mountPoint)...")

        // If progress is provided, use magic fallback wrapper
        if let progress = progress {
            await withMagicFallback(
                message: "Cleaning up...",
                progress: progress
            ) {
                self.performUnmount(at: mountPoint)
            }
        } else {
            // No progress tracking needed (error recovery paths)
            performUnmount(at: mountPoint)
        }
    }

    // Synchronous unmount helper (called from withMagicFallback or directly)
    private nonisolated func performUnmount(at mountPoint: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        task.arguments = ["detach", mountPoint]

        let errorPipe = Pipe()
        task.standardError = errorPipe

        do {
            try task.run()
            task.waitUntilExit()

            if task.terminationStatus == 0 {
                DiagnosticLogger.shared.log("✓ Clean detach succeeded")
                return
            }

            // Read error output
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
            DiagnosticLogger.shared.log(
                "Detach failed: \(DiagnosticLogger.compact(errorOutput))"
            )

            // Check for "resource busy" and retry once
            if errorOutput.lowercased().contains("resource busy") {
                DiagnosticLogger.shared.log("Resource busy, waiting 250ms and retrying...")
                Thread.sleep(forTimeInterval: 0.25)

                let retryTask = Process()
                retryTask.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                retryTask.arguments = ["detach", mountPoint]
                try? retryTask.run()
                retryTask.waitUntilExit()

                if retryTask.terminationStatus == 0 {
                    DiagnosticLogger.shared.log("✓ Retry detach succeeded")
                    return
                }
            }

            // Force detach as last resort
            DiagnosticLogger.shared.log("Using force detach...")
            let forceTask = Process()
            forceTask.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            forceTask.arguments = ["detach", mountPoint, "-force"]
            try? forceTask.run()
            forceTask.waitUntilExit()
            DiagnosticLogger.shared.log("✓ Force detach completed with status \(forceTask.terminationStatus)")
        } catch {
            DiagnosticLogger.shared.log("Error unmounting DMG: \(error)")
        }
    }

    // Unmount and cleanup (optionally move DMG to trash)
    private func unmountAndCleanup(mountPoint: String, dmgPath: String, shouldTrashDMG: Bool) async -> Bool {
        await unmountDMG(at: mountPoint)

        if shouldTrashDMG {
            showProgress("Moving disk image to trash...", progress: 0.8)
        } else {
            showProgress("Keeping disk image...", progress: 0.8)
        }

        return trashDMGIfNeeded(at: dmgPath, shouldTrash: shouldTrashDMG)
    }

    // Remove quarantine attributes from installed app
    // This prevents apps with auto-update mechanisms from incorrectly detecting
    // "needs update" states that can cause unwanted behavior
    private func removeQuarantineAttributes(from path: String) async {
        DiagnosticLogger.shared.log("Removing quarantine attributes from \(path)...")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        task.arguments = ["-dr", "com.apple.quarantine", path]

        let errorPipe = Pipe()
        task.standardError = errorPipe

        do {
            try task.run()
            task.waitUntilExit()

            if task.terminationStatus == 0 {
                DiagnosticLogger.shared.log("✓ Quarantine attributes removed")
            } else {
                // Read error but don't fail - this is non-critical
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
                DiagnosticLogger.shared.log(
                    "Note: Could not remove quarantine attributes: \(DiagnosticLogger.compact(errorOutput))"
                )
            }
        } catch {
            // Non-fatal error - log and continue
            DiagnosticLogger.shared.log("Note: xattr command failed: \(error)")
        }
    }

    // Open for manual installation (mount point)
    private func openForManualInstallation(mountPoint: String, reason: String) async {
        DiagnosticLogger.shared.log("Manual fallback opening mount point: \(mountPoint); reason=\(reason)")
        NSWorkspace.shared.open(URL(fileURLWithPath: mountPoint))
        ProgressWindowController.shared.hide()

        DiagnosticLogger.shared.log("✅ Opened mounted volume for manual installation")
    }

    // Open for manual installation (DMG path)
    private func openForManualInstallation(dmgPath: String, reason: String) async {
        DiagnosticLogger.shared.log("Manual fallback opening DMG path: \(dmgPath); reason=\(reason)")
        let dmgURL = URL(fileURLWithPath: dmgPath)
        let mounterURL = URL(fileURLWithPath: "/System/Library/CoreServices/DiskImageMounter.app")
        let configuration = NSWorkspace.OpenConfiguration()

        NSWorkspace.shared.open([dmgURL], withApplicationAt: mounterURL, configuration: configuration) { _, error in
            if let error {
                DiagnosticLogger.shared.log("❌ Failed to open DMG in DiskImageMounter (\(reason)): \(error)")
            }
        }
        ProgressWindowController.shared.hide()

        DiagnosticLogger.shared.log("✅ Opened DMG in DiskImageMounter for manual installation: \(reason)")
    }

    // Reveal app in Finder
    private func revealInFinder(path: String) {
        DiagnosticLogger.shared.log("Revealing app in Finder: \(path)")
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "/Applications")
    }

    // Handle errors
    private func handleError(_ message: String) async {
        DiagnosticLogger.shared.log("Error: \(message)")
        showProgress("Error: \(message)", progress: 0.0)

        // Keep error visible for 3 seconds
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        ProgressWindowController.shared.hide()

        DiagnosticLogger.shared.log("✅ Error handled, continuing queue if needed")
    }
}
