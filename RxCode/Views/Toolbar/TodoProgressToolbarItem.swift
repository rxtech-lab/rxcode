import SwiftUI
import RxCodeCore
import RxCodeChatKit

/// Toolbar pill rendering the current session's todo-style progress.
///
/// Hidden until the active session emits progress. The most recent todo list
/// can come from in-memory messages or a persisted update.
struct TodoProgressToolbarItem: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @State private var showPopover = false

    private var sessionKey: String {
        windowState.currentSessionId ?? windowState.newSessionKey
    }

    var body: some View {
        if let todos = appState.latestTodoSnapshot(forSessionId: sessionKey)?.items, !todos.isEmpty {
            let done = todos.filter { $0.status == .completed }.count
            let inProgress = todos.contains { $0.status == .inProgress }
            Button {
                showPopover.toggle()
            } label: {
                TodoProgressPill(done: done, total: todos.count, inProgress: inProgress)
            }
            .buttonStyle(.plain)
            .help("Todos (\(done)/\(todos.count))")
            .accessibilityIdentifier("todo-progress-button")
            .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                TodoListPopoverView(todos: todos)
                    .accessibilityIdentifier("todo-progress-popover")
            }
        }
    }
}
