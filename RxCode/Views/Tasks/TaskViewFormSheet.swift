import RxCodeCore
import SwiftUI

/// What the view editor is creating or editing.
struct TaskViewEditorPayload: Identifiable {
    let projectId: UUID
    var view: TaskSavedView
    let isNew: Bool

    var id: UUID { view.id }
}

/// Create/edit sheet for a project view tab: its name, layout, visible columns
/// and filters, including an agent-written Swift filter. Edits a draft and
/// commits on Save.
struct TaskViewFormSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let payload: TaskViewEditorPayload
    let onSave: (TaskSavedView) -> Void

    @State private var draft = TaskSavedView(name: "")

    private var board: TaskBoard { appState.taskBoard(for: payload.projectId) }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("View") {
                    TextField("Name", text: $draft.name, prompt: Text("e.g. Priority board"))
                    Picker("Layout", selection: $draft.layout) {
                        ForEach(TaskViewLayout.allCases, id: \.self) { layout in
                            Label {
                                Text(layout.displayName)
                            } icon: {
                                Image(systemName: layout.systemImage)
                            }
                            .tag(layout)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    ForEach(board.effectiveColumns) { column in
                        Toggle(isOn: statusBinding(column.id)) {
                            Label {
                                Text(column.name)
                            } icon: {
                                TaskStatusIcon(column: column)
                            }
                        }
                    }
                } header: {
                    Text("Statuses")
                } footer: {
                    Text("Board columns, or the rows a table shows. At least one stays visible.")
                }

                filterSection(
                    "Stories",
                    empty: "No stories on this project yet.",
                    footer: "Tasks in any selected story.",
                    options: board.stories.map { ($0.id, $0.title) },
                    selection: \.storyIds
                )

                filterSection(
                    "Versions",
                    empty: "No versions on this project yet.",
                    footer: "Tasks targeting any selected version.",
                    options: listed(board.allVersions, draft.versions),
                    selection: \.versions
                )

                filterSection(
                    "Milestones",
                    empty: "No milestones on this project yet.",
                    footer: "Tasks in any selected milestone.",
                    options: listed(board.allMilestones, draft.milestones),
                    selection: \.milestones
                )

                filterSection(
                    "Tags",
                    empty: "No tags on this project yet.",
                    footer: "Tasks must carry every selected tag.",
                    options: listed(board.allTags, draft.tags),
                    selection: \.tags
                )

                TaskFilterScriptSection(projectId: payload.projectId, script: $draft.filterScript)
            }
            .formStyle(.grouped)

            footer
        }
        .frame(width: 480, height: 640)
        .onAppear { draft = payload.view }
    }

    private var footer: some View {
        HStack {
            Text(payload.isNew ? "New View" : "Edit View")
                .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textSecondary)
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { save() }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Bindings

    /// Toggling reads through `visibleColumns` so "all" (the empty list) turns
    /// into an explicit list the first time a column is switched off. The last
    /// visible column can't be switched off.
    private func statusBinding(_ status: TaskStatus) -> Binding<Bool> {
        let columns = board.effectiveColumns
        return Binding(
            get: { draft.visibleColumns(in: columns).contains { $0.id == status } },
            set: { isOn in
                var set = Set(draft.visibleColumns(in: columns).map(\.id))
                if isOn { set.insert(status) } else { set.remove(status) }
                guard !set.isEmpty else { return }
                draft.statuses = set.count == columns.count
                    ? []
                    : columns.map(\.id).filter(set.contains)
            }
        )
    }

    /// One multi-select filter condition, matched as "any of" except tags.
    private func filterSection<Value: Hashable>(
        _ title: LocalizedStringKey,
        empty: LocalizedStringKey,
        footer: LocalizedStringKey,
        options: [(Value, String)],
        selection: WritableKeyPath<TaskSavedView, [Value]>
    ) -> some View {
        Section {
            if options.isEmpty {
                Text(empty)
                    .foregroundStyle(ClaudeTheme.textTertiary)
            } else {
                ForEach(options, id: \.0) { value, label in
                    Toggle(label, isOn: selectionBinding(value, in: selection))
                }
            }
        } header: {
            Text(title)
        } footer: {
            Text(footer)
        }
    }

    /// The board's values plus any selected value no item uses anymore, so a
    /// stale selection stays visible and can be switched off.
    private func listed(_ values: [String], _ selected: [String]) -> [(String, String)] {
        (values + selected.filter { !values.contains($0) }).map { ($0, $0) }
    }

    private func selectionBinding<Value: Hashable>(
        _ value: Value,
        in selection: WritableKeyPath<TaskSavedView, [Value]>
    ) -> Binding<Bool> {
        Binding(
            get: { draft[keyPath: selection].contains(value) },
            set: { isOn in
                if isOn {
                    if !draft[keyPath: selection].contains(value) { draft[keyPath: selection].append(value) }
                } else {
                    draft[keyPath: selection].removeAll { $0 == value }
                }
            }
        )
    }

    private func save() {
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !draft.hasFilterScript { draft.filterScript = nil }
        // Deleted stories can't be shown or unselected, so they don't persist.
        draft.storyIds.removeAll { board.story(id: $0) == nil }
        appState.upsertSavedView(draft, projectId: payload.projectId)
        onSave(draft)
        dismiss()
    }
}
