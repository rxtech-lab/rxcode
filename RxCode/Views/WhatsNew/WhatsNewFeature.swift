import SwiftUI

/// A single "What's New" feature card.
///
/// `slug` is a stable, hand-authored identifier (never random) used to track
/// whether the user has already seen this card. Once a slug is recorded as
/// seen it is never surfaced again, even across app updates — so adding a new
/// card with a new slug in a later version only shows that new card.
struct WhatsNewFeature: Identifiable {
    /// Stable, hand-authored identifier. Changing it re-shows the card.
    let slug: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    /// SF Symbol shown in the card's icon tile.
    let icon: String
    /// Short bullet points describing what the feature does.
    let highlights: [Highlight]

    var id: String { slug }

    struct Highlight {
        let icon: String
        let text: LocalizedStringKey
    }

    /// All shipped feature cards, oldest first. Append new cards to the end
    /// with a fresh, unique `slug`. Order here is the order users page through.
    static let all: [WhatsNewFeature] = [
        WhatsNewFeature(
            slug: "code-review-hook",
            title: "Automatic code review",
            subtitle: "Add a Code Review hook and a second agent reviews every change before you ship it.",
            icon: "checkmark.seal.fill",
            highlights: [
                Highlight(icon: "arrow.triangle.branch", text: "Runs after a session finishes and reviews the modified files in a linked thread."),
                Highlight(icon: "arrow.uturn.left", text: "Failed reviews are sent back to the original thread so the agent can fix and get re-reviewed."),
                Highlight(icon: "cpu", text: "Pick which model performs the review — defaults to the same model as the thread.")
            ]
        ),
        WhatsNewFeature(
            slug: "commit-push-hook",
            title: "Commit when a session finishes",
            subtitle: "The new Commit & Push hook commits — and optionally pushes — your work the moment an agent session completes.",
            icon: "arrow.up.circle.fill",
            highlights: [
                Highlight(icon: "checkmark.circle", text: "Triggers automatically once an agent session finishes."),
                Highlight(icon: "checkmark.seal", text: "When a Code Review hook is configured, commits only happen after the review passes."),
                Highlight(icon: "arrow.up.doc", text: "Push to the remote automatically, or keep the commit local.")
            ]
        )
    ]
}
