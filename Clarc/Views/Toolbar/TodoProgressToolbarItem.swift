import SwiftUI
import ClarcCore
import ClarcChatKit

/// Toolbar pill rendering the current session's TodoWrite progress.
///
/// Hidden until the active CLI session emits at least one `TodoWrite` tool
/// call. Live updates come from in-memory messages; a SwiftData-backed
/// snapshot fills in for cold opens before message replay completes. Tap
/// toggles a popover listing each todo with status icon.
struct TodoProgressToolbarItem: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @State private var showPopover = false

    private var sessionKey: String {
        windowState.currentSessionId ?? windowState.newSessionKey
    }

    private var todos: [TodoItem]? {
        if let messages = appState.sessionStates[sessionKey]?.messages,
           let live = TodoExtractor.latest(in: messages) {
            return live
        }
        return appState.threadStore.fetchTodoSnapshot(sessionId: sessionKey)?.items
    }

    var body: some View {
        if let todos, !todos.isEmpty {
            let done = todos.filter { $0.status == .completed }.count
            let inProgress = todos.contains { $0.status == .inProgress }
            Button {
                showPopover.toggle()
            } label: {
                TodoProgressPill(done: done, total: todos.count, inProgress: inProgress)
            }
            .buttonStyle(.plain)
            .help("Todos (\(done)/\(todos.count))")
            .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                TodoListPopoverView(todos: todos)
            }
        }
    }
}
