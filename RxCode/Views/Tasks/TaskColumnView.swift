import RxCodeCore
import SwiftUI

/// One kanban column. Accepts dropped cards and hands the status change to
/// `AppState.moveTask`, which is also what dispatches an agent when the new
/// status is In Progress.
struct TaskColumnView: View {
    @Environment(AppState.self) private var appState

    let status: TaskStatus
    let tasks: [ProjectTask]
    /// Stories whose rolled-up status is this column. Not draggable — a story
    /// moves only as its tasks do.
    let stories: [ProjectStory]
    let board: TaskBoard
    let onOpen: (TaskBoardSheet) -> Void
    let onAdd: () -> Void
    /// `nil` when this is the view's last visible column.
    let onHide: (() -> Void)?
    let onEditView: () -> Void
    @Binding var hoveredStoryId: UUID?

    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            columnHeader

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(stories) { story in
                        StoryCardView(story: story, progress: board.progress(for: story), hoveredStoryId: $hoveredStoryId) {
                            onOpen(.story(story))
                        }
                    }
                    ForEach(tasks) { task in
                        TaskCardView(task: task, board: board, hoveredStoryId: $hoveredStoryId) {
                            onOpen(.task(task))
                        }
                        // An In Progress card stays put while its agent runs.
                        .modifier(TaskCardDrag(task: task))
                    }
                    if tasks.isEmpty, stories.isEmpty {
                        emptyHint
                    }
                }
                .padding(.bottom, 8)
            }
            .scrollContentBackground(.hidden)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium)
                .fill(ClaudeTheme.surfacePrimary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium)
                .strokeBorder(ClaudeTheme.borderSubtle, lineWidth: 1)
        )
        .overlay(dropOverlay)
        // The dragged payload is the task's UUID string rather than a
        // `Transferable` conformance on `ProjectTask`: the id is all the drop
        // needs, and it avoids sending a model value across the drag boundary.
        .dropDestination(for: String.self) { items, _ in
            handleDrop(items)
        } isTargeted: { isTargeted = $0 }
        .accessibilityIdentifier("task-column-\(status.rawValue)")
    }

    // MARK: - Drop

    private func handleDrop(_ items: [String]) -> Bool {
        var didMove = false
        for raw in items {
            guard let id = UUID(uuidString: raw), let task = appState.task(id: id) else { continue }
            // Re-dropping into the same column is a no-op rather than a
            // reorder-to-end, which would make an accidental drag reshuffle the
            // board (and, for In Progress, re-dispatch the agent).
            guard task.status != status else { continue }
            appState.moveTask(task, to: status)
            didMove = true
        }
        return didMove
    }

    // MARK: - Chrome

    private var columnHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                TaskStatusIcon(status: status, size: 13)
                Text(status.displayName)
                    .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                TaskCountBadge(count: tasks.count + stories.count)

                Spacer(minLength: 0)

                Menu {
                    Button("Edit View…", action: onEditView)
                    if let onHide {
                        Button("Hide Column", action: onHide)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Column options")

                Button(action: onAdd) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add a task to this column")
            }

            Text(status.columnDescription)
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(ClaudeTheme.textTertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 2)
    }

    private var emptyHint: some View {
        Text(status == .pending ? "New tasks land here." : "Drag a card here.")
            .font(.system(size: ClaudeTheme.size(11)))
            .foregroundStyle(ClaudeTheme.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
    }

    /// Mirrors the composer's drag affordance (`InputBarView.dragOverlay`).
    @ViewBuilder
    private var dropOverlay: some View {
        if isTargeted {
            let shape = RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium)
            shape
                .strokeBorder(ClaudeTheme.accent.opacity(0.6), lineWidth: 2, antialiased: true)
                .background(ClaudeTheme.accent.opacity(0.05), in: shape)
                .allowsHitTesting(false)
        }
    }
}

/// Makes a card draggable unless its status is locked. `.disabled` can't be
/// used for this: it would also block tapping the card open.
private struct TaskCardDrag: ViewModifier {
    let task: ProjectTask

    func body(content: Content) -> some View {
        if task.isStatusLocked {
            content.help("The agent is working on this task")
        } else {
            content.draggable(task.id.uuidString)
        }
    }
}
