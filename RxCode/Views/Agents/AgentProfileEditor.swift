import RxCodeCore
import SwiftUI

/// Creates or edits an agent: its look, behavior and capabilities.
struct AgentProfileEditor: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State var profile: AgentProfile
    @State private var previewActivity: AgentActivity = .idle

    private var isNew: Bool { state.agentProfile(id: profile.id) == nil }
    private var looks: [PetLook] { PetController.shared.looks.looks }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        AgentAvatarView(agent: profile, activity: previewActivity, size: 110, showsStatus: false)
                            .id("\(profile.petLookId ?? profile.symbol)-\(profile.colorHex)")
                        Picker("Preview", selection: $previewActivity) {
                            Text("Idle").tag(AgentActivity.idle)
                            Text("Working").tag(AgentActivity.working)
                            Text("Done").tag(AgentActivity.celebrating)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 260)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    TextField("Name", text: $profile.name, prompt: Text("Researcher, Planner, Inbox Helper…"))
                        .accessibilityIdentifier("agent-profile-name")
                }

                Section("Appearance") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 10)], spacing: 10) {
                        ForEach(looks) { look in
                            appearanceTile(selected: profile.petLookId == look.id, title: look.name) {
                                PetSpriteView(
                                    character: look.character, state: PetState(), size: 52,
                                    isAnimationActive: profile.petLookId == look.id
                                )
                                .frame(width: 52, height: 52)
                            } action: {
                                profile.petLookId = look.id
                            }
                        }
                        appearanceTile(selected: profile.petLookId == nil, title: String(localized: "Symbol")) {
                            Image(systemName: profile.symbol)
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(Color(hex: profile.colorHex))
                                .frame(width: 52, height: 52)
                        } action: {
                            profile.petLookId = nil
                        }
                    }
                    .padding(.vertical, 4)

                    if profile.petLookId == nil {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 34), spacing: 6)], spacing: 6) {
                            ForEach(AgentProfile.symbols, id: \.self) { symbol in
                                Button { profile.symbol = symbol } label: {
                                    Image(systemName: symbol)
                                        .font(.system(size: 14))
                                        .frame(width: 32, height: 32)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(profile.symbol == symbol ? Color(hex: profile.colorHex).opacity(0.2) : ClaudeTheme.surfaceSecondary)
                                        )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(symbol)
                            }
                        }
                    }

                    LabeledContent("Color") {
                        HStack(spacing: 8) {
                            ForEach(AgentProfile.palette, id: \.self) { hex in
                                Button { profile.colorHex = hex } label: {
                                    Circle()
                                        .fill(Color(hex: hex))
                                        .frame(width: 20, height: 20)
                                        .overlay(Circle().strokeBorder(.white, lineWidth: profile.colorHex == hex ? 2 : 0))
                                        .shadow(color: profile.colorHex == hex ? Color(hex: hex).opacity(0.6) : .clear, radius: 3)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(hex)
                                .accessibilityAddTraits(profile.colorHex == hex ? .isSelected : [])
                            }
                        }
                    }
                }

                Section {
                    modelPicker
                    Picker("Tone", selection: $profile.tone) {
                        ForEach(AgentTone.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    TextField("Role and standing instructions", text: $profile.instructions, prompt: Text("What this agent is for and how it should work"), axis: .vertical)
                        .lineLimit(3...8)
                    TextField("Personality", text: $profile.personality, prompt: Text("How it talks and behaves"), axis: .vertical)
                        .lineLimit(2...6)
                } header: {
                    Text("Behavior")
                } footer: {
                    Text("The first line of the instructions tells teammates what this agent is good at, so they know when to ask it for help.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Capabilities") {
                    Toggle("Notify paired phones", isOn: $profile.notifiesPhone)
                    Toggle("Allow computer use", isOn: $profile.computerUse.isEnabled)
                    if profile.computerUse.isEnabled {
                        Picker("Computer use", selection: $profile.computerUse.mode) {
                            ForEach(AgentComputerUseMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        TextField("Fallback model", text: $profile.computerUse.openSourceModel)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isNew ? "New Agent" : "Edit Agent")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { state.upsertAgent(profile); dismiss() }
                        .disabled(profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(minWidth: 540, idealWidth: 580, minHeight: 680, idealHeight: 760, maxHeight: .infinity)
    }

    /// Every coding model: Claude, Codex and the ACP and local clients.
    private var modelPicker: some View {
        Picker("Model", selection: Binding(get: {
            state.codingModelSections.flatMap(\.models).first {
                $0.provider == profile.agent.provider && $0.id == profile.agent.model
            }?.key ?? ""
        }, set: { key in
            let model = state.codingModelSections.flatMap(\.models).first { $0.key == key }
            profile.agent = TaskAgentConfig(provider: model?.provider, model: model?.id)
        })) {
            Text("Workspace Default").tag("")
            ForEach(state.codingModelSections) { section in
                Section(section.title) {
                    ForEach(section.models, id: \.key) { Text($0.displayName).tag($0.key) }
                }
            }
        }
    }

    private func appearanceTile<Preview: View>(
        selected: Bool,
        title: String,
        @ViewBuilder preview: () -> Preview,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                preview()
                Text(title)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(selected ? ClaudeTheme.textPrimary : ClaudeTheme.textSecondary)
            }
            .padding(6)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? Color(hex: profile.colorHex).opacity(0.16) : ClaudeTheme.surfaceSecondary.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? Color(hex: profile.colorHex) : .clear, lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Screen sharing and control from paired phones.
struct AgentRemoteAccessView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Share screen with paired phones", isOn: Binding(get: { state.agentRemoteAccess.allowsViewing }, set: { value in
                        if value { _ = ComputerControl.requestScreenRecordingAccess() }
                        state.setAgentRemoteAccess(.init(allowsViewing: value, allowsControl: state.agentRemoteAccess.allowsControl))
                    }))
                    Toggle("Allow paired phones to control this Mac", isOn: Binding(get: { state.agentRemoteAccess.allowsControl }, set: { value in
                        if value { _ = ComputerControl.hasAccessibilityAccess(prompt: true) }
                        state.setAgentRemoteAccess(.init(allowsViewing: state.agentRemoteAccess.allowsViewing, allowsControl: value))
                    }))
                    .disabled(!state.agentRemoteAccess.allowsViewing)
                } footer: {
                    Text("Lets you watch agents that use the computer, and take over, from the RxCode app on your phone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Remote Access")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .frame(minWidth: 470, minHeight: 440, maxHeight: .infinity)
    }
}
