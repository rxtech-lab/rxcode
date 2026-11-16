import AVFoundation
import Observation
import RxCodeCore
import SwiftUI

// MARK: - Voices Pane (Embedded in Pet & Voice Settings)

/// Apple, Codex Realtime, and installed neural voices plus the Hugging Face
/// TTS catalog. Hosted as the Voices tab of `PetSettingsView`.
struct PetVoiceModelsPane: View {
    enum Tab: String, CaseIterable, Identifiable {
        case installed = "Voices"
        case browse = "Browse Hugging Face TTS"
        var id: String { rawValue }
    }

    @Bindable var controller: PetController
    @Environment(AppState.self) private var appState

    @State private var selectedTab: Tab = .installed
    @State private var actionOverlayMessage: String?
    @State private var errorMessage: String?
    @State private var pendingDeletion: LocalModelInfo?
    @State private var customizingModel: LocalModelInfo?
    @State private var isEditingAppleVoice = false
    @State private var isEditingCodexVoice = false
    /// Observed so README-derived voice settings refresh when the setup agent saves them.
    @AppStorage(StudioModelConfig.storageKey) private var studioConfigs = ""
    @AppStorage(StudioModelConfig.pendingStorageKey) private var pendingStudioConfigs = ""

    private var store: LocalModelStore { appState.localModels }

    private var installedSpeechModels: [LocalModelInfo] {
        store.installed.filter { LocalAudioMode(model: $0) == .speech }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()

            Group {
                switch selectedTab {
                case .installed:
                    installedVoicesContent
                case .browse:
                    PetVoiceCatalogView(
                        controller: controller,
                        actionOverlayMessage: $actionOverlayMessage,
                        errorMessage: $errorMessage
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if let message = actionOverlayMessage ?? activeDownloadStatusText {
                PetActionStatusOverlay(message: message)
            }
        }
        .sheet(isPresented: $isEditingAppleVoice) {
            PetAppleVoiceSheet(controller: controller) {
                actionOverlayMessage = "Apple voice saved"
            }
        }
        .sheet(isPresented: $isEditingCodexVoice) {
            PetCodexVoiceSheet(controller: controller) {
                actionOverlayMessage = "Codex voice saved"
            }
        }
        .sheet(item: $customizingModel) { model in
            PetNeuralVoiceSettingsSheet(controller: controller, model: model) {
                actionOverlayMessage = "Voice settings saved"
            }
            .environment(appState)
        }
        .task(id: actionOverlayMessage) {
            guard let message = actionOverlayMessage, message.hasSuffix(" saved") else { return }
            do {
                try await Task.sleep(for: .seconds(2))
                actionOverlayMessage = nil
            } catch {}
        }
        .confirmationDialog(
            "Delete Local Voice Model?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { model in
            Button("Delete “\(model.displayName)”", role: .destructive) {
                let target = model
                pendingDeletion = nil
                Task { await deleteVoiceModel(target) }
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: { model in
            Text("“\(model.displayName)” (\(LocalModelFormat.bytes(model.sizeBytes))) will be removed from disk.")
        }
        .alert(
            "Voice Model Error",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onChange(of: controller.alertErrorMessage) { _, message in
            guard let message else { return }
            errorMessage = message
            controller.alertErrorMessage = nil
        }
    }

    private var activeDownloadStatusText: String? {
        if let runtimeDL = store.runtimeDownload {
            return "Installing \(runtimeDL.title)…"
        }
        if let first = store.downloads.values.first {
            let pct = Int((first.fraction * 100).rounded())
            return "Downloading \(first.title) (\(pct)%)…"
        }
        return controller.actionStatusOverlayMessage
    }

    // MARK: - Installed Tab

    private var installedVoicesContent: some View {
        List {
            Section {
                systemVoiceRow
            } header: {
                Text("Apple Voice")
            }

            Section {
                codexVoiceRow
            } header: {
                Text("Codex Realtime")
            } footer: {
                Text("Used only while Codex Realtime voice mode is live.")
            }

            Section {
                if installedSpeechModels.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No neural local TTS models installed yet.")
                            .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                        Text("Switch to “Browse Hugging Face TTS” to install Kokoro-82M or any compatible MLX / GGUF speech synthesis model.")
                            .font(.system(size: ClaudeTheme.size(12)))
                            .foregroundStyle(.secondary)
                        Button {
                            selectedTab = .browse
                        } label: {
                            Label("Browse Voice Models", systemImage: "arrow.right.circle")
                        }
                        .padding(.top, 4)
                    }
                    .padding(.vertical, 8)
                } else {
                    ForEach(installedSpeechModels) { model in
                        installedModelRow(model)
                    }
                }
            } header: {
                Text("Installed Neural Voice Models")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var systemVoiceRow: some View {
        let isSelected = controller.configuration.localTTSModelID == PetConfiguration.systemTTSModelID
        return HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? ClaudeTheme.accent : .secondary)
                .font(.system(size: 16))

            VStack(alignment: .leading, spacing: 3) {
                Text("macOS System Voice")
                    .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                Text("\(appleVoiceSummary) · No download required")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                isEditingAppleVoice = true
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .controlSize(.small)
            .help("Choose Apple Voice")
            .accessibilityLabel("Choose Apple voice")

            Button("Preview") {
                controller.configuration.localTTSModelID = PetConfiguration.systemTTSModelID
                controller.previewVoiceSample()
            }
            .controlSize(.small)

            if !isSelected {
                Button("Use Voice") {
                    controller.configuration.localTTSModelID = PetConfiguration.systemTTSModelID
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private var appleVoiceSummary: String {
        let id = controller.configuration.systemVoiceIdentifier
        if id == PetConfiguration.spokenContentSystemVoiceID {
            return "Spoken Content System Voice (Siri capable)"
        }
        if let id, let voice = AVSpeechSynthesisVoice(identifier: id) {
            return "\(voice.name) · \(voice.language)"
        }
        return id == nil ? "Automatic for Spoken Language" : "Unavailable Voice"
    }

    private var codexVoiceRow: some View {
        let isActive = controller.configuration.voiceMode == .codexRealtime
        return HStack(spacing: 12) {
            Image(systemName: "waveform.circle")
                .foregroundStyle(isActive ? ClaudeTheme.accent : .secondary)
                .font(.system(size: 16))

            VStack(alignment: .leading, spacing: 3) {
                Text(controller.configuration.resolvedCodexVoice.displayName)
                    .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                Text("\(controller.configuration.codexTransport.title) · \(isActive ? "Active Voice Engine" : "Not the Active Voice Engine")")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                isEditingCodexVoice = true
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .controlSize(.small)
            .help("Configure Codex Realtime Voice")
            .accessibilityLabel("Configure Codex Realtime voice")
        }
        .padding(.vertical, 4)
    }

    private func installedModelRow(_ model: LocalModelInfo) -> some View {
        let isSelected = controller.configuration.localTTSModelID == model.id
        let fit = store.fit(bytes: model.sizeBytes)
        return HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? ClaudeTheme.accent : .secondary)
                .font(.system(size: 16))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                    Text(model.format.label)
                        .font(.system(size: ClaudeTheme.size(10), weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(ClaudeTheme.surfaceSecondary, in: Capsule())
                }
                Text("\(model.repoID) · \(LocalModelFormat.bytes(model.sizeBytes)) · \(fit.label)")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
                voiceStatusLine(model, isSelected: isSelected)
            }

            Spacer()

            Button {
                customizingModel = model
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .controlSize(.small)
            .help("Voice Settings")
            .accessibilityLabel("Voice settings for \(model.displayName)")

            Button("Preview") {
                PetVoicePresets.select(model: model, in: controller)
                controller.previewVoiceSample()
            }
            .controlSize(.small)

            if !isSelected {
                Button("Use Voice") {
                    PetVoicePresets.select(model: model, in: controller)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Button(role: .destructive) {
                pendingDeletion = model
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete voice model from disk")
        }
        .padding(.vertical, 4)
    }

    /// The active voice and whether the setup agent has read this model's README.
    @ViewBuilder
    private func voiceStatusLine(_ model: LocalModelInfo, isSelected: Bool) -> some View {
        let config = StudioModelConfig.decodeAll(studioConfigs)[model.id]
        let voiceCount = PetVoicePresets.voiceParameter(in: config)?.options?.count ?? 0
        HStack(spacing: 6) {
            if config == nil, StudioModelConfig.decodePending(pendingStudioConfigs).contains(model.id) {
                ProgressView().controlSize(.mini)
                Text("Reading README…")
            } else if config != nil {
                Image(systemName: "doc.text.magnifyingglass")
                Text(voiceCount > 0 ? "\(voiceCount) voices from README" : "Settings from README")
            } else {
                Image(systemName: "doc.text")
                Text("README not analyzed")
            }
            if isSelected, !controller.configuration.localTTSVoicePreset.isEmpty {
                Text("· Voice: \(controller.configuration.localTTSVoicePreset)")
            }
        }
        .font(.system(size: ClaudeTheme.size(10)))
        .foregroundStyle(.secondary)
    }

    // MARK: - Actions

    private func deleteVoiceModel(_ model: LocalModelInfo) async {
        actionOverlayMessage = "Removing \(model.displayName)…"
        if controller.configuration.localTTSModelID == model.id {
            controller.configuration.localTTSModelID = PetConfiguration.systemTTSModelID
        }
        await controller.localSynthesizer.cancelAll()
        await store.delete(model)
        actionOverlayMessage = nil
    }
}
