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
        .frame(width: 550, height: 500)
        .background(theme.background)
        .onAppear {
            NSApp.keyWindow?.titleVisibility = .hidden
        }
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
                    .foregroundStyle(colorScheme == .dark ? Color(hex: "F5E6C8") : Color(hex: "231A12"))
                    .tracking(-0.5)
                Text("v\(Bundle.main.appVersion)")
                    .font(.system(size: 12))
                    .foregroundStyle(colorScheme == .dark ? Color(hex: "D4B896") : Color(hex: "7D6A58"))
            }
            Spacer()
        }
        .padding(.vertical, 14)
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

                Rectangle()
                    .fill(theme.border)
                    .frame(height: 1)

                // Manual setup steps
                VStack(alignment: .leading, spacing: 14) {
                    Text("Manual Setup")
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

                Rectangle()
                    .fill(theme.border)
                    .frame(height: 1)

                // Open With section
                VStack(alignment: .leading, spacing: 14) {
                    Text("Open with EasyDMG Without Setting as Default")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(theme.text)

                    Text("Right click any DMG and select 'Open With' to have EasyDMG seamlessly handle installation and cleanup.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.muted)
                        .lineSpacing(2)
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

    static func isDefaultDMGHandler() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        for uti in dmgUTIs {
            guard let handler = LSCopyDefaultRoleHandlerForContentType(uti, .viewer)?.takeRetainedValue() as String? else {
                return false
            }
            if handler.caseInsensitiveCompare(bundleID) != .orderedSame {
                return false
            }
        }
        return true
    }

    static func setAsDefaultDMGHandler() {
        guard let bundleID = Bundle.main.bundleIdentifier as CFString? else { return }
        for uti in dmgUTIs {
            LSSetDefaultRoleHandlerForContentType(uti, .viewer, bundleID)
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
                        NSWorkspace.shared.open(URL(string: "https://github.com/jefe-johann/EasyDMG")!)
                    }
                    .buttonStyle(AmberOutlineButtonStyle(theme: theme))

                    Button("Report Issue ↗") {
                        NSWorkspace.shared.open(URL(string: "https://github.com/jefe-johann/EasyDMG/issues")!)
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
                        .toggleStyle(.checkbox)

                    Toggle("Reveal app in Finder after installation", isOn: $preferences.revealInFinder)
                        .toggleStyle(.checkbox)

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
                    }
                    .padding(.top, 4)
                }

                Rectangle()
                    .fill(theme.border)
                    .frame(height: 1)

                // Updates
                VStack(alignment: .leading, spacing: 14) {
                    Text("Updates")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(theme.text)

                    Button("Check for Updates…") {
                        viewModel.checkForUpdates()
                    }
                    .buttonStyle(NeutralOutlineButtonStyle(theme: theme))
                    .disabled(!viewModel.canCheckForUpdates)

                    Toggle("Automatically check for updates", isOn: Binding(
                        get: { viewModel.automaticallyChecksForUpdates },
                        set: { viewModel.setAutomaticallyChecks($0) }
                    ))
                    .toggleStyle(.checkbox)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
        }
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
