import SwiftUI
import ClarcCore

// MARK: - Todo Progress Pill

public struct TodoProgressPill: View {
    public let done: Int
    public let total: Int
    public let inProgress: Bool
    @State private var isHovering = false

    public init(done: Int, total: Int, inProgress: Bool) {
        self.done = done
        self.total = total
        self.inProgress = inProgress
    }

    private var isComplete: Bool { total > 0 && done == total }

    private var accent: Color {
        if isComplete { return ClaudeTheme.statusSuccess }
        if inProgress { return ClaudeTheme.accent }
        return ClaudeTheme.textSecondary
    }

    private var iconName: String {
        if isComplete { return "checkmark.circle.fill" }
        if inProgress { return "circle.dotted" }
        return "checklist"
    }

    public var body: some View {
        HStack(spacing: 5) {
            Image(systemName: iconName)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 12, height: 12)

            Text("\(done)/\(total)")
                .font(.system(size: ClaudeTheme.size(11), weight: .medium, design: .monospaced))
                .foregroundStyle(ClaudeTheme.textPrimary)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(isHovering ? ClaudeTheme.surfaceSecondary : ClaudeTheme.surfaceTertiary.opacity(0.6))
        )
        .overlay(
            Capsule()
                .strokeBorder(ClaudeTheme.borderSubtle, lineWidth: 0.5)
        )
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
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
