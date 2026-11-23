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

    /// Whether the desktop pet / voice companion asked for this confirmation.
    /// Its sessions all use a `pet-` key.
    var isFromPetCompanion: Bool { sessionKey.hasPrefix("pet-") }
}

/// An `ide__show_ui` view opened with `presentation: "dialog"`, kept with the
/// thread that showed it.
struct AgentUIDialog: Identifiable, Hashable {
    let id = UUID()
    /// The AppState session key of the thread that showed the view.
    let sessionKey: String
    let title: String?
    let spec: JSONUISpec
    var petPresentation: String? = nil
    /// Only short, read-only information belongs in the caption.
    var captionLines: [String]? {
        let supported: Set<String> = ["Stack", "Card", "Heading", "Text", "Badge", "Stat", "Callout", "KeyValue", "List", "Progress", "Divider"]
        guard spec.elements.values.allSatisfy({ supported.contains($0.type) }) else { return nil }
        let lines = spec.textLines.flatMap { $0.components(separatedBy: .newlines) }.filter { !$0.isEmpty }
        return (1...5).contains(lines.count) ? lines : nil
    }
    var usesPetCaption: Bool { isPetPresentation && petPresentation != "popover" && captionLines != nil }
    var isPetPresentation: Bool { sessionKey.hasPrefix("pet-") || petPresentation != nil }
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
        let requestedPetStyle = arguments["pet_presentation"]?.stringValue
        if arguments["pet_presentation"] != nil && !["popover", "bubble"].contains(requestedPetStyle ?? "") {
            throw IDEToolError.invalidArguments("pet_presentation must be popover or bubble.")
        }
        // Pet sessions always use the floating pet surface, even when the agent
        // omits pet_presentation or sends the shared tool's inline default.
        let petStyle = requestedPetStyle ?? (sessionKey.hasPrefix("pet-") ? "bubble" : nil)
        var input = arguments.objectValue ?? [:]
        if petStyle != nil { input["presentation"] = .string("dialog") }
        let validated: (payload: JSONUITool.Payload, spec: JSONUISpec, message: String)
        do {
            validated = try JSONUITool.validated(.object(input))
        } catch {
            throw IDEToolError.invalidArguments(error.localizedDescription)
        }
        if validated.payload.presentation == .dialog {
            var dialog = AgentUIDialog(sessionKey: sessionKey, title: validated.payload.title, spec: validated.spec, petPresentation: petStyle)
            if dialog.isPetPresentation && !dialog.usesPetCaption { dialog.petPresentation = "popover" }
            if dialog.isPetPresentation {
                guard PetController.shared.configuration.isEnabled else { throw IDEToolError.handlerFailed("Enable the desktop pet to show this interactive view.") }
                PetController.shared.presentation.expand(dialog.id)
                PetController.shared.panelController.show()
            }
            agentPrompts.views.append(dialog)
            agentPrompts.dialogs.append(dialog)
            if dialog.isPetPresentation {
                do { try await PetController.shared.presentation.waitUntilVisible { PetController.shared.presentation.visibleDialogID == dialog.id } }
                catch { removeAgentUIView(id: dialog.id); throw error }
                let visibleStyle = agentPrompts.dialogs.first { $0.id == dialog.id }?.petPresentation ?? "bubble"
                return PetPresentation.result("presented", "The UI is visibly presented in the pet-anchored \(visibleStyle).")
            }
        }
        return textResult(validated.message)
    }

    /// A caption exceeding the full five-row budget needs a popover.
    func expandPetCaptionToPopover(id: UUID) {
        for index in agentPrompts.dialogs.indices where agentPrompts.dialogs[index].id == id {
            agentPrompts.dialogs[index].petPresentation = "popover"
        }
        for index in agentPrompts.views.indices where agentPrompts.views[index].id == id {
            agentPrompts.views[index].petPresentation = "popover"
        }
        PetController.shared.panelController.updatePanelLayout()
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
        let projectId = projectID(forPromptSession: sessionKey)
        let confirmation = AgentConfirmation(request: request, sessionKey: sessionKey, projectId: projectId)
        let id = confirmation.id
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                agentPrompts.continuations.byId[id] = continuation
                agentPrompts.confirmations.append(confirmation)
                broadcastMobileConfirmationQueue()
                Task { @MainActor [weak self] in
                    guard let self,
                          self.agentPrompts.continuations.byId[id] != nil else { return }
                    let projectName = self.projects.first { $0.id == projectId }?.name
                    await self.hookManager.dispatchPermissionAsk(PermissionAskPayload(
                        toolUseId: id.uuidString,
                        toolName: request.title,
                        sessionId: self.resolveCurrentSessionId(sessionKey),
                        projectId: projectId,
                        projectName: projectName
                    ))
                }
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

    /// Confirmations the desktop pet / voice companion is waiting on that the
    /// user hasn't hidden, oldest first.
    var pendingPetConfirmations: [AgentConfirmation] {
        agentPrompts.confirmations.filter { $0.isFromPetCompanion && !$0.isMinimized }
    }

    /// Changes presentation without resolving the waiting tool call.
    func setAgentConfirmationMinimized(id: UUID, minimized: Bool) {
        guard let index = agentPrompts.confirmations.firstIndex(where: { $0.id == id }) else { return }
        agentPrompts.confirmations[index].isMinimized = minimized
    }

    /// Applies the user's decision on prompt `id`. When the turn that asked has
    /// already ended, nothing is waiting for the tool result anymore, so a
    /// decision is sent to the thread as a new message to continue the work.
    func resolveAgentConfirmation(id: UUID, confirmed: Bool) {
        guard let confirmation = agentPrompts.confirmations.first(where: { $0.id == id }) else { return }
        let turnEnded = !isSessionTurnRunning(confirmation.sessionKey)
        guard settleAgentConfirmation(id: id, confirmed: confirmed) else { return }
        guard turnEnded else { return }
        let prompt = confirmed
            ? "I confirmed \"\(confirmation.request.title)\". Go ahead."
            : "I rejected \"\(confirmation.request.title)\". Do not perform the rejected action. Continue with this decision."
        Task { await sendLatePromptAnswer(prompt, sessionKey: confirmation.sessionKey) }
    }

    /// Settles the prompt `id` and resumes its waiting tool call once. Returns
    /// whether the prompt was still pending.
    @discardableResult
    func settleAgentConfirmation(id: UUID, confirmed: Bool) -> Bool {
        guard let continuation = agentPrompts.continuations.byId.removeValue(forKey: id) else { return false }
        agentPrompts.confirmations.removeAll { $0.id == id }
        continuation.resume(returning: confirmed)
        broadcastMobileConfirmationQueue()
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
        if agentPrompts.dialogs.contains(where: { $0.id == id && $0.isPetPresentation }) {
            PetController.shared.presentation.collapse(id)
        } else {
            agentPrompts.dialogs.removeAll { $0.id == id }
        }
    }

    /// The dialog views shown in thread `sessionKey`, oldest first.
    func agentUIViews(forSession sessionKey: String) -> [AgentUIDialog] {
        agentPrompts.views.filter { resolveCurrentSessionId($0.sessionKey) == sessionKey }
    }

    /// Opens a kept view in front. A dialog open at the time closes, and stays
    /// in its thread's Views list.
    func openAgentUIView(id: UUID) {
        if let view = agentPrompts.views.first(where: { $0.id == id && $0.isPetPresentation }) {
            if !agentPrompts.dialogs.contains(where: { $0.id == id }) { agentPrompts.dialogs.append(view) }
            PetController.shared.presentation.expand(id)
            return
        }
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
        PetController.shared.presentation.removeDialog(id)
        agentPrompts.views.removeAll { $0.id == id }
        agentPrompts.dialogs.removeAll { $0.id == id }
    }
}
