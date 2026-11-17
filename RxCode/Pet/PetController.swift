import AppKit
import Foundation
import Observation
import os
import RxAgentClients
import RxAgentCore
import RxAgentVoice
import RxCodeCore

// MARK: - Companion Sheet Destinations

enum PetSheetDestination: String, Identifiable, Sendable {
    case dailyReport

    var id: String { rawValue }
}

enum PetWindows {
    static let companionID = "pet-companion-window"
    static let settingsID = "pet-settings-window"
}

// MARK: - Process-Global Desktop Pet & Voice Coordinator

@MainActor
@Observable
final class PetController {
    static let shared = PetController()

    let logger = Logger(subsystem: "com.claudework", category: "PetController")

    weak var workspaceManager: WorkspaceManager?

    var configuration: PetConfiguration {
        didSet {
            guard configuration != oldValue else { return }
            configuration.save()
            handleConfigurationChange(from: oldValue, to: configuration)
        }
    }

    let looks: PetLookStore
    var character: PetCharacter { looks.selected.character }
    var petState = PetState()

    struct ChatEntry: Identifiable {
        let id = UUID()
        let isUser: Bool
        var text: String
    }

    var chatTranscript: [ChatEntry] = []
    var isSendingText = false
    @ObservationIgnored var voiceTextReplyBaseline: Set<UUID>?
    @ObservationIgnored var announcedPermissionEventIDs: [String] = []
    @ObservationIgnored var notificationLocalizationTask: Task<Void, Never>?
    @ObservationIgnored private var textResumeSessionID: String?
    @ObservationIgnored private var textConversationID = UUID()
    @ObservationIgnored private var localVoiceWarmupTask: Task<Void, Never>?

    var voiceSession: VoiceSession?
    var activeVoiceMode: PetVoiceModeKind?
    var livePartialUserText: String = ""
    var isLocalUserSpeaking = false
    var toolActivity = PetToolActivity()
    @ObservationIgnored var realtimeToolCueMute: (@Sendable (Bool) -> Void)?
    @ObservationIgnored var toolSoundTask: Task<Void, Never>?
    @ObservationIgnored var toolExpiryTask: Task<Void, Never>?
    @ObservationIgnored var toolSounds = PetToolSoundPlayer()
    @ObservationIgnored var voiceConnectingSounds = PetToolSoundPlayer(loadingSoundName: "Submarine")
    @ObservationIgnored var voiceConnectedSound: NSSound?
    var activeToolDescription: String?
    var isTakingPhoto = false
    var isFacingLeft = false
    @ObservationIgnored lazy var presentation = PetPresentation(controller: self)
    @ObservationIgnored lazy var desktopActions = PetDesktopActions(controller: self)
    @ObservationIgnored lazy var music = PetMusic(controller: self)
    @ObservationIgnored lazy var screenCapture = PetScreenCapture(controller: self)
    var actionStatusOverlayMessage: String?
    var latestDailyReport: PetDailyReport?
    var isGeneratingDailyReport = false
    var isStandaloneSpeaking = false
    var standaloneOutputLevel: Float = 0
    @ObservationIgnored let speechPlayback = PetSpeechPlaybackSignal()

    var settingsTab: PetSettingsView.SettingsTab = .generalAgent
    var isMuted: Bool { configuration.isMuted ?? false }
    @ObservationIgnored var voiceStartGeneration = UUID()
    @ObservationIgnored var speechPermissionGeneration = UUID()
    @ObservationIgnored weak var voiceDraftPreview: PetVoiceDraftPreview?

    var activeSheet: PetSheetDestination?
    var alertErrorMessage: String?
    var openWindowAction: ((String) -> Void)?

    // Persistent voice subsystems
    @ObservationIgnored lazy var panelController = PetPanelController(controller: self)
    @ObservationIgnored lazy var standaloneSpeaker: PetStandaloneSpeaker = {
        let speaker = PetStandaloneSpeaker()
        speaker.speechPlayback = speechPlayback
        speaker.outputDeviceUID = { [weak self] in self?.configuration.speakerDeviceUID }
        speaker.onSpeakingStateChanged = { [weak self] speaking, level in
            guard let self else { return }
            self.isStandaloneSpeaking = speaking
            self.standaloneOutputLevel = level
            self.refreshPetState()
        }
        speaker.onFailure = { [weak self] message in
            self?.alertErrorMessage = message
        }
        return speaker
    }()

    @ObservationIgnored lazy var localRecognizer = PetLocalSpeechRecognizer { @MainActor [weak self] in
        let cfg = self?.configuration ?? PetConfiguration()
        return PetLocalSpeechRecognizer.Configuration(
            source: cfg.localSpeechSource,
            localeIdentifier: cfg.speechLocaleIdentifier,
            localModelID: cfg.localSTTModelID,
            onPartialTranscript: { [weak self] text in
                Task { @MainActor [weak self] in
                    self?.livePartialUserText = text
                    self?.refreshPetState()
                }
            },
            onSpeechActivityChanged: { [weak self] speaking in
                Task { @MainActor [weak self] in
                    self?.isLocalUserSpeaking = speaking
                    if speaking {
                        self?.hidePreviousToolCalls()
                        self?.standaloneSpeaker.stop()
                    }
                    self?.lastInteractionAt = .now
                    self?.refreshPetState()
                }
            }
        )
    }

    @ObservationIgnored lazy var localSynthesizer = PetLocalSpeechSynthesizer { @MainActor [weak self] in
        let cfg = self?.configuration ?? PetConfiguration()
        return PetLocalSpeechSynthesizer.Configuration(
            modelID: cfg.localTTSModelID,
            voicePreset: cfg.localTTSVoicePreset,
            systemVoiceIdentifier: cfg.systemVoiceIdentifier,
            localeIdentifier: cfg.conversationLanguageIdentifier ?? cfg.speechLocaleIdentifier,
            speechRate: cfg.speechRate,
            seed: cfg.resolvedLocalTTSSeed,
            onStatusUpdate: { [weak self] status in
                Task { @MainActor [weak self] in
                    self?.actionStatusOverlayMessage = status
                }
            }
        )
    }

    @ObservationIgnored lazy var customAgentResponder = PetCustomAgentResponder(
        buildTurnSetup: { [weak self] text, _, resumeID in
            guard let self else { throw VoiceError.invalidState }
            return try await self.prepareCustomAgentTurn(
                userText: text,
                resumeSessionID: resumeID
            )
        },
        onToolEvent: { [weak self] event in
            await self?.handlePetToolEvent(event)
        }
    )

    @ObservationIgnored weak var currentHardwareAudioDriver: PetVoiceAudioDriver?
    @ObservationIgnored var activePipelineSessionKey: String?
    @ObservationIgnored var stateSyncTask: Task<Void, Never>?
    @ObservationIgnored var schedulerTask: Task<Void, Never>?
    @ObservationIgnored var bubbleDismissTask: Task<Void, Never>?
    @ObservationIgnored var transientStatusResetTask: Task<Void, Never>?
    @ObservationIgnored var queuedProactiveSpeech: [String] = []
    @ObservationIgnored var announcementTask: Task<Void, Never>?
    @ObservationIgnored var announcementGeneration = UUID()
    @ObservationIgnored var lastInteractionAt: Date = .now
    @ObservationIgnored var lastObservedConfirmationIDs: Set<UUID> = []

    init(defaults: UserDefaults = .standard) {
        self.configuration = PetConfiguration.load(from: defaults)
        self.looks = PetLookStore(defaults: defaults)
    }

    var appState: AppState? {
        workspaceManager?.frontmostAppState
    }

    var isVoiceActive: Bool {
        guard let lifecycle = voiceSession?.lifecycle else { return false }
        switch lifecycle {
        case .active, .connecting, .paused:
            return true
        case .idle, .stopping, .stopped, .failed:
            return false
        }
    }

    var inputLevel: Float {
        voiceSession?.meters.input ?? 0
    }

    var outputLevel: Float {
        max(voiceSession?.meters.output ?? 0, standaloneOutputLevel)
    }

    // MARK: - Bootstrap & Panel Lifecycle

    func bind(to workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
        guard !AppSupport.isTestProcess && !AppSupport.isScreenshotCapture else { return }
        if configuration.isEnabled {
            panelController.show()
            prepareLocalVoiceIfNeeded()
        }
        startBackgroundMonitorIfNeeded()
    }

    func setPetEnabled(_ enabled: Bool) {
        configuration.isEnabled = enabled
    }

    private func handleConfigurationChange(from old: PetConfiguration, to new: PetConfiguration) {
        if old.isMuted != new.isMuted {
            if isMuted {
                voiceStartGeneration = UUID()
                speechPermissionGeneration = UUID()
                queuedProactiveSpeech.removeAll()
                announcementGeneration = UUID()
                announcementTask?.cancel()
                announcementTask = nil
                voiceConnectingSounds.update(isRunning: false, didFinish: false)
                voiceConnectedSound?.stop()
                voiceSession?.setMuted(true)
                interruptSpeaking()
                Task { await stopVoice(drainAnnouncements: false) }
            }
        }
        refreshToolSounds()
        if old.isEnabled != new.isEnabled || old.localTTSModelID != new.localTTSModelID
            || old.voiceMode != new.voiceMode || old.proactiveMode != new.proactiveMode {
            prepareLocalVoiceIfNeeded()
        }
        if old.isEnabled != new.isEnabled {
            if new.isEnabled {
                if !AppSupport.isTestProcess && !AppSupport.isScreenshotCapture {
                    panelController.show()
                    startBackgroundMonitorIfNeeded()
                }
            } else {
                Task { await stopVoice() }
                standaloneSpeaker.stop()
                panelController.hide()
            }
        }
        if old.petSize != new.petSize && new.isEnabled {
            panelController.updatePanelLayout()
        }
        if isVoiceActive && (old.voiceMode != new.voiceMode
            || old.conversationLanguageIdentifier != new.conversationLanguageIdentifier
            || old.microphoneDeviceUID != new.microphoneDeviceUID
            || old.speakerDeviceUID != new.speakerDeviceUID) {
            Task { await restartVoiceSession() }
        }
        if old.customAgent != new.customAgent || old.pinnedProjectId != new.pinnedProjectId
            || old.conversationLanguageIdentifier != new.conversationLanguageIdentifier {
            textResumeSessionID = nil
            textConversationID = UUID()
            Task { await customAgentResponder.resetConversation() }
        }
    }

    private func prepareLocalVoiceIfNeeded() {
        localVoiceWarmupTask?.cancel()
        guard !AppSupport.isTestProcess, !AppSupport.isScreenshotCapture,
              configuration.isEnabled,
              configuration.voiceMode == .localPipeline || configuration.proactiveMode == .voiceAndBubble else { return }
        let synthesizer = localSynthesizer
        localVoiceWarmupTask = Task { await synthesizer.warmUp() }
    }

    // MARK: - User Interactions with Pet

    func pat() {
        lastInteractionAt = .now
        petState.patReactionCount &+= 1
        let greetings = [
            "Hi! Ready to help with your tasks and threads.",
            "All ears! Click the phone anytime to talk.",
            "Purr… let me know what we are shipping next!",
            "Need a standup summary? Try Daily Report!",
        ]
        let index = abs(petState.patReactionCount) % greetings.count
        if petState.status == .sleeping {
            petState.status = .idle
        }
        petState.mood = .happy
        showBubble(
            PetBubbleMessage(
                title: character.displayName,
                text: greetings[index],
                isProactive: false,
                action: isVoiceActive ? nil : .openCompanion
            ),
            duration: 6.0
        )
        scheduleTransientMoodReset(after: 3.0)
    }

    func setWalking(_ walking: Bool) {
        lastInteractionAt = .now
        if petState.isWalking != walking {
            petState.isWalking = walking
            if walking && petState.status == .sleeping {
                petState.status = .idle
            }
        }
    }

    func wakeIfSleeping() {
        lastInteractionAt = .now
        if petState.status == .sleeping {
            petState.status = .idle
            petState.mood = .neutral
        }
    }

    func dismissBubble() {
        bubbleDismissTask?.cancel()
        bubbleDismissTask = nil
        petState.bubble = nil
        panelController.updatePanelLayout()
    }

    func performQuickAction(_ action: PetQuickAction) {
        lastInteractionAt = .now
        switch action {
        case .openCompanion:
            openCompanionWindow()
        case .openVoiceSettings:
            openSettingsWindow()
        case .openDailyReport:
            openCompanionWindow(sheet: .dailyReport)
        case .openURL(let url):
            NSWorkspace.shared.open(url)
        case .openPendingPrompt:
            openCompanionWindow()
        case .openThread(_, let sessionId):
            if let appState {
                var components = URLComponents()
                components.scheme = "rxcode"
                components.host = "widget"
                components.path = "/thread"
                components.queryItems = [
                    URLQueryItem(name: "workspace", value: appState.activeWorkspace.id),
                    URLQueryItem(name: "thread", value: sessionId),
                ]
                if let url = components.url {
                    NSApp.activate(ignoringOtherApps: true)
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    func openSettingsWindow(tab: PetSettingsView.SettingsTab = .generalAgent) {
        settingsTab = tab
        NSApp.activate(ignoringOtherApps: true)
        if let openWindowAction {
            openWindowAction(PetWindows.settingsID)
        } else if let existing = NSApp.windows.first(where: { $0.identifier?.rawValue == PetWindows.settingsID }) {
            existing.makeKeyAndOrderFront(nil)
        }
    }

    func openCompanionWindow(sheet: PetSheetDestination? = nil) {
        lastInteractionAt = .now
        if let sheet {
            activeSheet = sheet
        }
        NSApp.activate(ignoringOtherApps: true)
        if let openWindowAction {
            openWindowAction(PetWindows.companionID)
        } else if let existing = NSApp.windows.first(where: { $0.identifier?.rawValue == PetWindows.companionID || $0.title == "Pet Companion" }) {
            existing.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Voice Session Control (Codex Realtime & Local Pipeline)

    func toggleVoice() {
        Task {
            if isVoiceActive {
                await stopVoice()
            } else {
                await startVoice()
            }
        }
    }

    func startVoice(mode overrideMode: PetVoiceModeKind? = nil) async {
        guard !isMuted, !AppSupport.isTestProcess else { return }
        let generation = UUID()
        voiceStartGeneration = generation
        lastInteractionAt = .now
        if let overrideMode, configuration.voiceMode != overrideMode {
            configuration.voiceMode = overrideMode
        }
        let targetMode = configuration.voiceMode
        if targetMode == .localPipeline { prepareLocalVoiceIfNeeded() }
        await stopVoice(drainAnnouncements: false)
        guard !isMuted, voiceStartGeneration == generation else { return }
        standaloneSpeaker.stop()

        if !configuration.isEnabled {
            configuration.isEnabled = true
        }

        actionStatusOverlayMessage = "Connecting \(targetMode.shortTitle)…"
        voiceConnectingSounds.update(isRunning: targetMode == .codexRealtime, didFinish: false)
        activeToolDescription = nil
        livePartialUserText = ""
        isLocalUserSpeaking = false
        petState.status = .thinking
        petState.mood = .focused

        do {
            let session = try await buildVoiceSession(for: targetMode)
            guard !isMuted, voiceStartGeneration == generation else {
                await session.stop()
                return
            }
            self.voiceSession = session
            self.activeVoiceMode = targetMode
            try await session.start()
            guard !isMuted, voiceStartGeneration == generation else {
                if self.voiceSession === session {
                    await stopVoice(drainAnnouncements: false)
                } else {
                    await session.stop()
                }
                return
            }
            if targetMode == .localPipeline {
                actionStatusOverlayMessage = nil
                // The local pipeline has no remote "connected" event; it's live once started.
                playVoiceConnectedSound()
            }
            startVoiceStateSyncLoop(for: session)
            startAnnouncementDeliveryIfNeeded()
            refreshPetState()
        } catch {
            guard !isMuted, voiceStartGeneration == generation else { return }
            voiceConnectingSounds.update(isRunning: false, didFinish: false)
            actionStatusOverlayMessage = nil
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            alertErrorMessage = message
            petState.status = .failed
            petState.mood = .concerned
            showBubble(
                PetBubbleMessage(
                    title: "Voice Unavailable",
                    text: message,
                    isProactive: false,
                    action: .openVoiceSettings
                ),
                duration: 10.0
            )
            scheduleTransientMoodReset(after: 5.0)
        }
    }

    func restartVoiceSession() async {
        await startVoice(mode: configuration.voiceMode)
    }

    func stopVoice(drainAnnouncements: Bool = true) async {
        voiceConnectingSounds.update(isRunning: false, didFinish: false)
        screenCapture.cancel()
        desktopActions.cancel()
        speechPlayback.reset()
        speechPlayback.setSuppressed(false)
        voiceTextReplyBaseline = nil
        announcementGeneration = UUID()
        announcementTask?.cancel()
        announcementTask = nil
        stateSyncTask?.cancel()
        stateSyncTask = nil
        voiceConnectedSound?.stop()
        voiceConnectedSound = nil
        handlePetToolEvent(nil)
        livePartialUserText = ""
        isLocalUserSpeaking = false
        activeToolDescription = nil
        actionStatusOverlayMessage = nil
        currentHardwareAudioDriver = nil

        if let session = voiceSession {
            voiceSession = nil
            activeVoiceMode = nil
            await session.stop()
        }
        if let pipelineKey = activePipelineSessionKey, let ideMCP = appState?.ideMCPServer {
            activePipelineSessionKey = nil
            await ideMCP.release(sessionKey: pipelineKey)
        }
        await localSynthesizer.cancelAll()
        if drainAnnouncements, !queuedProactiveSpeech.isEmpty {
            if configuration.isEnabled {
                startAnnouncementDeliveryIfNeeded()
            }
        }
        refreshPetState()
    }

    func toggleMute() {
        configuration.isMuted = !isMuted
        refreshPetState()
    }

    func interruptSpeaking() {
        screenCapture.cancel()
        desktopActions.cancel()
        speechPlayback.reset()
        standaloneSpeaker.stop()
        voiceDraftPreview?.stop()
        voiceSession?.interrupt()
        Task { await localSynthesizer.cancelAll() }
        refreshPetState()
    }

    func sendTextMessage(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSendingText else { return }
        lastInteractionAt = .now
        hidePreviousToolCalls()
        if isVoiceActive, let session = voiceSession {
            voiceTextReplyBaseline = Set(session.transcript.filter { !$0.isUser }.map(\.id))
            do {
                try await session.send(text: trimmed)
            } catch {
                voiceTextReplyBaseline = nil
                alertErrorMessage = error.localizedDescription
            }
            return
        }
        guard let appState else { return }
        isSendingText = true
        let conversationID = textConversationID
        let sessionKey = "pet-chat-\(conversationID.uuidString.lowercased())"
        chatTranscript.append(ChatEntry(isUser: true, text: trimmed))
        let reply = ChatEntry(isUser: false, text: "")
        chatTranscript.append(reply)
        defer {
            isSendingText = false
            handlePetToolEvent(nil)
            Task { await appState.ideMCPServer.release(sessionKey: sessionKey) }
        }
        do {
            let setup = try await prepareCustomAgentTurn(
                userText: trimmed,
                resumeSessionID: textResumeSessionID, sessionKeyOverride: sessionKey
            )
            for await event in setup.client.send(setup.sendRequest) {
                switch event {
                case .sessionStarted(let info):
                    if conversationID == textConversationID {
                        textResumeSessionID = info.nativeSessionID
                    }
                case .textDelta(let delta):
                    if let index = chatTranscript.firstIndex(where: { $0.id == reply.id }) {
                        chatTranscript[index].text += delta
                    }
                case .toolCallStarted, .toolCallResult, .turnEnded:
                    handlePetToolEvent(event)
                case .failed(let error):
                    alertErrorMessage = error.localizedDescription
                default:
                    break
                }
            }
        } catch {
            alertErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Proactive Talk & Daily Report

    /// A companion-origin approval was already explained by the current assistant.
    /// Other permission events are keyed by their tool-use ID, never by message text.
    func shouldAnnouncePermission(eventID: String, sessionID: String?) -> Bool {
        guard isVoiceActive else { return true }
        guard !announcedPermissionEventIDs.contains(eventID) else { return false }
        announcedPermissionEventIDs.append(eventID)
        if announcedPermissionEventIDs.count > 256 { announcedPermissionEventIDs.removeFirst() }
        return sessionID?.hasPrefix("pet-") != true
    }

    func notifyProactiveEvent(
        title: String?,
        spokenText: String,
        mood: PetMood,
        status: PetStatus,
        action: PetQuickAction?
    ) {
        guard configuration.isEnabled, isVoiceActive || configuration.proactiveMode != .off else { return }
        guard !configuration.conversationLanguageInstruction.isEmpty, appState != nil else {
            presentProactiveEvent(title: title, spokenText: spokenText, mood: mood, status: status, action: action)
            return
        }
        let speechGeneration = speechPermissionGeneration
        let allowsSpeech = !isMuted
        // Serialize translations so slower completions cannot reorder notifications.
        let previous = notificationLocalizationTask
        notificationLocalizationTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            var language: String?
            var localized = (title: title, text: spokenText)
            repeat {
                language = self.configuration.conversationLanguageIdentifier
                localized = await Self.localizeNotification(
                    title: title, text: spokenText, configuration: self.configuration
                ) { prompt in
                    await self.completeNotification(prompt)
                }
            } while !Task.isCancelled && language != self.configuration.conversationLanguageIdentifier
            guard !Task.isCancelled else { return }
            self.presentProactiveEvent(
                title: localized.title, spokenText: localized.text, mood: mood, status: status, action: action,
                allowsSpeech: allowsSpeech && self.speechPermissionGeneration == speechGeneration
            )
        }
    }

    private func presentProactiveEvent(
        title: String?, spokenText: String, mood: PetMood, status: PetStatus, action: PetQuickAction?,
        allowsSpeech: Bool = true
    ) {
        guard configuration.isEnabled, isVoiceActive || configuration.proactiveMode != .off else { return }
        lastInteractionAt = .now
        petState.mood = mood
        petState.status = status

        showBubble(
            PetBubbleMessage(
                title: title,
                text: spokenText,
                isProactive: true,
                action: action
            ),
            duration: 16.0
        )
        scheduleTransientMoodReset(after: 7.0)

        guard allowsSpeech, isVoiceActive || configuration.proactiveMode == .voiceAndBubble else { return }
        speakProactivelyOrQueue(spokenText)
    }

    func triggerDailyReport(speakAloud: Bool = true, openSheet: Bool = false) async {
        guard let appState else { return }
        guard !isGeneratingDailyReport else { return }
        lastInteractionAt = .now
        isGeneratingDailyReport = true
        actionStatusOverlayMessage = "Generating daily workspace report…"
        petState.status = .thinking
        petState.mood = .focused

        let speechGeneration = speechPermissionGeneration
        let allowsSpeech = speakAloud && !isMuted
        let report = await PetDailyReportService.generate(for: appState)
        latestDailyReport = report
        isGeneratingDailyReport = false
        actionStatusOverlayMessage = nil

        petState.mood = report.ciFailing ? .concerned : .happy
        petState.status = .celebrating
        showBubble(
            PetBubbleMessage(
                title: "Daily Report · \(report.workspaceName)",
                text: report.spokenSummary,
                isProactive: true,
                action: .openDailyReport
            ),
            duration: 20.0
        )
        scheduleTransientMoodReset(after: 6.0)

        if openSheet {
            openCompanionWindow(sheet: .dailyReport)
        }
        if allowsSpeech, speechPermissionGeneration == speechGeneration {
            speakProactivelyOrQueue(report.spokenSummary)
        }
    }

    func readReportAloud(_ report: PetDailyReport) {
        speakProactivelyOrQueue(report.spokenSummary)
    }

    func previewVoiceSample(_ sampleText: String = "Hi there! I am RxBuddy, your RxCode voice companion.") {
        guard !isMuted else { return }
        Task {
            await stopVoice(drainAnnouncements: false)
            guard !isMuted else { return }
            standaloneSpeaker.speak(text: sampleText, synthesizer: localSynthesizer)
        }
    }
}
