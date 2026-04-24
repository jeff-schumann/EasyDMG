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

struct SettingsView: View {
    @StateObject private var preferences = UserPreferences.shared
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            // Header with app icon and title (always visible)
            HStack(spacing: 12) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 64, height: 64)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("EasyDMG")
                        .font(.system(size: 24, weight: .bold))
                    Text("Version \(Bundle.main.appVersion)")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding(20)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Tabbed content
            TabView(selection: $selectedTab) {
                SetupTabView()
                    .tabItem {
                        Label("Setup", systemImage: "gearshape.2")
                    }
                    .tag(0)

                SettingsTabView(preferences: preferences)
                    .tabItem {
                        Label("Settings", systemImage: "slider.horizontal.3")
                    }
                    .tag(1)

                AboutTabView()
                    .tabItem {
                        Label("About", systemImage: "info.circle")
                    }
                    .tag(2)
            }
            .padding(20)
        }
        .frame(width: 550, height: 450)
    }
}

// MARK: - Setup Tab

struct SetupTabView: View {
    @State private var isDefault = DefaultHandlerHelper.isDefaultDMGHandler()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Quick usage intro
                Text("Right click any DMG and select 'Open With' to have EasyDMG seamlessly handle app installation and cleanup.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 8)

                Divider()

                Text("Set as Default for DMG Files")
                    .font(.headline)

                if isDefault {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 18))
                        Text("EasyDMG is your default app for DMG files.")
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    Text("Make EasyDMG automatically handle DMG files when you double-click them.")
                        .foregroundColor(.secondary)

                    Button(action: {
                        DefaultHandlerHelper.setAsDefaultDMGHandler()
                        isDefault = DefaultHandlerHelper.isDefaultDMGHandler()
                    }) {
                        Label("Set as Default for DMG Files", systemImage: "checkmark.circle")
                    }
                    .controlSize(.large)
                }

                Divider()

                Text("Manual Setup")
                    .font(.headline)

                Text("You can also set the default via Finder:")
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 12) {
                    StepView(number: 1, text: "Right-click any .dmg file")
                    StepView(number: 2, text: "Select \"Get Info\"")
                    StepView(number: 3, text: "Under \"Open with:\" choose EasyDMG")
                    StepView(number: 4, text: "Click \"Change All...\"")
                }
                .padding(.leading, 8)

                // Screenshot
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .bottom])
            .padding(.top, 8)
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

struct StepView: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 24, height: 24)
                Text("\(number)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
            }
            Text(text)
        }
    }
}

// MARK: - About Tab

struct AboutTabView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Installing simple Mac apps should be one click!")
                    .font(.system(size: 14))

                Text("The standard DMG workflow is clunky and annoying: mount the DMG, drag the app to Applications, go find it in Applications, eject the disk, and then send the DMG to the trash (or forgetting the last two steps, and having a GB of old DMGs in your downloads folder 🫠).")
                    .font(.system(size: 14))

                Text("EasyDMG is a simple, tiny utility that handles all of those steps automatically: mount, install, tidy up, done! The app doesn't need to be running - no dock icon, no menu bar icon, it just opens when needed and closes when finished.")
                    .font(.system(size: 14))

                Text("If a DMG contains something unusual, like a license agreement, a .pkg installer, or a non-standard setup, EasyDMG won't guess. It simply opens the image and lets you take it from there.")
                    .font(.system(size: 14))

                HStack(spacing: 16) {
                    Button(action: {
                        NSWorkspace.shared.open(URL(string: "https://github.com/jefe-johann/EasyDMG")!)
                    }) {
                        Label("GitHub", systemImage: "link")
                    }

                    Button(action: {
                        NSWorkspace.shared.open(URL(string: "https://github.com/jefe-johann/EasyDMG/issues")!)
                    }) {
                        Label("Report Issue", systemImage: "exclamationmark.bubble")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .bottom])
            .padding(.top, 8)
        }
    }
}

// MARK: - Settings Tab

struct SettingsTabView: View {
    @ObservedObject var preferences: UserPreferences

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Installation Preferences")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 16) {
                    // Feedback mode picker
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Installation feedback:")
                            .font(.body)

                        Picker("", selection: $preferences.feedbackMode) {
                            ForEach(FeedbackMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 400, alignment: .leading)
                    }

                    Toggle("Automatically move DMG to trash after installation", isOn: $preferences.autoTrashDMG)
                        .toggleStyle(.checkbox)

                    Toggle("Reveal app in Finder after installation", isOn: $preferences.revealInFinder)
                        .toggleStyle(.checkbox)
                }
                .padding(.leading, 8)

                Divider()
                    .padding(.vertical, 8)

                Text("Updates")
                    .font(.headline)

                CheckForUpdatesView()
                    .padding(.leading, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .bottom])
            .padding(.top, 8)
        }
    }
}

// MARK: - Feedback Mode

enum FeedbackMode: String, CaseIterable, Identifiable {
    case progressBar = "progressBar"
    case notification = "notification"
    case silent = "silent"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .progressBar:
            return "Show progress bar during DMG handling"
        case .notification:
            return "Show notification when installation is complete"
        case .silent:
            return "Silent"
        }
    }
}

// MARK: - User Preferences

class UserPreferences: ObservableObject {
    static let shared = UserPreferences()

    @Published var autoTrashDMG: Bool {
        didSet {
            UserDefaults.standard.set(autoTrashDMG, forKey: "autoTrashDMG")
        }
    }

    @Published var revealInFinder: Bool {
        didSet {
            UserDefaults.standard.set(revealInFinder, forKey: "revealInFinder")
        }
    }

    @Published var feedbackMode: FeedbackMode {
        didSet {
            UserDefaults.standard.set(feedbackMode.rawValue, forKey: "feedbackMode")
        }
    }

    private init() {
        self.autoTrashDMG = UserDefaults.standard.object(forKey: "autoTrashDMG") as? Bool ?? true
        self.revealInFinder = UserDefaults.standard.object(forKey: "revealInFinder") as? Bool ?? true

        // Default to progress bar mode
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

        // Observe canCheckForUpdates reactively
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)

        // Observe automaticallyChecksForUpdates reactively
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

struct CheckForUpdatesView: View {
    @EnvironmentObject var viewModel: CheckForUpdatesViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Check for Updates...") {
                    viewModel.checkForUpdates()
                }
                .disabled(!viewModel.canCheckForUpdates)

                Spacer()
            }

            Toggle("Automatically check for updates", isOn: Binding(
                get: { viewModel.automaticallyChecksForUpdates },
                set: { newValue in
                    viewModel.setAutomaticallyChecks(newValue)
                }
            ))
            .toggleStyle(.checkbox)
        }
    }
}

// MARK: - Bundle Extension

extension Bundle {
    var appVersion: String {
        return infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}
