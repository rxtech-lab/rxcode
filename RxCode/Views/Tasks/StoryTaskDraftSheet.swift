import PDFKit
import RxCodeCore
import SwiftUI

/// Adds or edits one task of a generated story outline. Works on a copy, so
/// Cancel leaves the outline as it was.
struct StoryTaskDraftSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State var draft: TaskFormSheet.StoryTaskDraft
    let isNew: Bool
    /// Other drafts this one may start after without making a cycle.
    let startsAfterOptions: [TaskFormSheet.StoryTaskDraft]
    let onSave: (TaskFormSheet.StoryTaskDraft) -> Void

    private var canSave: Bool {
        !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(isNew ? "New Task" : "Edit Task") {
                    TextField("Title", text: $draft.title, prompt: Text("What needs doing?"))
                        .multilineTextAlignment(.leading)
                        .accessibilityIdentifier("story-draft-task-title")
                    TextField("Details", text: $draft.details, prompt: Text("Task details"), axis: .vertical)
                        .multilineTextAlignment(.leading)
                        .lineLimit(4...12)
                        .accessibilityIdentifier("story-draft-task-details")
                    Picker("Size", selection: $draft.size) {
                        Text("None").tag(TaskSize?.none)
                        ForEach(TaskSize.allCases, id: \.self) { size in
                            Text("\(size.shortName) · \(size.displayNameText)").tag(TaskSize?.some(size))
                        }
                    }
                    .accessibilityIdentifier("story-draft-task-size")
                    if !startsAfterOptions.isEmpty {
                        Picker("Starts after", selection: $draft.startsAfter) {
                            Text("None").tag(UUID?.none)
                            ForEach(startsAfterOptions) { option in
                                Text(option.title.isEmpty ? String(localized: "Untitled task") : option.title)
                                    .tag(UUID?.some(option.id))
                            }
                        }
                        .accessibilityIdentifier("story-draft-task-starts-after")
                    }
                }
            }
            .formStyle(TaskEditorFormStyle())

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    draft.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    draft.details = draft.details.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("story-draft-task-save")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 460, height: 440)
    }
}
