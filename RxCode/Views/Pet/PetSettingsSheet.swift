import AppKit
import AVFoundation
import MusicKit
import RxCodeCore
import SwiftUI

// MARK: - Dedicated Pet & Voice Settings Window

struct PetSettingsView: View {
    @Bindable var controller: PetController
    @Environment(AppState.self) private var appState
    @State private var microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var isRequestingMicrophone = false
    @State private var audioDevices = PetAudioDeviceCatalog()
    @State private var audioTest: PetAudioTest?
    private var selectedTab: SettingsTab {
        get { controller.settingsTab }
        nonmutating set { controller.settingsTab = newValue }
    }
    @State private var isEditingAppleVoice = false
    @State private var editingVoiceModel: LocalModelInfo?
    /// Observed so README-derived voice settings refresh when the setup agent saves them.
    @AppStorage(StudioModelConfig.storageKey) private var studioConfigs = ""

    private static let supportedLocales = PetConfiguration.supportedConversationLocales

    private var installedSpeechSynthesisModels: [LocalModelInfo] {
        appState.localModels.installed.filter { LocalAudioMode(model: $0) == .speech }
    }

    private var installedTranscriptionModels: [LocalModelInfo] {
        appState.localModels.installed.filter { LocalAudioMode(model: $0) == .transcription }
    }

    private var appleVoiceSummary: String {
        let id = controller.configuration.systemVoiceIdentifier
        if id == PetConfiguration.spokenContentSystemVoiceID {
            return "Spoken Content System Voice"
        }
        if let id, let voice = AVSpeechSynthesisVoice(identifier: id) {
            return "\(voice.name) (\(voice.language))"
        }
        return id == nil ? "Automatic for Language" : "Unavailable Voice"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                settingsTabBar
                Divider()
                if selectedTab == .looks {
                    PetLooksPane(controller: controller)
                } else if selectedTab == .voices {
                    PetVoiceModelsPane(controller: controller)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                Form {
                    switch selectedTab {
                    case .generalAgent:
                        customAgentSection
                        notificationModelSection
                        projectScopeSection
                    case .voice:
                        voiceModeSection
                        audioDevicesSection
                        microphoneSection
                        if controller.configuration.voiceMode == .codexRealtime {
                            codexRealtimeSection
                        } else {
                            Section("Conversation Agent") {
                                LabeledContent("Agent Model", value: customAgentSelectionLabel)
                                Button("Choose General Agent…") { selectedTab = .generalAgent }
                            }
                            localSpeechRecognitionSection
                            localVoiceSynthesisSection
                        }
                    case .looks, .voices:
                        EmptyView()
                    case .music:
                        musicSection
                    case .desktop:
                        desktopPetSection
                        screenCaptureSection
                        accessibilitySection
                        proactiveAndDailyReportSection
                    }
                }
                .formStyle(.grouped)
                .id(selectedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Pet & Voice Settings")
        }
        .frame(minWidth: 700, idealWidth: 780, maxWidth: .infinity,
               minHeight: 600, idealHeight: 700, maxHeight: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            if selectedTab == .music { Task { await controller.music.refreshConnection() } }
        }
        .sheet(item: $audioTest) { test in
            PetAudioTestSheet(test: test, configuration: controller.configuration)
        }
        .sheet(isPresented: $isEditingAppleVoice) {
            PetAppleVoiceSheet(controller: controller)
        }
        .sheet(item: $editingVoiceModel) { model in
            PetNeuralVoiceSettingsSheet(controller: controller, model: model)
                .environment(appState)
        }
        .task(id: selectedTab) {
            if selectedTab == .music { await controller.music.refreshConnection() }
        }
        .overlay {
            if selectedTab == .music, controller.music.isBusy || controller.music.isTurningOff {
                PetActionStatusOverlay(message: "Updating Apple Music…")
            } else if let status = controller.actionStatusOverlayMessage {
                PetActionStatusOverlay(message: status)
            }
        }
        .alert("Pet Notice", isPresented: Binding(
            get: { controller.alertErrorMessage != nil },
            set: { if !$0 { controller.alertErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { controller.alertErrorMessage = nil }
        } message: {
            Text(controller.alertErrorMessage ?? "")
        }
    }

    @ViewBuilder
    private var musicSection: some View {
        let music = controller.music
        Section {
            HStack(spacing: 12) {
                Image(systemName: musicStatusSymbol)
                    .font(.title2)
                    .foregroundStyle(musicStatusTint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple Music")
                    Text(musicStatusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                musicPrimaryAction
                Menu {
                    Button("Recheck Connection") { linkAppleMusic() }
                        .disabled(music.isBusy || music.isTurningOff)
                    Button("Open Music") { openMusicApp() }
                    Button("Privacy Settings…") { openMusicPrivacySettings() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More Apple Music options")
            }
            .padding(.vertical, 4)
            if let error = music.errorMessage {
                Label {
                    Text(error).textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.caption)
            }
        } header: {
            Text("Apple Music")
        } footer: {
            Text("Uses the Apple Music account signed in to Music on this Mac. Catalog playback needs an active subscription.")
        }
        Section {
            if music.enabled {
                LabeledContent {
                    Button("Stop", role: .destructive) {
                        Task { _ = await music.off() }
                    }
                    .disabled(music.isTurningOff)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(music.title).lineLimit(1)
                        if !music.artist.isEmpty {
                            Text(music.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            } else {
                Text("Nothing playing")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Pet Player")
        } footer: {
            Text("Ask the voice agent to play, pause, resume, or stop a song or artist.")
        }
    }

    /// One contextual call to action; everything else lives in the "…" menu.
    @ViewBuilder
    private var musicPrimaryAction: some View {
        let music = controller.music
        switch music.authorizationStatus {
        case .denied, .restricted:
            Button("Open Settings") { openMusicPrivacySettings() }
        case .authorized where music.isLinked && music.canPlayCatalogContent == false:
            Button("Open Music") { openMusicApp() }
        case .authorized where music.isLinked:
            EmptyView()
        case .authorized:
            Button("Retry Account Check") { music.refreshConnectionInBackground() }
                .disabled(music.isCheckingConnection)
        default:
            Button("Link") { linkAppleMusic() }
                .buttonStyle(.borderedProminent)
                .disabled(music.isBusy || music.isTurningOff)
        }
    }

    private var musicStatusSymbol: String {
        let music = controller.music
        switch music.authorizationStatus {
        case .denied, .restricted: return "xmark.circle.fill"
        case .authorized where music.isLinked:
            return music.canPlayCatalogContent == false ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
        default: return music.errorMessage == nil ? "music.note" : "exclamationmark.circle.fill"
        }
    }

    private var musicStatusTint: Color {
        switch musicStatusSymbol {
        case "checkmark.circle.fill": .green
        case "xmark.circle.fill": .red
        case "exclamationmark.circle.fill": .orange
        default: .secondary
        }
    }

    private var musicStatusDetail: String {
        let music = controller.music
        switch music.authorizationStatus {
        case .denied: return "Access denied in Privacy settings"
        case .restricted: return "Access restricted on this Mac"
        case .authorized where music.isLinked:
            return music.canPlayCatalogContent == false ? "Linked · Subscription required for playback" : "Linked · Ready to play"
        case .authorized:
            if music.isCheckingConnection { return "Authorized · Checking account…" }
            return music.connectionError ?? "Authorized · Account not verified"
        default: return "Not linked"
        }
    }

    private func linkAppleMusic() {
        Task {
            do {
                _ = try await controller.music.handle(.object(["action": .string("connect")]))
            } catch is CancellationError {
            } catch {
                controller.alertErrorMessage = error.localizedDescription
            }
        }
    }

    private func openMusicApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    private func openMusicPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Media") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Mirrors the toolbar-style tab strip of a macOS Settings window: compact,
    /// centered icon-over-label items with a subtle rounded highlight on the
    /// selected pane.
    private var settingsTabBar: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                SettingsToolbarTabButton(
                    title: tab.title,
                    systemImage: tab.systemImage,
                    isSelected: selectedTab == tab
                ) {
                    selectedTab = tab
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - Sections

    private var microphoneSection: some View {
        Section("Microphone Access") {
            LabeledContent("Permission", value: microphoneStatusLabel)
            if microphoneStatus == .notDetermined {
                Button("Grant Microphone Access…") {
                    Task { @MainActor in
                        isRequestingMicrophone = true
                        _ = await PetVoiceAudioDriver.requestMicrophoneAccess()
                        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                        isRequestingMicrophone = false
                    }
                }
                .disabled(isRequestingMicrophone)
            }
            Link("Open Microphone Settings…", destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            if microphoneStatus == .restricted {
                Text("Microphone access is restricted by this Mac's policy. Contact your administrator.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Enable RxCode in System Settings → Privacy & Security → Microphone, then try Start Voice again. If access is already enabled, quit and reopen RxCode.")
                    .foregroundStyle(.secondary)
            }
        }
        .overlay {
            if isRequestingMicrophone {
                PetActionStatusOverlay(message: "Requesting microphone access…")
            }
        }
    }

    private var audioDevicesSection: some View {
        Section {
            Toggle("Tool activity sounds", isOn: Binding(
                get: { controller.configuration.playsToolSounds },
                set: { controller.configuration.toolSoundsEnabled = $0 }
            ))
            .help("Play quiet activity cues while pet tools run. Cues pause during speech and while the call is muted.")
            devicePicker(
                "Microphone",
                selection: $controller.configuration.microphoneDeviceUID,
                devices: audioDevices.inputs
            )
            devicePicker(
                "Speaker",
                selection: $controller.configuration.speakerDeviceUID,
                devices: audioDevices.outputs
            )
            HStack {
                Button("Test Microphone…") { audioTest = .microphone }
                Button("Test Speaker…") { audioTest = .speaker }
            }
        } header: {
            Text("Audio Devices")
        } footer: {
            Text("System Default follows System Settings → Sound. You can change devices during a call.")
        }
    }

    private func devicePicker(
        _ title: LocalizedStringKey,
        selection: Binding<String?>,
        devices: [PetAudioDevice]
    ) -> some View {
        Picker(title, selection: selection) {
            Text("System Default").tag(String?.none)
            if !devices.isEmpty { Divider() }
            ForEach(devices) { device in
                Text(device.name).tag(Optional(device.uid))
            }
            if let uid = selection.wrappedValue, !devices.contains(where: { $0.uid == uid }) {
                Text("Disconnected Device").tag(Optional(uid))
            }
        }
    }

    private var microphoneStatusLabel: String {
        switch microphoneStatus {
        case .authorized: "Granted"
        case .notDetermined: "Not Requested"
        case .denied: "Denied"
        case .restricted: "Restricted"
        @unknown default: "Unknown"
        }
    }

    private var accessibilitySection: some View {
        Section("Accessibility Access") {
            LabeledContent("Permission", value: controller.desktopActions.authorizationGranted ? "Granted" : "Not Granted")
            if !controller.desktopActions.authorizationGranted {
                Button("Grant Accessibility Access…") {
                    Task { await controller.desktopActions.refreshAuthorization(prompt: true) }
                }
                .disabled(controller.desktopActions.isCheckingAuthorization)
            }
            Button("Open Accessibility Settings…") { controller.desktopActions.openSettings() }
            Button("Recheck Accessibility Access") {
                Task { await controller.desktopActions.refreshAuthorization() }
            }
            .disabled(controller.desktopActions.isCheckingAuthorization)
            Text("Required for requested window focus, clicks, scrolling and typing. Enable this copy of RxCode in System Settings. If authorization does not update, fully quit and reopen the same app. Screen Recording is a separate permission.")
                .foregroundStyle(.secondary)
        }
        .task { await controller.desktopActions.refreshAuthorization() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await controller.desktopActions.refreshAuthorization() }
        }
        .overlay {
            if controller.desktopActions.isCheckingAuthorization {
                PetActionStatusOverlay(message: "Checking Accessibility access…")
            }
        }
    }

    private var screenCaptureSection: some View {
        Section("Screen Recording Access") {
            LabeledContent("Permission", value: controller.screenCapture.permissionGranted ? "Access Confirmed" : "Not Confirmed — Try Capture")
            if !controller.screenCapture.permissionGranted {
                Button("Grant Screen Recording Access…") {
                    Task { await controller.screenCapture.requestPermission() }
                }
            }
            Button("Open Screen Recording Settings…") { controller.screenCapture.openPermissionSettings() }
            Button("Refresh Permission Status") { controller.screenCapture.refreshPermission() }
            DisclosureGroup("App Requesting Access") {
                Text(controller.screenCapture.applicationIdentity).font(.caption).textSelection(.enabled)
                if let granted = controller.screenCapture.lastRequestGranted {
                    LabeledContent("Last Native Request", value: granted ? "Access confirmed" : "Access not confirmed")
                }
            }
            Text("The pet only takes a single photo when you ask. It can photograph its display, another display, or a visible window. macOS may require reopening RxCode after access changes.")
                .foregroundStyle(.secondary)
        }
        .task { controller.screenCapture.refreshPermission() }
        .alert("Screen Recording Access", isPresented: Binding(
            get: { controller.screenCapture.permissionIssueMessage != nil },
            set: { if !$0 { controller.screenCapture.permissionIssueMessage = nil } }
        )) {
            Button("Open System Settings") {
                controller.screenCapture.permissionIssueMessage = nil
                controller.screenCapture.openPermissionSettings()
            }
            Button("Cancel", role: .cancel) { controller.screenCapture.permissionIssueMessage = nil }
        } message: {
            Text(controller.screenCapture.permissionIssueMessage ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.screenCapture.refreshPermission()
        }
        .overlay {
            if controller.actionStatusOverlayMessage == "Requesting Screen Recording access…" {
                PetActionStatusOverlay(message: "Requesting Screen Recording access…")
            }
        }
    }

    private var desktopPetSection: some View {
        Section {
            Toggle("Show Desktop Pet across Spaces", isOn: $controller.configuration.isEnabled)

            LabeledContent("Pet Size") {
                HStack(spacing: 10) {
                    Slider(value: $controller.configuration.petSize, in: 84...168, step: 4)
                        .frame(maxWidth: 220)
                    Text("\(Int(controller.configuration.petSize)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
            }

            if controller.configuration.normalizedScreenX != nil || controller.configuration.normalizedScreenY != nil {
                Button("Reset Desktop Position") {
                    controller.configuration.normalizedScreenX = nil
                    controller.configuration.normalizedScreenY = nil
                    controller.refreshPetState()
                }
            }
        } header: {
            Text("Desktop Pet")
        } footer: {
            Text("Click the pet to pat it, drag it anywhere on screen, or double-click it to start or stop live voice mode.")
        }
    }

    private var voiceModeSection: some View {
        Section {
            Picker("Active Voice Engine", selection: $controller.configuration.voiceMode) {
                ForEach(PetVoiceModeKind.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
        } header: {
            Text("Voice Mode")
        } footer: {
            Text(controller.configuration.voiceMode.summary)
        }
    }

    private var codexRealtimeSection: some View {
        Section {
            Picker("Transport", selection: $controller.configuration.codexTransport) {
                ForEach(CodexRealtimeTransportPreference.allCases) { transport in
                    Text(transport.title).tag(transport)
                }
            }

            Picker("Realtime Voice", selection: $controller.configuration.codexVoice) {
                ForEach(CodexRealtimeVoicePreset.allCases) { preset in
                    Text(preset.displayName).tag(preset.rawValue)
                }
            }

            TextField("Optional Realtime Model Override (default managed by Codex)", text: $controller.configuration.codexRealtimeModel)
        } header: {
            Text("Codex Realtime")
        } footer: {
            Text("Codex Realtime connects through RxAgentSDK and exposes RxCode IDE tools so you can manage tasks, send threads, and open interactive views by voice.")
        }
    }

    private var customAgentSection: some View {
        Section {
            Picker("Conversation Language", selection: $controller.configuration.conversationLanguageIdentifier) {
                Text("Automatic").tag(nil as String?)
                ForEach(Self.supportedLocales, id: \.id) { locale in
                    Text(locale.label).tag(Optional(locale.id))
                }
            }
            .help("Controls replies and notification announcements in both voice modes. Automatic follows the conversation. Speech recognition and TTS voice are configured separately.")
            LabeledContent("Agent Model") {
                Menu {
                    Button {
                        controller.configuration.customAgent = nil
                    } label: {
                        HStack {
                            Text("Workspace Default (\(appState.taskAgentLabel(appState.defaultTaskAgent())))")
                            if controller.configuration.customAgent == nil {
                                Image(systemName: "checkmark")
                            }
                        }
                    }

                    Divider()

                    ForEach(appState.availableAgentModelSections(), id: \.id) { section in
                        Section(section.title) {
                            ForEach(section.models, id: \.key) { model in
                                Button {
                                    controller.configuration.customAgent = TaskAgentConfig(
                                        provider: model.provider,
                                        model: model.id
                                    )
                                } label: {
                                    HStack {
                                        Text(model.displayName)
                                        if controller.configuration.customAgent?.provider == model.provider,
                                           controller.configuration.customAgent?.model == model.id {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                        Text(customAgentSelectionLabel)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.borderedButton)
            }
        } header: {
            Text("General Agent")
        } footer: {
            Text("Used for typed conversations, daily report summaries, and Local Speech voice mode. Choose any available Claude Code, Codex, ACP client, or RxCode Local Agent model with RxCode IDE tools. Codex Realtime has its own model in the Voice tab.")
        }
    }

    private var notificationModelSection: some View {
        Section {
            LabeledContent("Notification Model") {
                Menu {
                    Button {
                        controller.configuration.notificationAgent = nil
                    } label: {
                        HStack {
                            Text("Apple Intelligence (On-Device)")
                            if controller.configuration.notificationAgent == nil { Image(systemName: "checkmark") }
                        }
                    }
                    Divider()
                    ForEach(appState.availableAgentModelSections(), id: \.id) { section in
                        Section(section.title) {
                            ForEach(section.models.filter { model in
                                model.provider != .localAgent || appState.localModels.model(id: model.id)?.studioKind == .chat
                            }, id: \.key) { model in
                                Button {
                                    controller.configuration.notificationAgent = TaskAgentConfig(provider: model.provider, model: model.id)
                                } label: {
                                    HStack {
                                        Text(model.displayName)
                                        if controller.configuration.notificationAgent == TaskAgentConfig(provider: model.provider, model: model.id) {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Text(controller.configuration.notificationAgent.map { appState.taskAgentLabel($0) }
                         ?? "Apple Intelligence (On-Device)")
                }
                .menuStyle(.borderedButton)
            }
            if controller.configuration.notificationAgent == nil,
               let reason = FoundationModelSummarizationService.unavailabilityReason {
                Text("\(reason) Original notification text will be used until it is available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Notification Text")
        } footer: {
            Text("Generates notification summaries and translations independently of the General Agent. Defaults to Apple Intelligence. Supports Claude Code, Codex, ACP clients, and installed local text models (MLX / GGUF). During calls, the voice assistant announces updates. If generation fails, the original text is preserved.")
        }
    }

    private var localSpeechRecognitionSection: some View {
        Section {
            Picker("Speech Recognizer", selection: $controller.configuration.localSpeechSource) {
                ForEach(PetLocalSpeechSource.allCases) { source in
                    Text(source.title).tag(source)
                }
            }

            Picker("Spoken Language", selection: $controller.configuration.speechLocaleIdentifier) {
                if !Self.supportedLocales.contains(where: { $0.id == controller.configuration.speechLocaleIdentifier }) {
                    Text(controller.configuration.speechLocaleIdentifier)
                        .tag(controller.configuration.speechLocaleIdentifier)
                }
                ForEach(Self.supportedLocales, id: \.id) { locale in
                    Text(locale.label).tag(locale.id)
                }
            }

            if controller.configuration.localSpeechSource == .localWhisperModel {
                if installedTranscriptionModels.isEmpty {
                    Text("No local transcription model is installed yet. Apple on-device speech recognition will be used automatically until you install an audio transcription model in Local Models.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Transcription Model", selection: $controller.configuration.localSTTModelID) {
                        Text("Automatic (\(installedTranscriptionModels[0].displayName))")
                            .tag(Optional<String>.none)
                        ForEach(installedTranscriptionModels) { model in
                            Text("\(model.displayName) (\(model.format.label))")
                                .tag(Optional(model.id))
                        }
                    }
                }
            }
        } header: {
            Text("Local Speech Recognition")
        }
    }

    private var localVoiceSynthesisSection: some View {
        Section {
            Picker("Voice Model", selection: $controller.configuration.localTTSModelID) {
                Text("macOS System Voice (Zero-Download)").tag(PetConfiguration.systemTTSModelID)
                ForEach(installedSpeechSynthesisModels) { model in
                    Text("\(model.displayName) (\(model.format.label))").tag(model.id)
                }
            }

            if controller.configuration.localTTSModelID == PetConfiguration.systemTTSModelID {
                LabeledContent("Apple Voice") {
                    Button {
                        isEditingAppleVoice = true
                    } label: {
                        HStack(spacing: 6) {
                            Text(appleVoiceSummary)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Choose a Premium, Enhanced, Personal, or Siri voice. Siri voices are used through the Spoken Content System Voice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                neuralVoicePicker
            }

            if controller.configuration.localTTSModelID != PetConfiguration.systemTTSModelID {
                TextField("Voice Seed", value: Binding(
                    get: { controller.configuration.resolvedLocalTTSSeed },
                    set: { controller.configuration.localTTSSeed = max(0, min($0, Int(Int32.max))) }
                ), format: .number.grouping(.never))
                Button("Choose New Random Seed") {
                    controller.configuration.localTTSSeed = Int.random(in: 0...Int(Int32.max))
                }
                Text("The seed stays the same for replies and notifications until you change it. Choose a new random seed to try another voice variation. Its effect depends on the model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Speech Speed") {
                HStack(spacing: 10) {
                    Slider(value: $controller.configuration.speechRate, in: 0.75...1.35, step: 0.05)
                        .frame(maxWidth: 200)
                    Text(String(format: "%.2fx", controller.configuration.speechRate))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
            }

            HStack(spacing: 10) {
                Button {
                    controller.previewVoiceSample()
                } label: {
                    Label("Preview Voice", systemImage: "play.circle")
                }

                Spacer()

                Button {
                    selectedTab = .voices
                } label: {
                    Label("Manage Voices…", systemImage: "person.wave.2")
                }
            }
        } header: {
            Text("Local Voice Model (TTS)")
        } footer: {
            Text("Install neural MLX or GGUF text-to-speech models (such as Kokoro-82M) for natural local speech, or use the built-in macOS voice immediately.")
        }
        .onChange(of: controller.configuration.localTTSModelID) { _, modelID in
            if let model = installedSpeechSynthesisModels.first(where: { $0.id == modelID }) {
                PetVoicePresets.select(model: model, in: controller)
            }
        }
    }

    /// README-derived voices when the setup agent has analyzed the model,
    /// Kokoro's built-in list otherwise, else free text.
    @ViewBuilder
    private var neuralVoicePicker: some View {
        let modelID = controller.configuration.localTTSModelID
        let config = StudioModelConfig.decodeAll(studioConfigs)[modelID]
        let current = controller.configuration.localTTSVoicePreset
        if let options = PetVoicePresets.options(modelID: modelID, config: config) {
            Picker(PetVoicePresets.voiceParameter(in: config)?.label ?? "Neural Voice",
                   selection: $controller.configuration.localTTSVoicePreset) {
                if !options.contains(where: { $0.id == current }) {
                    Text("\(current.isEmpty ? "Model Default" : current) (Not Listed)").tag(current)
                }
                ForEach(options) { option in
                    Text(option.label).tag(option.id)
                }
            }
        } else if modelID.localizedCaseInsensitiveContains("qwen3-tts"),
                  modelID.localizedCaseInsensitiveContains("-base") {
            LabeledContent("Neural Voice", value: "Model Default")
        } else {
            TextField("Model Voice", text: $controller.configuration.localTTSVoicePreset, prompt: Text("Model Default"))
        }
        if let model = installedSpeechSynthesisModels.first(where: { $0.id == modelID }) {
            Button("Voice Settings…") { editingVoiceModel = model }
            Text(config == nil
                 ? "Voice Settings can read this model's README to find every speaker it supports."
                 : "Voices come from this model's README, read by the setup agent.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var projectScopeSection: some View {
        Section {
            Picker("Default Project Scope", selection: $controller.configuration.pinnedProjectId) {
                Text("First / Active Workspace Project").tag(Optional<UUID>.none)
                ForEach(appState.projects) { project in
                    Text(project.name).tag(Optional(project.id))
                }
            }
        } header: {
            Text("Workspace & Project Scope")
        } footer: {
            Text("Used as the default working directory when starting threads or running tasks with the pet. You can still name any project in the workspace during conversation.")
        }
    }

    private var proactiveAndDailyReportSection: some View {
        Section {
            Picker("When Background Works Finish or Need Input", selection: $controller.configuration.proactiveMode) {
                ForEach(PetProactiveMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }

            Toggle("Scheduled Daily Workspace Report", isOn: $controller.configuration.dailyReportAutoEnabled)

            if controller.configuration.dailyReportAutoEnabled {
                DatePicker(
                    "Report Time",
                    selection: dailyReportTimeBinding,
                    displayedComponents: .hourAndMinute
                )
            }

            Button {
                Task {
                    await controller.triggerDailyReport(speakAloud: true, openSheet: true)
                }
            } label: {
                Label("Generate Daily Report Now", systemImage: "doc.text.magnifyingglass")
            }
            .disabled(controller.isGeneratingDailyReport)
        } header: {
            Text("Proactive Talk & Daily Report")
        } footer: {
            Text("\(controller.character.displayName) proactively reacts when coding sessions finish, request permissions or answers, or when CI fails.")
        }
    }

    // MARK: - Helpers

    private var customAgentSelectionLabel: String {
        guard let custom = controller.configuration.customAgent else {
            return "Workspace Default (\(appState.taskAgentLabel(appState.defaultTaskAgent())))"
        }
        return appState.taskAgentLabel(custom)
    }

    private var dailyReportTimeBinding: Binding<Date> {
        Binding(
            get: {
                var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                comps.hour = controller.configuration.dailyReportHour
                comps.minute = controller.configuration.dailyReportMinute
                return Calendar.current.date(from: comps) ?? Date()
            },
            set: { newDate in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                controller.configuration.dailyReportHour = comps.hour ?? 9
                controller.configuration.dailyReportMinute = comps.minute ?? 30
            }
        )
    }
}
