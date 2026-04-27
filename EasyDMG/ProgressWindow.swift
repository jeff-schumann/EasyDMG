//
//  ProgressWindow.swift
//  EasyDMG
//
//  Floating progress window for background processing
//

import SwiftUI
import AppKit
import Combine

// Observable state for progress updates
@MainActor
class ProgressState: ObservableObject {
    @Published var message: String = "Processing..."
    @Published var progress: Double = 0.0
}

@MainActor
class ProgressWindowController: NSWindowController {
    static let shared = ProgressWindowController()
    private let progressState = ProgressState()

    private init() {
        // Create a compact notification-style window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 75),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.title = "EasyDMG"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.isReleasedWhenClosed = false

        super.init(window: window)

        // Set up the SwiftUI content view with observable state
        let contentView = InstallProgressView()
            .environmentObject(progressState)
        window.contentView = NSHostingView(rootView: contentView)

        // Position in top-right corner (notification area)
        positionInTopRight()
    }

    private func positionInTopRight() {
        guard let window = window, let screen = NSScreen.main else { return }

        let screenFrame = screen.visibleFrame
        let windowWidth = window.frame.width
        let windowHeight = window.frame.height

        // Position 20px from right, 50px from top
        let x = screenFrame.maxX - windowWidth - 20
        let y = screenFrame.maxY - windowHeight - 50

        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(message: String, progress: Double = 0.0) {
        guard let window = window else {
            print("❌ Window is nil!")
            return
        }

        // Update the observable state (SwiftUI will automatically update the view)
        progressState.message = message
        progressState.progress = progress

        // Position in top-right corner and show the window
        positionInTopRight()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(message: String, progress: Double) {
        guard window != nil else {
            print("❌ Window is nil!")
            return
        }

        // Update the observable state (SwiftUI will automatically update the view)
        progressState.message = message
        progressState.progress = progress
    }

    func hide() {
        window?.orderOut(nil)
    }
}

// SwiftUI view for the progress window
struct InstallProgressView: View {
    @EnvironmentObject var state: ProgressState

    var body: some View {
        HStack(spacing: 12) {
            // EasyDMG wizard hamster icon
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 48, height: 48)
            } else {
                // Fallback if app icon not found
                Image(systemName: "opticaldiscdrive.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.blue)
            }

            // Text and progress bar
            VStack(alignment: .leading, spacing: 6) {
                Text(state.message)
                    .font(.custom("Quantico-Regular", size: 13))
                    .lineLimit(1)

                // Custom progress bar with manual drawing (SwiftUI's .tint() is unreliable on macOS)
                SwiftUI.ProgressView(value: state.progress, total: 1.0)
                    .progressViewStyle(CustomProgressBarStyle())
                    .frame(height: 6)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(VisualEffectView())
    }
}

// Custom progress bar style with manual drawing (SwiftUI's .tint() is broken on macOS)
struct CustomProgressBarStyle: ProgressViewStyle {
    var fillColor: Color = Color(hex: "B0DA7F")
    var backgroundColor: Color = Color.white.opacity(0.25)
    var height: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background track
                Capsule()
                    .fill(backgroundColor)
                    .frame(height: height)

                // Filled portion
                Capsule()
                    .fill(fillColor)
                    .frame(
                        width: geometry.size.width * CGFloat(configuration.fractionCompleted ?? 0),
                        height: height
                    )
            }
        }
    }
}

// Hex color extension for convenience
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 6: // RGB (24-bit)
            (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (1, 1, 1)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: 1
        )
    }
}

// Native blur effect
struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
