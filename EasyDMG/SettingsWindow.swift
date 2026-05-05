//
//  SettingsWindow.swift
//  EasyDMG
//
//  Settings window with Setup, About, and Settings tabs
//

import SwiftUI
import AppKit
import Combine
import CoreServices
import Sparkle

// MARK: - Tab Enum

enum SettingsTab: String, CaseIterable {
    case setup    = "Setup"
    case settings = "Settings"
    case about    = "About"
}

// MARK: - Window Configurator

private struct WindowConfigurator: NSViewRepresentable {
    let backgroundColor: NSColor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isMovableByWindowBackground = true
            window.backgroundColor = backgroundColor
            repositionTrafficLights(in: window, targetX: 16)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.backgroundColor = backgroundColor
        }
    }

    private func repositionTrafficLights(in window: NSWindow, targetX: CGFloat) {
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        guard let close = window.standardWindowButton(.closeButton) else { return }
        let dx = targetX - close.frame.origin.x
        guard dx != 0 else { return }
        for type in types {
            if let button = window.standardWindowButton(type) {
                button.setFrameOrigin(NSPoint(x: button.frame.origin.x + dx, y: button.frame.origin.y))
            }
        }
    }
}

// MARK: - Root Settings View

struct SettingsView: View {
    @StateObject private var preferences = UserPreferences.shared
    @State private var selectedTab: SettingsTab = .setup
    @Environment(\.colorScheme) private var colorScheme

    private var theme: SettingsTheme { SettingsTheme.resolve(for: colorScheme) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HeroHeader()
                SettingsTabBar(selection: $selectedTab, theme: theme)
            }
            .background(
                colorScheme == .dark
                    ? AnyView(SettingsPalette.heroGradient)
                    : AnyView(Color.clear)
            )
            .overlay(alignment: .bottom) {
                if colorScheme == .dark {
                    Rectangle()
                        .fill(SettingsPalette.heroHairline)
                        .frame(height: 1)
                }
            }
            Group {
                switch selectedTab {
                case .setup:
                    SetupTabView(theme: theme)
                case .settings:
                    SettingsTabView(preferences: preferences, theme: theme)
                case .about:
                    AboutTabView(theme: theme)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 550, idealWidth: 550, maxWidth: .infinity,
               minHeight: 500, idealHeight: 500, maxHeight: .infinity)
        .background(theme.background)
        .background(WindowConfigurator(backgroundColor: NSColor(theme.background)))
        .ignoresSafeArea()
    }
}

// MARK: - Hero Header

private struct HeroHeader: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: colorScheme == .dark ? 14 : 4) {
            Image("wizardhamster")
                .resizable()
                .frame(width: 84, height: 84)
                .cornerRadius(16)
            VStack(alignment: .leading, spacing: 5) {
                Text("EasyDMG")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(colorScheme == .dark ? Color(hex: "FDF8EC") : Color(hex: "231A12"))
                    .tracking(-0.5)
                Text("v\(Bundle.main.appVersion)")
                    .font(.system(size: 12))
                    .foregroundStyle(colorScheme == .dark ? Color(hex: "EDDFBD") : Color(hex: "7D6A58"))
            }
            Spacer()
        }
        .padding(.top, 32)
        .padding(.bottom, 4)
        .padding(.horizontal, 16)
        .background(
            colorScheme == .dark
                ? AnyView(Color.clear)
                : AnyView(SettingsPalette.heroBackground)
        )
    }
}

// MARK: - Setup Tab

struct SetupTabView: View {
    let theme: SettingsTheme
    @State private var isDefault = DefaultHandlerHelper.isDefaultDMGHandler()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                // Set as Default section
                VStack(alignment: .leading, spacing: 14) {
                    Text("Set as Default")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(theme.text)

                    if isDefault {
                        HStack(spacing: 8) {
                            Text("✓")
                                .font(.system(size: 16))
                            Text("EasyDMG is your default app for DMG files.")
                                .font(.system(size: 13))
                        }
                        .foregroundStyle(theme.successGreen)
                    } else {
                        Text("Make EasyDMG automatically handle DMG files when you double-click them.")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.muted)

                        Button("Set as Default for DMG Files") {
                            DefaultHandlerHelper.setAsDefaultDMGHandler()
                            isDefault = DefaultHandlerHelper.isDefaultDMGHandler()
                        }
                        .buttonStyle(AmberFilledButtonStyle())
                    }
                }

                HStack(spacing: 12) {
                    Rectangle().fill(theme.border).frame(height: 1)
                    Text("OR")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(theme.muted)
                    Rectangle().fill(theme.border).frame(height: 1)
                }

                // Manual setup steps
                VStack(alignment: .leading, spacing: 14) {
                    Text("Alternative: Manual Setup")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(theme.text)

                    VStack(alignment: .leading, spacing: 10) {
                        StepBubble(number: 1, text: "Right-click any .dmg file",           textColor: theme.text)
                        StepBubble(number: 2, text: "Select \"Get Info\"",                  textColor: theme.text)
                        StepBubble(number: 3, text: "Under \"Open with:\" choose EasyDMG", textColor: theme.text)
                        StepBubble(number: 4, text: "Click \"Change All...\"",              textColor: theme.text)
                    }

                    HStack {
                        Spacer()
                        Image("easydmg-select")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 395)
                            .cornerRadius(8)
                            .shadow(radius: 2)
                        Spacer()
                    }
                    .padding(.top, 8)
                }

                HStack(spacing: 12) {
                    Rectangle().fill(theme.border).frame(height: 1)
                    Text("OR")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(theme.muted)
                    Rectangle().fill(theme.border).frame(height: 1)
                }

                // Open With section
                VStack(alignment: .leading, spacing: 14) {
                    Text("Open with EasyDMG Without Setting as Default")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(theme.text)

                    Text("Right click any DMG and select 'Open With' to have EasyDMG seamlessly handle installation and cleanup.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.muted)
                        .lineSpacing(2)

                    // Held off on this for now — see if it belongs in About instead.
                    // Text("Note: if you've already set EasyDMG as your default, you can use right click > 'Open With' and choose DiskImageMounter to use the regular Apple app.")
                    //     .font(.system(size: 11.5))
                    //     .foregroundStyle(theme.muted)
                    //     .lineSpacing(2)
                    //     .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
        }
        .onAppear {
            isDefault = DefaultHandlerHelper.isDefaultDMGHandler()
        }
    }
}

// MARK: - Default Handler Helper

enum DefaultHandlerHelper {
    private static let dmgUTIs: [CFString] = [
        "com.apple.disk-image-udif" as CFString,
        "public.disk-image" as CFString
    ]
    // Finder may consult the all-roles handler for double-click opens.
    private static let handlerRoles: [LSRolesMask] = [.viewer, .all]

    static func isDefaultDMGHandler() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        for uti in dmgUTIs {
            for role in handlerRoles {
                guard let handler = LSCopyDefaultRoleHandlerForContentType(uti, role)?.takeRetainedValue() as String? else {
                    return false
                }
                if handler.caseInsensitiveCompare(bundleID) != .orderedSame {
                    return false
                }
            }
        }
        return true
    }

    static func setAsDefaultDMGHandler() {
        guard let bundleID = Bundle.main.bundleIdentifier as CFString? else { return }
        for uti in dmgUTIs {
            for role in handlerRoles {
                LSSetDefaultRoleHandlerForContentType(uti, role, bundleID)
            }
        }
    }
}

// MARK: - About Tab

struct AboutTabView: View {
    let theme: SettingsTheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 11) {
                Text("Installing simple Mac apps should be one click!")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.text)
                    .lineSpacing(3)

                Text("The standard DMG workflow is clunky and annoying: mount the DMG, drag the app to Applications, go find it in Applications, eject the disk, and then send the DMG to the trash (or forgetting the last two steps, and having a GB of old DMGs in your downloads folder 🫠).")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.muted)
                    .lineSpacing(3)

                Text("EasyDMG is a simple, tiny utility that handles all of those steps automatically: mount, install, tidy up, done! The app doesn't need to be running - no dock icon, no menu bar icon, it just opens when needed and closes when finished.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.muted)
                    .lineSpacing(3)

                Text("If a DMG contains something unusual, like a license agreement, a .pkg installer, or a non-standard setup, EasyDMG won't guess. It simply opens the image and lets you take it from there.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.muted)
                    .lineSpacing(3)

                HStack(spacing: 8) {
                    Button("GitHub ↗") {
                        NSWorkspace.shared.open(URL(string: "https://github.com/jeff-schumann/EasyDMG")!)
                    }
                    .buttonStyle(AmberOutlineButtonStyle(theme: theme))

                    Button("Report Issue ↗") {
                        NSWorkspace.shared.open(URL(string: "https://github.com/jeff-schumann/EasyDMG/issues")!)
                    }
                    .buttonStyle(AmberOutlineButtonStyle(theme: theme))
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }
}

// MARK: - Settings Tab

struct SettingsTabView: View {
    @ObservedObject var preferences: UserPreferences
    let theme: SettingsTheme
    @StateObject private var notificationPermissions = NotificationPermissionViewModel()
    @EnvironmentObject private var viewModel: CheckForUpdatesViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Installation Preferences
                VStack(alignment: .leading, spacing: 14) {
                    Text("Installation Preferences")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(theme.text)

                    Toggle("Move DMG to trash after installation", isOn: $preferences.autoTrashDMG)
                        .toggleStyle(SettingsCheckboxStyle(theme: theme))

                    Toggle("Reveal app in Finder after installation", isOn: $preferences.revealInFinder)
                        .toggleStyle(SettingsCheckboxStyle(theme: theme))

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Installation feedback:")
                            .font(.system(size: 11.5))
                            .foregroundStyle(theme.muted)

                        InlineSegmentedPicker(
                            selection: $preferences.feedbackMode,
                            options: Array(FeedbackMode.allCases),
                            label: { $0.shortName },
                            theme: theme
                        )

                        if preferences.feedbackMode == .notification,
                           notificationPermissions.state.shouldShowFeedbackWarning {
                            NotificationFeedbackNotice(
                                state: notificationPermissions.state,
                                theme: theme,
                                action: notificationPermissions.performPrimaryAction
                            )
                        }
                    }
                    .padding(.top, 4)
                }

                Rectangle()
                    .fill(theme.border)
                    .frame(height: 1)

                // Notifications
                NotificationSettingsSection(
                    state: notificationPermissions.state,
                    isRequesting: notificationPermissions.isRequesting,
                    theme: theme,
                    action: notificationPermissions.performPrimaryAction
                )

                Rectangle()
                    .fill(theme.border)
                    .frame(height: 1)

                // Updates
                VStack(alignment: .leading, spacing: 14) {
                    Text("Updates")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(theme.text)

                    Toggle("Automatically check for updates", isOn: Binding(
                        get: { viewModel.automaticallyChecksForUpdates },
                        set: { viewModel.setAutomaticallyChecks($0) }
                    ))
                    .toggleStyle(SettingsCheckboxStyle(theme: theme))

                    Button("Check for Updates…") {
                        viewModel.checkForUpdates()
                    }
                    .buttonStyle(NeutralOutlineButtonStyle(theme: theme))
                    .disabled(!viewModel.canCheckForUpdates)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
        }
        .onAppear {
            notificationPermissions.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            notificationPermissions.refresh()
        }
        .onChange(of: preferences.feedbackMode) { mode in
            if mode == .notification {
                notificationPermissions.prepareForNotificationFeedback()
            }
        }
    }
}

private struct NotificationSettingsSection: View {
    let state: NotificationPermissionState
    let isRequesting: Bool
    let theme: SettingsTheme
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Notifications")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(theme.text)

                NotificationStatusBadge(state: state, theme: theme)

                Spacer()
            }

            Text(state.settingsDescription)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.muted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            NotificationPermissionActionButton(
                title: isRequesting ? "Requesting…" : state.primaryActionTitle,
                isPrimary: state.usesPrimaryAction,
                isDisabled: state == .loading || isRequesting,
                theme: theme,
                action: action
            )
        }
    }
}

private struct NotificationPermissionActionButton: View {
    let title: String
    let isPrimary: Bool
    let isDisabled: Bool
    let theme: SettingsTheme
    let action: () -> Void

    var body: some View {
        if isPrimary {
            Button(title) {
                action()
            }
            .buttonStyle(AmberFilledButtonStyle())
            .disabled(isDisabled)
            .fixedSize()
        } else {
            Button(title) {
                action()
            }
            .buttonStyle(NeutralOutlineButtonStyle(theme: theme))
            .disabled(isDisabled)
            .fixedSize()
        }
    }
}

private struct NotificationStatusBadge: View {
    let state: NotificationPermissionState
    let theme: SettingsTheme

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 6, height: 6)

            Text(state.badgeText)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(theme.text)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(theme.border, lineWidth: 1)
        )
        .fixedSize()
    }

    private var indicatorColor: Color {
        switch state {
        case .on:
            return theme.successGreen
        case .limited, .notDetermined:
            return SettingsPalette.gold
        case .off:
            return Color(hex: "C34834")
        case .loading:
            return theme.muted
        }
    }
}

private struct NotificationFeedbackNotice: View {
    let state: NotificationPermissionState
    let theme: SettingsTheme
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SettingsPalette.gold)
                .padding(.top, 1)

            Text(state.feedbackWarningText)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.muted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            if state != .loading {
                Button(state.warningActionTitle) {
                    action()
                }
                .buttonStyle(NeutralOutlineButtonStyle(theme: theme))
            }
        }
        .padding(10)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(theme.border, lineWidth: 1)
        )
    }
}

private extension NotificationPermissionState {
    var badgeText: String {
        switch self {
        case .loading:       return "Checking"
        case .notDetermined: return "Not Set"
        case .on:            return "On"
        case .limited:       return "Limited"
        case .off:           return "Off"
        }
    }

    var settingsDescription: String {
        switch self {
        case .loading:
            return "EasyDMG is checking macOS notification settings."
        case .notDetermined, .on, .limited, .off:
            return "EasyDMG uses notifications for failed install details, and for installation complete messages when notification feedback is selected above."
        }
    }

    var primaryActionTitle: String {
        switch self {
        case .loading:       return "Checking…"
        case .notDetermined: return "Turn On Notifications…"
        case .on, .limited:  return "Notification Settings…"
        case .off:           return "Open Notification Settings…"
        }
    }

    var warningActionTitle: String {
        switch self {
        case .notDetermined: return "Turn On…"
        default:             return "Open Settings…"
        }
    }

    var feedbackWarningText: String {
        switch self {
        case .notDetermined:
            return "EasyDMG needs notification permission before this feedback mode can show completion alerts."
        case .limited:
            return "Notification banners are disabled, so EasyDMG will show the progress bar until banners are enabled."
        case .off:
            return "Notifications are off, so EasyDMG will show the progress bar until they are turned on."
        case .loading:
            return "EasyDMG is checking whether notification feedback is available."
        case .on:
            return ""
        }
    }

    var shouldShowFeedbackWarning: Bool {
        !canUseNotificationFeedback
    }

    var usesPrimaryAction: Bool {
        self == .notDetermined || self == .off
    }
}

// MARK: - Feedback Mode

enum FeedbackMode: String, CaseIterable, Identifiable, Hashable {
    case progressBar  = "progressBar"
    case notification = "notification"
    case silent       = "silent"

    var id: String { rawValue }

    var shortName: String {
        switch self {
        case .progressBar:  return "Progress bar"
        case .notification: return "Notification"
        case .silent:       return "Silent"
        }
    }
}

// MARK: - User Preferences

class UserPreferences: ObservableObject {
    static let shared = UserPreferences()

    @Published var autoTrashDMG: Bool {
        didSet { UserDefaults.standard.set(autoTrashDMG, forKey: "autoTrashDMG") }
    }

    @Published var revealInFinder: Bool {
        didSet { UserDefaults.standard.set(revealInFinder, forKey: "revealInFinder") }
    }

    @Published var feedbackMode: FeedbackMode {
        didSet { UserDefaults.standard.set(feedbackMode.rawValue, forKey: "feedbackMode") }
    }

    private init() {
        self.autoTrashDMG = UserDefaults.standard.object(forKey: "autoTrashDMG") as? Bool ?? true
        self.revealInFinder = UserDefaults.standard.object(forKey: "revealInFinder") as? Bool ?? true

        let savedMode = UserDefaults.standard.string(forKey: "feedbackMode") ?? FeedbackMode.progressBar.rawValue
        self.feedbackMode = FeedbackMode(rawValue: savedMode) ?? .progressBar
    }
}

// MARK: - Sparkle Updates View Model

final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false
    @Published var automaticallyChecksForUpdates = true

    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater

        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)

        updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$automaticallyChecksForUpdates)
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }

    func setAutomaticallyChecks(_ value: Bool) {
        updater.automaticallyChecksForUpdates = value
    }
}

// MARK: - Bundle Extension

extension Bundle {
    var appVersion: String {
        return infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}
