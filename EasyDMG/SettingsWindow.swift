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
import Darwin
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
            window.identifier = .easyDMGSettingsWindow
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
    @AppStorage("lastSettingsTab") private var selectedTab: SettingsTab = .setup
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
               minHeight: 500, idealHeight: 600, maxHeight: .infinity)
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
                .interpolation(.high)
                .antialiased(true)
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                            .interpolation(.high)
                            .antialiased(true)
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

/// Placement of the tree fiddy easter egg. Horizontally he hangs off the right
/// edge of the window; vertically he tracks the support button, so he arrives
/// in the same spot beside it whatever height the user has dragged the window
/// to. Tune `width` first — the rest follow from it.
private enum NessieMetrics {
    /// Rendered width of the artwork (bubble through tail tip).
    static let width: CGFloat = 210
    /// How far his tail pokes past the window edge when he's out.
    static let restingX: CGFloat = 16
    /// Far enough right that even the spring's overshoot stays out of sight.
    static var hiddenX: CGFloat { width + 30 }
    /// How far the top of the speech bubble clears the top of the button. The
    /// trimmed artwork starts at the bubble, so this is measured off its top edge.
    static let bubbleLift: CGFloat = 15
}

/// Reports where the support button has landed so the easter egg can line up
/// with it, rather than with the bottom of a window the user can resize.
private struct SupportButtonTopKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct AboutTabView: View {
    let theme: SettingsTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingNessie = false
    @State private var supportButtonTop: CGFloat = 0

    private static let coordinateSpace = "aboutTabContent"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 11) {
                Text("Installing simple Mac apps should be one click!")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.text)
                    .lineSpacing(3)

                Text("The standard DMG workflow is clunky and annoying: mount the DMG, drag the app to Applications, go find it in Applications, eject the disk, and then send the DMG to the trash - or forgetting the last two steps, and having a GB of old DMGs in your downloads folder 🫠.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.muted)
                    .lineSpacing(3)

                Text("EasyDMG is a simple, tiny utility that handles all of those steps from a double-click: mount, install, tidy up, done! The app doesn't need to be running - no dock icon, no menu bar icon, it just opens when needed and closes when finished.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.muted)
                    .lineSpacing(3)

                Text("If a DMG contains something unusual, like a license agreement, a .pkg installer, or a non-standard setup, EasyDMG won't guess. It simply opens the image and lets you take it from there.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.muted)
                    .lineSpacing(3)

                HStack(spacing: 8) {
                    Button("Star on GitHub ↗") {
                        NSWorkspace.shared.open(URL(string: "https://github.com/jeff-schumann/EasyDMG")!)
                    }
                    .buttonStyle(AmberOutlineButtonStyle(theme: theme))

                    Button("Support Development :)") {
                        NSWorkspace.shared.open(URL(string: "https://buymeacoffee.com/jeff.schumann")!)
                    }
                    .buttonStyle(AmberOutlineButtonStyle(theme: theme))
                    .onHover { isShowingNessie = $0 }
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: SupportButtonTopKey.self,
                                value: geo.frame(in: .named(Self.coordinateSpace)).minY
                            )
                        }
                    )
                }
                .padding(.top, 4)

                // Logs section
                Rectangle()
                    .fill(theme.border)
                    .frame(height: 1)
                    .padding(.top, 6)

                Text("Logs")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(theme.text)

                Text("EasyDMG keeps a local log of what it does each time it runs. Open it to see what happened, or include it when reporting an issue on GitHub.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.muted)
                    .lineSpacing(3)

                HStack(spacing: 8) {
                    Button("Show Logs") {
                        showLogs()
                    }
                    .buttonStyle(AmberOutlineButtonStyle(theme: theme))

                    Button("Report Issue ↗") {
                        NSWorkspace.shared.open(URL(string: "https://github.com/jeff-schumann/EasyDMG/issues")!)
                    }
                    .buttonStyle(AmberOutlineButtonStyle(theme: theme))
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .coordinateSpace(name: Self.coordinateSpace)
        .onPreferenceChange(SupportButtonTopKey.self) { supportButtonTop = $0 }
        .overlay(alignment: .topTrailing) { nessie }
        // Keeps him genuinely invisible while parked past the window edge.
        .clipped()
    }

    /// Easter egg: hovering the support button slides the tree fiddy monster in
    /// from beyond the right edge of the window. Purely decorative, so he never
    /// takes the mouse — otherwise he'd steal the hover that summoned him and
    /// flicker in and out.
    private var nessie: some View {
        Image("tree-fiddy")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: NessieMetrics.width)
            // Vertical placement follows the button and so is never animated —
            // only the horizontal slide is.
            .offset(x: nessieOffsetX, y: supportButtonTop - NessieMetrics.bubbleLift)
            .opacity(reduceMotion && !isShowingNessie ? 0 : 1)
            .animation(nessieAnimation, value: isShowingNessie)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var nessieOffsetX: CGFloat {
        // Reduce Motion swaps the slide for a fade, so he stays put and appears.
        if reduceMotion { return NessieMetrics.restingX }
        return isShowingNessie ? NessieMetrics.restingX : NessieMetrics.hiddenX
    }

    private var nessieAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.2)
            : .spring(response: 0.34, dampingFraction: 0.78)
    }

    private func showLogs() {
        guard let path = DiagnosticLogger.shared.logFilePath else { return }
        let url = URL(fileURLWithPath: path)

        // Open the log in the user's default text viewer. If it doesn't exist yet
        // (no session has written to it), reveal the logs folder as a fallback.
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
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

                    Toggle("Move DMG to trash after successful installation", isOn: $preferences.autoTrashDMG)
                        .toggleStyle(SettingsCheckboxStyle(theme: theme))

                    Toggle("Reveal app in Finder after installation", isOn: $preferences.revealInFinder)
                        .toggleStyle(SettingsCheckboxStyle(theme: theme))

                    Toggle("Open app after installation", isOn: $preferences.openAppAfterInstall)
                        .toggleStyle(SettingsCheckboxStyle(theme: theme))

                    HStack(spacing: 6) {
                        Toggle("Do not warn me about apps from unidentified developers", isOn: $preferences.skipUnverifiedAppWarning)
                            .toggleStyle(SettingsCheckboxStyle(theme: theme))
                            .onChange(of: preferences.skipUnverifiedAppWarning) { newValue in
                                if newValue {
                                    preferences.unverifiedWarningDismissed = false
                                }
                            }

                        if preferences.skipUnverifiedAppWarning && preferences.unverifiedWarningDismissed {
                            Button {
                                withAnimation(.easeOut(duration: 0.35)) {
                                    preferences.unverifiedWarningDismissed = false
                                }
                            } label: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(SettingsPalette.warningText)
                                    .offset(y: 1)
                            }
                            .buttonStyle(.plain)
                            .help("Show the unidentified developer warning")
                            .transition(.opacity)
                        }
                    }

                    if preferences.skipUnverifiedAppWarning && !preferences.unverifiedWarningDismissed {
                        // The symbol sits in its own column so wrapped lines indent
                        // past it instead of running back under the icon.
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(SettingsPalette.warningText)
                                .padding(.top, 2)

                            Text("EasyDMG will install apps even when macOS can't verify them. Only turn this on if you trust the apps you download. Click this message to hide.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(SettingsPalette.warningText)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.35)) {
                                preferences.unverifiedWarningDismissed = true
                            }
                        }
                        .transition(.opacity)
                    }

                    if preferences.autoInstallNewerVersions {
                        Toggle("Always install newer versions without asking", isOn: $preferences.autoInstallNewerVersions)
                            .toggleStyle(SettingsCheckboxStyle(theme: theme))
                    }

                    // The two pickers are a quieter subsection of the checkbox list
                    // above: a rule fences them off, and the labels below carry the
                    // separation between them.
                    Rectangle()
                        .fill(theme.border)
                        .frame(height: 1)
                        .padding(.top, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        SettingGroupLabel(title: "Installation feedback", theme: theme)

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

                    InstallLocationSection(preferences: preferences, theme: theme)
                        .padding(.top, 6)
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

/// Heading for a picker-backed setting. Sits at full strength so these labels —
/// not the readouts beneath them — are what separates one setting from the next.
private struct SettingGroupLabel: View {
    let title: String
    let theme: SettingsTheme

    var body: some View {
        Text(title)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(theme.text)
    }
}

private struct InstallLocationSection: View {
    private enum Warning {
        case couldNotCreateFolder
        case notWritable
        case incompatibleDriveFormat

        var message: String {
            switch self {
            case .couldNotCreateFolder:
                return "EasyDMG couldn't create this folder, so installs will fail. Your disk may be full, or your home folder may not allow changes."
            case .notWritable:
                return "This folder isn't writable by your account, so installs will fail. That usually means the account isn't an administrator."
            case .incompatibleDriveFormat:
                return "This drive's format can't reliably store Mac apps. Some apps may fail to install or open. Choose a folder on an APFS or Mac OS Extended drive."
            }
        }

        var offersPersonalFolder: Bool {
            self != .incompatibleDriveFormat
        }
    }

    @ObservedObject var preferences: UserPreferences
    let theme: SettingsTheme

    /// Bumped when the window reactivates so writability is re-checked after the
    /// user changes folder permissions or gains admin rights outside the app.
    @State private var refreshToken = 0

    @State private var isHoveringPath = false

    /// Set when creating the Personal folder fails. `isWritable` treats that folder's
    /// absence as normal — it is made on demand — so nothing else would report it.
    @State private var couldNotCreateFolder = false

    private var directory: URL { preferences.installDirectory }

    private var isWritable: Bool {
        _ = refreshToken
        return InstallLocation.isWritable(directory)
    }

    /// The warning to show in place of the description, if there is one. A failed
    /// creation wins: it is the more specific answer, and it is what the user just
    /// asked for by clicking the path.
    private var warning: Warning? {
        if couldNotCreateFolder {
            return .couldNotCreateFolder
        }

        if !isWritable {
            return .notWritable
        }

        if preferences.installLocation == .custom,
           InstallLocation.hasIncompatibleMacAppFileSystem(directory) {
            return .incompatibleDriveFormat
        }

        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingGroupLabel(title: "Install location", theme: theme)

            InlineSegmentedPicker(
                selection: Binding(
                    get: { preferences.installLocation },
                    set: { selectLocation($0) }
                ),
                options: Array(InstallLocation.allCases),
                label: { $0.shortName },
                theme: theme
            )

            HStack(spacing: 6) {
                // The readout doubles as the way to go look at the folder. A button
                // here would have to sit beside "Choose…" and look like its twin
                // while doing something else entirely, so the affordance rides on
                // the thing that already stands for the location.
                Button {
                    showInFinder()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.system(size: 11))

                        // Full path rather than the ~ shorthand: the point of this readout is
                        // that someone can go find their installed apps, and Finder never
                        // shows a tilde — it shows the account name.
                        Text(directory.path)
                            .font(.system(size: 11.5, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .underline(isHoveringPath)
                    }
                    .foregroundStyle(isHoveringPath ? theme.text : theme.subtle)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show \(directory.path) in Finder")
                .onHover { hovering in
                    isHoveringPath = hovering
                    // `set` rather than `push`/`pop`: a missed exit event would
                    // otherwise leave the pointing hand stuck for the session.
                    (hovering ? NSCursor.pointingHand : NSCursor.arrow).set()
                }

                if preferences.installLocation == .custom {
                    Button("Choose…") { chooseCustomFolder() }
                        .buttonStyle(NeutralOutlineButtonStyle(theme: theme, size: .compact))
                        .padding(.leading, 6)
                }
            }
            .padding(.top, 1)

            // The neutral description gives way to the warning: someone who has just
            // been told this destination is unreliable has no use for "apps go in a
            // folder you pick", and dropping it keeps this group to three blocks.
            if let warning {
                // A bordered callout rather than one more paragraph: the box stops
                // an important destination problem blending into the text above it.
                // The path stays out of the sentence — it is on the row directly
                // above, and repeating it twice in 40pt was most of the bulk.
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SettingsPalette.warningText)
                        .padding(.top, 1)

                    Text(warning.message)
                        .font(.system(size: 11.5))
                        .foregroundStyle(SettingsPalette.warningText)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)

                    if warning.offersPersonalFolder,
                       preferences.installLocation != .userApplications {
                        Button("Switch to Personal") {
                            selectLocation(.userApplications)
                        }
                        .buttonStyle(NeutralOutlineButtonStyle(theme: theme, tone: .accent))
                    }
                }
                .padding(10)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(theme.border, lineWidth: 1)
                )
                .transition(.opacity)
            } else {
                Text(preferences.installLocation.explanation)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
                    .lineSpacing(2)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshToken += 1

            // Someone who went and made the folder by hand shouldn't come back to a
            // warning about it.
            if FileManager.default.fileExists(atPath: directory.path) {
                couldNotCreateFolder = false
            }
        }
    }

    private func selectLocation(_ location: InstallLocation) {
        // Picking "Custom" is meaningless without a folder, so ask for one right away.
        if location == .custom && preferences.customInstallPath.isEmpty {
            chooseCustomFolder()
            return
        }

        // The warning belongs to the folder that failed, not to whatever is picked next.
        couldNotCreateFolder = false
        preferences.installLocation = location
        refreshToken += 1
    }

    /// Opens the install folder so someone can see for themselves where apps land.
    private func showInFinder() {
        if !FileManager.default.fileExists(atPath: directory.path) {
            // Personal is the one folder EasyDMG makes itself, so it can be honest
            // about the path it just displayed. Opening anywhere else — the home
            // folder, say — drops the user somewhere that visibly lacks the folder
            // the readout names, which reads as the app being wrong about its own
            // setting. Everywhere else, a missing folder already raises the warning
            // below this readout, so there is nothing useful to open.
            guard directory == preferences.userApplicationsDirectory else { return }

            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                // The warning below the readout carries this rather than an alert:
                // the user asked to look at a folder, not to start an install.
                DiagnosticLogger.shared.diagnostic("Failed to create install folder \(directory.path): \(error)")
                couldNotCreateFolder = true
                return
            }
        }

        couldNotCreateFolder = false
        NSWorkspace.shared.open(directory)
    }

    private func chooseCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder where EasyDMG should install apps."
        panel.directoryURL = directory

        guard panel.runModal() == .OK, let url = panel.url else { return }

        preferences.customInstallPath = url.path
        preferences.installLocation = .custom
        refreshToken += 1
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

// MARK: - Install Location

enum InstallLocation: String, CaseIterable, Identifiable, Hashable {
    case system           = "system"
    case userApplications = "userApplications"
    case custom           = "custom"

    static let systemDirectory = URL(fileURLWithPath: "/Applications", isDirectory: true)

    static var userDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
    }

    var id: String { rawValue }

    var shortName: String {
        switch self {
        case .system:           return "Applications"
        case .userApplications: return "Personal"
        case .custom:           return "Custom"
        }
    }

    var explanation: String {
        switch self {
        case .system:
            // Deliberately says nothing about administrator accounts. Most people
            // have the rights already, and raising the requirement here reads as a
            // hurdle. `isWritable` surfaces the warning only when it actually bites.
            return "The usual place for Mac apps. Recommended for most people."
        case .userApplications:
            return "Installs to a personal Applications folder inside your home folder. Useful on work, school, or shared Macs."
        case .custom:
            return "Apps are installed in a folder you pick."
        }
    }

    /// Directory for the built-in locations. `custom` resolves from the stored path instead.
    var fixedDirectory: URL? {
        switch self {
        case .system:           return Self.systemDirectory
        case .userApplications: return Self.userDirectory
        case .custom:           return nil
        }
    }

    /// Whether this account can place a new app in `directory`.
    ///
    /// This is the only signal that reliably predicts an install failure. Admin
    /// group membership and MDM enrollment both mislabel common setups: managed
    /// Macs often grant admin, and plenty of unmanaged Macs have a standard
    /// second account that can't write to /Applications.
    ///
    /// Answers first-install only — replacing an app that is already installed is
    /// gated separately by App Management (TCC), preflighted in DMGProcessor.
    static func isWritable(_ directory: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            // ~/Applications is created on demand at install time, so a missing
            // folder there isn't a problem worth warning about.
            return directory == userDirectory
        }

        return isDirectory.boolValue && FileManager.default.isWritableFile(atPath: directory.path)
    }

    /// Windows-formatted drives can be writable on macOS without reliably
    /// preserving everything inside a Mac app bundle. Only warn for formats we
    /// know are unsuitable; an unknown filesystem may be unusual but still valid.
    static func hasIncompatibleMacAppFileSystem(_ directory: URL) -> Bool {
        guard let values = try? directory.resourceValues(forKeys: [.volumeIsLocalKey]),
              values.volumeIsLocal == true else {
            return false
        }

        var fileSystem = statfs()
        let result = directory.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return statfs(path, &fileSystem)
        }
        guard result == 0 else { return false }

        let type = withUnsafePointer(to: &fileSystem.f_fstypename) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MFSNAMELEN)) {
                String(cString: $0).lowercased()
            }
        }

        return type == "exfat"
            || type == "msdos"
            || type == "msdosfs"
            || type.contains("ntfs")
    }

    /// The location that will actually work on this Mac. Supplies the first-run default.
    static var recommendedForThisMac: InstallLocation {
        isWritable(systemDirectory) ? .system : .userApplications
    }
}

extension URL {
    /// `/Users/me/Applications` → `~/Applications`, for display in dialogs and Settings.
    var abbreviatedPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

// MARK: - User Preferences

class UserPreferences: ObservableObject {
    static let shared = UserPreferences()

    private static let sparkleHasLaunchedBeforeKey = "SUHasLaunchedBefore"
    private static let lastRunVersionKey = "lastRunVersion"

    @Published var autoTrashDMG: Bool {
        didSet { UserDefaults.standard.set(autoTrashDMG, forKey: "autoTrashDMG") }
    }

    @Published var revealInFinder: Bool {
        didSet { UserDefaults.standard.set(revealInFinder, forKey: "revealInFinder") }
    }

    @Published var openAppAfterInstall: Bool {
        didSet { UserDefaults.standard.set(openAppAfterInstall, forKey: "openAppAfterInstall") }
    }

    @Published var skipUnverifiedAppWarning: Bool {
        didSet { UserDefaults.standard.set(skipUnverifiedAppWarning, forKey: "skipUnverifiedAppWarning") }
    }

    /// Whether the standing warning under `skipUnverifiedAppWarning` has been
    /// dismissed. Persisted so hiding it sticks — a warning that reappears every
    /// launch isn't dismissible, it's just briefly quiet. Reset when the setting
    /// is switched back on, so re-opting into the risk shows the caveat again.
    @Published var unverifiedWarningDismissed: Bool {
        didSet { UserDefaults.standard.set(unverifiedWarningDismissed, forKey: "unverifiedWarningDismissed") }
    }

    @Published var feedbackMode: FeedbackMode {
        didSet { UserDefaults.standard.set(feedbackMode.rawValue, forKey: "feedbackMode") }
    }

    /// When true, skip the Replace prompt when the DMG contains a newer version
    /// than the installed app. Opt-in via the in-dialog suppression checkbox.
    @Published var autoInstallNewerVersions: Bool {
        didSet { UserDefaults.standard.set(autoInstallNewerVersions, forKey: "autoInstallNewerVersions") }
    }

    @Published var installLocation: InstallLocation {
        didSet { UserDefaults.standard.set(installLocation.rawValue, forKey: "installLocation") }
    }

    /// Only meaningful when `installLocation == .custom`.
    @Published var customInstallPath: String {
        didSet { UserDefaults.standard.set(customInstallPath, forKey: "customInstallPath") }
    }

    /// Where installs should land. A `.custom` selection with no usable path falls
    /// back to /Applications so an install never targets an empty path.
    var installDirectory: URL {
        if let fixed = installLocation.fixedDirectory {
            return fixed
        }

        let trimmed = customInstallPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return InstallLocation.systemDirectory }

        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true)
    }

    var userApplicationsDirectory: URL { InstallLocation.userDirectory }

    // MARK: - Startup Migrations

    /// The EasyDMG version recorded on the previous launch, or nil when no launch
    /// has been recorded yet — a genuinely new user, or someone upgrading from a
    /// release older than this marker.
    ///
    /// Only meaningful during `runStartupMigrations`, which reads it before
    /// replacing it with the running version.
    private(set) static var previousRunVersion: String?

    private static var hasRunStartupMigrations = false

    /// One-time work that must happen before anything reads preferences, and
    /// before Sparkle starts — Sparkle marks the launch as soon as its updater runs.
    ///
    /// Records the running version on every launch so later releases can tell an
    /// upgrading user from a new one. Any future default that needs that
    /// distinction should branch on `previousRunVersion`, not on Sparkle's launch
    /// marker: that marker is a single fuse, spent by the install-location
    /// migration below, and reads as "has launched before" for everyone from here on.
    static func runStartupMigrations() {
        guard !hasRunStartupMigrations else { return }
        hasRunStartupMigrations = true

        let defaults = UserDefaults.standard
        previousRunVersion = defaults.string(forKey: lastRunVersionKey)

        _ = prepareInstallLocationDefault(defaults)

        defaults.set(Bundle.main.appVersion, forKey: lastRunVersionKey)
    }

    /// Supplies the install-location preference the first time a build carrying the
    /// setting runs. Older releases always installed into /Applications, while
    /// genuinely new users should start with the location this account can actually
    /// write to.
    ///
    /// Reads Sparkle's marker because this shipped before EasyDMG kept its own, so
    /// `previousRunVersion` is nil for everyone on this release. Safe to retire once
    /// no one can still be updating from a build that predates the setting.
    private static func prepareInstallLocationDefault(_ defaults: UserDefaults) -> InstallLocation {
        if let savedLocation = defaults.string(forKey: "installLocation"),
           let location = InstallLocation(rawValue: savedLocation) {
            return location
        }

        let hasLaunchedBefore = defaults.bool(forKey: sparkleHasLaunchedBeforeKey)
        let resolved: InstallLocation = hasLaunchedBefore ? .system : .recommendedForThisMac
        defaults.set(resolved.rawValue, forKey: "installLocation")
        return resolved
    }

    private init() {
        self.autoTrashDMG = UserDefaults.standard.object(forKey: "autoTrashDMG") as? Bool ?? true
        self.revealInFinder = UserDefaults.standard.object(forKey: "revealInFinder") as? Bool ?? true
        self.openAppAfterInstall = UserDefaults.standard.object(forKey: "openAppAfterInstall") as? Bool ?? false
        self.skipUnverifiedAppWarning = UserDefaults.standard.object(forKey: "skipUnverifiedAppWarning") as? Bool ?? false
        self.unverifiedWarningDismissed = UserDefaults.standard.object(forKey: "unverifiedWarningDismissed") as? Bool ?? false
        self.autoInstallNewerVersions = UserDefaults.standard.object(forKey: "autoInstallNewerVersions") as? Bool ?? false

        let savedMode = UserDefaults.standard.string(forKey: "feedbackMode") ?? FeedbackMode.progressBar.rawValue
        self.feedbackMode = FeedbackMode(rawValue: savedMode) ?? .progressBar

        // Use the same idempotent migration path even if something initializes
        // preferences before the app delegate runs the normal startup migrations.
        self.installLocation = Self.prepareInstallLocationDefault(UserDefaults.standard)

        self.customInstallPath = UserDefaults.standard.string(forKey: "customInstallPath") ?? ""
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
