import AppKit
import SwiftUI
import RxCodeCore

// MARK: - ModeSwitchControl

struct ModeSwitchControl: View {
    @Binding var selection: InspectorMode

    var body: some View {
        HStack(spacing: 0) {
            ForEach(InspectorMode.allCases, id: \.self) { mode in
                let isSelected = selection == mode
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { selection = mode }
                } label: {
                    Text(LocalizedStringKey(mode.rawValue))
                        .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .foregroundStyle(isSelected ? ClaudeTheme.textOnAccent : ClaudeTheme.textTertiary)
                        .background(
                            ZStack {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(ClaudeTheme.accent)
                                        .shadow(color: ClaudeTheme.accent.opacity(0.25), radius: 3, x: 0, y: 1)
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(ClaudeTheme.surfaceSecondary.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
    }
}

// MARK: - HeaderPickerLabel

/// Shared chevron-down dropdown label used by both Review and Inspector mode.
struct HeaderPickerLabel: View {
    let icon: String?
    let title: String
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textSecondary)
            }
            Text(LocalizedStringKey(title))
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textPrimary)
            Image(systemName: "chevron.down")
                .font(.system(size: ClaudeTheme.size(9), weight: .bold))
                .foregroundStyle(ClaudeTheme.textTertiary)
                .padding(.leading, 1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            (isHovered ? ClaudeTheme.surfaceSecondary : Color.clear),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(ClaudeTheme.borderSubtle.opacity(isHovered ? 0.6 : 0.0), lineWidth: 0.5)
        )
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}

// MARK: - ReviewTabPicker

struct ReviewTabPicker: View {
    @Binding var selection: InspectorReviewTab

    var body: some View {
        Menu {
            ForEach(InspectorReviewTab.allCases, id: \.self) { tab in
                Button {
                    selection = tab
                } label: {
                    HStack {
                        Text(LocalizedStringKey(tab.rawValue))
                        if selection == tab { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HeaderPickerLabel(icon: nil, title: selection.rawValue)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - InspectorTabPicker

struct InspectorTabPicker: View {
    @Binding var selection: InspectorTab
    var onTabClick: (InspectorTab) -> Void = { _ in }

    var body: some View {
        Menu {
            ForEach(InspectorTab.allCases, id: \.self) { tab in
                Button {
                    selection = tab
                    onTabClick(tab)
                } label: {
                    HStack {
                        Image(systemName: tab.icon)
                        Text(LocalizedStringKey(tab.rawValue))
                        if selection == tab { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HeaderPickerLabel(icon: selection.icon, title: selection.rawValue)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - HeaderIconButton

struct HeaderIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                .foregroundStyle(isHovered ? ClaudeTheme.textPrimary : ClaudeTheme.textTertiary)
                .frame(width: 22, height: 22)
                .background(
                    isHovered ? ClaudeTheme.surfaceSecondary : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}

// MARK: - Empty State Helper

struct InspectorEmptyState: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "doc.badge.plus")
                .font(.system(size: ClaudeTheme.size(32)))
                .foregroundStyle(ClaudeTheme.textTertiary)
            Text(title)
                .font(.system(size: ClaudeTheme.size(14), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textSecondary)
            Text(message)
                .font(.system(size: ClaudeTheme.size(12)))
                .foregroundStyle(ClaudeTheme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
