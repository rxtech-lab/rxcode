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
    /// Illustration in the asset catalog, displayed above the card title.
    let illustration: String
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
            illustration: "WhatsNewCodeReview",
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
            illustration: "WhatsNewCommitPush",
            highlights: [
                Highlight(icon: "checkmark.circle", text: "Triggers automatically once an agent session finishes."),
                Highlight(icon: "checkmark.seal", text: "When a Code Review hook is configured, commits only happen after the review passes."),
                Highlight(icon: "arrow.up.doc", text: "Push to the remote automatically, or keep the commit local.")
            ]
        ),
        WhatsNewFeature(
            slug: "custom-context-menus",
            title: "Custom context menus",
            subtitle: "Build your own project, thread, and briefing-card menu items in Settings → Context Menus. They sync to your phone automatically.",
            illustration: "WhatsNewContextMenus",
            highlights: [
                Highlight(icon: "globe", text: "Call an external API — define the method, URL, headers, and body once, with {{placeholders}} for project and branch context."),
                Highlight(icon: "bubble.left.and.bubble.right", text: "Create a new thread or continue an existing one with a templated message."),
                Highlight(icon: "iphone", text: "Scope an item to one project or all of them; it shows up on desktop and mobile alike.")
            ]
        ),
        WhatsNewFeature(
            slug: "projects-dashboard",
            title: "Projects dashboard",
            subtitle: "Plan and track work across your projects with stories, tasks, and a board for each project.",
            illustration: "WhatsNewProjectsDashboard",
            highlights: [
                Highlight(icon: "square.stack.3d.up", text: "See recent stories and task progress for every project in one place."),
                Highlight(icon: "rectangle.split.3x1", text: "Open a project to organize tasks in board or table views with custom columns and filters."),
                Highlight(icon: "sparkles", text: "Assign an agent to a task and move it into a chat column to start work.")
            ]
        ),
        WhatsNewFeature(
            slug: "scheduled-tasks",
            title: "Scheduled tasks",
            subtitle: "Plan recurring agent prompts for a project and manage them from one place.",
            illustration: "WhatsNewScheduledTasks",
            highlights: [
                Highlight(icon: "sparkles", text: "Create a schedule with AI or fill in the form yourself."),
                Highlight(icon: "calendar", text: "Choose the project, prompt, agent, and timing."),
                Highlight(icon: "pause.circle", text: "Pause, edit, or delete schedules whenever you need to.")
            ]
        ),
        WhatsNewFeature(
            slug: "standalone-chat",
            title: "Standalone chat",
            subtitle: "Start an agent conversation without adding a project first.",
            illustration: "WhatsNewStandaloneChat",
            highlights: [
                Highlight(icon: "bubble.left", text: "Open Chat from the sidebar to start a conversation."),
                Highlight(icon: "square.and.pencil", text: "Start a fresh chat whenever you want a separate topic."),
                Highlight(icon: "clock.arrow.circlepath", text: "Return to earlier conversations from Chat History.")
            ]
        )
    ]
}
