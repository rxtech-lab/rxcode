import SwiftUI
import RxCodeCore

/// Markdown preview that fills whatever height its card offers. On its own it
/// asks for at most `maximumHeight`; when the card is stretched to match a
/// taller neighbor it shows more content instead of leaving a gap, and keeps
/// "Show more" pinned to the bottom whenever content is clipped.
struct BriefingSummaryPreview: View {
    let text: String
    let maximumHeight: CGFloat
    let onShowMore: () -> Void

    @State private var contentHeight: CGFloat = 0
    @State private var visibleHeight: CGFloat = 0

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
                .frame(
                    minHeight: 0,
                    idealHeight: min(contentHeight, maximumHeight),
                    maxHeight: .infinity,
                    alignment: .top
                )
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { visibleHeight = $0 }
                .clipped()

            if contentHeight > visibleHeight + 1 {
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

// MARK: - Card motion

/// Hover lift, scroll-edge fade, and insert/remove transitions for briefing
/// cards. Motion is skipped when Reduce Motion is on.
struct BriefingCardMotion: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isHovering && !reduceMotion ? 1.012 : 1, anchor: .center)
            .shadow(
                color: Color.black.opacity(isHovering ? 0.12 : 0),
                radius: isHovering ? 12 : 0,
                x: 0,
                y: isHovering ? 6 : 0
            )
            .animation(.snappy(duration: 0.2), value: isHovering)
            .onHover { isHovering = $0 }
            .scrollTransition(.interactive, axis: .vertical) { view, phase in
                view
                    .opacity(phase.isIdentity ? 1 : 0.55)
                    .scaleEffect(phase.isIdentity || reduceMotion ? 1 : 0.97)
                    .offset(y: reduceMotion ? 0 : phase.value * 10)
            }
            .transition(
                reduceMotion
                    ? .opacity
                    : .asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.96)).combined(with: .offset(y: 12)),
                        removal: .opacity.combined(with: .scale(scale: 0.96))
                    )
            )
    }
}

extension View {
    func briefingCardMotion() -> some View {
        modifier(BriefingCardMotion())
    }
}
