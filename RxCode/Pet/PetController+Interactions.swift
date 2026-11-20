import AppKit
import RxCodeCore

extension PetController {
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
            openSettingsWindow(tab: .voice)
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

    func openSpeechVoicePicker() {
        openSettingsWindow(tab: .voice)
        isChoosingSpeechVoice = true
    }

    func openSettingsWindow(tab: PetSettingsView.SettingsTab = .generalAgent) {
        isChoosingSpeechVoice = false
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

    func showBubble(_ message: PetBubbleMessage, duration: TimeInterval) {
        bubbleDismissTask?.cancel()
        petState.bubble = message
        panelController.updatePanelLayout()
        bubbleDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self else { return }
            if self.petState.bubble?.id == message.id {
                self.petState.bubble = nil
                self.panelController.updatePanelLayout()
            }
        }
    }

    func scheduleTransientMoodReset(after seconds: TimeInterval) {
        transientStatusResetTask?.cancel()
        transientStatusResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            if self.petState.status == .celebrating || self.petState.status == .failed {
                self.petState.status = .idle
            }
            self.petState.mood = .neutral
            self.refreshPetState()
        }
    }
}
