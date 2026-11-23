import Foundation
import RxAgentVoice
import RxCodeCore

extension PetController {
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
        action: PetQuickAction?,
        allowsSpeech: Bool = true
    ) {
        guard configuration.isEnabled, configuration.proactiveMode != .off else { return }
        guard !configuration.conversationLanguageInstruction.isEmpty, appState != nil else {
            presentProactiveEvent(title: title, spokenText: spokenText, mood: mood, status: status, action: action, allowsSpeech: allowsSpeech)
            return
        }
        // Serialize translations so slower completions cannot reorder notifications.
        let previous = notificationLocalizationTask
        let generation = muteGeneration
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
                allowsSpeech: allowsSpeech && self.muteGeneration == generation
            )
        }
    }

    private func presentProactiveEvent(
        title: String?, spokenText: String, mood: PetMood, status: PetStatus, action: PetQuickAction?,
        allowsSpeech: Bool
    ) {
        guard configuration.isEnabled, configuration.proactiveMode != .off else { return }
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

        guard allowsSpeech, configuration.proactiveMode == .voiceAndBubble else { return }
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

        let generation = muteGeneration
        let report = await PetDailyReportService.generate(for: appState, companion: self)
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
        if speakAloud, muteGeneration == generation {
            speakProactivelyOrQueue(report.spokenSummary)
        }
    }

    func readReportAloud(_ report: PetDailyReport) {
        speakProactivelyOrQueue(report.spokenSummary)
    }

    func previewVoiceSample(_ sampleText: String = "Hi there! I am RxBuddy, your RxCode voice companion.") {
        guard !isMuted else { return }
        voiceDraftPreview?.stop()
        let generation = muteGeneration
        Task {
            guard muteGeneration == generation else { return }
            await stopVoice(drainAnnouncements: false)
            guard muteGeneration == generation else { return }
            standaloneSpeaker.speak(text: sampleText, synthesizer: localSynthesizer)
            startAnnouncementDeliveryIfNeeded()
        }
    }

    @discardableResult
    func speakProactivelyOrQueue(_ text: String) -> UUID? {
        guard !isMuted, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        normalizeSpeechQueueIDs()
        let id = UUID()
        queuedProactiveSpeech.append(text)
        queuedSpeechIDs.append(id)
        startAnnouncementDeliveryIfNeeded()
        return id
    }

    func normalizeSpeechQueueIDs() {
        if queuedSpeechIDs.count != queuedProactiveSpeech.count {
            queuedSpeechIDs = queuedProactiveSpeech.map { _ in UUID() }
        }
    }

    func removeQueuedSpeech(ids: [UUID]) {
        normalizeSpeechQueueIDs()
        for id in ids {
            guard let index = queuedSpeechIDs.firstIndex(of: id) else { continue }
            queuedSpeechIDs.remove(at: index)
            queuedProactiveSpeech.remove(at: index)
        }
    }

    func discardSpokenAnnouncements() {
        announcementGeneration = UUID()
        announcementTask?.cancel()
        announcementTask = nil
        announcementRetryAfter = nil
        let speechIDs = queuedSpeechIDs
        queuedSpeechIDs.removeAll()
        queuedProactiveSpeech.removeAll()
        // Scheduled reports already displayed their captions when they entered the queue.
        if !speechIDs.isEmpty {
            Task { await acknowledgeScheduledReports(speechIDs: speechIDs) }
        }
    }

    /// Keep background updates in order without replacing a report already playing.
    func startAnnouncementDeliveryIfNeeded() {
        guard !isMuted, announcementTask == nil, !queuedProactiveSpeech.isEmpty else { return }
        guard announcementRetryAfter.map({ $0 <= Date.now }) ?? true else { return }
        let generation = UUID()
        announcementGeneration = generation
        announcementTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.announcementGeneration == generation { self.announcementTask = nil }
            }
            var quietSince: ContinuousClock.Instant?
            while !Task.isCancelled, !self.queuedProactiveSpeech.isEmpty {
                if let session = self.voiceSession, self.isVoiceActive {
                    // Both voice modes own notification responses. A busy conversation keeps
                    // updates queued; it must never fall back to a separate agent or speaker.
                    let realtime = self.activeVoiceMode == .codexRealtime ? self.realtimeNotifications : nil
                    let canRespond = self.activeVoiceMode == .codexRealtime
                        ? realtime?.canSend == true : session.activity == .listening
                    guard session.lifecycle == .active, canRespond,
                          !self.isAwaitingVoiceTextReply(in: session),
                          !self.isLocalUserSpeaking, self.livePartialUserText.isEmpty,
                          session.meters.input < 0.04,
                          session.transcript.last.map({ !$0.isUser && $0.isFinal }) ?? true,
                          self.activeToolDescription == nil, !self.isStandaloneSpeaking,
                          self.currentHardwareAudioDriver?.hasPendingPlayback != true,
                          session.meters.output < 0.01 else {
                        quietSince = nil
                        try? await Task.sleep(for: .milliseconds(100))
                        continue
                    }
                    if quietSince == nil { quietSince = .now }
                    guard quietSince!.duration(to: .now) >= .milliseconds(300) else {
                        try? await Task.sleep(for: .milliseconds(100))
                        continue
                    }
                    let updates = self.queuedProactiveSpeech
                    self.normalizeSpeechQueueIDs()
                    let speechIDs = self.queuedSpeechIDs
                    let previousEntries = Set(session.transcript.map(\.id))
                    let previousReplies = realtime?.completedReplies ?? 0
                    let receipt = PetRealtimeVoiceNotifications.Receipt()
                    do {
                        let prompt = Self.voiceUpdatePrompt(updates, languageInstruction: self.configuration.conversationLanguageInstruction)
                        if let realtime {
                            try await realtime.send(prompt) { [weak self, weak session] in
                                guard let self, let session, self.voiceSession === session,
                                      self.announcementGeneration == generation, !receipt.acknowledged else { return }
                                receipt.acknowledged = true
                                self.removeQueuedSpeech(ids: speechIDs)
                                Task { await self.acknowledgeScheduledReports(speechIDs: speechIDs) }
                            }
                        } else {
                            try await session.send(text: prompt)
                        }
                        guard !Task.isCancelled, self.announcementGeneration == generation else { return }
                    } catch {
                        guard !Task.isCancelled else { return }
                        // An RPC error can be ambiguous. Do not automatically resend possibly
                        // accepted speech; retain it until the user restarts the call to retry.
                        self.announcementRetryAfter = .distantFuture
                        self.alertErrorMessage = "Could not deliver the update to the voice agent: \(error.localizedDescription). The update remains queued; restart voice chat to retry."
                        return
                    }
                    // Sending returns before the agent starts responding. Wait for its completed
                    // reply so a second background event cannot cancel the first pipeline turn.
                    @MainActor func receivedReply() -> Bool {
                        if let realtime { return realtime.completedReplies > previousReplies }
                        return session.transcript.contains(where: {
                              !previousEntries.contains($0.id) && !$0.isUser && $0.isFinal
                        })
                    }
                    while !Task.isCancelled, self.voiceSession === session,
                          session.lifecycle == .active, !receivedReply() {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    guard !Task.isCancelled, self.announcementGeneration == generation else { return }
                    guard receivedReply() else { return } // Keep unacknowledged updates queued after a drop.
                    if !receipt.acknowledged {
                        self.removeQueuedSpeech(ids: speechIDs)
                        await self.acknowledgeScheduledReports(speechIDs: speechIDs)
                    }
                    quietSince = nil
                } else {
                    // A dropped call does not authorize overlapping fallback playback.
                    guard self.voiceSession == nil else { return }
                    if self.isStandaloneSpeaking || self.voiceDraftPreview?.isPlaying == true {
                        try? await Task.sleep(for: .milliseconds(100))
                        continue
                    }
                    let text = self.queuedProactiveSpeech[0]
                    self.normalizeSpeechQueueIDs()
                    let speechID = self.queuedSpeechIDs[0]
                    let failures = self.speechFailureCount
                    self.standaloneSpeaker.speak(text: text, synthesizer: self.localSynthesizer)
                    while !Task.isCancelled, self.isStandaloneSpeaking {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    guard !Task.isCancelled, self.announcementGeneration == generation else { return }
                    guard self.speechFailureCount == failures else {
                        self.announcementRetryAfter = Date.now.addingTimeInterval(30)
                        return
                    }
                    self.removeQueuedSpeech(ids: [speechID])
                    await self.acknowledgeScheduledReports(speechIDs: [speechID])
                }
            }
        }
    }

    func isAwaitingVoiceTextReply(in session: VoiceSession) -> Bool {
        guard let baseline = voiceTextReplyBaseline else { return false }
        if session.transcript.contains(where: { !$0.isUser && $0.isFinal && !baseline.contains($0.id) }) {
            voiceTextReplyBaseline = nil
            return false
        }
        return true
    }
}
