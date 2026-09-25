import RxCodeCore
import RxCodeSync
import SwiftUI

// MARK: - Styling

extension TaskColumn {
    var tint: Color { Color(hex: colorHex) }
}

extension TaskPriority {
    var tint: Color { Color(hex: colorHex) }
}

extension TaskItemType {
    var tint: Color { Color(hex: colorHex) }
}

extension TaskBoard {
    func labelTint(for tag: String) -> Color {
        labelColorHex(for: tag).map { Color(hex: $0) } ?? .secondary
    }
}

// MARK: - Row

/// One task in a list: title, column, classification pills, and live run
/// state. Shared by the board, story detail, and search results.
struct MobileTaskRow: View {
    @EnvironmentObject private var state: MobileAppState
    let task: ProjectTask
    let board: TaskBoard
    var showsColumn = false
    var showsStory = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let type = board.itemType(id: task.typeId) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(type.tint)
                }
                Text(task.title.isEmpty ? String(localized: "Untitled Task") : task.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 4)
                statusIndicator
            }

            if !task.details.isEmpty {
                Text(task.details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let reason = task.attentionReason {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            MobileTaskPills(
                board: board,
                column: showsColumn ? board.column(for: task.status) : nil,
                story: showsStory ? board.story(id: task.storyId) : nil,
                priority: task.priority,
                version: task.version,
                milestone: task.milestone,
                tags: task.tags
            )
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("task-row-\(task.id.uuidString)")
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if state.isTaskAgentRunning(task) {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Agent running")
        } else if state.isTaskClassifying(task) {
            Image(systemName: "sparkles")
                .foregroundStyle(.purple)
                .symbolEffect(.pulse)
                .accessibilityLabel("Classifying")
        } else if state.taskSessionID(task) != nil {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// The classification chips under a task or story, wrapped onto new lines.
struct MobileTaskPills: View {
    let board: TaskBoard
    var column: TaskColumn?
    var story: ProjectStory?
    var priority: TaskPriority?
    var version: String?
    var milestone: String?
    var tags: [String] = []

    private var isEmpty: Bool {
        column == nil && story == nil && priority == nil && version == nil && milestone == nil && tags.isEmpty
    }

    var body: some View {
        if !isEmpty {
            FlowLayout(spacing: 4) {
                if let column {
                    TaskPill(text: column.name, icon: column.systemImage, tint: column.tint)
                }
                if let priority {
                    TaskPill(text: priority.displayNameText, icon: priority.systemImage, tint: priority.tint)
                }
                if let story {
                    TaskPill(text: story.title, icon: "rectangle.stack")
                }
                if let version, !version.isEmpty {
                    TaskPill(text: version, icon: "tag")
                }
                if let milestone, !milestone.isEmpty {
                    TaskPill(text: milestone, icon: "flag")
                }
                ForEach(tags, id: \.self) { tag in
                    TaskPill(text: tag, tint: board.labelTint(for: tag))
                }
            }
        }
    }
}

/// Done / in-flight / remaining bar for a story's child tasks.
struct MobileStoryProgressBar: View {
    let progress: StoryProgress

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule()
                        .fill(Color.blue.opacity(0.45))
                        .frame(width: width * min(1, progress.fraction + progress.activeFraction))
                    Capsule()
                        .fill(Color.green)
                        .frame(width: width * progress.fraction)
                }
            }
            .frame(height: 6)
            Text("\(progress.done)/\(progress.total)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(progress.done) of \(progress.total) tasks done")
    }
}

/// A story in a list: title, rolled-up column, progress, and pills.
struct MobileStoryRow: View {
    let story: ProjectStory
    let board: TaskBoard
    let rollup: StoryRollup?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "rectangle.stack")
                    .foregroundStyle(.secondary)
                Text(story.title.isEmpty ? String(localized: "Untitled Story") : story.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 4)
            }
            if let rollup, rollup.progress.total > 0 {
                MobileStoryProgressBar(progress: rollup.progress)
            }
            MobileTaskPills(
                board: board,
                column: rollup.map { board.column(for: $0.status) },
                priority: story.priority,
                version: story.version,
                milestone: story.milestone,
                tags: story.tags
            )
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("story-row-\(story.id.uuidString)")
    }
}

// MARK: - Agent label

extension MobileAppState {
    /// Model sections synced from the desktop, grouped by provider, with a
    /// fallback for desktops that only send the flat list.
    var taskModelSections: [AgentModelSection] {
        if let sections = desktopSettings?.modelSections, !sections.isEmpty {
            return sections
        }
        let flat = desktopSettings?.availableModels ?? []
        var providers: [AgentProvider] = []
        for model in flat where !providers.contains(model.provider) {
            providers.append(model.provider)
        }
        return providers.map { provider in
            AgentModelSection(
                id: provider.rawValue,
                title: provider.displayNameText,
                provider: provider,
                models: flat.filter { $0.provider == provider }
            )
        }
    }

    /// Human-readable label for a task's agent assignment.
    func taskAgentLabel(_ agent: TaskAgentConfig) -> String {
        guard agent.isAssigned else { return String(localized: "Unassigned") }
        if let model = agent.model, !model.isEmpty {
            let match = taskModelSections
                .flatMap(\.models)
                .first { $0.id == model && (agent.provider == nil || $0.provider == agent.provider) }
            return match?.displayName ?? model
        }
        return agent.provider?.displayNameText ?? String(localized: "Unassigned")
    }
}
