import AVFoundation
import Observation
import RxCodeCore
import SwiftUI

/// The speech voice used by the custom-agent pipeline and by standalone announcements.
struct PetVoiceModelsPane: View {
    enum Tab: String, CaseIterable, Identifiable {
        case available = "Speech Voices"
        case browse = "Browse Hugging Face TTS"
        var id: String { rawValue }
    }

    @Bindable var controller: PetController
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: Tab = .available
    @State private var actionOverlayMessage: String?
    @State private var errorMessage: String?
    @State private var pendingDeletion: LocalModelInfo?
    @State private var customizingModel: LocalModelInfo?
    @State private var isEditingAppleVoice = false
    @State private var isEditingFlowcyVoice = false
    @State private var preview = PetVoiceDraftPreview()
    /// Observed so README-derived voice settings refresh when the setup agent saves them.
    @AppStorage(StudioModelConfig.storageKey) private var studioConfigs = ""
    @AppStorage(StudioModelConfig.pendingStorageKey) private var pendingStudioConfigs = ""

    private var store: LocalModelStore { appState.localModels }

    private var installedSpeechModels: [LocalModelInfo] {
        store.installed.filter { LocalAudioMode(model: $0) == .speech }
    }

    var body: some View {
        NavigationStack {
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

                ClaudeThemeDivider()

                Group {
                    switch selectedTab {
                    case .available:
                        availableVoicesContent
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
            .navigationTitle("Choose Speech Voice")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(minWidth: 620, idealWidth: 720, maxWidth: .infinity,
               minHeight: 540, idealHeight: 680, maxHeight: .infinity)
        .onDisappear { preview.shutdown() }
        .onChange(of: preview.errorMessage) { _, message in
            if let message { errorMessage = message }
        }
        .overlay {
            if let message = actionOverlayMessage ?? preview.status ?? activeDownloadStatusText {
                PetActionStatusOverlay(message: message).allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $isEditingAppleVoice) {
            PetAppleVoiceSheet(controller: controller) {
                actionOverlayMessage = "Apple voice saved"
            }
        }
        .sheet(isPresented: $isEditingFlowcyVoice) {
            PetFlowcyVoiceSheet(controller: controller, client: FlowcyMediaClient(auth: appState.rxAuth),
                                isSignedIn: appState.rxAuth.isAuthenticated) {
                actionOverlayMessage = "Flowcy voice saved"
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

    // MARK: - Available Voices

    private var availableVoicesContent: some View {
        List {
            Section {
                systemVoiceRow
            } header: {
                Text("Apple Voice")
            }

            Section {
                flowcyVoiceRow
            } header: {
                Text("Flowcy")
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
        let isSelected = controller.configuration.usesLocalVoice(modelID: PetConfiguration.systemTTSModelID)
        return HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? ClaudeTheme.accent : ClaudeTheme.textSecondary)
                .font(.system(size: 16))

            VStack(alignment: .leading, spacing: 3) {
                Text("macOS System Voice")
                    .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                Text("\(controller.configuration.appleVoiceSummary) · No download required")
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
                var draft = controller.configuration
                draft.selectLocalVoice(modelID: PetConfiguration.systemTTSModelID)
                preview.play(configuration: draft, controller: controller)
            }
            .disabled(controller.isMuted)
            .controlSize(.small)

            if !isSelected {
                Button("Use Voice") {
                    controller.configuration.selectLocalVoice(modelID: PetConfiguration.systemTTSModelID)
                    actionOverlayMessage = "Apple voice saved"
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private var flowcyVoiceRow: some View {
        let selection = controller.configuration.flowcyVoice
        return HStack(spacing: 12) {
            Image(systemName: selection == nil ? "circle" : "checkmark.circle.fill")
                .foregroundStyle(selection == nil ? ClaudeTheme.textSecondary : ClaudeTheme.accent)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 3) {
                Text(selection?.voice.name ?? "Flowcy Speech")
                    .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                Text(selection?.model.alias ?? "Voices from your Flowcy account")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Choose Flowcy Voice…") { isEditingFlowcyVoice = true }
                .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private func installedModelRow(_ model: LocalModelInfo) -> some View {
        let isSelected = controller.configuration.usesLocalVoice(modelID: model.id)
        let fit = store.fit(bytes: model.sizeBytes)
        return HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? ClaudeTheme.accent : ClaudeTheme.textSecondary)
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
                var draft = controller.configuration
                PetVoicePresets.select(model: model, in: &draft)
                preview.play(configuration: draft, controller: controller)
            }
            .disabled(controller.isMuted)
            .controlSize(.small)

            if !isSelected {
                Button("Use Voice") {
                    PetVoicePresets.select(model: model, in: &controller.configuration)
                    actionOverlayMessage = "Voice settings saved"
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

extension PetConfiguration {
    var appleVoiceSummary: String {
        let id = systemVoiceIdentifier
        if id == PetConfiguration.spokenContentSystemVoiceID {
            return "Spoken Content System Voice (Siri capable)"
        }
        if let id, let voice = AVSpeechSynthesisVoice(identifier: id) {
            return "\(voice.name) · \(voice.language)"
        }
        return id == nil ? "Automatic for Spoken Language" : "Unavailable Voice"
    }
}
