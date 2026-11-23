import Foundation
import RxCodeCore

@Observable
final class CodingPlanRoom {
    var plan: CodingPlan
    var liveTurn = PlanningTurn() {
        didSet {
            liveBroadcast = CodingPlanBroadcast(liveTurn.text, hostRevision: plan.nextStep?.isHostRevision == true, streaming: true)
        }
    }
    private(set) var liveBroadcast = CodingPlanBroadcast("", hostRevision: false)
    var liveText: String { liveBroadcast.body }
    private(set) var dispatch: Dispatch?
    struct Dispatch: Identifiable {
        let id: UUID
        let text: String
    }
    var turnStartIndex = 0
    var isHandingOff = false
    var canAddReviewer: Bool { !isHandingOff && plan.approvedVersionID == nil }
    var runID: UUID?
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored var questions: CodingPlanQuestions?

    init(_ plan: CodingPlan) { self.plan = plan }

    func publishBriefing(_ text: String?, role: String, turnID: UUID) {
        guard dispatch?.id != turnID, let text, !text.isEmpty else { return }
        dispatch = .init(id: turnID, text: "\(role). \(text)")
    }

    func stop() {
        runID = nil
        questions?.close()
        task?.cancel()
        task = nil
        liveTurn = PlanningTurn()
    }
}

extension AppState {
    func codingPlanRoom(for threadID: String) -> CodingPlanRoom? {
        if let id = UUID(uuidString: threadID), let room = codingPlanRooms[id] { return room }
        guard let stored = threadStore.codingPlan(for: threadID) else { return nil }
        let room = CodingPlanRoom(stored)
        // Each implementation keeps the version approved for its own run.
        if UUID(uuidString: threadID) == stored.id { codingPlanRooms[stored.id] = room }
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
            origin: .legacyRxCode, worktreePath: worktreePath, worktreeBranch: worktreeBranch, threadLabel: ChatSession.codingPlanLabel
        )
        if project.isGlobalChat {
            try await Task.detached {
                try FileManager.default.createDirectory(atPath: project.path, withIntermediateDirectories: true)
            }.value
        }
        try await persistence.saveSession(session)
        // The chat transcript holds only the goal. The plan tracks its turns separately.
        var summary = session.summary
        summary.hasUnfinishedTurn = false
        threadStore.upsert(summary)
        do {
            try threadStore.saveCodingPlan(plan)
        } catch {
            threadStore.delete(id: session.id)
            try await persistence.deleteSession(projectId: project.id, sessionId: session.id, origin: session.origin, cwd: project.path)
            throw error
        }
        let room = CodingPlanRoom(plan)
        codingPlanRooms[plan.id] = room
        allSessionSummaries.insert(summary, at: 0)
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
        let planID = room.plan.id.uuidString
        debatingCodingPlanIDs.insert(planID)
        room.task = Task { [weak self, weak room] in
            guard let self, let room else { return }
            defer {
                if room.runID == run {
                    debatingCodingPlanIDs.remove(planID)
                    room.task = nil
                    room.runID = nil
                    room.liveTurn = PlanningTurn()
                }
            }
            do {
                while let step = room.plan.nextStep, room.runID == run {
                    let turnID = UUID()
                    let turnStart = room.plan.contributions.endIndex
                    room.turnStartIndex = turnStart
                    let speaker = room.plan.speaker(for: step)
                    room.liveTurn = PlanningTurn()
                    let questions = CodingPlanQuestions(appState: self, room: room, runID: run)
                    room.questions = questions
                    defer {
                        questions.close()
                        if room.questions === questions { room.questions = nil }
                    }
                    let result: Result<PlanningTurn, Error>
                    do {
                        let turn = try await planningTurn(model: speaker.model, prompt: room.plan.prompt(for: step),
                                                          cwd: cwd, questions: questions) { update in
                            guard room.runID == run else { return }
                            room.liveTurn = update
                            if room.dispatch?.id != turnID {
                                room.publishBriefing(room.liveBroadcast.briefing, role: speaker.role, turnID: turnID)
                            }
                        }
                        result = .success(turn)
                    } catch {
                        result = .failure(error)
                    }
                    if try await questions.receivedAnswerAfterTurn() { continue }
                    guard room.runID == run, !Task.isCancelled else { return }
                    let response = try result.get()
                    let broadcastBody = CodingPlanBroadcast(response.text, hostRevision: step.isHostRevision).body
                    guard !broadcastBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw PlanningTurnError(message: "The agent returned a radio update without its planning response.")
                    }
                    var updated = room.plan
                    updated.finish(step, text: response.text, toolCalls: response.toolCalls, at: turnStart)
                    try threadStore.saveCodingPlan(updated)
                    room.plan = updated
                    let message = updated.contributions[turnStart]
                    room.publishBriefing(message.radioSummary, role: speaker.role, turnID: turnID)
                }
            } catch {
                guard room.runID == run, !Task.isCancelled, let step = room.plan.nextStep else { return }
                let speaker = room.plan.speaker(for: step)
                room.plan.lastError = "\(speaker.role) (\(speaker.model.displayName))\n\(error.localizedDescription)"
                try? threadStore.saveCodingPlan(room.plan)
            }
        }
    }

    func addCodingPlanReviewer(_ reviewer: CodingPlan.Reviewer, to room: CodingPlanRoom, cwd: String) throws {
        guard room.canAddReviewer else {
            throw PlanningTurnError(message: "This plan is closed to additional reviews.")
        }
        let wasReady = room.plan.nextStep == nil
        var updated = room.plan
        guard updated.addReviewer(reviewer) else { return }
        try threadStore.saveCodingPlan(updated)
        room.plan = updated
        if wasReady { resumeCodingPlan(room, cwd: cwd) }
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
    func implementCodingPlan(_ room: CodingPlanRoom, versionID: UUID, model: AgentModel, effort: String? = nil,
                             in window: WindowState) async -> UUID? {
        let sourceID = room.plan.id.uuidString
        guard let originID = window.currentSessionId,
              originID == sourceID || threadStore.fetch(id: originID)?.implementationPlanID == room.plan.id,
              room.runID == nil, room.plan.nextStep == nil, !room.isHandingOff,
              let version = room.plan.versions.first(where: { $0.id == versionID }),
              let source = threadStore.fetch(id: sourceID) else { return nil }
        room.isHandingOff = true
        defer { room.isHandingOff = false }
        let chosenEffort = await sanitizedEffort(effort, for: model.provider, model: model.id)
        guard window.currentSessionId == originID else { return nil }
        var approved = codingPlanRoom(for: sourceID)?.plan ?? room.plan
        approved.approvedVersionID = versionID
        approved.implementationReview = nil
        let inChatTab = window.generalRoute == .chat
        startNewChat(in: window)
        window.inputText = ""
        window.attachments = []
        window.messageQueue = []
        window.pendingWorktreePath = source.worktreePath
        window.pendingWorktreeBranch = source.worktreeBranch
        window.sessionAgentProvider = model.provider
        window.sessionModel = model.id
        window.sessionEffort = chosenEffort
        if permissionMode == .plan { window.sessionPermissionMode = .default }
        if inChatTab { window.generalRoute = .chat }
        let stream = await sendPrompt(CodingPlan.implementationPrompt(for: version),
                                      implementationPlan: approved, in: window)
        if stream == nil, window.currentSessionId == nil {
            selectSession(id: originID, inChatTab: inChatTab, in: window)
        }
        return stream
    }

    func discardCodingPlanRun(threadID: String) {
        guard let id = UUID(uuidString: threadID) else { return }
        codingPlanRooms.removeValue(forKey: id)?.stop()
        debatingCodingPlanIDs.remove(id.uuidString)
    }
}
