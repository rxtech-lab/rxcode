import RxCodeCore
import SwiftUI

/// Makes a task row draggable onto other rows and column headers. Agent-owned
/// tasks stay put, matching the desktop board.
struct MobileTaskDraggable: ViewModifier {
    let task: ProjectTask
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if #available(iOS 27.0, *), isEnabled {
            // Register the card itself as the source, so SwiftUI lifts this
            // row rather than using the enclosing column as its preview.
            content
                .draggable(containerItemID: task.id)
                .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 10))
        } else if #available(iOS 27.0, *) {
            content.moveDisabled(true)
        } else if isEnabled {
            content.draggable(task.id.uuidString) {
                Text(task.title.isEmpty ? String(localized: "Untitled Task") : task.title)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        } else {
            content
        }
    }
}

enum MobileTaskRoute: Hashable {
    case board(UUID)
    case task(projectID: UUID, taskID: UUID)
    case story(projectID: UUID, storyID: UUID)
}

/// Registers the task board's push destinations on the enclosing stack.
/// Applied once per stack: by the dashboard root, or by a board presented in
/// its own sheet.
struct MobileTaskDestinations: ViewModifier {
    var isEnabled = true
    let onOpenChat: (String) -> Void

    func body(content: Content) -> some View {
        if isEnabled {
            content.navigationDestination(for: MobileTaskRoute.self) { route in
                switch route {
                case .board(let projectID):
                    MobileTaskBoardView(projectID: projectID, onOpenChat: onOpenChat, isModal: false)
                case .task(let projectID, let taskID):
                    MobileTaskDetailView(projectID: projectID, taskID: taskID, onOpenChat: onOpenChat)
                case .story(let projectID, let storyID):
                    MobileStoryDetailView(projectID: projectID, storyID: storyID, onOpenChat: onOpenChat)
                }
            }
        } else {
            content
        }
    }
}

/// Presents card details locally so dashboard navigation cannot intercept a card tap.
/// A task this phone ran on a paired Mac opens its session there instead while it runs.
struct MobileTaskDetailButton<Label: View>: View {
    @EnvironmentObject private var state: MobileAppState
    let route: MobileTaskRoute
    let onOpenChat: (String) -> Void
    @ViewBuilder let label: () -> Label

    @State private var showingDetail = false
    @State private var pendingChat: String?
    @State private var openingOn: String?
    @State private var errorMessage: String?

    private var runningTask: ProjectTask? {
        guard case .task(let projectID, let taskID) = route,
              let task = state.taskBoard(for: projectID).tasks.first(where: { $0.id == taskID }),
              state.activeTaskRunLink(for: task) != nil
        else { return nil }
        return task
    }

    var body: some View {
        Button {
            MobileHaptics.buttonTap()
            if let task = runningTask {
                openRunSession(task)
            } else {
                showingDetail = true
            }
        } label: {
            label()
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(openingOn != nil)
        .overlay(alignment: .trailing) {
            if let openingOn {
                ProgressView("Opening on \(openingOn)…")
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
            }
        }
        .mobileTaskErrorAlert($errorMessage)
        .sheet(isPresented: $showingDetail, onDismiss: {
            if let sessionID = pendingChat {
                pendingChat = nil
                onOpenChat(sessionID)
            }
        }) {
            NavigationStack {
                Group {
                    switch route {
                    case .task(let projectID, let taskID):
                        MobileTaskDetailView(projectID: projectID, taskID: taskID, onOpenChat: openChat)
                    case .story(let projectID, let storyID):
                        MobileStoryDetailView(projectID: projectID, storyID: storyID, onOpenChat: openChat)
                    case .board(let projectID):
                        MobileTaskBoardView(projectID: projectID, onOpenChat: openChat, isModal: false)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            MobileHaptics.buttonTap()
                            showingDetail = false
                        }
                        .accessibilityIdentifier("task-detail-done")
                    }
                }
            }
            .mobileSheetPresentation([.large])
        }
    }

    private func openChat(_ sessionID: String) {
        pendingChat = sessionID
        showingDetail = false
    }

    /// Switches to the Mac running `task` and opens its session.
    private func openRunSession(_ task: ProjectTask) {
        openingOn = state.activeTaskRunLink(for: task)?.desktopName
        let isCloud = state.usesCloudTasks
        Task {
            defer { openingOn = nil }
            do {
                let session = try await state.openTaskRunSession(for: task)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                if isCloud {
                    // Cloud hosts open the Mac's workspace from a deep link.
                    state.openThreadFromNotification(sessionID: session.sessionID, projectID: session.projectID)
                }
                onOpenChat(session.sessionID)
            } catch {
                errorMessage = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}

// MARK: - Shared task actions

/// Shared task actions. Native reorderable cards use an explicit menu;
/// other rows retain their long-press menu and swipe actions.
struct MobileTaskActions: ViewModifier {
    @EnvironmentObject private var state: MobileAppState
    let task: ProjectTask
    let board: TaskBoard
    let onEdit: () -> Void
    let onOpenChat: (String) -> Void
    let onError: (String) -> Void
    var nativeReordering = false

    @State private var runRequest: MobileTaskRunRequest?

    private var isLocked: Bool { board.isStatusLocked(task) }

    private var canRun: Bool {
        guard let chatColumn = board.firstChatColumn else { return false }
        return state.moveStartsRun(task, to: chatColumn.id)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if !state.canEditCard(task) {
            content
        } else {
            taskContent(content)
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if canRun {
                        Button {
                            requestRun()
                        } label: {
                            Label("Run", systemImage: "play.fill")
                        }
                        .tint(.green)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        perform { try await state.deleteTask(task) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button(action: onEdit) {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(.blue)
                }
                .mobileTaskRunDevicePicker($runRequest)
        }
    }

    @ViewBuilder
    private func taskContent(_ content: Content) -> some View {
        if #available(iOS 27.0, *), nativeReordering {
            // Reserve long press for native reordering; the same actions
            // remain available through an explicit card menu.
            content.overlay(alignment: .topTrailing) {
                Menu { menuActions } label: {
                    Image(systemName: "ellipsis")
                        .padding(10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Task Actions")
                .accessibilityIdentifier("task-actions-\(task.id)")
            }
        } else {
            content.contextMenu { menuActions }
        }
    }

    @ViewBuilder
    private var menuActions: some View {
        Button(action: onEdit) {
            Label("Edit", systemImage: "pencil")
        }
        if let sessionID = state.taskSessionID(task) {
            Button {
                onOpenChat(sessionID)
            } label: {
                Label("Open Chat", systemImage: "bubble.left.and.text.bubble.right")
            }
        }
        if canRun {
            Button {
                requestRun()
            } label: {
                Label("Run with Agent", systemImage: "play")
            }
        }
        Menu {
            ForEach(board.effectiveColumns) { column in
                Button {
                    move(to: column.id)
                } label: {
                    Label(column.name, systemImage: column.systemImage)
                }
                .disabled(column.id == board.resolvedStatus(of: task))
            }
        } label: {
            Label("Move To", systemImage: "arrow.right.square")
        }
        .disabled(isLocked)
        Divider()
        Button(role: .destructive) {
            perform { try await state.deleteTask(task) }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func requestRun() {
        guard let chatColumn = board.firstChatColumn else { return }
        move(to: chatColumn.id)
    }

    /// Moves into a run column only after the Mac that runs it is picked.
    private func move(to status: TaskStatus) {
        if state.moveStartsRun(task, to: status) {
            runRequest = MobileTaskRunRequest(task: task, status: status)
        } else {
            perform { try await state.moveTask(task, to: status) }
        }
    }

    private func perform(_ operation: @escaping () async throws -> Void) {
        Task {
            do {
                try await operation()
            } catch {
                onError(error.localizedDescription)
            }
        }
    }
}

extension View {
    /// Presents a task-board error as an alert while `message` is non-nil.
    func mobileTaskErrorAlert(_ message: Binding<String?>) -> some View {
        alert(
            "Task Board Error",
            isPresented: Binding(
                get: { message.wrappedValue != nil },
                set: { if !$0 { message.wrappedValue = nil } }
            )
        ) {
            Button("OK", role: .cancel) { message.wrappedValue = nil }
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}

