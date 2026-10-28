import RxCodeCore
import SwiftUI

/// Only values that change the menu's structure or enabled state belong here.
/// Streaming summaries and card hover updates must not rebuild a tracked submenu.
struct TaskContextMenuState: Equatable {
    struct Destination: Identifiable, Equatable {
        let id: TaskStatus
        let name: String
    }

    let taskID: UUID
    let destinations: [Destination]
    let currentStatus: TaskStatus
    let isStatusLocked: Bool
    let canOpenChat: Bool
    let canFixCheckError: Bool
    let canRunWithAgent: Bool

    init(task: ProjectTask, board: TaskBoard, canOpenChat: Bool) {
        taskID = task.id
        destinations = board.effectiveColumns.map { Destination(id: $0.id, name: $0.name) }
        currentStatus = board.resolvedStatus(of: task)
        isStatusLocked = board.isStatusLocked(task)
        self.canOpenChat = canOpenChat
        canFixCheckError = task.checkErrorFixPrompt != nil && !isStatusLocked
            && (canOpenChat || (task.agent.isAssigned && board.firstChatColumn != nil))
        canRunWithAgent = task.agent.isAssigned && !board.column(for: task.status).triggersChat
            && board.firstChatColumn != nil
    }
}

/// Shared by board cards, table rows and story task lists.
struct TaskContextMenuItems: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    let task: ProjectTask
    let onEdit: () -> Void
    let onDelete: () -> Void
    var onOpenChat: (() -> Void)?

    var body: some View {
        let currentTask = appState.task(id: task.id) ?? task
        TaskContextMenuContent(
            state: TaskContextMenuState(
                task: currentTask,
                board: appState.taskBoard(for: currentTask.projectId),
                canOpenChat: appState.canOpenChat(for: currentTask)
            ),
            onAction: perform
        )
        .equatable()
        .disabled(!appState.canEditCard(currentTask))
    }

    private func perform(_ action: TaskContextMenuAction) {
        // An open menu can outlive a background board update. Never write the
        // card's old copy over newer task fields when a destination is picked.
        guard let currentTask = appState.task(id: task.id) else { return }
        let board = appState.taskBoard(for: currentTask.projectId)
        switch action {
        case .edit:
            onEdit()
        case .openChat:
            onOpenChat?()
            appState.openChat(for: currentTask, in: windowState)
        case .fixCheckError:
            guard !appState.isStatusLocked(currentTask), let prompt = currentTask.checkErrorFixPrompt else { return }
            if appState.canOpenChat(for: currentTask) {
                Task { await appState.sendTaskFollowUp(currentTask, text: prompt) }
            } else if let column = board.firstChatColumn, currentTask.agent.isAssigned {
                appState.moveTask(currentTask, to: column.id)
            }
        case .runWithAgent:
            if currentTask.agent.isAssigned, !board.column(for: currentTask.status).triggersChat,
               let column = board.firstChatColumn {
                appState.moveTask(currentTask, to: column.id)
            }
        case .move(let status):
            guard board.effectiveColumns.contains(where: { $0.id == status }) else { return }
            appState.moveTask(currentTask, to: status)
        case .delete:
            onDelete()
        }
    }
}

private enum TaskContextMenuAction {
    case edit, openChat, fixCheckError, runWithAgent, delete
    case move(TaskStatus)
}

/// Keep observation reads outside this view: SwiftUI can then retain the native
/// menu while unrelated AppState or hover changes re-evaluate its parent.
private struct TaskContextMenuContent: View, Equatable {
    let state: TaskContextMenuState
    let onAction: (TaskContextMenuAction) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.state == rhs.state
    }

    var body: some View {
        Button("Edit…") { onAction(.edit) }
        if state.canOpenChat {
            Button("Open Chat") { onAction(.openChat) }
        }
        if state.canFixCheckError {
            Button("Fix Check Error", systemImage: "wrench.and.screwdriver") { onAction(.fixCheckError) }
        }
        if state.canRunWithAgent {
            Button("Run with Agent") { onAction(.runWithAgent) }
        }
        Divider()
        Menu("Move To") {
            ForEach(state.destinations) { destination in
                Button(destination.name) { onAction(.move(destination.id)) }
                    .disabled(destination.id == state.currentStatus)
            }
        }
        .disabled(state.isStatusLocked)
        Divider()
        Button("Delete", role: .destructive) { onAction(.delete) }
    }
}
