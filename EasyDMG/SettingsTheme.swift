//
//  SettingsTheme.swift
//  EasyDMG
//
//  Design tokens and brand palette for the settings window.
//

import SwiftUI
import AppKit

// MARK: - Brand Palette

enum SettingsPalette {
    static let amber        = Color(hex: "D28438")
    static let gold         = Color(hex: "E9A440")
    static let sand         = Color(hex: "F1CB9C")
    static let walnut       = Color(hex: "643E26")
    static let darkAmber    = Color(hex: "B8621A")
    static let navy         = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
        return isDark
            ? NSColor(srgbRed: 0x2D / 255, green: 0x54 / 255, blue: 0x87 / 255, alpha: 1)
            : NSColor(srgbRed: 0x2E / 255, green: 0x43 / 255, blue: 0x62 / 255, alpha: 1)
    })

    // Flat dark surface — paired with a thin gold hairline at the hero's bottom edge
    static let heroGradient = Color(hex: "2B1A0E")
    static let heroHairline = SettingsPalette.sand.opacity(0.45)

    // Magic: gold radial glow from bottom-right over deep navy
    // static let heroGradient = RadialGradient(
    //     gradient: Gradient(stops: [
    //         .init(color: Color(hex: "F1CB9C"), location: 0.0),
    //         .init(color: Color(hex: "8C6E47"), location: 0.35),
    //         .init(color: Color(hex: "1A2238"), location: 1.0)
    //     ]),
    //     center: .bottomTrailing,
    //     startRadius: 0,
    //     endRadius: 340
    // )

    // Subtle all-navy gradient: surface → border
    // static let heroGradient = LinearGradient(
    //     colors: [Color(hex: "22283A"), Color(hex: "333D52")],
    //     startPoint: .topLeading,
    //     endPoint: .bottomTrailing
    // )

    // Navy → gold gradient (matches dark surface + About-tab GitHub button accent)
    // static let heroGradient = LinearGradient(
    //     colors: [Color(hex: "22283A"), Color(hex: "F1CB9C")],
    //     startPoint: .topLeading,
    //     endPoint: .bottomTrailing
    // )

    // Original amber gradient — keep around in case we want to revert
    // static let heroGradient = LinearGradient(
    //     colors: [Color(hex: "643E26"), Color(hex: "B8621A")],
    //     startPoint: .topLeading,
    //     endPoint: .bottomTrailing
    // )
    static let heroBackground = Color(hex: "FDF8EC")
}

// MARK: - Theme Tokens

struct SettingsTheme {
    let background: Color
    let surface: Color
    let border: Color
    let text: Color
    let muted: Color
    let successGreen: Color
    let tabBarBackground: Color
    let tabTrack: Color
    let accentOutline: Color

    static func resolve(for colorScheme: ColorScheme) -> SettingsTheme {
        colorScheme == .dark ? .dark : .light
    }

    static let light = SettingsTheme(
        background:            Color(hex: "FAF7F3"),
        surface:               Color(hex: "F2ECE4"),
        border:                Color(hex: "DDD4C8"),
        text:                  Color(hex: "231A12"),
        muted:                 Color(hex: "7D6A58"),
        successGreen:          Color(hex: "2F7D32"),
        tabBarBackground:      Color(hex: "FDF8EC"),
        tabTrack:              Color.clear,
        accentOutline:         SettingsPalette.navy
    )

    static let dark = SettingsTheme(
        background:            Color(hex: "1a100a"),
        surface:               Color(hex: "251812"),
        border:                Color(hex: "3A271C"),
        text:                  Color(hex: "F2EADD"),
        muted:                 Color(hex: "A89685"),
        successGreen:          Color(hex: "9BCB6A"),
        tabBarBackground:      Color.clear,
        tabTrack:              Color(hex: "1F140E"),
        accentOutline:         SettingsPalette.sand
    )
}

// MARK: - Color + Hex

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 6:
            (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (1, 1, 1)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: 1)
    }
}
