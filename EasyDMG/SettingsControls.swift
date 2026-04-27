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

// MARK: - Navigation Tab Bar

struct SettingsTabBar: View {
    @Binding var selection: SettingsTab
    let theme: SettingsTheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                Button(tab.rawValue) {
                    withAnimation(.easeInOut(duration: 0.14)) { selection = tab }
                }
                .buttonStyle(NavSegmentStyle(isSelected: selection == tab, muted: theme.muted))
                .frame(maxWidth: .infinity)
            }
        }
        .padding(3)
        .background(theme.tabTrack, in: RoundedRectangle(cornerRadius: 8))
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

private struct NavSegmentStyle: ButtonStyle {
    let isSelected: Bool
    let muted: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(isSelected ? Color.white : muted)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? SettingsPalette.navy : Color.clear)
                    .animation(.easeInOut(duration: 0.14), value: isSelected)
            )
            .contentShape(Rectangle())
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
        configuration.label
            .font(.system(size: 11.5, weight: .bold))
            .foregroundStyle(isSelected ? Color.white : theme.muted)
            .padding(.vertical, 4)
            .padding(.horizontal, 11)
            .background(
                isSelected ? SettingsPalette.navy : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.clear : theme.border, lineWidth: 1.5)
            )
            .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

// MARK: - Amber Filled Button (Set as Default CTA)

struct AmberFilledButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .bold))
            .foregroundStyle(Color.white)
            .padding(.vertical, 6)
            .padding(.horizontal, 14)
            .background(SettingsPalette.navy, in: RoundedRectangle(cornerRadius: 7))
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
    let theme: SettingsTheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(theme.text)
            .padding(.vertical, 5)
            .padding(.horizontal, 12)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(theme.border, lineWidth: 1.5)
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

// MARK: - Numbered Step Bubble

struct StepBubble: View {
    let number: Int
    let text: String
    let textColor: Color

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(SettingsPalette.navy)
                    .frame(width: 22, height: 22)
                Text("\(number)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.white)
            }
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(textColor)
        }
    }
}
