import Foundation
import RxCodeCore

@Observable
final class CodingPlanRoom {
    var plan: CodingPlan
    var liveTurn = PlanningTurn()
    var liveText: String { liveTurn.text }
    var turnStartIndex = 0
    var isHandingOff = false
    var runID: UUID?
    @ObservationIgnored var task: Task<Void, Never>?

    init(_ plan: CodingPlan) { self.plan = plan }

    func stop() {
        runID = nil
        task?.cancel()
        task = nil
        liveTurn = PlanningTurn()
    }
}

extension AppState {
    func codingPlanRoom(for threadID: String) -> CodingPlanRoom? {
        if let id = UUID(uuidString: threadID), let room = codingPlanRooms[id] { return room }
        guard let stored = threadStore.codingPlan(for: threadID) else { return nil }
        if let room = codingPlanRooms[stored.id] { return room }
        let room = CodingPlanRoom(stored)
        codingPlanRooms[stored.id] = room
        return room
    }

    func startCodingPlan(
        goal: String, source: String, configuration: CodingPlan.Configuration,
        project: Project, worktreePath: String?, worktreeBranch: String?, in window: WindowState
    ) async throws {
        let plan = CodingPlan(id: UUID(), goal: goal, source: source, configuration: configuration)
        let messages = [ChatMessage(role: .user, content: goal)]
        let session = ChatSession(
            id: plan.id.uuidString, projectId: project.id, title: ChatSession.placeholderTitle(from: goal),
            messages: messages, agentProvider: configuration.planner.provider, model: configuration.planner.id,
            origin: .legacyRxCode, worktreePath: worktreePath, worktreeBranch: worktreeBranch, threadLabel: "Plan"
        )
        if project.isGlobalChat {
            try await Task.detached {
                try FileManager.default.createDirectory(atPath: project.path, withIntermediateDirectories: true)
            }.value
        }
        try await persistence.saveSession(session)
        threadStore.upsert(session.summary)
        do {
            try threadStore.saveCodingPlan(plan)
        } catch {
            threadStore.delete(id: session.id)
            try await persistence.deleteSession(projectId: project.id, sessionId: session.id, origin: session.origin, cwd: project.path)
            throw error
        }
        let room = CodingPlanRoom(plan)
        codingPlanRooms[plan.id] = room
        allSessionSummaries.insert(session.summary, at: 0)
        let inChatTab = window.generalRoute == .chat
        window.cancelSessionSwitchTask()
        selectProject(project, in: window)
        switchToSession(session, messages: messages, in: window)
        if inChatTab { window.generalRoute = .chat }
        resumeCodingPlan(room, cwd: worktreePath ?? project.path)
        await didSwitchToSession(session)
    }

    func resumeCodingPlan(_ room: CodingPlanRoom, cwd: String) {
        guard room.runID == nil, room.plan.nextStep != nil, room.plan.approvedVersionID == nil else { return }
        let run = UUID()
        room.turnStartIndex = room.plan.contributions.endIndex
        room.runID = run
        room.plan.lastError = nil
        room.task = Task { [weak self, weak room] in
            guard let self, let room else { return }
            defer {
                if room.runID == run {
                    room.task = nil
                    room.runID = nil
                    room.liveTurn = PlanningTurn()
                }
            }
            do {
                while let step = room.plan.nextStep, room.runID == run {
                    let turnStart = room.plan.contributions.endIndex
                    room.turnStartIndex = turnStart
                    let speaker = room.plan.speaker(for: step)
                    room.liveTurn = PlanningTurn()
                    let response = try await planningTurn(model: speaker.model, prompt: room.plan.prompt(for: step), cwd: cwd) { turn in
                        if room.runID == run { room.liveTurn = turn }
                    }
                    guard room.runID == run, !Task.isCancelled else { return }
                    var updated = room.plan
                    updated.finish(step, text: response.text, toolCalls: response.toolCalls, at: turnStart)
                    try threadStore.saveCodingPlan(updated)
                    room.plan = updated
                }
            } catch {
                guard room.runID == run, !Task.isCancelled, let step = room.plan.nextStep else { return }
                let speaker = room.plan.speaker(for: step)
                room.plan.lastError = "\(speaker.role) (\(speaker.model.displayName))\n\(error.localizedDescription)"
                try? threadStore.saveCodingPlan(room.plan)
            }
        }
    }

    func sendCodingPlanMessage(_ text: String, to room: CodingPlanRoom, cwd: String) throws {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        guard !room.isHandingOff, room.plan.approvedVersionID == nil else {
            throw PlanningTurnError(message: "Continue this conversation in the implementation chat.")
        }
        var updated = room.plan
        updated.contributions.append(.init(role: "You", model: nil, text: message))
        if updated.nextStep == nil { updated.nextStep = .reply }
        try threadStore.saveCodingPlan(updated)
        room.plan = updated
        resumeCodingPlan(room, cwd: cwd)
    }

    func reviseCodingPlan(
        _ room: CodingPlanRoom, base: UUID, text: String, askHost: Bool, comment: String? = nil, cwd: String
    ) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, room.runID == nil, room.plan.nextStep == nil,
              !room.isHandingOff, room.plan.approvedVersionID == nil, room.plan.versions.last?.id == base else {
            throw PlanningTurnError(message: "The plan has changed. Reopen the latest version to revise it.")
        }
        var updated = room.plan
        if askHost {
            updated.contributions.append(.init(role: "You", model: nil, text: trimmed))
            updated.nextStep = .revise(trimmed)
        } else {
            updated.edit(markdown: text, comment: comment?.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        try threadStore.saveCodingPlan(updated)
        room.plan = updated
        if askHost { resumeCodingPlan(room, cwd: cwd) }
    }

    func addCodingPlanComment(_ text: String, to editIndex: Int, in versionID: UUID, room: CodingPlanRoom) throws {
        let comment = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = room.plan
        guard !comment.isEmpty, !room.isHandingOff, updated.approvedVersionID == nil,
              let index = updated.versions.firstIndex(where: { $0.id == versionID }),
              updated.versions[index].edits.indices.contains(editIndex) else {
            throw PlanningTurnError(message: "This change is no longer available for comments.")
        }
        var edit = updated.versions[index].edits[editIndex]
        edit.userComments = (edit.userComments ?? []) + [comment]
        updated.versions[index].edits[editIndex] = edit
        try threadStore.saveCodingPlan(updated)
        room.plan = updated
    }

    @discardableResult
    func implementCodingPlan(_ room: CodingPlanRoom, versionID: UUID, model: AgentModel, in window: WindowState) async -> UUID? {
        let sourceID = room.plan.id.uuidString
        guard window.currentSessionId == sourceID, room.runID == nil, room.plan.nextStep == nil,
              !room.isHandingOff, room.plan.approvedVersionID == nil,
              let version = room.plan.versions.first(where: { $0.id == versionID }),
              let source = threadStore.fetch(id: sourceID) else { return nil }
        room.isHandingOff = true
        defer { room.isHandingOff = false }
        var approved = room.plan
        approved.approvedVersionID = versionID
        let inChatTab = window.generalRoute == .chat
        startNewChat(in: window)
        window.inputText = ""
        window.attachments = []
        window.messageQueue = []
        window.pendingWorktreePath = source.worktreePath
        window.pendingWorktreeBranch = source.worktreeBranch
        window.sessionAgentProvider = model.provider
        window.sessionModel = model.id
        if permissionMode == .plan { window.sessionPermissionMode = .default }
        if inChatTab { window.generalRoute = .chat }
        let stream = await sendPrompt(CodingPlan.implementationPrompt(for: version),
                                      implementationPlan: approved, in: window)
        if stream == nil, window.currentSessionId == nil {
            selectSession(id: sourceID, inChatTab: inChatTab, in: window)
        }
        return stream
    }

    func discardCodingPlanRun(threadID: String) {
        guard let id = UUID(uuidString: threadID) else { return }
        codingPlanRooms.removeValue(forKey: id)?.stop()
    }
}
