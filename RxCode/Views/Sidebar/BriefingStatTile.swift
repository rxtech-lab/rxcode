import SwiftUI
import RxCodeCore

/// Fixed-height statistic card used by the briefing usage panels: icon and
/// title, a large value, a detail line, and an optional footnote.
struct BriefingStatTile: View {
    /// Shared by every briefing statistic card so tiles line up in the grid.
    /// Fits a provider tile with two rows plus its footnote.
    static let height: CGFloat = 152

    let icon: String
    let title: LocalizedStringKey
    let value: String
    let detail: String
    let footnote: String?
    /// Trailing glyph hinting that the tile opens more detail; nil when inert.
    let accessoryIcon: String?
    let help: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.accent)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                Spacer(minLength: 0)
                if let accessoryIcon {
                    Image(systemName: accessoryIcon)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
            }
            Text(value)
                .font(.system(size: 20, weight: .semibold).monospacedDigit())
                .foregroundStyle(ClaudeTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .contentTransition(.numericText())
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(ClaudeTheme.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let footnote {
                Text(footnote)
                    .font(.system(size: 10.5))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge, style: .continuous)
                .fill(ClaudeTheme.surfacePrimary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge, style: .continuous)
                .strokeBorder(ClaudeTheme.border.opacity(0.6), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge, style: .continuous))
        .help(help)
        .animation(.easeInOut(duration: 0.2), value: value)
    }
}

/// Capsule dropdown used in the briefing usage panel headers.
struct BriefingPanelMenu<Option: Hashable>: View {
    let options: [Option]
    let selection: Option
    let title: (Option) -> String
    let help: String
    let onSelect: (Option) -> Void

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    onSelect(option)
                } label: {
                    if option == selection {
                        Label(title(option), systemImage: "checkmark")
                    } else {
                        Text(title(option))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(title(selection))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(ClaudeTheme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(ClaudeTheme.surfaceSecondary)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(ClaudeTheme.border.opacity(0.6), lineWidth: 0.5)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
    }
}

/// Briefing statistic card comparing one metric across providers: a row per
/// provider with its value and an optional detail line.
struct BriefingProviderStatTile: View {
    struct Row: Identifiable {
        let id: String
        let label: String
        let value: String
        let detail: String?
    }

    let icon: String
    let title: LocalizedStringKey
    let rows: [Row]
    let footnote: String?
    /// Trailing glyph hinting that the tile opens more detail; nil when inert.
    let accessoryIcon: String?
    let help: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.accent)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                Spacer(minLength: 0)
                if let accessoryIcon {
                    Image(systemName: accessoryIcon)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
            }
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.label)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(ClaudeTheme.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(row.value)
                            .font(.system(size: 15, weight: .semibold).monospacedDigit())
                            .foregroundStyle(ClaudeTheme.textPrimary)
                            .lineLimit(1)
                            .contentTransition(.numericText())
                    }
                    if let detail = row.detail {
                        Text(detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
            if let footnote {
                Text(footnote)
                    .font(.system(size: 10.5))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(
            maxWidth: .infinity,
            minHeight: BriefingStatTile.height,
            maxHeight: BriefingStatTile.height,
            alignment: .topLeading
        )
        .background(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge, style: .continuous)
                .fill(ClaudeTheme.surfacePrimary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge, style: .continuous)
                .strokeBorder(ClaudeTheme.border.opacity(0.6), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge, style: .continuous))
        .help(help)
    }
}
