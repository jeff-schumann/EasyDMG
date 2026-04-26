//
//  DiagnosticLogger.swift
//  EasyDMG
//
//  Lightweight file-backed diagnostics for debugging launch and DMG handling.
//

import Foundation

final class DiagnosticLogger: @unchecked Sendable {
    nonisolated static let shared = DiagnosticLogger()

    private static let environmentKey = "EASYDMG_DIAGNOSTIC_LOGGING"
    private static let defaultsKey = "diagnosticLoggingEnabled"

    private let lock = NSLock()
    private let enabled: Bool
    private let logURL: URL?
    private let timestampFormatter: DateFormatter

    nonisolated var isEnabled: Bool {
        enabled
    }

    nonisolated var logFilePath: String? {
        logURL?.path
    }

    private init() {
        let environment = ProcessInfo.processInfo.environment[Self.environmentKey]
        let enabledByEnvironment = Self.isEnabledValue(environment)
        let enabledByDefaults = UserDefaults.standard.bool(forKey: Self.defaultsKey)
        self.enabled = enabledByEnvironment || enabledByDefaults
        self.timestampFormatter = Self.makeTimestampFormatter()

        guard enabled else {
            self.logURL = nil
            return
        }

        let logsDirectory = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("EasyDMG", isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: logsDirectory,
                withIntermediateDirectories: true
            )
            self.logURL = logsDirectory.appendingPathComponent("diagnostic.log")
        } catch {
            self.logURL = nil
            print("EasyDMG diagnostics unavailable: \(error)")
        }
    }

    nonisolated func startSession() {
        guard enabled else {
            return
        }

        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let bundleID = bundle.bundleIdentifier ?? "unknown"
        let executable = bundle.executablePath ?? "unknown"

        write("")
        write("=== EasyDMG diagnostic session started ===")
        write("bundleID=\(bundleID) version=\(version) build=\(build)")
        write("bundlePath=\(bundle.bundlePath)")
        write("executablePath=\(executable)")
        write("processID=\(ProcessInfo.processInfo.processIdentifier)")
        write("timeZone=\(Self.timeZoneDescription())")
        write("logPath=\(logFilePath ?? "unavailable")")
    }

    nonisolated func log(_ message: @autoclosure () -> String) {
        let rendered = message()
        print(rendered)
        write(rendered)
    }

    nonisolated func write(_ message: @autoclosure () -> String) {
        guard enabled, let logURL else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        rotateIfNeeded(at: logURL)

        let timestamp = timestampFormatter.string(from: Date())
        let line = "[\(timestamp)] \(message())\n"
        let data = Data(line.utf8)

        do {
            if FileManager.default.fileExists(atPath: logURL.path) {
                let handle = try FileHandle(forWritingTo: logURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: logURL, options: .atomic)
            }
        } catch {
            print("EasyDMG diagnostics write failed: \(error)")
        }
    }

    nonisolated static func compact(_ value: String, maxLength: Int = 2_000) -> String {
        let compacted = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard compacted.count > maxLength else {
            return compacted
        }

        return "\(compacted.prefix(maxLength))... [truncated]"
    }

    nonisolated private static func isEnabledValue(_ value: String?) -> Bool {
        guard let value else {
            return false
        }

        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on", "enabled":
            return true
        default:
            return false
        }
    }

    nonisolated private static func makeTimestampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS ZZZZZ"
        return formatter
    }

    nonisolated private static func timeZoneDescription(for date: Date = Date()) -> String {
        let timeZone = TimeZone.autoupdatingCurrent
        let secondsFromGMT = timeZone.secondsFromGMT(for: date)
        let hours = secondsFromGMT / 3600
        let minutes = abs(secondsFromGMT / 60) % 60
        let offset = String(format: "%+.2d:%02d", hours, minutes)

        if let abbreviation = timeZone.abbreviation(for: date) {
            return "\(timeZone.identifier) \(abbreviation) \(offset)"
        }

        return "\(timeZone.identifier) \(offset)"
    }

    nonisolated private func rotateIfNeeded(at logURL: URL) {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
            let size = attributes[.size] as? NSNumber,
            size.uint64Value > 512 * 1024
        else {
            return
        }

        let archivedURL = logURL.deletingLastPathComponent().appendingPathComponent("diagnostic.previous.log")
        try? FileManager.default.removeItem(at: archivedURL)
        try? FileManager.default.moveItem(at: logURL, to: archivedURL)
    }
}
