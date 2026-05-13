import SwiftUI
import ClarcCore

// MARK: - Todo Progress Ring

public struct TodoProgressRing: View {
    public let done: Int
    public let total: Int
    public let inProgress: Bool

    public init(done: Int, total: Int, inProgress: Bool) {
        self.done = done
        self.total = total
        self.inProgress = inProgress
    }

    private var progress: Double {
        guard total > 0 else { return 0 }
        return Double(done) / Double(total)
    }

    private var arcColor: Color {
        if total > 0 && done == total { return ClaudeTheme.statusSuccess }
        return ClaudeTheme.accent
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(ClaudeTheme.borderSubtle, lineWidth: 2)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(arcColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.25), value: progress)
            if inProgress && done < total {
                Circle()
                    .fill(ClaudeTheme.accent)
                    .frame(width: 3, height: 3)
            }
        }
    }
}

// MARK: - Todo List Popover

public struct TodoListPopoverView: View {
    public let todos: [TodoItem]

    public init(todos: [TodoItem]) {
        self.todos = todos
    }

    private var doneCount: Int { todos.filter { $0.status == .completed }.count }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ClaudeTheme.borderSubtle.frame(height: 0.5)
            if todos.isEmpty {
                Text("No todos", bundle: .module)
                    .font(.system(size: ClaudeTheme.size(12)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .padding(12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(todos) { todo in
                            row(todo)
                        }
                    }
                    .padding(12)
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "checklist")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(ClaudeTheme.textSecondary)
            Text("Todos", bundle: .module)
                .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textPrimary)
            Spacer()
            Text("\(doneCount)/\(todos.count)")
                .font(.system(size: ClaudeTheme.size(11), design: .monospaced))
                .foregroundStyle(ClaudeTheme.textTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func row(_ todo: TodoItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            statusIcon(todo.status)
                .font(.system(size: ClaudeTheme.size(13)))
                .frame(width: 16)
                .padding(.top, 1)
            Text(label(for: todo))
                .font(.system(size: ClaudeTheme.size(12)))
                .foregroundStyle(textColor(todo.status))
                .strikethrough(todo.status == .completed, color: ClaudeTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func statusIcon(_ status: TodoItem.Status) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(ClaudeTheme.textTertiary)
        case .inProgress:
            Image(systemName: "arrow.right.circle.fill")
                .foregroundStyle(ClaudeTheme.accent)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(ClaudeTheme.statusSuccess)
        }
    }

    private func label(for todo: TodoItem) -> String {
        todo.status == .inProgress && !todo.activeForm.isEmpty ? todo.activeForm : todo.content
    }

    private func textColor(_ status: TodoItem.Status) -> Color {
        switch status {
        case .pending: return ClaudeTheme.textSecondary
        case .inProgress: return ClaudeTheme.textPrimary
        case .completed: return ClaudeTheme.textTertiary
        }
    }
}
