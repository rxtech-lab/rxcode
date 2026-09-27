import SwiftUI
import RxCodeCore

struct BriefingSummaryPreview: View {
    let text: String
    let maximumHeight: CGFloat
    let onShowMore: () -> Void

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            BriefingMarkdownView(text: text, fontSize: 12.5)
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: BriefingSummaryHeightKey.self,
                            value: geometry.size.height
                        )
                    }
                }
                .frame(maxHeight: maximumHeight, alignment: .top)
                .clipped()

            if contentHeight > maximumHeight + 1 {
                BriefingShowMoreButton(action: onShowMore)
            }
        }
        .onPreferenceChange(BriefingSummaryHeightKey.self) { contentHeight = $0 }
    }
}

private struct BriefingSummaryHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct BriefingShowMoreButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Show more", systemImage: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(ClaudeTheme.accent)
        .accessibilityIdentifier("briefing-show-more-button")
    }
}

struct BriefingInfoChip: View {
    let icon: String
    let text: String
    var accented = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(accented ? ClaudeTheme.accent : ClaudeTheme.textSecondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(
            Capsule(style: .continuous)
                .fill(accented ? ClaudeTheme.accent.opacity(0.12) : ClaudeTheme.surfaceSecondary)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(accented ? ClaudeTheme.accent.opacity(0.25) : ClaudeTheme.border.opacity(0.6), lineWidth: 0.5)
        )
    }
}
