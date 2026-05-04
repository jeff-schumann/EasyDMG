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
    private enum ManualFallbackReason: String, Sendable {
        case genericMountFailure = "generic_mount_failure"
        case invalidAppBundle = "invalid_app_bundle"
        case packageInstaller = "package_installer"
        case installerOrAuxiliaryApp = "installer_or_auxiliary_app"
        case passwordProtected = "password_protected"
        case noAppFound = "no_app_found"
        case multipleAppsFound = "multiple_apps_found"
        case licenseRequired = "license_required"
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

    // Progressive messages shown at intervals if operation takes too long
    private let magicMessages: [(delay: UInt64, message: String)] = [
        (4_000_000_000, "🪄 Invoking ancient hamster magic..."),
        (8_000_000_000, "Opening a high capacity portal 🎩..."),
        (12_000_000_000, "🐹 Hamster is strong, but app is big...")
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
                    DiagnosticLogger.shared.diagnostic("📝 \(magicMsg) (\(Int(progress * 100))%)")
                }
            }
        }

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

        let operationTask = Task.detached(priority: .userInitiated) {
            operation()
        }

        let timerTasks = magicMessages.map { delayNanos, magicMsg in
            Task { @MainActor [currentFeedbackMode] in
                try? await Task.sleep(nanoseconds: delayNanos)
                if !Task.isCancelled && currentFeedbackMode == .progressBar {
                    ProgressWindowController.shared.update(message: magicMsg, progress: progress)
                    DiagnosticLogger.shared.diagnostic("📝 \(magicMsg) (\(Int(progress * 100))%)")
                }
            }
        }

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
            diagnostic("❌ Notification error: \(error)")
        }
    }

    private func requestNotificationPermissionsIfNeeded() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()

        if settings.authorizationStatus == .notDetermined {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
    }

    // Get the effective feedback mode (fallback to progress bar if notifications denied)
    private func effectiveFeedbackMode() async -> FeedbackMode {
        let userMode = UserPreferences.shared.feedbackMode

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
            let shouldReplace = await showSkipReplaceDialog(appName: resolvedAppName)

            if !shouldReplace {
                diagnostic("Installation skipped by user")
                support(
                    event: "install_decision",
                    details: ["action": "skip", "app": resolvedAppName, "dmg": dmgName]
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
                        message: "\(resolvedAppName) was skipped; disk image moved to Trash"
                    )
                }

                ProgressWindowController.shared.hide()
                recordCompletion(
                    dmgName: dmgName,
                    outcome: "skipped",
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
                await sendNotification(title: "EasyDMG", message: "\(resolvedAppName) installed successfully")
            }
        } catch {
            diagnostic("Installation failed while copying/replacing: \(error)")
            cleanupStagedAppIfNeeded(at: stagedURL)
            support(
                event: "install_result",
                details: errorDetails(error).merging([
                    "app": resolvedAppName,
                    "dmg": dmgName,
                    "reason": "copy_or_replace_failed",
                    "result": "failed"
                ]) { current, _ in current }
            )
            recordCompletion(
                dmgName: dmgName,
                outcome: "error",
                details: ["app": resolvedAppName, "reason": "copy_or_replace_failed"]
            )
            await handleError("Installation failed")
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
                "trashed_dmg": boolString(didTrashDMG)
            ]
        )
    }

    private func showSkipReplaceDialog(appName: String) async -> Bool {
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.alertStyle = .informational
                alert.messageText = "EasyDMG"
                alert.informativeText = "\(appName) already exists in Applications.\n\nWhat would you like to do?"

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
    }

    private func revealInFinder(path: String) {
        diagnostic("Revealing app in Finder: \(path)")
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "/Applications")
    }

    private func handleError(_ message: String) async {
        diagnostic("Error: \(message)")
        showProgress("Error: \(message)", progress: 0.0)

        try? await Task.sleep(nanoseconds: 3_000_000_000)
        ProgressWindowController.shared.hide()

        diagnostic("✅ Error handled, continuing queue if needed")
    }
}
