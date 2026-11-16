import Foundation
import RxCodeCore

#if os(macOS)
/// Lifecycle hook that drives proactive Pet reactions and spoken announcements
/// when background chats/tasks finish, ask for approval/input, or fail CI.
@MainActor
final class PetCompanionHook: Hook {
    let hookID = "builtin.petCompanion"
    private let pet: PetController

    init(pet: PetController? = nil) { self.pet = pet ?? .shared }

    func afterSessionEnd(_ payload: SessionEndPayload, controller: any HookController) async -> HookOutcome {
        // Ignore internal pet voice threads so the pet does not double-announce its own voice turns.
        if payload.sessionKey.hasPrefix("pet-") || payload.sessionId.hasPrefix("pet-") {
            return .ignored
        }
        guard payload.reason != .cancelled else { return .ignored }

        guard pet.configuration.isEnabled, pet.isVoiceActive || pet.configuration.proactiveMode != .off else {
            return .ignored
        }

        let sessionTitle = controller.sessionTitle(sessionId: payload.sessionId)
            ?? payload.project.name
        let projectId = payload.project.id
        let sessionId = payload.sessionId

        if payload.turnDidError {
            pet.notifyProactiveEvent(
                title: "\(payload.project.name) · Error",
                spokenText: "Heads up: work in \(payload.project.name) ran into an error on \(sessionTitle).",
                mood: .concerned,
                status: .failed,
                action: .openThread(projectId: projectId, sessionId: sessionId)
            )
            return .proceed
        }

        guard payload.reason == .completed else { return .ignored }
        let fallback = controller.responseNotificationFallback(from: payload.lastAssistantText)
        let rawText = payload.lastAssistantText

        // The active voice assistant receives the original result and owns the summary.
        // Outside voice chat, use the pet's independently configured notification model.
        func deliver(_ detail: String) {
            let concise = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            let spoken = concise.isEmpty
                ? "Finished working on \(sessionTitle) in \(payload.project.name)."
                : "\(payload.project.name) finished \(sessionTitle): \(concise)"
            pet.notifyProactiveEvent(
                title: "\(payload.project.name) · Done",
                spokenText: spoken,
                mood: .happy,
                status: .celebrating,
                action: .openThread(projectId: projectId, sessionId: sessionId)
            )
        }
        if pet.isVoiceActive {
            deliver(rawText)
        } else {
            Task { @MainActor in
                let aiSummary = await pet.summarizeNotification(rawText, projectID: projectId)
                // Voice chat may have started while the outside-chat summary was running.
                deliver(pet.isVoiceActive ? rawText : (aiSummary ?? fallback))
            }
        }

        return .proceed
    }

    func onPermissionAsk(_ payload: PermissionAskPayload, controller: any HookController) async -> HookOutcome {
        guard pet.configuration.isEnabled, pet.isVoiceActive || pet.configuration.proactiveMode != .off else {
            return .ignored
        }
        guard pet.shouldAnnouncePermission(eventID: payload.toolUseId, sessionID: payload.sessionId) else { return .ignored }
        let label = payload.projectName ?? "A thread"
        let action: PetQuickAction? = {
            guard let projectId = payload.projectId, let sessionId = payload.sessionId else { return nil }
            return .openThread(projectId: projectId, sessionId: sessionId)
        }()
        pet.notifyProactiveEvent(
            title: "Approval Needed",
            spokenText: "\(label) needs your permission to run \(payload.toolName).",
            mood: .curious,
            status: .listening,
            action: action
        )
        return .proceed
    }

    func onQuestionAsk(_ payload: QuestionAskPayload, controller: any HookController) async -> HookOutcome {
        guard pet.configuration.isEnabled, pet.isVoiceActive || pet.configuration.proactiveMode != .off else {
            return .ignored
        }
        let label = payload.projectName ?? "An agent"
        let action: PetQuickAction? = {
            guard let projectId = payload.projectId, let sessionId = payload.sessionId else { return nil }
            return .openThread(projectId: projectId, sessionId: sessionId)
        }()
        pet.notifyProactiveEvent(
            title: "Question from Agent",
            spokenText: "\(label) has a question for you.",
            mood: .curious,
            status: .listening,
            action: action
        )
        return .proceed
    }

    func onCIFailed(_ payload: CIFailedPayload, controller: any HookController) async -> HookOutcome {
        guard pet.configuration.isEnabled, pet.isVoiceActive || pet.configuration.proactiveMode != .off else {
            return .ignored
        }
        let projName = payload.projectName ?? "Project"
        pet.notifyProactiveEvent(
            title: "CI Failed · \(projName)",
            spokenText: payload.spokenSummary,
            mood: .concerned,
            status: .failed,
            action: payload.detailsURL.map { .openURL($0) }
        )
        return .proceed
    }
}
#endif
