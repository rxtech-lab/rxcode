import RxCodeCore
import SwiftUI

/// What the column editor is creating or editing.
struct TaskColumnEditorPayload: Identifiable {
    let projectId: UUID
    var column: TaskColumn
    let isNew: Bool

    var id: String { column.id.rawValue }
}

/// Create/edit sheet for one board column: its name, look, and the triggers
/// that make it behave like a hook — starting a chat when a card is dropped in,
/// and routing a card elsewhere when its thread stops or is reviewed. Edits a
/// draft and commits on Save.
struct TaskColumnFormSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let payload: TaskColumnEditorPayload

    @State private var draft = TaskColumn(name: "")
    @State private var confirmingDelete = false
    @State private var deleteDestination: TaskStatus?

    private var board: TaskBoard { appState.taskBoard(for: payload.projectId) }

    /// Every other column, as trigger targets.
    private var otherColumns: [TaskColumn] {
        board.effectiveColumns.filter { $0.id != draft.id }
    }

    private var taskCount: Int {
        board.tasks(in: draft.id).count
    }

    /// A chat column must hand its cards somewhere when the turn ends, or they
    /// would stay agent-locked in it.
    private var missingStopTarget: Bool {
        guard draft.triggersChat else { return false }
        guard let target = draft.onSessionStop else { return true }
        return board.column(for: target).triggersChat
    }

    private var deleteTargetName: String {
        board.column(for: deleteDestination ?? otherColumns.first?.id ?? draft.id).name
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !missingStopTarget
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Column") {
                    TextField("Name", text: $draft.name, prompt: Text("e.g. QA"))
                    TextField("Description", text: $draft.details, prompt: Text("Optional"))
                    ColorPicker(
                        "Color",
                        selection: Binding(
                            get: { draft.tint },
                            set: { draft.colorHex = $0.hexString }
                        ),
                        supportsOpacity: false
                    )
                    Picker("Icon", selection: $draft.systemImage) {
                        ForEach(Self.symbols, id: \.self) { symbol in
                            Label(symbol, systemImage: symbol)
                                .labelStyle(.iconOnly)
                                .tag(symbol)
                        }
                    }
                    Toggle("Counts as done", isOn: $draft.countsAsDone)
                }

                Section {
                    Toggle("Trigger chat", isOn: $draft.triggersChat)
                } header: {
                    Text("Chat")
                } footer: {
                    Text("Dropping a card here starts a chat with its assigned agent. The card stays here, locked, until the chat stops.")
                }

                Section {
                    ForEach(TaskTriggerEvent.allCases, id: \.self) { event in
                        Picker(selection: targetBinding(event)) {
                            Text("Do nothing").tag(TaskStatus?.none)
                            ForEach(otherColumns) { column in
                                Label {
                                    Text(column.name)
                                } icon: {
                                    TaskStatusIcon(column: column)
                                }
                                .tag(TaskStatus?.some(column.id))
                            }
                        } label: {
                            Label {
                                Text(event.displayName)
                            } icon: {
                                Image(systemName: event.systemImage)
                            }
                        }
                    }
                } header: {
                    Text("Triggers")
                } footer: {
                    if missingStopTarget {
                        Text("A column that triggers a chat needs an “On session stop” column that doesn't trigger a chat itself.")
                            .foregroundStyle(ClaudeTheme.statusError)
                    } else {
                        Text("Where a card in this column moves when its chat stops, or when a code review of that chat starts, passes or fails.")
                    }
                }
            }
            .formStyle(.grouped)

            footer
        }
        .frame(width: 480, height: 620)
        .onAppear { draft = payload.column }
        .confirmationDialog(
            "Delete column “\(draft.name)”?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                appState.deleteColumn(draft, projectId: payload.projectId, moveTasksTo: deleteDestination)
                dismiss()
            }
        } message: {
            if taskCount > 0 {
                Text("Its \(taskCount) task(s) move to “\(deleteTargetName)”, and triggers that point here point there instead.")
            } else {
                Text("Triggers that point here will point to “\(deleteTargetName)” instead.")
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !payload.isNew {
                Button("Delete…", role: .destructive) { confirmingDelete = true }
                    .disabled(otherColumns.isEmpty)
                if taskCount > 0, !otherColumns.isEmpty {
                    Picker("Move tasks to", selection: $deleteDestination) {
                        ForEach(otherColumns) { column in
                            Text(column.name).tag(TaskStatus?.some(column.id))
                        }
                    }
                    .fixedSize()
                    .onAppear {
                        if deleteDestination == nil { deleteDestination = otherColumns.first?.id }
                    }
                }
            }
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

    private func targetBinding(_ event: TaskTriggerEvent) -> Binding<TaskStatus?> {
        Binding(
            get: { draft.target(for: event) },
            set: { draft.setTarget($0, for: event) }
        )
    }

    private func save() {
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.upsertColumn(draft, projectId: payload.projectId)
        dismiss()
    }

    /// Column glyphs offered in the icon picker.
    static let symbols = [
        "circle", "tray", "circle.dotted.circle", "eye.circle", "checkmark.circle.fill",
        "bolt.circle", "hammer.circle", "flag.circle", "exclamationmark.circle",
        "pause.circle", "archivebox", "testtube.2", "shippingbox", "sparkles",
    ]
}
