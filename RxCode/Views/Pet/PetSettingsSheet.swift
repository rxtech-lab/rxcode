import AppKit
import AVFoundation
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
    @State private var isEditingCodexVoice = false

    private static let supportedLocales = PetConfiguration.supportedConversationLocales

    private var installedTranscriptionModels: [LocalModelInfo] {
        appState.localModels.installed.filter { LocalAudioMode(model: $0) == .transcription }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                settingsTabBar
                ClaudeThemeDivider()
                if selectedTab == .looks {
                    PetLooksPane(controller: controller)
                } else {
                    Form {
                        switch selectedTab {
                        case .generalAgent:
                            customAgentSection
                            notificationModelSection
                            projectScopeSection
                        case .voice:
                            voiceModeSection
                            if controller.configuration.voiceMode == .codexRealtime {
                                codexRealtimeSection
                            }
                            speechVoiceSection
                            if controller.configuration.voiceMode == .localPipeline {
                                Section("Conversation Agent") {
                                    LabeledContent("Agent Model", value: customAgentSelectionLabel)
                                    Button("Choose General Agent…") { selectedTab = .generalAgent }
                                }
                                localSpeechRecognitionSection
                            }
                            audioDevicesSection
                            microphoneSection
                        case .looks:
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
            PetAudioTestSheet(test: test, controller: controller)
        }
        .sheet(isPresented: $controller.isChoosingSpeechVoice) {
            PetVoiceModelsPane(controller: controller)
        }
        .sheet(isPresented: $isEditingCodexVoice) {
            PetCodexVoiceSheet(controller: controller)
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
            .foregroundStyle(ClaudeTheme.textPrimary, ClaudeTheme.textSecondary, ClaudeTheme.textTertiary)
        } header: {
            Text("Voice Mode")
        } footer: {
            Text(controller.configuration.voiceMode.summary)
        }
    }

    private var codexRealtimeSection: some View {
        Section("Codex Realtime") {
            LabeledContent("Call Voice", value: controller.configuration.resolvedCodexVoice.displayName)
            Button("Configure Codex Realtime…") { isEditingCodexVoice = true }
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

    private var speechVoiceSection: some View {
        let usesCodex = controller.configuration.voiceMode == .codexRealtime
        return Section {
            LabeledContent("Selected Voice", value: speechVoiceSummary)
            HStack {
                Button("Choose Speech Voice…") { controller.isChoosingSpeechVoice = true }
                Button("Preview Voice") { controller.previewVoiceSample() }
                    .disabled(controller.isMuted)
            }
        } header: {
            Text(usesCodex ? "Notification Voice" : "Reply and Notification Voice")
        } footer: {
            if usesCodex {
                Text("Choose an Apple voice, installed voice model, or Flowcy voice for notifications outside calls. During a call, Codex Realtime speaks notifications.")
            } else {
                Text("Choose an Apple voice, installed voice model, or Flowcy voice for spoken replies and notifications.")
            }
        }
    }

    private var speechVoiceSummary: String {
        let config = controller.configuration
        if let selection = config.flowcyVoice {
            return "Flowcy · \(selection.model.alias) · \(selection.voice.name)"
        }
        if config.localTTSModelID == PetConfiguration.systemTTSModelID {
            return "Apple · \(config.appleVoiceSummary)"
        }
        let model = appState.localModels.model(id: config.localTTSModelID)?.displayName ?? config.localTTSModelID
        return config.localTTSVoicePreset.isEmpty ? model : "\(model) · \(config.localTTSVoicePreset)"
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
