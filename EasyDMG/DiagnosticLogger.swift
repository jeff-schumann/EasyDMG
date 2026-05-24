//
//  DiagnosticLogger.swift
//  EasyDMG
//
//  File-backed support and diagnostic logging for launch and DMG handling.
//

import Foundation
import Darwin

final class DiagnosticLogger: @unchecked Sendable {
    private struct LogTarget: Sendable {
        let url: URL
        let archivedURL: URL
        let lockURL: URL
        let maxBytes: UInt64
    }

    nonisolated static let shared = DiagnosticLogger()

    private static let environmentKey = "EASYDMG_DIAGNOSTIC_LOGGING"
    private static let defaultsKey = "diagnosticLoggingEnabled"

    private let lock = NSLock()
    private let sessionID = UUID().uuidString.lowercased()
    private let supportTarget: LogTarget?
    private let diagnosticTarget: LogTarget?
    private let diagnosticEnabled: Bool

    nonisolated var isEnabled: Bool {
        diagnosticEnabled
    }

    nonisolated var isDiagnosticEnabled: Bool {
        diagnosticEnabled
    }

    nonisolated var supportLogFilePath: String? {
        supportTarget?.url.path
    }

    nonisolated var diagnosticLogFilePath: String? {
        diagnosticTarget?.url.path
    }

    private init() {
        let environment = ProcessInfo.processInfo.environment[Self.environmentKey]
        let enabledByEnvironment = Self.isEnabledValue(environment)
        let enabledByDefaults = UserDefaults.standard.bool(forKey: Self.defaultsKey)
        diagnosticEnabled = enabledByEnvironment || enabledByDefaults

        let logsDirectory = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("EasyDMG", isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: logsDirectory,
                withIntermediateDirectories: true
            )

            supportTarget = LogTarget(
                url: logsDirectory.appendingPathComponent("support.log"),
                archivedURL: logsDirectory.appendingPathComponent("support.previous.log"),
                lockURL: logsDirectory.appendingPathComponent("support.log.lock"),
                maxBytes: 256 * 1024
            )

            if diagnosticEnabled {
                diagnosticTarget = LogTarget(
                    url: logsDirectory.appendingPathComponent("diagnostic.log"),
                    archivedURL: logsDirectory.appendingPathComponent("diagnostic.previous.log"),
                    lockURL: logsDirectory.appendingPathComponent("diagnostic.log.lock"),
                    maxBytes: 512 * 1024
                )
            } else {
                diagnosticTarget = nil
            }
        } catch {
            supportTarget = nil
            diagnosticTarget = nil
            #if DEBUG
            print("EasyDMG logging unavailable: \(error)")
            #endif
        }
    }

    nonisolated func startSession() {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let bundleID = bundle.bundleIdentifier ?? "unknown"

        support(
            event: "session_start",
            details: [
                "bundle_id": bundleID,
                "diagnostic_logging": diagnosticEnabled ? "enabled" : "disabled",
                "build": build,
                "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
                "version": version
            ]
        )

        guard diagnosticEnabled else {
            return
        }

        diagnostic("")
        diagnostic("=== EasyDMG diagnostic session started ===")
        diagnostic("sessionID=\(sessionID)")
        diagnostic("bundleID=\(bundleID) version=\(version) build=\(build)")
        diagnostic("bundlePath=\(bundle.bundlePath)")
        diagnostic("executablePath=\(bundle.executablePath ?? "unknown")")
        diagnostic("processID=\(ProcessInfo.processInfo.processIdentifier)")
        diagnostic("supportLogPath=\(supportLogFilePath ?? "unavailable")")
        diagnostic("diagnosticLogPath=\(diagnosticLogFilePath ?? "unavailable")")
    }

    nonisolated func support(event: String, details: [String: String] = [:]) {
        guard let supportTarget else {
            return
        }

        let renderedLine = renderSupportLine(event: event, details: details)
        append(line: renderedLine, to: supportTarget)
    }

    nonisolated func diagnostic(_ message: @autoclosure () -> String) {
        guard let diagnosticTarget else {
            return
        }

        let rendered = message()
        #if DEBUG
        print(rendered)
        #endif
        append(line: "[\(timestamp())] \(rendered)\n", to: diagnosticTarget)
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

    nonisolated private func renderSupportLine(event: String, details: [String: String]) -> String {
        var components = [
            "time=\(timestamp())",
            "session_id=\(escapeSupportValue(sessionID))",
            "event=\(escapeSupportValue(event))"
        ]

        for key in details.keys.sorted() {
            guard let value = details[key], !value.isEmpty else {
                continue
            }
            components.append("\(key)=\(escapeSupportValue(value))")
        }

        return components.joined(separator: " ") + "\n"
    }

    nonisolated private func escapeSupportValue(_ value: String) -> String {
        guard value.rangeOfCharacter(from: CharacterSet(charactersIn: " =\"")) != nil else {
            return value
        }

        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    nonisolated private func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    nonisolated private func append(line: String, to target: LogTarget) {
        lock.lock()
        defer { lock.unlock() }

        do {
            try withExclusiveFileLock(at: target.lockURL) {
                rotateIfNeeded(target)
                try appendLine(line, to: target.url)
            }
        } catch {
            #if DEBUG
            print("EasyDMG logging write failed: \(error)")
            #endif
        }
    }

    nonisolated private func withExclusiveFileLock<T>(
        at lockURL: URL,
        operation: () throws -> T
    ) throws -> T {
        let fileDescriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR,
            mode_t(S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        )
        guard fileDescriptor >= 0 else {
            throw POSIXError(Self.currentPOSIXErrorCode())
        }

        defer { _ = Darwin.close(fileDescriptor) }

        while flock(fileDescriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw POSIXError(Self.currentPOSIXErrorCode())
            }
        }

        defer { _ = flock(fileDescriptor, LOCK_UN) }

        return try operation()
    }

    nonisolated private func appendLine(_ line: String, to url: URL) throws {
        let fileDescriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_APPEND,
            mode_t(S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        )
        guard fileDescriptor >= 0 else {
            throw POSIXError(Self.currentPOSIXErrorCode())
        }

        defer { _ = Darwin.close(fileDescriptor) }

        let bytes = Array(line.utf8)
        try bytes.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }

            var offset = 0
            while offset < buffer.count {
                let bytesWritten = Darwin.write(
                    fileDescriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )

                if bytesWritten > 0 {
                    offset += bytesWritten
                } else if bytesWritten == 0 {
                    throw POSIXError(.EIO)
                } else if errno != EINTR {
                    throw POSIXError(Self.currentPOSIXErrorCode())
                }
            }
        }
    }

    nonisolated private static func currentPOSIXErrorCode() -> POSIXErrorCode {
        POSIXErrorCode(rawValue: errno) ?? .EIO
    }

    nonisolated private func rotateIfNeeded(_ target: LogTarget) {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: target.url.path),
            let size = attributes[.size] as? NSNumber,
            size.uint64Value > target.maxBytes
        else {
            return
        }

        try? FileManager.default.removeItem(at: target.archivedURL)
        try? FileManager.default.moveItem(at: target.url, to: target.archivedURL)
    }
}
