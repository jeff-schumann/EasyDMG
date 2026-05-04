//
//  NotificationPermissions.swift
//  EasyDMG
//
//  Shared notification permission helpers for settings UI and feedback fallback.
//

import AppKit
import Combine
import Foundation
import UserNotifications

enum NotificationPermissionState: String, Equatable {
    case loading
    case notDetermined
    case on
    case limited
    case off

    init(settings: UNNotificationSettings) {
        switch settings.authorizationStatus {
        case .notDetermined:
            self = .notDetermined
        case .denied:
            self = .off
        case .authorized, .provisional:
            self = settings.canShowVisibleAlerts ? .on : .limited
        @unknown default:
            self = .off
        }
    }

    var canUseNotificationFeedback: Bool {
        self == .on
    }
}

extension UNNotificationSettings {
    var canShowVisibleAlerts: Bool {
        authorizationStatus == .authorized &&
            alertSetting == .enabled &&
            alertStyle != .none
    }

    var diagnosticDescription: String {
        [
            "authorization=\(authorizationStatus.diagnosticDescription)",
            "alert=\(alertSetting.diagnosticDescription)",
            "alertStyle=\(alertStyle.diagnosticDescription)",
            "sound=\(soundSetting.diagnosticDescription)",
            "notificationCenter=\(notificationCenterSetting.diagnosticDescription)"
        ].joined(separator: " ")
    }
}

private extension UNAuthorizationStatus {
    var diagnosticDescription: String {
        switch self {
        case .notDetermined: return "notDetermined"
        case .denied:        return "denied"
        case .authorized:    return "authorized"
        case .provisional:   return "provisional"
        case .ephemeral:     return "ephemeral"
        @unknown default:    return "unknown(\(rawValue))"
        }
    }
}

private extension UNNotificationSetting {
    var diagnosticDescription: String {
        switch self {
        case .notSupported:  return "notSupported"
        case .disabled:      return "disabled"
        case .enabled:       return "enabled"
        @unknown default:    return "unknown(\(rawValue))"
        }
    }
}

private extension UNAlertStyle {
    var diagnosticDescription: String {
        switch self {
        case .none:          return "none"
        case .banner:        return "banner"
        case .alert:         return "alert"
        @unknown default:    return "unknown(\(rawValue))"
        }
    }
}

@MainActor
final class NotificationPermissionViewModel: ObservableObject {
    @Published private(set) var state: NotificationPermissionState = .loading
    @Published private(set) var isRequesting = false

    private let center = UNUserNotificationCenter.current()
    private var settingsRefreshTask: Task<Void, Never>?

    deinit {
        settingsRefreshTask?.cancel()
    }

    func refresh() {
        Task {
            await refreshNow()
        }
    }

    func prepareForNotificationFeedback() {
        switch state {
        case .notDetermined:
            requestAuthorization()
        default:
            refresh()
        }
    }

    func performPrimaryAction() {
        switch state {
        case .notDetermined:
            requestAuthorization()
        case .loading:
            break
        case .on, .limited, .off:
            NotificationSettingsOpener.open()
            refreshWhileSystemSettingsIsOpen()
        }
    }

    private func refreshNow() async {
        let settings = await center.notificationSettings()
        state = NotificationPermissionState(settings: settings)
    }

    private func requestAuthorization() {
        guard !isRequesting else { return }

        Task {
            isRequesting = true
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            await refreshNow()
            isRequesting = false
        }
    }

    private func refreshWhileSystemSettingsIsOpen() {
        settingsRefreshTask?.cancel()

        settingsRefreshTask = Task {
            for _ in 0..<60 {
                if Task.isCancelled { return }

                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }

                let previousState = state
                await refreshNow()

                if state.canUseNotificationFeedback && previousState != state {
                    return
                }
            }

            await refreshNow()
        }
    }
}

private enum NotificationSettingsOpener {
    static func open() {
        for url in candidateURLs {
            if NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private static var candidateURLs: [URL] {
        var strings: [String] = []

        if let bundleID = Bundle.main.bundleIdentifier?
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            strings.append("x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)")
            strings.append("x-apple.systempreferences:com.apple.preference.notifications?id=\(bundleID)")
        }

        strings.append("x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        strings.append("x-apple.systempreferences:com.apple.preference.notifications")

        return strings.compactMap(URL.init(string:))
    }
}
