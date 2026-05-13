import SwiftUI
import ClarcCore
import ClarcChatKit

/// Toolbar pill rendering the current session's TodoWrite progress.
///
/// Hidden until the active CLI session emits at least one `TodoWrite` tool
/// call. Tap toggles a popover listing each todo with status icon.
struct TodoProgressToolbarItem: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @State private var showPopover = false

    private var todos: [TodoItem]? {
        let key = windowState.currentSessionId ?? windowState.newSessionKey
        guard let messages = appState.sessionStates[key]?.messages else { return nil }
        return TodoExtractor.latest(in: messages)
    }

    var body: some View {
        if let todos, !todos.isEmpty {
            let done = todos.filter { $0.status == .completed }.count
            let inProgress = todos.contains { $0.status == .inProgress }
            Button {
                showPopover.toggle()
            } label: {
                TodoProgressRing(done: done, total: todos.count, inProgress: inProgress)
                    .frame(width: 16, height: 16)
                    .padding(2)
            }
            .buttonStyle(.plain)
            .help("Todos (\(done)/\(todos.count))")
            .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                TodoListPopoverView(todos: todos)
            }
        }
    }
}
