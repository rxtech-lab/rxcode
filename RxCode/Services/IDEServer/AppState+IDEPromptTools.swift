import Foundation
import RxCodeCore

/// A pending `ide__show_confirmation` prompt. `HookUIModifier` shows it as a
/// sheet and resolves it through `AppState.resolveAgentConfirmation`.
struct AgentConfirmation: Identifiable, Hashable {
    let id = UUID()
    let request: ConfirmationTool.Request
    let sessionKey: String
    let projectId: UUID?
    var isMinimized = false
}

/// An `ide__show_ui` view opened with `presentation: "dialog"`, kept with the
/// thread that showed it.
struct AgentUIDialog: Identifiable, Hashable {
    let id = UUID()
    /// The AppState session key of the thread that showed the view.
    let sessionKey: String
    let title: String?
    let spec: JSONUISpec
}

/// Agent prompts queued for the user, oldest first. `AgentPromptUIModifier`
/// presents the first expanded confirmation or dialog as a sheet.
struct AgentPromptState {
    /// `ide__show_confirmation` prompts awaiting the user's decision.
    var confirmations: [AgentConfirmation] = []
    /// Dialog views waiting to be shown; the first is the open sheet.
    var dialogs: [AgentUIDialog] = []
    /// Every dialog view of every thread, oldest first. Closing a dialog keeps it
    /// here; the inspector's Views tab lists the current thread's views.
    var views: [AgentUIDialog] = []
    /// Resumes the `ide__show_confirmation` call waiting on each prompt. A reference
    /// so resuming a call doesn't publish a change.
    let continuations = Continuations()

    final class Continuations {
        var byId: [UUID: CheckedContinuation<Bool, Never>] = [:]
    }
}

extension AppState {
    @MainActor
    func handleShowUI(arguments: JSONValue, sessionKey: String) async throws -> JSONValue {
        let validated: (payload: JSONUITool.Payload, spec: JSONUISpec, message: String)
        do {
            validated = try JSONUITool.validated(arguments)
        } catch {
            throw IDEToolError.invalidArguments(error.localizedDescription)
        }
        if validated.payload.presentation == .dialog {
            let dialog = AgentUIDialog(sessionKey: sessionKey, title: validated.payload.title, spec: validated.spec)
            agentPrompts.views.append(dialog)
            agentPrompts.dialogs.append(dialog)
        }
        return textResult(validated.message)
    }

    @MainActor
    func handleShowConfirmation(arguments: JSONValue, sessionKey: String) async throws -> JSONValue {
        let request: ConfirmationTool.Request
        do {
            request = try ConfirmationTool.request(from: arguments)
        } catch {
            throw IDEToolError.invalidArguments(error.localizedDescription)
        }
        let confirmed = await requestAgentConfirmation(request, sessionKey: sessionKey)
        return jsonTextResult(ConfirmationTool.result(confirmed: confirmed))
    }

    /// Queues `request` for the user and waits for their decision. Returns
    /// `false` when they cancel or the waiting call is cancelled.
    func requestAgentConfirmation(_ request: ConfirmationTool.Request, sessionKey: String) async -> Bool {
        let resolved = resolveCurrentSessionId(sessionKey)
        let projectId = allSessionSummaries.first { resolveCurrentSessionId($0.id) == resolved }?.projectId
            ?? registeredWindows().first {
                resolveCurrentSessionId($0.currentSessionId ?? $0.newSessionKey) == resolved
            }?.selectedProject?.id
        let confirmation = AgentConfirmation(request: request, sessionKey: sessionKey, projectId: projectId)
        let id = confirmation.id
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                agentPrompts.continuations.byId[id] = continuation
                agentPrompts.confirmations.append(confirmation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.settleAgentConfirmation(id: id, confirmed: false)
            }
        }
    }

    /// Queue independently per thread, including after a provider renames its session.
    func agentConfirmations(forSession sessionKey: String) -> [AgentConfirmation] {
        let resolved = resolveCurrentSessionId(sessionKey)
        return agentPrompts.confirmations.filter { resolveCurrentSessionId($0.sessionKey) == resolved }
    }

    /// Changes presentation without resolving the waiting tool call.
    func setAgentConfirmationMinimized(id: UUID, minimized: Bool) {
        guard let index = agentPrompts.confirmations.firstIndex(where: { $0.id == id }) else { return }
        agentPrompts.confirmations[index].isMinimized = minimized
    }

    /// Applies the user's decision on prompt `id`. When the turn that asked has
    /// already ended, nothing is waiting for the tool result anymore, so a
    /// confirmation is sent to the thread as a new message to continue the work.
    func resolveAgentConfirmation(id: UUID, confirmed: Bool) {
        guard let confirmation = agentPrompts.confirmations.first(where: { $0.id == id }) else { return }
        let turnEnded = !isSessionTurnRunning(confirmation.sessionKey)
        guard settleAgentConfirmation(id: id, confirmed: confirmed) else { return }
        guard confirmed, turnEnded else { return }
        let prompt = "I confirmed \"\(confirmation.request.title)\". Go ahead."
        Task { await sendLatePromptAnswer(prompt, sessionKey: confirmation.sessionKey) }
    }

    /// Settles the prompt `id` and resumes its waiting tool call once. Returns
    /// whether the prompt was still pending.
    @discardableResult
    func settleAgentConfirmation(id: UUID, confirmed: Bool) -> Bool {
        guard let continuation = agentPrompts.continuations.byId.removeValue(forKey: id) else { return false }
        agentPrompts.confirmations.removeAll { $0.id == id }
        continuation.resume(returning: confirmed)
        return true
    }

    /// Whether thread `sessionKey` has a turn running, so a tool call can still
    /// be waiting on the user's answer.
    func isSessionTurnRunning(_ sessionKey: String) -> Bool {
        sessionStates[resolveCurrentSessionId(sessionKey)]?.isStreaming == true
    }

    /// Sends a prompt answer given after its turn ended as a new message in
    /// thread `sessionKey`, so the agent still receives it. Queued instead when
    /// another turn started in the meantime.
    func sendLatePromptAnswer(_ prompt: String, sessionKey: String) async {
        let sessionID = resolveCurrentSessionId(sessionKey)
        if isSessionTurnRunning(sessionID) {
            let queued = QueuedMessage(text: prompt, attachments: [])
            threadStore.appendQueued(sessionKey: sessionID, message: queued)
            appendToWindowQueueMirrors(sessionID: sessionID, message: queued)
            broadcastMobileSessionStatus(sessionID: sessionID)
            return
        }
        let window: WindowState
        if let open = registeredWindows().first(where: {
            $0.selectedProject != nil && $0.currentSessionId.map(resolveCurrentSessionId) == sessionID
        }) {
            window = open
        } else {
            guard let summary = allSessionSummaries.first(where: { $0.id == sessionID }),
                  let project = projects.first(where: { $0.id == summary.projectId })
            else { return }
            window = WindowState()
            window.selectedProject = project
            window.currentSessionId = sessionID
        }
        _ = await sendPrompt(prompt, displayText: prompt, in: window)
    }

    /// Closes the open dialog. The view stays in its thread's Views list.
    func dismissAgentUIDialog(id: UUID) {
        agentPrompts.dialogs.removeAll { $0.id == id }
    }

    /// The dialog views shown in thread `sessionKey`, oldest first.
    func agentUIViews(forSession sessionKey: String) -> [AgentUIDialog] {
        agentPrompts.views.filter { resolveCurrentSessionId($0.sessionKey) == sessionKey }
    }

    /// Opens a kept view in front. A dialog open at the time closes, and stays
    /// in its thread's Views list.
    func openAgentUIView(id: UUID) {
        guard let view = agentPrompts.views.first(where: { $0.id == id }),
              agentPrompts.dialogs.first?.id != id else { return }
        agentPrompts.dialogs.removeAll { $0.id == id }
        agentPrompts.dialogs.insert(view, at: 0)
    }

    /// Opens the view a chat card stands for, reusing its kept entry when the
    /// thread already has one.
    func openAgentUIView(title: String?, spec: JSONUISpec, sessionKey: String) {
        if let view = agentUIViews(forSession: sessionKey).last(where: { $0.title == title && $0.spec == spec }) {
            openAgentUIView(id: view.id)
            return
        }
        let view = AgentUIDialog(sessionKey: sessionKey, title: title, spec: spec)
        agentPrompts.views.append(view)
        openAgentUIView(id: view.id)
    }

    /// Removes a view from its thread's Views list, closing it if open.
    func removeAgentUIView(id: UUID) {
        agentPrompts.views.removeAll { $0.id == id }
        agentPrompts.dialogs.removeAll { $0.id == id }
    }
}
