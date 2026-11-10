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
                .mobileDeliberateDragLift()
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
            .mobileDeliberateDragLift()
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
                Group {
                    switch route {
                    case .board(let projectID):
                        MobileTaskBoardView(projectID: projectID, onOpenChat: onOpenChat, isModal: false)
                    case .task(let projectID, let taskID):
                        MobileTaskDetailView(projectID: projectID, taskID: taskID, onOpenChat: onOpenChat)
                    case .story(let projectID, let storyID):
                        MobileStoryDetailView(projectID: projectID, storyID: storyID, onOpenChat: onOpenChat)
                    }
                }
                .toolbar { RemoteWorkspaceCloseToolbar(regularWidthOnly: true) }
            }
        } else {
            content
        }
    }
}

/// Presents card details locally so dashboard navigation cannot intercept a card tap.
/// Every task opens the same detail sheet, including active and reviewed tasks.
struct MobileTaskDetailButton<Label: View>: View {
    let route: MobileTaskRoute
    let onOpenChat: (String) -> Void
    @ViewBuilder let label: () -> Label

    @State private var showingDetail = false
    @State private var pendingChat: String?

    var body: some View {
        MobileRowButton {
            showingDetail = true
        } label: {
            label()
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
}

// MARK: - Shared task actions

/// Shared task actions. Native reorderable cards use an explicit menu;
/// other rows retain their long-press menu and swipe actions.
/// The dropdown that holds a card's actions. Cards have no swipe actions, so
/// long press stays free for reordering and swipes stay free for scrolling.
struct MobileCardMenu<Actions: View>: View {
    let label: LocalizedStringKey
    let identifier: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        Menu {
            actions()
        } label: {
            Image(systemName: "ellipsis")
                .padding(10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

struct MobileTaskActions: ViewModifier {
    @EnvironmentObject private var state: MobileAppState
    let task: ProjectTask
    let board: TaskBoard
    let onEdit: () -> Void
    let onOpenChat: (String) -> Void
    let onError: (String) -> Void

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
            content
                .overlay(alignment: .topTrailing) {
                    MobileCardMenu(label: "Task Actions", identifier: "task-actions-\(task.id)") {
                        menuActions
                    }
                }
                .mobileTaskRunDevicePicker($runRequest)
        }
    }

    @ViewBuilder
    private var menuActions: some View {
        Button(action: onEdit) {
            Label("Edit", systemImage: "pencil")
        }
        Divider()
        if state.taskSessionID(task) != nil || canRun {
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
            Divider()
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
    /// Keeps a card's content clear of its `MobileCardMenu`.
    func mobileCardMenuInset() -> some View {
        padding(.trailing, 32)
    }

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

