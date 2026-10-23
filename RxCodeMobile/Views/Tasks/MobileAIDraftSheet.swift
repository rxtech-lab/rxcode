import RxCodeChatKit
import SwiftUI

/// AI generation is separate from the editable creation form and never saves an item.
struct MobileAIDraftSheet: View {
    @Environment(MobileCloudState.self) private var cloud
    @Environment(\.dismiss) private var dismiss
    let projectID: String
    let kind: ProjectCloudService.DraftKind
    let apply: (ProjectCloudService.ItemDraft) -> Void
    @State private var prompt = ""
    @State private var draft: ProjectCloudService.ItemDraft?
    @State private var generation: Task<Void, Never>?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let draft {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(draft.title).font(.title2.bold())
                            MarkdownContentView(text: draft.details)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    }
                } else {
                    Form {
                        Section {
                            TextField("What needs to be done?", text: $prompt, axis: .vertical)
                                .lineLimit(6...14)
                                .accessibilityIdentifier("ai-draft-prompt")
                        } footer: {
                            Text("AI writes a title and description. Review the draft before adding it to your board.")
                        }
                    }
                }
            }
            .disabled(generation != nil)
            .navigationTitle(kind == .task ? "Create Task with AI" : "Create Story with AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { MobileHaptics.buttonTap(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if let draft {
                        Button("Use Draft") {
                            MobileHaptics.buttonTap()
                            apply(draft)
                            dismiss()
                        }
                        .accessibilityIdentifier("ai-draft-apply")
                    } else {
                        Button("Generate") { generate() }
                            .disabled(generation != nil || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || prompt.count > 8000)
                            .accessibilityIdentifier("ai-draft-generate")
                    }
                }
            }
            .overlay {
                if generation != nil {
                    ProgressView("Generating draft…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .accessibilityIdentifier("ai-draft-progress")
                }
            }
            .mobileTaskErrorAlert($errorMessage)
            .onDisappear { generation?.cancel(); generation = nil }
        }
    }

    private func generate() {
        guard generation == nil else { return }
        MobileHaptics.buttonTap()
        generation = Task { @MainActor in
            defer { generation = nil }
            do {
                let result = try await cloud.generateDraft(projectID: projectID, kind: kind, prompt: prompt)
                try Task.checkCancellation()
                draft = result
                MobileHaptics.streamFinished()
            } catch {
                guard !MobileCloudState.isCancellation(error) else { return }
                errorMessage = error.localizedDescription
                MobileHaptics.connectionError()
            }
        }
    }
}
