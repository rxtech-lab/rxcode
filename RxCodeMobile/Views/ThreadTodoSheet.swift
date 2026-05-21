import Combine
import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

// MARK: - Todo Progress Indicator

/// Compact progress ring shown beside the navigation title while a thread has
/// todos. Mirrors the desktop `TodoProgressPill`: a determinate ring filling as
/// todos complete, accented while work is in progress and green once done.
struct MobileTodoProgressIndicator: View {
    let done: Int
    let total: Int
    let inProgress: Bool

    private var isComplete: Bool { total > 0 && done == total }

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(done) / Double(total)))
    }

    private var accent: Color {
        if isComplete { return ClaudeTheme.statusSuccess }
        if inProgress { return ClaudeTheme.accent }
        return .secondary
    }

    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                Circle()
                    .stroke(accent.opacity(0.22), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.25), value: fraction)
            }
            .frame(width: 15, height: 15)

            Text("\(done)/\(total)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.secondary.opacity(0.14)))
        .contentShape(Capsule())
    }
}

// MARK: - Thread Todo Sheet

/// Bottom sheet listing the thread's todo items and its generated summary,
/// mirroring the desktop's todo popover. Opened from the navigation-title
/// progress indicator.
struct ThreadTodoSheet: View {
    let threadTitle: String
    let todos: [TodoItem]
    let summary: MobileThreadSummary?
    @Environment(\.dismiss) private var dismiss

    private var doneCount: Int {
        todos.filter { $0.status == .completed }.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    titleHeader
                    if !todos.isEmpty {
                        todoSection
                    }
                    summarySection
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(todos.isEmpty ? "Thread Summary" : "Todos & Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Title header

    private var titleHeader: some View {
        Text(threadTitle)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Todo section

    @ViewBuilder
    private var todoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Todos")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text("\(doneCount)/\(todos.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            if todos.isEmpty {
                Text("No todos for this thread.")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .italic()
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(todos) { todo in
                        todoRow(todo)
                    }
                }
            }
        }
    }

    private func todoRow(_ todo: TodoItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon(todo.status)
                .font(.system(size: 17))
                .frame(width: 22)
            Text(label(for: todo))
                .font(.callout)
                .foregroundStyle(textColor(todo.status))
                .strikethrough(todo.status == .completed, color: .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func statusIcon(_ status: TodoItem.Status) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
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
        case .pending: return .secondary
        case .inProgress: return .primary
        case .completed: return .secondary
        }
    }

    // MARK: Summary section

    @ViewBuilder
    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "text.alignleft")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Summary")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }

            if let summary, !summary.summary.isEmpty {
                ChatTextContentView(
                    markdown: summary.summary,
                    size: 15,
                    color: .primary,
                    lineSpacing: 3
                )
            } else {
                Text("No summary yet. A summary is generated once the thread finishes a turn on your Mac.")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .italic()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
