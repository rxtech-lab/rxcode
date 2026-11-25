import RxCodeCore
import RxCodeSync
import SwiftUI

struct MobileAgentEditorDraft: Identifiable {
    var profile: AgentProfile
    let isNew: Bool
    var id: UUID { profile.id }
}

/// Creates or edits one of the paired Mac's agents. Saving sends the profile
/// to the Mac, which owns the agent, and waits for it to confirm.
struct MobileAgentEditorSheet: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    let isNew: Bool
    let onSaved: (UUID) -> Void
    @State private var profile: AgentProfile
    /// The pet look the agent had when the sheet opened; the phone can't show
    /// pets, so it can only keep or drop it.
    private let originalPetLookId: String?
    @State private var saving = false
    @State private var error: String?

    init(draft: MobileAgentEditorDraft, onSaved: @escaping (UUID) -> Void) {
        isNew = draft.isNew
        self.onSaved = onSaved
        _profile = State(initialValue: draft.profile)
        originalPetLookId = draft.profile.petLookId
    }

    private var modelSections: [AgentModelSection] { state.desktopSettings?.modelSections ?? [] }
    private var canSave: Bool { !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !saving }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 10) {
                        MobileAgentAvatar(profile: profile, size: 76)
                        TextField("Name", text: $profile.name, prompt: Text("Researcher, Planner, Inbox Helper…"))
                            .font(.title3.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("agent-editor-name")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }

                Section("Appearance") {
                    if originalPetLookId != nil {
                        Toggle("Show as Pet on Mac", isOn: Binding(
                            get: { profile.petLookId != nil },
                            set: { profile.petLookId = $0 ? originalPetLookId : nil }
                        ))
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 8)], spacing: 8) {
                        ForEach(AgentProfile.symbols, id: \.self) { symbol in
                            Button {
                                MobileHaptics.buttonTap()
                                profile.symbol = symbol
                            } label: {
                                Image(systemName: symbol)
                                    .font(.system(size: 16))
                                    .frame(width: 40, height: 40)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10).fill(
                                            profile.symbol == symbol
                                                ? Color(hex: profile.colorHex).opacity(0.22)
                                                : Color(.tertiarySystemFill)
                                        )
                                    )
                                    .foregroundStyle(profile.symbol == symbol ? Color(hex: profile.colorHex) : .primary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(symbol)
                            .accessibilityAddTraits(profile.symbol == symbol ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 4)
                    HStack {
                        ForEach(AgentProfile.palette, id: \.self) { hex in
                            Button {
                                MobileHaptics.buttonTap()
                                profile.colorHex = hex
                            } label: {
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 28, height: 28)
                                    .overlay {
                                        if profile.colorHex == hex {
                                            Image(systemName: "checkmark")
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel(hex)
                            .accessibilityAddTraits(profile.colorHex == hex ? .isSelected : [])
                        }
                    }
                }

                Section {
                    modelPicker
                    Picker("Tone", selection: $profile.tone) {
                        ForEach(AgentTone.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    TextField("Role and standing instructions", text: $profile.instructions,
                              prompt: Text("What this agent is for and how it should work"), axis: .vertical)
                        .lineLimit(3...8)
                    TextField("Personality", text: $profile.personality,
                              prompt: Text("How it talks and behaves"), axis: .vertical)
                        .lineLimit(2...6)
                } header: {
                    Text("Behavior")
                } footer: {
                    Text("The first line of the instructions tells teammates what this agent is good at, so they know when to ask it for help.")
                }

                Section("Capabilities") {
                    Toggle("Notify This Phone", isOn: $profile.notifiesPhone)
                    Toggle("Allow Computer Use", isOn: $profile.computerUse.isEnabled)
                    if profile.computerUse.isEnabled {
                        Picker("Computer Use", selection: $profile.computerUse.mode) {
                            ForEach(AgentComputerUseMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "New Agent" : "Edit Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                        .accessibilityIdentifier("agent-editor-save")
                }
            }
            .interactiveDismissDisabled(saving)
            .overlay {
                if saving {
                    ProgressView("Saving…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .alert("Could Not Save Agent", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    /// Every coding model the Mac offers: Claude, Codex and its ACP clients.
    private var modelPicker: some View {
        let models = modelSections.flatMap(\.models)
        let currentKey = profile.agent.model.map { AgentModel.key(for: $0, provider: profile.agent.provider ?? .claudeCode) }
        let currentIsListed = models.contains { $0.provider == profile.agent.provider && $0.id == profile.agent.model }
        return Picker("Model", selection: Binding(get: {
            models.first { $0.provider == profile.agent.provider && $0.id == profile.agent.model }?.key ?? currentKey ?? ""
        }, set: { key in
            guard let model = models.first(where: { $0.key == key }) else {
                if key.isEmpty { profile.agent = TaskAgentConfig() }
                return
            }
            // Effort and permission levels differ per model; the Mac falls back to its defaults.
            profile.agent = TaskAgentConfig(provider: model.provider, model: model.id)
        })) {
            Text("Workspace Default").tag("")
            if !currentIsListed, let currentKey, let model = profile.agent.model {
                Text(model).tag(currentKey)
            }
            ForEach(modelSections) { section in
                Section(section.title) {
                    ForEach(section.models, id: \.key) { Text($0.displayName).tag($0.key) }
                }
            }
        }
        .pickerStyle(.navigationLink)
    }

    private func save() {
        guard canSave else { return }
        MobileHaptics.buttonTap()
        saving = true
        var payload = profile
        payload.name = payload.name.trimmingCharacters(in: .whitespacesAndNewlines)
        payload.updatedAt = .now
        Task {
            do {
                let result = try await state.performAgentRequest(
                    .init(operation: isNew ? .createAgent : .updateAgent, agent: payload, agentID: payload.id)
                )
                MobileHaptics.connected()
                onSaved(result.agentID ?? payload.id)
                saving = false
                dismiss()
            } catch {
                saving = false
                self.error = error.localizedDescription
                MobileHaptics.connectionError()
            }
        }
    }
}
