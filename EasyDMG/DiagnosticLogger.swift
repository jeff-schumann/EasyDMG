//
//  DiagnosticLogger.swift
//  EasyDMG
//
//  File-backed activity log for launch and DMG handling. A single, always-on,
//  human-readable log lets users see what EasyDMG did and attach it to a GitHub
//  issue if something goes wrong.
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

    private let lock = NSLock()
    private let sessionID = UUID().uuidString.lowercased()
    private let target: LogTarget?

    nonisolated var logFilePath: String? {
        target?.url.path
    }

    private init() {
        let logsDirectory = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("EasyDMG", isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: logsDirectory,
                withIntermediateDirectories: true
            )

            Self.removeLegacyLogs(in: logsDirectory)

            target = LogTarget(
                url: logsDirectory.appendingPathComponent("easydmg.log"),
                archivedURL: logsDirectory.appendingPathComponent("easydmg.previous.log"),
                lockURL: logsDirectory.appendingPathComponent("easydmg.log.lock"),
                maxBytes: 512 * 1024
            )
        } catch {
            target = nil
            #if DEBUG
            print("EasyDMG logging unavailable: \(error)")
            #endif
        }
    }

    /// One-time best-effort cleanup of the pre-consolidation log files (the old
    /// support/diagnostic split). Idempotent: once we stop writing these names,
    /// they never reappear. Prevents users from grabbing a stale log for an issue.
    nonisolated private static func removeLegacyLogs(in directory: URL) {
        let legacyNames = [
            "support.log",
            "support.previous.log",
            "support.log.lock",
            "diagnostic.log",
            "diagnostic.previous.log",
            "diagnostic.log.lock"
        ]

        for name in legacyNames {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    nonisolated func startSession() {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let bundleID = bundle.bundleIdentifier ?? "unknown"

        log("")
        log("=== EasyDMG session started ===")
        log("date=\(humanReadableDate())")
        log("sessionID=\(sessionID)")
        log("bundleID=\(bundleID) version=\(version) build=\(build)")
        log("os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        log("bundlePath=\(bundle.bundlePath)")
        log("executablePath=\(bundle.executablePath ?? "unknown")")
        log("processID=\(ProcessInfo.processInfo.processIdentifier)")
        log("logPath=\(logFilePath ?? "unavailable")")
    }

    /// Structured event with optional key/value details, rendered as one readable
    /// line. Kept as a convenience for lifecycle events; output goes to the same
    /// single log as `diagnostic`.
    nonisolated func support(event: String, details: [String: String] = [:]) {
        let rendered = details.keys.sorted()
            .compactMap { key -> String? in
                guard let value = details[key], !value.isEmpty else { return nil }
                return "\(key)=\(value)"
            }
            .joined(separator: " ")

        log(rendered.isEmpty ? event : "\(event) — \(rendered)")
    }

    nonisolated func diagnostic(_ message: @autoclosure () -> String) {
        log(message())
    }

    nonisolated private func log(_ message: @autoclosure () -> String) {
        guard let target else {
            return
        }

        let rendered = message()
        #if DEBUG
        print(rendered)
        #endif
        append(line: "[\(timestamp())] \(rendered)\n", to: target)
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

    nonisolated private func humanReadableDate() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return formatter.string(from: Date())
    }

    nonisolated private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: Date())
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
