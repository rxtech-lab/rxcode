import RxCodeCore
import SwiftUI
import UniformTypeIdentifiers

/// One kanban column. Accepts dropped cards and hands the status change to
/// `AppState.moveTask`, which is also what dispatches an agent when the column
/// triggers a chat. Its header is itself draggable, so columns can be
/// rearranged on the board as well as in the columns manager.
struct TaskColumnView: View {
    @Environment(AppState.self) private var appState

    let projectId: UUID
    let column: TaskColumn
    let tasks: [ProjectTask]
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

    private var status: TaskStatus { column.id }

    @State private var isTargeted = false
    @State private var isColumnTargeted = false
    @State private var revealedOlderTaskCount = 0
    @State private var currentDate = Date()

    var body: some View {
        // Only finished cards age out; open work stays on the board however
        // long it sits untouched.
        let cutoff = currentDate.addingTimeInterval(-Double(appState.taskCardRetentionDays) * 24 * 60 * 60)
        let recentTasks = column.countsAsDone ? tasks.filter { $0.updatedAt >= cutoff } : tasks
        let olderTasks = column.countsAsDone
            ? tasks.filter { $0.updatedAt < cutoff }.sorted { $0.updatedAt > $1.updatedAt }
            : []
        let shownTasks = recentTasks + Array(olderTasks.prefix(revealedOlderTaskCount))
        let hiddenCount = max(0, olderTasks.count - revealedOlderTaskCount)
        // Queued cards are never aged out: the queue's order is what the user
        // arranges, so all of it stays on screen, below the running cards.
        let queuedTasks = column.triggersChat ? tasks.filter(\.isQueued) : []
        let visibleTasks = shownTasks.filter { !$0.isQueued || !column.triggersChat }

        TaskKanbanColumnContent {
            columnHeader
        } cards: {
            ForEach(visibleTasks) { task in
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
            if !queuedTasks.isEmpty {
                queueHeader(count: queuedTasks.count)
                ForEach(Array(queuedTasks.enumerated()), id: \.element.id) { offset, task in
                    TaskCardView(
                        task: task,
                        board: board,
                        storyRollup: task.storyId.flatMap { storyRollups[$0] },
                        queuePosition: offset + 1
                    ) {
                        onOpen(.task(task))
                    }
                    .modifier(TaskCardDrag(isLocked: false, task: task))
                    .modifier(TaskQueueDropTarget { items in
                        handleQueueDrop(items, before: task.id)
                    })
                    .transition(TaskBoardMotion.card)
                }
            }
            if hiddenCount > 0 {
                Button {
                    revealedOlderTaskCount += 10
                } label: {
                    Text("Show \(min(10, hiddenCount)) more older tasks (\(hiddenCount) hidden)")
                        .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .foregroundStyle(ClaudeTheme.accent)
                .padding(.vertical, 8)
                .accessibilityIdentifier("task-column-show-more-\(status.rawValue)")
            }
            if tasks.isEmpty {
                emptyHint
                    .transition(.opacity)
            }
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
        .task(id: TaskCardAgeSchedule(
            retentionDays: appState.taskCardRetentionDays,
            updatedDates: column.countsAsDone ? tasks.map(\.updatedAt) : []
        )) {
            guard column.countsAsDone else { return }
            let retentionInterval = Double(appState.taskCardRetentionDays) * 24 * 60 * 60
            while !Task.isCancelled {
                let now = Date()
                currentDate = now
                guard let nextExpiration = tasks.map({ $0.updatedAt.addingTimeInterval(retentionInterval) })
                    .filter({ $0 >= now }).min() else { break }
                // The cutoff uses a strict comparison, so wake just after the boundary.
                let delay = nextExpiration.timeIntervalSince(now) + 0.01
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    break
                }
            }
        }
    }

    // MARK: - Drop

    private func handleDrop(_ items: [String]) -> Bool {
        var didMove = false
        for raw in items {
            guard let id = UUID(uuidString: raw), let task = appState.task(id: id) else { continue }
            // A queued card dropped on its own column's body goes to the back
            // of the queue.
            if task.isQueued, board.resolvedStatus(of: task) == status {
                appState.reorderQueuedTask(task.id, before: nil)
                didMove = true
                continue
            }
            // Re-dropping into the same column is a no-op rather than a
            // reorder-to-end, which would make an accidental drag reshuffle the
            // board (and, for a chat column, re-dispatch the agent).
            guard board.resolvedStatus(of: task) != status else { continue }
            appState.moveTask(task, to: status)
            didMove = true
        }
        return didMove
    }

    /// A card dropped on a queued card: a queued card from this column moves
    /// ahead of it in the queue; anything else is an ordinary column drop.
    private func handleQueueDrop(_ items: [String], before targetId: UUID) -> Bool {
        var didMove = false
        for raw in items {
            guard let id = UUID(uuidString: raw), let task = appState.task(id: id) else { continue }
            if task.isQueued, board.resolvedStatus(of: task) == status {
                appState.reorderQueuedTask(task.id, before: targetId)
                didMove = true
            } else {
                didMove = handleDrop([raw]) || didMove
            }
        }
        return didMove
    }

    // MARK: - Chrome

    private func queueHeader(count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "hourglass")
            Text("Queued (\(count))")
                .fontWeight(.semibold)
            Spacer(minLength: 0)
            Text("Drag to reorder")
        }
        .font(.system(size: ClaudeTheme.size(11)))
        .foregroundStyle(ClaudeTheme.textTertiary)
        .padding(.horizontal, 2)
        .padding(.top, 4)
        .accessibilityIdentifier("task-column-queue-\(status.rawValue)")
    }

    /// "2 of 4 running" for a chat column; opens the column editor, where the
    /// limit is set.
    private var concurrencySummary: some View {
        let running = appState.runningTaskCount(in: column.id, projectId: projectId)
        return Button(action: onEditColumn) {
            HStack(spacing: 4) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                Text("\(running) of \(column.concurrencyLimit) running")
            }
            .font(.system(size: ClaudeTheme.size(11), weight: .medium))
            .foregroundStyle(running >= column.concurrencyLimit ? ClaudeTheme.statusWarning : ClaudeTheme.textSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Maximum tasks that run at once in this column. Later tasks wait in the queue.")
        .accessibilityIdentifier("task-column-concurrency-\(status.rawValue)")
    }

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

            if column.triggersChat {
                concurrencySummary
            }
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
            TaskCountBadge(count: tasks.count)
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

private struct TaskCardAgeSchedule: Hashable {
    let retentionDays: Int
    let updatedDates: [Date]
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

/// Lets a queued card take drops, so another queued card can be placed ahead
/// of it. Highlighted while a card hovers.
private struct TaskQueueDropTarget: ViewModifier {
    let onDrop: ([String]) -> Bool

    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if isTargeted {
                    Capsule()
                        .fill(ClaudeTheme.accent)
                        .frame(height: 3)
                        .offset(y: -5)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: String.self) { items, _ in
                onDrop(items)
            } isTargeted: { isTargeted = $0 }
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
