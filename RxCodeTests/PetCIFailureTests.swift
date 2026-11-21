import AVFoundation
import Foundation
import RxAgentVoice
import RxAgentCore
import Testing
@testable import RxCode
import RxCodeCore

struct PetCIFailureTests {
    @Test("CI failure uses the existing speech queue")
    @MainActor
    func ciFailureQueuesSpeech() async throws {
        let suite = "PetCISpeechTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var config = PetConfiguration()
        config.isEnabled = true
        config.isMuted = false
        config.proactiveMode = .voiceAndBubble
        config.save(to: defaults)
        let pet = PetController(defaults: defaults)
        // Hold draining so this test observes delivery without starting audio.
        pet.announcementTask = Task {}
        let app = AppState(persistence: MockAppStatePersistence(), startBackgroundServices: false)
        let payload = CIFailedPayload(projectId: nil, projectName: "RxCode", failingWorkflowNames: ["Tests"])
        _ = await PetCompanionHook(pet: pet).onCIFailed(payload, controller: AppStateHookController(app: app))
        #expect(pet.queuedProactiveSpeech == [payload.spokenSummary])
        pet.announcementTask?.cancel()
        pet.announcementTask = nil
        pet.queuedProactiveSpeech.removeAll()
        pet.bubbleDismissTask?.cancel()
        pet.transientStatusResetTask?.cancel()
    }

    @Test("Muted CI notifications keep the run details in the caption")
    @MainActor
    func ciFailureNotificationSettings() async throws {
        let app = AppState(persistence: MockAppStatePersistence(), startBackgroundServices: false)
        let hookController = AppStateHookController(app: app)
        let url = "https://github.com/rxlab/RxCode/actions/runs/100"
        let payload = CIFailedPayload(projectId: UUID(), projectName: "RxCode", failingWorkflowNames: ["Build"], runURL: url)
        for mode in [PetProactiveMode.off, .bubbleOnly, .voiceAndBubble] {
            let suite = "PetCIFailureTests-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            var config = PetConfiguration()
            config.isEnabled = true
            config.isMuted = true
            config.proactiveMode = mode
            config.save(to: defaults)
            let pet = PetController(defaults: defaults)
            pet.announcementTask = Task {}
            _ = await PetCompanionHook(pet: pet).onCIFailed(payload, controller: hookController)
            if mode == .off {
                #expect(pet.petState.bubble == nil)
            } else {
                let bubble = try #require(pet.petState.bubble)
                #expect(bubble.text == "GitHub Actions CI failed in RxCode: Build.")
                #expect(bubble.action == .openURL(try #require(URL(string: url))))
                #expect(pet.petState.mood == .concerned)
            }
            #expect(pet.queuedProactiveSpeech.isEmpty)
            pet.announcementTask?.cancel()
            pet.announcementTask = nil
            pet.bubbleDismissTask?.cancel()
            pet.transientStatusResetTask?.cancel()
        }
    }
}
