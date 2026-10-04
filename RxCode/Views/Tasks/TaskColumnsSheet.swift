import RxCodeCore
import SwiftUI

/// Manages one project's board columns: reorder by dragging, open a column to
/// edit its triggers, or add a new one. Reordering applies immediately, like
/// the fields manager; each column's details are edited in
/// `TaskColumnFormSheet`.
struct TaskColumnsSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let projectId: UUID

    @State private var editor: TaskColumnEditorPayload?

    private var board: TaskBoard { appState.taskBoard(for: projectId) }

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    ForEach(board.effectiveColumns) { column in
                        row(column)
                    }
                    .onMove(perform: move)
                } header: {
                    Text("Columns")
                } footer: {
                    Text("Drag to reorder. New tasks start in the first column.")
                }
            }

            HStack {
                Button {
                    editor = TaskColumnEditorPayload(
                        projectId: projectId,
                        column: TaskColumn(
                            name: "",
                            colorHex: TaskLabel.palette[board.effectiveColumns.count % TaskLabel.palette.count]
                        ),
                        isNew: true
                    )
                } label: {
                    Label("Add Column", systemImage: "plus")
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 520, height: 520)
        .sheet(item: $editor) { payload in
            TaskColumnFormSheet(payload: payload)
                .environment(appState)
        }
    }

    private func row(_ column: TaskColumn) -> some View {
        Button {
            editor = TaskColumnEditorPayload(projectId: projectId, column: column, isNew: false)
        } label: {
            HStack(spacing: 10) {
                TaskStatusIcon(column: column, size: 13)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(column.name)
                            .foregroundStyle(ClaudeTheme.textPrimary)
                        if column.triggersChat {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: ClaudeTheme.size(10)))
                                .foregroundStyle(ClaudeTheme.statusWarning)
                        }
                    }
                    let summary = board.triggerSummary(for: column)
                    if !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: ClaudeTheme.size(11)))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                TaskCountBadge(count: board.tasks(in: column.id).count)
                Image(systemName: "chevron.right")
                    .font(.system(size: ClaudeTheme.size(9), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func move(from source: IndexSet, to destination: Int) {
        var order = board.effectiveColumns.map(\.id)
        order.move(fromOffsets: source, toOffset: destination)
        appState.reorderColumns(order, projectId: projectId)
    }
}
