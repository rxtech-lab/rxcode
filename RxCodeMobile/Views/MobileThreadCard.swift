import SwiftUI
import RxCodeCore
import RxCodeSync

/// A thread card in the mobile threads list.
///
/// Solid surface card (see `MobileSurfaceCard.swift`). The leading icon tile and
/// coloured rail show the thread's state (working, needs input, finished, idle).
/// The time sits top-right, like a mail list.
struct MobileThreadCard: View {
    let session: SessionSummary
    let isSelected: Bool
    var onSelect: (() -> Void)?
    /// Nesting depth; review children render one level in from their parent.
    var indentLevel: Int = 0
    /// Replaces the thread title (e.g. `"Review 1"` for a nested review child).
    var titleOverride: String? = nil
    /// Whether to show the `threadLabel` chip (hidden on review children since
    /// the nesting already conveys what they are).
    var showLabelChip: Bool = true

    // MARK: Review disclosure (Android-parity, in-card leading control)

    /// Number of nested code-review children this thread owns.
    var reviewCount: Int = 0
    /// Whether the nested reviews are currently expanded.
    var isReviewExpanded: Bool = false
    /// Whether any nested review is actively streaming.
    var isReviewStreaming: Bool = false
    /// Toggles review expansion. When non-nil, a review disclosure control is
    /// rendered at the trailing edge of the card.
    var onToggleReviews: (() -> Void)?

    private var displayTitle: String {
        if let titleOverride, !titleOverride.isEmpty { return titleOverride }
        let cleaned = ChatSession.stripAttachmentMarkers(from: session.title)
        return cleaned.isEmpty ? ChatSession.defaultTitle : cleaned
    }

    private var isChild: Bool { indentLevel > 0 }

    var body: some View {
        HStack(spacing: 0) {
            if isChild {
                // Thread line connecting a review to its parent.
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 2)
                    .padding(.leading, 18)
                    .padding(.trailing, 10)
            }

            if let onToggleReviews {
                cardWithDisclosure(onToggleReviews: onToggleReviews)
            } else {
                plainCard
            }
        }
    }

    // MARK: - Card variants

    /// Standard card: the whole surface is one navigable button.
    /// The UI-test identifier is applied directly on the button. Applied to an
    /// enclosing container, it doesn't reach the button XCUITest queries.
    private var plainCard: some View {
        MobileRowButton {
            onSelect?()
        } label: {
            cardContent
        }
        .buttonStyle(MobileCardButtonStyle(isSelected: isSelected, rail: status.rail))
        .accessibilityIdentifier("thread-row-\(session.id)")
    }

    /// Parent card with nested reviews: the navigable content and a trailing
    /// review disclosure are sibling tap targets on one surface (SwiftUI can't
    /// reliably nest a button inside a button).
    private func cardWithDisclosure(onToggleReviews: @escaping () -> Void) -> some View {
        HStack(spacing: 0) {
            MobileRowButton { onSelect?() } label: { cardContent }
                .buttonStyle(.plain)
                .accessibilityIdentifier("thread-row-\(session.id)")

            Divider()
                .padding(.vertical, 12)

            disclosureControl(onToggle: onToggleReviews)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            MobileCardSurface(isSelected: isSelected, rail: status.rail)
        }
    }

    /// Trailing review-count control, tappable independently of the row.
    private func disclosureControl(onToggle: @escaping () -> Void) -> some View {
        Button {
            onToggle()
        } label: {
            VStack(spacing: 3) {
                if isReviewStreaming {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Text("\(reviewCount)")
                        .font(.system(size: 13, weight: .bold))
                        .monospacedDigit()
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .rotationEffect(.degrees(isReviewExpanded ? 180 : 0))
            }
            .foregroundStyle(ClaudeTheme.accent)
            .frame(width: 48)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isReviewExpanded ? "Hide code reviews" : "Show \(reviewCount) code reviews")
    }

    // MARK: - Content

    private var cardContent: some View {
        HStack(alignment: .top, spacing: 12) {
            MobileCardIconTile(
                systemImage: status.icon,
                tint: status.tint,
                size: isChild ? 30 : 36
            )
            .overlay {
                if session.isStreaming {
                    RoundedRectangle(cornerRadius: (isChild ? 30 : 36) * 0.28, style: .continuous)
                        .strokeBorder(status.tint.opacity(0.5), lineWidth: 1.5)
                        .modifier(PulseModifier())
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if session.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(ClaudeTheme.accent)
                    }

                    Text(displayTitle)
                        .font(.system(size: isChild ? 14 : 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Spacer(minLength: 6)

                    Text(compactElapsed(since: session.updatedAt))
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }

                metadataRow
            }
        }
        .padding(.leading, status.rail == nil ? 14 : 18)
        .padding(.trailing, 14)
        .padding(.vertical, isChild ? 10 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var metadataRow: some View {
        HStack(spacing: 6) {
            Text(status.caption)
                .font(.system(size: 12, weight: status.isNotable ? .semibold : .regular))
                .foregroundStyle(status.isNotable ? status.tint : .secondary)
                .lineLimit(1)

            if showLabelChip, let label = session.threadLabel, !label.isEmpty {
                MobileCardTag(text: label, tint: ClaudeTheme.accent)
            }

            if let todos = session.todos, !todos.isEmpty {
                let completed = todos.filter { $0.status == .completed }.count
                let done = completed == todos.count
                MobileCardTag(
                    text: "\(completed)/\(todos.count)",
                    systemImage: done ? "checkmark" : "list.bullet",
                    tint: done ? ClaudeTheme.statusSuccess : .secondary
                )
            }
        }
    }

    // MARK: - Status

    private struct Status {
        let icon: String
        let tint: Color
        let caption: LocalizedStringKey
        let rail: Color?
        let isNotable: Bool
    }

    private var status: Status {
        if let attention = session.attention {
            let isQuestion = attention == .question
            let tint: Color = isQuestion ? .yellow : .orange
            return Status(
                icon: isQuestion ? "questionmark" : "hand.raised.fill",
                tint: tint,
                caption: isQuestion ? "Waiting for your answer" : "Needs permission",
                rail: tint,
                isNotable: true
            )
        }
        if session.isStreaming {
            return Status(
                icon: "sparkles",
                tint: ClaudeTheme.accent,
                caption: "Working…",
                rail: ClaudeTheme.accent,
                isNotable: true
            )
        }
        if session.isInterrupted {
            return Status(icon: "pause.circle", tint: ClaudeTheme.statusWarning, caption: "Interrupted",
                          rail: ClaudeTheme.statusWarning, isNotable: true)
        }
        if session.hasUncheckedCompletion {
            return Status(
                icon: "checkmark",
                tint: ClaudeTheme.statusSuccess,
                caption: "Finished",
                rail: ClaudeTheme.statusSuccess,
                isNotable: true
            )
        }
        return Status(
            icon: isChild ? "checklist" : "bubble.left",
            tint: .secondary,
            caption: isChild ? "Code review" : "Idle",
            rail: nil,
            isNotable: false
        )
    }

    // MARK: - Helpers

    private func compactElapsed(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "now" }

        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }

        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }

        let days = hours / 24
        if days < 7 { return "\(days)d" }

        let weeks = days / 7
        if weeks < 52 { return "\(weeks)w" }

        return "\(days / 365)y"
    }
}

/// Gentle repeating fade used to show a thread is working.
private struct PulseModifier: ViewModifier {
    @State private var isOn = false

    func body(content: Content) -> some View {
        content
            .opacity(isOn ? 0.15 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    isOn = true
                }
            }
    }
}

// MARK: - Previews

#Preview("Thread States") {
    let todos = [
        TodoItem(id: 1, content: "Create models", activeForm: "Creating models", status: .completed),
        TodoItem(id: 2, content: "Add views", activeForm: "Adding views", status: .inProgress),
        TodoItem(id: 3, content: "Write tests", activeForm: "Writing tests", status: .pending)
    ]
    func make(_ id: String, _ title: String, ago: TimeInterval, pinned: Bool = false, streaming: Bool = false,
              attention: SessionAttentionKind? = nil, todos: [TodoItem]? = nil, done: Bool = false) -> SessionSummary {
        SessionSummary(
            id: id, projectId: UUID(), title: title,
            updatedAt: Date().addingTimeInterval(-ago),
            isPinned: pinned, isArchived: false, isStreaming: streaming,
            attention: attention, todos: todos, hasUncheckedCompletion: done
        )
    }

    return ScrollView {
        VStack(spacing: 10) {
            MobileThreadCard(session: make("1", "Building new feature module", ago: 0, streaming: true, todos: todos), isSelected: false)
            MobileThreadCard(session: make("2", "Redesign the cards", ago: 300, pinned: true), isSelected: true)
            MobileThreadCard(session: make("3", "Deploy to production", ago: 120, attention: .permission), isSelected: false)
            MobileThreadCard(session: make("4", "Code review assistance", ago: 600, attention: .question), isSelected: false,
                             reviewCount: 2, isReviewExpanded: true, onToggleReviews: {})
            MobileThreadCard(session: make("5", "Review 1", ago: 650), isSelected: false, indentLevel: 1)
            MobileThreadCard(session: make("6", "Fix scrolling performance", ago: 3600, done: true), isSelected: false)
            MobileThreadCard(session: make("7", "Review pull request", ago: 86400), isSelected: false)
        }
        .padding()
    }
    .background(MobileCard.pageBackground)
}
