import RxCodeCore
import RxCodeChatKit
import SwiftUI

/// AI generation is separate from the editable creation form and never saves an item.
struct MobileAIDraftSheet: View {
    @Environment(MobileCloudState.self) private var cloud
    @Environment(\.dismiss) private var dismiss
    let board: TaskBoard
    let kind: ProjectCloudService.DraftKind
    let storyTitle: String?
    let candidates: [String]
    let apply: (MobileTaskDraft) -> Void
    @State private var provider = Provider.flowcy
    @State private var prompt = ""
    @State private var draft: MobileTaskDraft?
    @State private var generation: Task<Void, Never>?
    @State private var errorMessage: String?

    private enum Provider: String, CaseIterable, Identifiable {
        case flowcy, onDevice
        var id: Self { self }
        var title: String { self == .flowcy ? "Flowcy AI" : "Apple On-Device" }
    }

    init(board: TaskBoard, kind: ProjectCloudService.DraftKind, initialPrompt: String = "",
         storyTitle: String? = nil, candidates: [String] = [], apply: @escaping (MobileTaskDraft) -> Void) {
        self.board = board
        self.kind = kind
        self.storyTitle = storyTitle
        self.candidates = candidates
        self.apply = apply
        _prompt = State(initialValue: initialPrompt)
    }

    private var unavailableReason: String? {
        provider == .onDevice ? MobileTaskDraftService.onDeviceUnavailableReason
            : (cloud.isSignedIn ? nil : "Sign in to Flowcy to use Flowcy AI.")
    }

    private var promptLimit: Int { provider == .onDevice ? 3000 : 8000 }

    private var classificationPreview: ProjectTask {
        var task = ProjectTask(projectId: UUID(), title: draft?.title ?? "")
        draft?.classification.apply(to: &task, board: board)
        return task
    }

    var body: some View {
        NavigationStack {
            Group {
                if let draft {
                    Form {
                        Section {
                            VStack(alignment: .leading, spacing: 12) {
                                Label("AI Draft", systemImage: "sparkles")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.secondary)
                                Text(draft.title)
                                    .font(.title2.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } footer: {
                            Text("Review the suggestion. You can edit every detail after choosing Use Draft.")
                        }

                        Section("Description") {
                            MarkdownContentView(text: draft.details)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                        }

                        Section("Properties") {
                            draftProperty("Type", systemImage: "square.grid.2x2",
                                          value: board.effectiveTypes.first { $0.id == classificationPreview.typeId }?.name ?? "None")
                            draftProperty("Priority", systemImage: "flag",
                                          value: classificationPreview.priority?.rawValue.capitalized ?? "None")
                            draftProperty("Version", systemImage: "tag", value: classificationPreview.version ?? "None")
                            draftProperty("Size", systemImage: "ruler", value: classificationPreview.size?.rawValue.uppercased() ?? "None")
                            if let milestone = classificationPreview.milestone {
                                draftProperty("Milestone", systemImage: "mappin", value: milestone)
                            }
                            if !classificationPreview.tags.isEmpty {
                                draftProperty("Tags", systemImage: "number", value: classificationPreview.tags.joined(separator: ", "))
                            }
                            if let deadline = classificationPreview.deadline {
                                draftProperty("Deadline", systemImage: "calendar", value: deadline.formatted())
                            }
                        }

                        Section {
                            Button {
                                MobileHaptics.buttonTap()
                                self.draft = nil
                            } label: {
                                Label("Revise Request", systemImage: "square.and.pencil")
                            }
                            .accessibilityIdentifier("ai-draft-revise")
                        } footer: {
                            Text("Return to your request to generate a new draft.")
                        }
                    }
                } else {
                    Form {
                        Section {
                            Picker("AI Provider", selection: $provider) {
                                ForEach(Provider.allCases) { Text($0.title).tag($0) }
                            }
                            .accessibilityIdentifier("ai-draft-provider")
                        } footer: {
                            if let reason = unavailableReason {
                                Text(reason)
                            } else if provider == .onDevice {
                                Text("Runs privately on this device without a paired Mac.")
                            }
                        }
                        Section {
                            MobileTaskVoiceField(text: $prompt, placeholder: "What needs to be done?")
                                .accessibilityIdentifier("ai-draft-prompt")
                        } footer: {
                            Text("AI fills the title, description, type, priority, version, and size. Review the draft before adding it to your board.")
                            if prompt.count > promptLimit {
                                Text("Shorten the request to \(promptLimit) characters for this provider.").foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
            .disabled(generation != nil)
            .navigationTitle(draft != nil ? "Review Draft" : (kind == .task ? "Create Task with AI" : "Create Story with AI"))
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
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("ai-draft-apply")
                    } else {
                        Button("Generate") { generate() }
                            .disabled(generation != nil || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || prompt.count > promptLimit || unavailableReason != nil)
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
            .onAppear {
                if !cloud.isSignedIn, MobileTaskDraftService.onDeviceUnavailableReason == nil { provider = .onDevice }
            }
            .onChange(of: provider) { MobileHaptics.buttonTap() }
            .onDisappear { generation?.cancel(); generation = nil }
        }
    }

    private func draftProperty(_ title: LocalizedStringKey, systemImage: String, value: String) -> some View {
        LabeledContent {
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func generate() {
        guard generation == nil, unavailableReason == nil, prompt.count <= promptLimit else { return }
        MobileHaptics.buttonTap()
        generation = Task { @MainActor in
            defer { generation = nil }
            do {
                let request = MobileTaskDraftService.prompt(source: prompt, board: board, kind: kind,
                                                            storyTitle: storyTitle, candidates: candidates)
                let result: MobileTaskDraft
                if provider == .onDevice {
                    result = try await MobileTaskDraftService.onDevice(prompt: request)
                } else {
                    result = try await cloud.generateClassifiedDraft(prompt: request)
                }
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
