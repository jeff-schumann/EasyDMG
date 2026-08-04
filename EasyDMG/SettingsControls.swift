//
//  SettingsControls.swift
//  EasyDMG
//
//  Reusable UI controls for the settings window.
//

import SwiftUI

// MARK: - iOS-style Pill Toggle

struct PillToggleStyle: ToggleStyle {
    let accent: Color
    let inactiveTrack: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 9.5)
                .fill(configuration.isOn ? accent : inactiveTrack)
                .frame(width: 34, height: 19)
                .overlay(
                    Circle()
                        .fill(.white)
                        .frame(width: 15, height: 15)
                        .shadow(color: .black.opacity(0.25), radius: 1.5, x: 0, y: 1)
                        .offset(x: configuration.isOn ? 7.5 : -7.5)
                        .animation(.easeInOut(duration: 0.18), value: configuration.isOn)
                )
            configuration.label
        }
        .contentShape(Rectangle())
        .onTapGesture { configuration.isOn.toggle() }
    }
}

// MARK: - Themed Checkbox

struct SettingsCheckboxStyle: ToggleStyle {
    let theme: SettingsTheme

    func makeBody(configuration: Configuration) -> some View {
        SettingsCheckboxBody(configuration: configuration, theme: theme)
    }
}

private struct SettingsCheckboxBody: View {
    let configuration: ToggleStyleConfiguration
    let theme: SettingsTheme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let onFill: Color = colorScheme == .dark ? SettingsPalette.sand : SettingsPalette.navy
        let onCheck: Color = colorScheme == .dark ? Color(hex: "1A110A") : .white

        return HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 3.5)
                    .fill(configuration.isOn ? onFill : Color.clear)
                    .frame(width: 14, height: 14)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3.5)
                            .strokeBorder(configuration.isOn ? Color.clear : theme.muted.opacity(0.7), lineWidth: 1)
                    )
                if configuration.isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(onCheck)
                }
            }
            configuration.label
                .foregroundStyle(theme.text)
        }
        .contentShape(Rectangle())
        .onTapGesture { configuration.isOn.toggle() }
    }
}

// MARK: - Navigation Tab Bar

struct SettingsTabBar: View {
    @Binding var selection: SettingsTab
    let theme: SettingsTheme

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.14)) { selection = tab }
                    }) {
                        ZStack {
                            ForEach(SettingsTab.allCases, id: \.self) { sizing in
                                Text(sizing.rawValue).hidden()
                            }
                            Text(tab.rawValue)
                        }
                        .modifier(NavSegmentStyle(isSelected: selection == tab, muted: theme.muted))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(theme.tabTrack, in: RoundedRectangle(cornerRadius: 8))
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
        .padding(.bottom, 8)
        .padding(.horizontal, 16)
        .background(theme.tabBarBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.border)
                .frame(height: 1)
        }
    }
}

private struct NavSegmentStyle: ViewModifier {
    let isSelected: Bool
    let muted: Color
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let darkActiveFill = Color(hex: "1F140E")
        let darkOutline = SettingsPalette.sand.opacity(0.55)
        let fill: Color = isSelected
            ? (colorScheme == .dark ? darkActiveFill : .white)
            : .clear
        let stroke: Color = isSelected
            ? (colorScheme == .dark ? darkOutline : SettingsPalette.navy)
            : .clear

        return content
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(isSelected ? (colorScheme == .dark ? Color.white : SettingsPalette.navy) : muted)
            .padding(.vertical, 4)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(stroke, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .animation(.easeInOut(duration: 0.14), value: isSelected)
    }
}

// MARK: - Inline Segmented Picker (outline style)

struct InlineSegmentedPicker<V: Hashable>: View {
    @Binding var selection: V
    let options: [V]
    let label: (V) -> String
    let theme: SettingsTheme

    var body: some View {
        HStack(spacing: 5) {
            ForEach(options, id: \.self) { option in
                let isSelected = selection == option
                Button(action: { selection = option }) {
                    ZStack {
                        ForEach(options, id: \.self) { sizing in
                            Text(label(sizing)).hidden()
                        }
                        Text(label(option))
                    }
                }
                .buttonStyle(OutlinedSegmentStyle(isSelected: isSelected, theme: theme))
            }
        }
    }
}

private struct OutlinedSegmentStyle: ButtonStyle {
    let isSelected: Bool
    let theme: SettingsTheme

    func makeBody(configuration: Configuration) -> some View {
        OutlinedSegmentContent(configuration: configuration, isSelected: isSelected, theme: theme)
    }
}

private struct OutlinedSegmentContent: View {
    let configuration: ButtonStyle.Configuration
    let isSelected: Bool
    let theme: SettingsTheme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // These pickers set a value; the tab bar navigates. Deliberately kept
        // lighter than SettingsTabBar so the two don't read as the same tier —
        // a tinted selection rather than a solid one, in the same colour family
        // as the checkboxes they sit beside (navy in light, sand in dark).
        let accent: Color = colorScheme == .dark ? SettingsPalette.sand : SettingsPalette.navy

        let fill: Color = isSelected ? accent.opacity(colorScheme == .dark ? 0.14 : 0.10) : .clear
        let stroke: Color = isSelected
            ? accent.opacity(colorScheme == .dark ? 0.5 : 1.0)
            : theme.border

        return configuration.label
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(isSelected ? accent : theme.muted)
            .padding(.vertical, 3)
            .padding(.horizontal, 10)
            .background(fill, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(stroke, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

// MARK: - Amber Filled Button (Set as Default CTA)

struct AmberFilledButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AmberFilledButtonContent(configuration: configuration)
    }
}

private struct AmberFilledButtonContent: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let fill: Color = colorScheme == .dark ? SettingsPalette.sand : SettingsPalette.navy
        let label: Color = colorScheme == .dark ? Color(hex: "1A110A") : Color.white

        return configuration.label
            .font(.system(size: 12.5, weight: .bold))
            .foregroundStyle(label)
            .padding(.vertical, 6)
            .padding(.horizontal, 14)
            .background(fill, in: RoundedRectangle(cornerRadius: 7))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

// MARK: - Muted Outline Button (GitHub, Report Issue)

struct AmberOutlineButtonStyle: ButtonStyle {
    let theme: SettingsTheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(theme.accentOutline)
            .padding(.vertical, 5)
            .padding(.horizontal, 12)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(theme.accentOutline, lineWidth: 1.5)
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

// MARK: - Neutral Outline Button (Check for Updates)

struct NeutralOutlineButtonStyle: ButtonStyle {
    /// `standard` for section-level actions. `compact` for a sub-action attached
    /// to another control, which shouldn't outweigh the control it modifies.
    enum Size {
        case standard
        case compact
    }

    let theme: SettingsTheme
    var size: Size = .standard

    func makeBody(configuration: Configuration) -> some View {
        // Scaled to sit alongside InlineSegmentedPicker without overpowering it,
        // one notch up since these are actions rather than values. The surface
        // fill is what separates the two: picker segments are outline-only, so
        // an unfilled button here would read as another segment.
        let isCompact = size == .compact
        let radius: CGFloat = isCompact ? 5 : 6

        return configuration.label
            .font(.system(size: isCompact ? 11 : 11.5, weight: isCompact ? .regular : .medium))
            .foregroundStyle(theme.text)
            .padding(.vertical, isCompact ? 2 : 4)
            .padding(.horizontal, isCompact ? 8 : 11)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(theme.border, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

// MARK: - Numbered Step Bubble

struct StepBubble: View {
    let number: Int
    let text: String
    let textColor: Color
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let fill: Color = colorScheme == .dark ? SettingsPalette.sand : SettingsPalette.navy
        let numberColor: Color = colorScheme == .dark ? Color(hex: "1A110A") : Color.white

        return HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(fill)
                    .frame(width: 22, height: 22)
                Text("\(number)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(numberColor)
            }
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(textColor)
        }
    }
}
