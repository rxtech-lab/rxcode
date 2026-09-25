import RxCodeCore
import SwiftUI
import UniformTypeIdentifiers

/// One kanban column. Accepts dropped cards and hands the status change to
/// `AppState.moveTask`, which is also what dispatches an agent when the column
/// triggers a chat. Its header is itself draggable, so columns can be
/// rearranged on the board as well as in the columns manager.
struct TaskColumnView: View {
    @Environment(AppState.self) private var appState

    let column: TaskColumn
    let tasks: [ProjectTask]
    /// Stories whose rolled-up status is this column. Not draggable — a story
    /// moves only as its tasks do.
    let stories: [ProjectStory]
    let board: TaskBoard
    /// Every story's progress and column, computed once for the whole board.
    let storyRollups: [UUID: StoryRollup]
    let onOpen: (TaskBoardSheet) -> Void
    /// A new task starts in this column; a story has no column of its own.
    let onAddTask: (TaskCreationMode) -> Void
    let onAddStory: (TaskCreationMode) -> Void
    /// `nil` when this is the view's last visible column.
    let onHide: (() -> Void)?
    let onEditView: () -> Void
    let onEditColumn: () -> Void
    /// A column header was dropped on this one: the dragged column takes this
    /// column's slot in the board order.
    let onReorder: (TaskStatus) -> Void
    @Binding var collapsedStoryIds: Set<UUID>

    private var status: TaskStatus { column.id }

    @State private var isTargeted = false
    @State private var isColumnTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            columnHeader

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(stories) { story in
                        StoryCardView(
                            story: story,
                            progress: storyRollups[story.id]?.progress ?? board.progress(for: story),
                            board: board,
                            isCollapsed: collapsedStoryIds.contains(story.id),
                            onToggleCollapse: {
                                if collapsedStoryIds.contains(story.id) {
                                    collapsedStoryIds.remove(story.id)
                                } else {
                                    collapsedStoryIds.insert(story.id)
                                }
                            },
                            onOpen: { onOpen(.story(story)) },
                            onNewTask: { onOpen(.task($0)) }
                        )
                        .transition(TaskBoardMotion.card)
                    }
                    // Separates the story roll-ups from the column's own tasks.
                    if !stories.isEmpty, !tasks.isEmpty {
                        ClaudeThemeDivider()
                            .padding(.vertical, 4)
                            .transition(.opacity)
                    }
                    ForEach(tasks) { task in
                        TaskCardView(
                            task: task,
                            board: board,
                            storyRollup: task.storyId.flatMap { storyRollups[$0] }
                        ) {
                            onOpen(.task(task))
                        }
                        // A card in a chat column stays put while its agent runs.
                        .modifier(TaskCardDrag(isLocked: board.isStatusLocked(task), task: task))
                        .transition(TaskBoardMotion.card)
                    }
                    if tasks.isEmpty, stories.isEmpty {
                        emptyHint
                            .transition(.opacity)
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
        // Shown for a hovering card and for a hovering column header alike —
        // in both cases this column is where the drop lands.
        .taskDropHighlight(
            isTargeted || isColumnTargeted,
            in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium),
            scale: 1.008
        )
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
            // board (and, for a chat column, re-dispatch the agent).
            guard board.resolvedStatus(of: task) != status else { continue }
            appState.moveTask(task, to: status)
            didMove = true
        }
        return didMove
    }

    // MARK: - Chrome

    private var columnHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                // Only the title carries the drag: the menu and add button in
                // the same row have to stay clickable.
                titleGroup
                    .contentShape(Rectangle())
                    .draggable(TaskColumnTransfer(columnId: column.id)) {
                        TaskColumnDragPreview(column: column)
                    }
                    .help("Drag onto another column header to reorder the board")

                Spacer(minLength: 0)

                Menu {
                    Button("Edit Column…", action: onEditColumn)
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

                Menu {
                    TaskCreationMenuItems(onNewTask: onAddTask, onNewStory: onAddStory)
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add a task to this column, or a story")
            }

            Text(column.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                 ? board.triggerSummary(for: column)
                 : column.details)
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(ClaudeTheme.textTertiary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 2)
        // The header is the column's drop target for other column headers; the
        // body below keeps taking cards. Two payload types, two destinations,
        // so a card drag can never land as a reorder or the other way round.
        .contentShape(Rectangle())
        .dropDestination(for: TaskColumnTransfer.self) { items, _ in
            guard let dragged = items.first?.columnId, dragged != column.id else { return false }
            onReorder(dragged)
            return true
        } isTargeted: { isColumnTargeted = $0 }
    }

    /// Icon, name, count and the chat bolt — the header's drag handle.
    private var titleGroup: some View {
        HStack(spacing: 7) {
            TaskStatusIcon(column: column, size: 13)
            Text(column.name)
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textPrimary)
                .lineLimit(1)
            TaskCountBadge(count: tasks.count + stories.count)
            if column.triggersChat {
                Image(systemName: "bolt.fill")
                    .font(.system(size: ClaudeTheme.size(10)))
                    .foregroundStyle(ClaudeTheme.statusWarning)
                    .help("Dropping a card here starts a chat with its agent")
            }
        }
    }

    private var emptyHint: some View {
        Text(status == board.firstColumn.id ? "New tasks land here." : "Drag a card here.")
            .font(.system(size: ClaudeTheme.size(11)))
            .foregroundStyle(ClaudeTheme.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
    }
}

// MARK: - Column drag

/// The drag payload of a board column.
///
/// A dedicated `Transferable` rather than the card drag's plain id string: the
/// column header and the column body are drop targets in the same hierarchy, so
/// the two drags have to be distinguishable by type.
struct TaskColumnTransfer: Codable, Sendable, Transferable {
    let columnId: TaskStatus

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .rxCodeTaskColumn)
    }
}

extension UTType {
    /// Declared in the app's Info.plist (`UTExportedTypeDeclarations`).
    static let rxCodeTaskColumn = UTType(exportedAs: "com.rxlab.RxCode.task-column")
}

/// The chip that follows the pointer while a column header is dragged.
private struct TaskColumnDragPreview: View {
    let column: TaskColumn

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
        HStack(spacing: 6) {
            TaskStatusIcon(column: column, size: 12)
            Text(column.name)
                .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(ClaudeTheme.surfacePrimary, in: shape)
        .overlay(shape.strokeBorder(ClaudeTheme.border, lineWidth: 1))
    }
}

/// Makes a card draggable unless its status is locked. `.disabled` can't be
/// used for this: it would also block tapping the card open.
private struct TaskCardDrag: ViewModifier {
    let isLocked: Bool
    let task: ProjectTask

    func body(content: Content) -> some View {
        if isLocked {
            content.help("The agent is working on this task")
        } else {
            content.draggable(task.id.uuidString)
        }
    }
}
