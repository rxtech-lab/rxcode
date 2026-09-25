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
/// and filters. Edits a draft and commits on Save.
struct TaskViewFormSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let payload: TaskViewEditorPayload
    let onSave: (TaskSavedView) -> Void

    @State private var draft = TaskSavedView(name: "")

    private var board: TaskBoard { appState.taskBoard(for: payload.projectId) }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.visibleStatuses.isEmpty
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
                    ForEach(TaskStatus.allCases, id: \.self) { status in
                        Toggle(isOn: statusBinding(status)) {
                            Label {
                                Text(status.displayName)
                            } icon: {
                                TaskStatusIcon(status: status)
                            }
                        }
                    }
                } header: {
                    Text("Statuses")
                } footer: {
                    Text("Board columns, or the rows a table shows.")
                }

                Section("Filters") {
                    Picker("Story", selection: $draft.storyId) {
                        Text("Any story").tag(UUID?.none)
                        ForEach(board.stories) { story in
                            Text(story.title).tag(UUID?.some(story.id))
                        }
                    }

                    Picker("Version", selection: versionBinding) {
                        Text("Any version").tag("")
                        ForEach(board.allVersions, id: \.self) { version in
                            Text(version).tag(version)
                        }
                    }
                }

                Section {
                    if board.allTags.isEmpty {
                        Text("No tags on this project yet.")
                            .foregroundStyle(ClaudeTheme.textTertiary)
                    } else {
                        ForEach(board.allTags, id: \.self) { tag in
                            Toggle(tag, isOn: tagBinding(tag))
                        }
                    }
                } header: {
                    Text("Tags")
                } footer: {
                    Text("Tasks must carry every selected tag.")
                }
            }
            .formStyle(.grouped)

            footer
        }
        .frame(width: 480, height: 560)
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

    /// Toggling reads through `visibleStatuses` so "all" (the empty list) turns
    /// into an explicit list the first time a column is switched off.
    private func statusBinding(_ status: TaskStatus) -> Binding<Bool> {
        Binding(
            get: { draft.visibleStatuses.contains(status) },
            set: { isOn in
                var set = Set(draft.visibleStatuses)
                if isOn { set.insert(status) } else { set.remove(status) }
                draft.statuses = set.count == TaskStatus.allCases.count
                    ? []
                    : TaskStatus.allCases.filter(set.contains)
            }
        )
    }

    private func tagBinding(_ tag: String) -> Binding<Bool> {
        Binding(
            get: { draft.tags.contains(tag) },
            set: { isOn in
                if isOn {
                    if !draft.tags.contains(tag) { draft.tags.append(tag) }
                } else {
                    draft.tags.removeAll { $0 == tag }
                }
            }
        )
    }

    private var versionBinding: Binding<String> {
        Binding(
            get: { draft.version ?? "" },
            set: { draft.version = $0.isEmpty ? nil : $0 }
        )
    }

    private func save() {
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.upsertSavedView(draft, projectId: payload.projectId)
        onSave(draft)
        dismiss()
    }
}
