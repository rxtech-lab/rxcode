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

    /// Roughly two to three times what fits in `maximumHeight` at card width,
    /// leaving room for a card stretched to a taller neighbour. Laying out the
    /// whole briefing (often 4x the visible height) made rows slow to appear.
    private static let characterBudget = 900

    var body: some View {
        let isTruncated = BriefingMarkdownView.isTruncated(text, characterBudget: Self.characterBudget)
        VStack(alignment: .leading, spacing: 8) {
            BriefingMarkdownView(text: text, fontSize: 12.5, characterBudget: Self.characterBudget)
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

            if isTruncated || contentHeight > visibleHeight + 1 {
                BriefingShowMoreButton(action: onShowMore)
            }
        }
        .onPreferenceChange(BriefingSummaryHeightKey.self) { height in
            if abs(height - contentHeight) >= 0.5 {
                BriefingPerformanceLog.log("summary preview content height\(BriefingTimelineScrollActivity.isAnyScrolling ? " [scrolling]" : "") \(Int(contentHeight)) -> \(Int(height))")
            }
            contentHeight = height
        }
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

// MARK: - Deferred menu

/// A `Menu` that renders only its label until the pointer reaches it. On macOS
/// every `Menu` is an AppKit pop-up button whose items are built eagerly, which
/// made the first layout of each card row scrolling into view slow. The real
/// menu is created on hover (never mid-scroll), before any click can land.
/// Style modifiers (`menuStyle`, `menuIndicator`, `buttonStyle`) applied by the
/// caller still reach the menu through the environment.
struct BriefingDeferredMenu<Content: View, Label: View>: View {
    @ViewBuilder let content: () -> Content
    @ViewBuilder let label: () -> Label

    @Environment(BriefingTimelineScrollActivity.self) private var scrollActivity: BriefingTimelineScrollActivity?
    @State private var isHovering = false
    @State private var isActive = false

    var body: some View {
        let shouldActivate = isHovering && scrollActivity?.isScrolling != true
        Group {
            if isActive {
                Menu(content: content, label: label)
            } else {
                label()
                    .contentShape(Rectangle())
            }
        }
        .onHover { isHovering = $0 }
        .onChange(of: shouldActivate, initial: true) { _, activate in
            if activate { isActive = true }
        }
    }
}

// MARK: - Card motion

/// Hover lift for briefing cards. Skipped when Reduce Motion is on. Cards live
/// in the AppKit timeline, so there is deliberately no per-frame scroll effect.
/// The lift is also held off while the timeline scrolls: otherwise every card
/// passing under a still pointer would animate its lift in and out.
struct BriefingCardMotion: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(BriefingTimelineScrollActivity.self) private var scrollActivity: BriefingTimelineScrollActivity?
    @State private var isHovering = false

    func body(content: Content) -> some View {
        let isLifted = isHovering && scrollActivity?.isScrolling != true
        content
            .background {
                // Shadow a plain shape behind the opaque card rather than the
                // card itself, so the shadow doesn't trace every text run.
                RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge, style: .continuous)
                    .fill(ClaudeTheme.surfacePrimary)
                    .shadow(
                        color: Color.black.opacity(isLifted ? 0.12 : 0),
                        radius: isLifted ? 12 : 0,
                        x: 0,
                        y: isLifted ? 6 : 0
                    )
            }
            .scaleEffect(isLifted && !reduceMotion ? 1.012 : 1, anchor: .center)
            .animation(.snappy(duration: 0.2), value: isLifted)
            .onHover { hovering in
                BriefingPerformanceLog.log("card hover\(BriefingTimelineScrollActivity.isAnyScrolling ? " [scrolling]" : "") -> \(hovering)")
                isHovering = hovering
            }
    }
}

extension View {
    func briefingCardMotion() -> some View {
        modifier(BriefingCardMotion())
    }
}
