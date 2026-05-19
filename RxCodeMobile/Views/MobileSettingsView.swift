import SwiftUI
import RxCodeCore
import RxCodeSync

struct MobileSettingsView: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    @State private var showUnpairConfirm = false
    @State private var modelDraft = ""
    @State private var acpClientDraft = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Paired Mac") {
                    HStack {
                        Image(systemName: "desktopcomputer").frame(width: 22)
                        Text(state.pairedDesktopName.isEmpty ? "Unknown Mac" : state.pairedDesktopName)
                    }
                    HStack {
                        Text("Connection")
                        Spacer()
                        connectionLabel
                    }
                }

                if let settings = state.desktopSettings {
                    desktopRuntimeSection(settings)
                    desktopBehaviorSection(settings)
                    desktopAutoPreviewSection(settings)
                    desktopSummarizationSection(settings)
                } else {
                    Section("Desktop Settings") {
                        ProgressView("Syncing settings…")
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showUnpairConfirm = true
                    } label: {
                        Label("Unpair", systemImage: "minus.circle")
                    }
                } footer: {
                    Text("Unpairing regenerates this device's identity. You'll need to scan a fresh QR to re-pair.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Unpair this device?", isPresented: $showUnpairConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Unpair", role: .destructive) {
                    Task { await state.unpair() }
                    dismiss()
                }
            }
            .onAppear {
                modelDraft = state.desktopSettings?.selectedModel ?? ""
                acpClientDraft = state.desktopSettings?.selectedACPClientId ?? ""
            }
            .onChange(of: state.desktopSettings?.selectedModel) { _, value in
                modelDraft = value ?? ""
            }
            .onChange(of: state.desktopSettings?.selectedACPClientId) { _, value in
                acpClientDraft = value ?? ""
            }
        }
    }

    private func desktopRuntimeSection(_ settings: MobileSettingsSnapshot) -> some View {
        Section("Desktop Runtime") {
            Picker("Agent", selection: settingBinding(settings.selectedAgentProvider) { value in
                MobileSettingsUpdatePayload(selectedAgentProvider: value)
            }) {
                ForEach(AgentProvider.allCases, id: \.self) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }

            HStack {
                Text("Model")
                TextField("Model", text: $modelDraft)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { applyModelDraft() }
            }

            Button("Apply Model") {
                applyModelDraft()
            }
            .disabled(modelDraft.trimmingCharacters(in: .whitespacesAndNewlines) == settings.selectedModel)

            if settings.selectedAgentProvider == .acp {
                HStack {
                    Text("ACP Client")
                    TextField("Client ID", text: $acpClientDraft)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { applyACPClientDraft() }
                }

                Button("Apply ACP Client") {
                    applyACPClientDraft()
                }
                .disabled(acpClientDraft.trimmingCharacters(in: .whitespacesAndNewlines) == settings.selectedACPClientId)
            }

            Picker("Effort", selection: settingBinding(settings.selectedEffort) { value in
                MobileSettingsUpdatePayload(selectedEffort: value)
            }) {
                ForEach(settings.availableEfforts, id: \.self) { effort in
                    Text(effort == "auto" ? "Auto" : effortDisplayName(effort)).tag(effort)
                }
            }

            Picker("Permission", selection: settingBinding(settings.permissionMode) { value in
                MobileSettingsUpdatePayload(permissionMode: value)
            }) {
                ForEach(PermissionMode.allCases, id: \.self) { mode in
                    Label(mode.displayName, systemImage: mode.systemImage).tag(mode)
                }
            }
        }
    }

    private func desktopBehaviorSection(_ settings: MobileSettingsSnapshot) -> some View {
        Section("Desktop Behavior") {
            Toggle("Response notifications", isOn: settingBinding(settings.notificationsEnabled) { value in
                MobileSettingsUpdatePayload(notificationsEnabled: value)
            })
            Toggle("Focus mode", isOn: settingBinding(settings.focusMode) { value in
                MobileSettingsUpdatePayload(focusMode: value)
            })
            Toggle("Auto-archive", isOn: settingBinding(settings.autoArchiveEnabled) { value in
                MobileSettingsUpdatePayload(autoArchiveEnabled: value)
            })
            Stepper(
                "Archive after \(settings.archiveRetentionDays) day\(settings.archiveRetentionDays == 1 ? "" : "s")",
                value: settingBinding(settings.archiveRetentionDays) { value in
                    MobileSettingsUpdatePayload(archiveRetentionDays: value)
                },
                in: 1...365
            )
            .disabled(!settings.autoArchiveEnabled)
        }
    }

    private func desktopAutoPreviewSection(_ settings: MobileSettingsSnapshot) -> some View {
        Section("Attachment Auto-Preview") {
            Toggle("URLs", isOn: autoPreviewBinding(settings, \.url))
            Toggle("File paths", isOn: autoPreviewBinding(settings, \.filePath))
            Toggle("Images", isOn: autoPreviewBinding(settings, \.image))
            Toggle("Long text", isOn: autoPreviewBinding(settings, \.longText))
        }
    }

    private func desktopSummarizationSection(_ settings: MobileSettingsSnapshot) -> some View {
        Section {
            LabeledContent("Provider", value: settings.summarizationProviderDisplayName)
            if !settings.openAISummarizationEndpoint.isEmpty {
                LabeledContent("Endpoint", value: settings.openAISummarizationEndpoint)
            }
            if !settings.openAISummarizationModel.isEmpty {
                LabeledContent("Model", value: settings.openAISummarizationModel)
            }
        } header: {
            Text("Summarization")
        } footer: {
            Text("API keys stay on the Mac and are not synced to this device.")
        }
    }

    private func settingBinding<Value>(
        _ value: Value,
        update: @escaping (Value) -> MobileSettingsUpdatePayload
    ) -> Binding<Value> {
        Binding(
            get: { value },
            set: { newValue in
                Task { await state.updateDesktopSettings(update(newValue)) }
            }
        )
    }

    private func autoPreviewBinding(
        _ settings: MobileSettingsSnapshot,
        _ keyPath: WritableKeyPath<AttachmentAutoPreviewSettings, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { settings.autoPreviewSettings[keyPath: keyPath] },
            set: { newValue in
                var next = settings.autoPreviewSettings
                next[keyPath: keyPath] = newValue
                Task {
                    await state.updateDesktopSettings(
                        MobileSettingsUpdatePayload(autoPreviewSettings: next)
                    )
                }
            }
        )
    }

    private func applyModelDraft() {
        let trimmed = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { await state.updateDesktopSettings(MobileSettingsUpdatePayload(selectedModel: trimmed)) }
    }

    private func applyACPClientDraft() {
        let trimmed = acpClientDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await state.updateDesktopSettings(MobileSettingsUpdatePayload(selectedACPClientId: trimmed)) }
    }

    private func effortDisplayName(_ effort: String) -> String {
        switch effort {
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh": return "Extra High"
        case "max": return "Max"
        default: return effort.capitalized
        }
    }

    @ViewBuilder
    private var connectionLabel: some View {
        switch state.connectionState {
        case .connected:
            Label("Live", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .connecting:
            Label("Connecting…", systemImage: "circle.dotted")
        case .disconnected:
            Label("Disconnected", systemImage: "circle.slash").foregroundStyle(.secondary)
        case .reconnecting(let seconds):
            Label("Reconnecting in \(seconds)s", systemImage: "arrow.clockwise.circle").foregroundStyle(.orange)
        }
    }
}
