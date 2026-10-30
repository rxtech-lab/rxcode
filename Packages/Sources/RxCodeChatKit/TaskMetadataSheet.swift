import RxCodeCore
import SwiftUI

/// Shared project metadata management, with a dedicated create/edit sheet.
public struct TaskMetadataSheet: View {
    @Environment(\.dismiss) private var dismiss
    public let board: TaskBoard
    public let field: TaskMetadataEdit.Field
    public let onSave: (TaskMetadataEdit) async throws -> Void
    @State private var editor: Editor?

    private struct Editor: Identifiable {
        let id = UUID()
        var original: String?
    }

    public init(board: TaskBoard, field: TaskMetadataEdit.Field,
                onSave: @escaping (TaskMetadataEdit) async throws -> Void) {
        self.board = board
        self.field = field
        self.onSave = onSave
    }

    public var body: some View {
        NavigationStack {
            List(field.values(in: board), id: \.self) { name in
                Button { editor = Editor(original: name) } label: {
                    HStack {
                        Text(name).foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "pencil").foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if field.values(in: board).isEmpty {
                    ContentUnavailableView("No values yet", systemImage: "tag", description: Text("Use Add to create a project value."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(Text(field.title))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Add", systemImage: "plus") { editor = Editor() }
                }
            }
        }
        #if os(macOS)
        .frame(width: 480, height: 600)
        #endif
        #if !os(macOS)
        .sensoryFeedback(.selection, trigger: editor?.id)
        #endif
        .sheet(item: $editor) { item in
            TaskMetadataEditor(field: field, original: item.original, onSave: onSave)
        }
    }
}

private struct TaskMetadataEditor: View {
    @Environment(\.dismiss) private var dismiss
    let field: TaskMetadataEdit.Field
    let original: String?
    let onSave: (TaskMetadataEdit) async throws -> Void
    @State private var name = ""
    @State private var saving = false
    @State private var error: String?
    @State private var successCount = 0

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Section {
                    Text("Changes apply to this project's tasks, stories and saved views immediately.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(original == nil ? "Create Value" : "Edit Value")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .disabled(saving)
            .overlay {
                if saving {
                    ZStack {
                        Color.black.opacity(0.15).ignoresSafeArea()
                        ProgressView("Saving…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
        #if os(macOS)
        .frame(width: 440, height: 360)
        #else
        .sensoryFeedback(.success, trigger: successCount)
        .sensoryFeedback(.error, trigger: error)
        #endif
        .interactiveDismissDisabled(saving)
        .onAppear { name = original ?? "" }
        .alert("Unable to Save", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func save() {
        saving = true
        Task { @MainActor in
            defer { saving = false }
            do {
                try await onSave(TaskMetadataEdit(field: field, original: original, name: name))
                successCount += 1
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
