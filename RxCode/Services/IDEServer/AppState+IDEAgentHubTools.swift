import AppKit
import Foundation
import os
import RxCodeCore

// MARK: - Agent tools (Agents tab)

/// Pixel size of the latest agent screenshot of each display, so action
/// coordinates map back to the screen.
@MainActor
enum AgentScreenshotGeometry {
    static var latest: [CGDirectDisplayID: (width: Int, height: Int, frame: CGRect)] = [:]
    /// Longest edge of screenshots sent to models.
    static let maxDimension = 1366
}

extension AppState {
    func handleAgentHubTool(_ name: String, arguments: JSONValue, sessionKey: String) async throws -> JSONValue {
        guard let owner = agentContext(forSession: sessionKey) else {
            throw IDEToolError.notSupported("\(name) is only available to agents from the Agents tab.")
        }
        let agent = owner.agent
        switch name {
        case IDEToolRegistry.agentMemoryTool.name:
            return try handleAgentMemoryTool(agent: agent, arguments: arguments)
        case IDEToolRegistry.agentSpawnSubagentTool.name:
            try requireConversation(owner.role, tool: name)
            return try handleSpawnSubagentTool(agent: agent, arguments: arguments, sessionKey: sessionKey)
        case IDEToolRegistry.agentRunBackgroundTaskTool.name:
            try requireConversation(owner.role, tool: name)
            return try await handleBackgroundTaskTool(agent: agent, arguments: arguments, sessionKey: sessionKey)
        case IDEToolRegistry.agentJobsTool.name:
            try requireConversation(owner.role, tool: name)
            return try await handleAgentJobsTool(agent: agent, arguments: arguments)
        case IDEToolRegistry.agentScheduleTool.name:
            try requireConversation(owner.role, tool: name)
            return try await handleAgentScheduleTool(agent: agent, arguments: arguments)
        case IDEToolRegistry.agentContactTool.name:
            try requireConversation(owner.role, tool: name)
            return try handleAgentContactTool(agent: agent, arguments: arguments, sessionKey: sessionKey)
        case IDEToolRegistry.agentNotifyUserTool.name:
            return try handleNotifyUserTool(agent: agent, arguments: arguments, sessionKey: sessionKey, role: owner.role)
        case IDEToolRegistry.computerScreenshotTool.name, IDEToolRegistry.computerActionTool.name, IDEToolRegistry.computerDelegateTool.name:
            let session = agentSessionModel(sessionKey, agent: agent)
            guard let driver = agent.computerUse.resolvedDriver(provider: session.provider, model: session.model) else {
                throw IDEToolError.notSupported("Computer use is turned off for \(agent.displayName). Turn it on in the agent's settings.")
            }
            return try await withAgentComputerUse(agent) {
                switch name {
                case IDEToolRegistry.computerDelegateTool.name:
                    guard driver == .openSource else {
                        throw IDEToolError.notSupported("This agent drives the screen itself; use ide__computer_screenshot and ide__computer_action.")
                    }
                    let task = arguments["task"]?.stringValue ?? ""
                    return try await OpenSourceComputerUseAgent.shared.run(task: task, model: agent.computerUse.openSourceModel)
                case IDEToolRegistry.computerScreenshotTool.name:
                    return try await agentScreenshotResult(displayID: try displayArgument(arguments), note: nil)
                default:
                    return try await handleComputerAction(arguments)
                }
            }
        default:
            throw IDEToolError.unknownTool(name)
        }
    }

    private func requireConversation(_ role: AgentPromptBuilder.Role, tool: String) throws {
        guard role == .conversation else {
            throw IDEToolError.notSupported("\(tool) is only available in the agent's own conversation, not in subagents.")
        }
    }

    // MARK: Teammates

    private func handleAgentContactTool(agent: AgentProfile, arguments: JSONValue, sessionKey: String) throws -> JSONValue {
        switch arguments["action"]?.stringValue ?? "list" {
        case "list":
            return jsonTextResult(.array(agentTeammates(of: agent.id).map { mate in
                .object([
                    "agent_id": .string(mate.id.uuidString),
                    "name": .string(mate.name),
                    "summary": .string(mate.summary),
                    "busy": .bool(mate.isBusy),
                ])
            }))
        case "send":
            let reference = arguments["agent"]?.stringValue ?? ""
            guard !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw IDEToolError.invalidArguments("agent is required: a teammate's agent_id or name from action=list.")
            }
            guard let target = resolveTeammate(reference, excluding: agent.id) else {
                throw IDEToolError.invalidArguments("No teammate matches \"\(reference)\". Call action=list to see your teammates.")
            }
            let job = try contactAgent(
                from: agent.id, to: target.id,
                title: arguments["title"]?.stringValue ?? "",
                message: arguments["message"]?.stringValue ?? "",
                parentSessionId: sessionKey
            )
            return jsonTextResult(.object([
                "job_id": .string(job.id.uuidString),
                "teammate": .string(target.displayName),
                "status": .string(job.status.rawValue),
                "note": .string("\(target.displayName) is working on it in its own thread. Its reply arrives in this conversation when it finishes; you don't need to poll."),
            ]))
        default:
            throw IDEToolError.invalidArguments("action must be list or send.")
        }
    }

    // MARK: Memory

    private func handleAgentMemoryTool(agent: AgentProfile, arguments: JSONValue) throws -> JSONValue {
        let action = arguments["action"]?.stringValue ?? "list"
        let kind = arguments["kind"]?.stringValue.flatMap(AgentMemoryNote.Kind.init(rawValue:))
        switch action {
        case "list":
            return jsonTextResult(.array(agentMemory(agent.id).map(memoryJSON)))
        case "add":
            let note = try addAgentMemory(
                agentId: agent.id, content: arguments["content"]?.stringValue ?? "",
                kind: kind ?? .note, source: .agent
            )
            return jsonTextResult(.object(["saved": memoryJSON(note)]))
        case "update":
            let id = try uuidArgument(arguments["id"], name: "id")
            guard agentMemoryNotes.first(where: { $0.id == id })?.agentId == agent.id else { throw AgentHubError.unknownMemory }
            let note = try updateAgentMemory(id: id, content: arguments["content"]?.stringValue ?? "", kind: kind)
            return jsonTextResult(.object(["updated": memoryJSON(note)]))
        case "delete":
            let id = try uuidArgument(arguments["id"], name: "id")
            guard agentMemoryNotes.first(where: { $0.id == id })?.agentId == agent.id else { throw AgentHubError.unknownMemory }
            deleteAgentMemory(id: id)
            return textResult("Deleted memory note \(id.uuidString).")
        default:
            throw IDEToolError.invalidArguments("action must be list, add, update or delete.")
        }
    }

    private func memoryJSON(_ note: AgentMemoryNote) -> JSONValue {
        .object([
            "id": .string(note.id.uuidString),
            "kind": .string(note.kind.rawValue),
            "content": .string(note.content),
            "source": .string(note.source.rawValue),
            "updated_at": .string(ISO8601DateFormatter().string(from: note.updatedAt)),
        ])
    }

    // MARK: Jobs

    private func handleSpawnSubagentTool(agent: AgentProfile, arguments: JSONValue, sessionKey: String) throws -> JSONValue {
        let title = arguments["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prompt = arguments["prompt"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !prompt.isEmpty else { throw IDEToolError.invalidArguments("prompt is required.") }
        var config = TaskAgentConfig()
        if let raw = arguments["provider"]?.stringValue, !raw.isEmpty {
            guard let provider = AgentProvider(rawValue: raw), provider != .flowcy else {
                throw IDEToolError.invalidArguments("provider must be claudeCode, codex, acp or localAgent.")
            }
            config.provider = provider
            config.model = arguments["model"]?.stringValue
            config.permissionMode = resolvedAgentConfig(agent).permissionMode
        }
        let job = try spawnSubagent(
            agentId: agent.id, title: title.isEmpty ? String(prompt.prefix(60)) : title,
            prompt: prompt, config: config.isAssigned ? config : nil, parentSessionId: sessionKey
        )
        return jsonTextResult(.object([
            "job_id": .string(job.id.uuidString),
            "status": .string(job.status.rawValue),
            "note": .string("The subagent works in the background. You will receive its report in this conversation when it finishes; you don't need to poll."),
        ]))
    }

    private func handleBackgroundTaskTool(agent: AgentProfile, arguments: JSONValue, sessionKey: String) async throws -> JSONValue {
        let title = arguments["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let command = arguments["command"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !command.isEmpty else { throw IDEToolError.invalidArguments("command is required.") }
        let seconds = arguments["timeout_seconds"]?.numberValue ?? 3600
        guard seconds.isFinite, seconds >= 1 else { throw IDEToolError.invalidArguments("timeout_seconds must be positive.") }
        let folder = arguments["working_directory"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard await requestAgentConfirmation(.init(title: "Run background command?", message: command, confirmLabel: "Run"), sessionKey: sessionKey) else {
            return textResult("The user cancelled the command.")
        }
        let job = try await startBackgroundShellTask(
            agentId: agent.id, title: title.isEmpty ? String(command.prefix(60)) : title, command: command,
            workingDirectory: folder?.isEmpty == false ? folder : nil,
            timeout: .seconds(min(seconds, 86_400)), parentSessionId: sessionKey
        )
        return jsonTextResult(.object([
            "job_id": .string(job.id.uuidString),
            "status": .string(job.status.rawValue),
            "working_directory": .string(job.workingDirectory ?? ""),
            "note": .string("The command runs in the background. You will receive its exit status and output in this conversation when it ends."),
        ]))
    }

    private func handleAgentJobsTool(agent: AgentProfile, arguments: JSONValue) async throws -> JSONValue {
        switch arguments["action"]?.stringValue ?? "list" {
        case "list":
            let includeFinished = arguments["include_finished"]?.boolValue ?? true
            let jobs = agentJobs(for: agent.id).filter { includeFinished || $0.status.isActive }.prefix(40)
            return jsonTextResult(.array(jobs.map { jobJSON($0, full: false) }))
        case "get":
            let id = try uuidArgument(arguments["job_id"], name: "job_id")
            guard let job = agentJob(id: id), job.agentId == agent.id else { throw AgentHubError.unknownJob }
            var value = jobJSON(job, full: true)
            if job.kind == .shell, job.status.isActive, let output = agentShellOutput(id), case .object(var object) = value {
                object["live_output"] = .string(String(output.suffix(AgentJob.summaryLimit)))
                value = .object(object)
            }
            return jsonTextResult(value)
        case "cancel":
            let id = try uuidArgument(arguments["job_id"], name: "job_id")
            guard let job = agentJob(id: id), job.agentId == agent.id else { throw AgentHubError.unknownJob }
            guard job.status.isActive else { return textResult("Job \(id.uuidString) already ended (\(job.status.rawValue)).") }
            await cancelAgentJob(id, reason: String(localized: "Cancelled by \(agent.displayName)."))
            return textResult("Cancelled job \(id.uuidString).")
        default:
            throw IDEToolError.invalidArguments("action must be list, get or cancel.")
        }
    }

    private func jobJSON(_ job: AgentJob, full: Bool) -> JSONValue {
        let formatter = ISO8601DateFormatter()
        var object: [String: JSONValue] = [
            "job_id": .string(job.id.uuidString),
            "kind": .string(job.kind.rawValue),
            "title": .string(job.displayTitle),
            "status": .string(job.status.rawValue),
            "created_at": .string(formatter.string(from: job.createdAt)),
        ]
        if let finishedAt = job.finishedAt { object["finished_at"] = .string(formatter.string(from: finishedAt)) }
        if let sessionKey = job.sessionKey { object["thread_id"] = .string(resolveCurrentSessionId(sessionKey)) }
        if let exitCode = job.exitCode { object["exit_code"] = .number(Double(exitCode)) }
        if let error = job.errorMessage { object["error"] = .string(error) }
        if let summary = job.resultSummary {
            object["result"] = .string(full ? summary : String(summary.prefix(300)))
        }
        if full { object["prompt"] = .string(job.prompt) }
        return .object(object)
    }

    // MARK: Schedules

    private func handleAgentScheduleTool(agent: AgentProfile, arguments: JSONValue) async throws -> JSONValue {
        switch arguments["action"]?.stringValue ?? "list" {
        case "list":
            return jsonTextResult(.array(agentSchedules(agent.id).map(scheduleJSON)))
        case "create":
            let name = arguments["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let prompt = arguments["prompt"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty, !prompt.isEmpty else { throw IDEToolError.invalidArguments("name and prompt are required.") }
            var task = ScheduledTask(name: name, prompt: prompt, cronExpression: "0 9 * * *")
            task.agentId = agent.id
            try applyScheduleTiming(arguments, to: &task, requireTiming: true)
            if let enabled = arguments["enabled"]?.boolValue { task.isEnabled = enabled }
            upsertScheduledTask(task)
            return jsonTextResult(.object(["created": scheduleJSON(task)]))
        case "update":
            var task = try agentSchedule(arguments, agent: agent)
            if let name = arguments["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { task.name = name }
            if let prompt = arguments["prompt"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty { task.prompt = prompt }
            try applyScheduleTiming(arguments, to: &task, requireTiming: false)
            if let enabled = arguments["enabled"]?.boolValue { task.isEnabled = enabled }
            upsertScheduledTask(task)
            return jsonTextResult(.object(["updated": scheduleJSON(task)]))
        case "delete":
            let task = try agentSchedule(arguments, agent: agent)
            deleteScheduledTask(id: task.id)
            return textResult("Deleted schedule \(task.id.uuidString).")
        case "run_now":
            let task = try agentSchedule(arguments, agent: agent)
            guard !isScheduledTaskRunning(task.id) else { return textResult("A run of this schedule is already in progress.") }
            Task { [weak self] in _ = await self?.runScheduledTask(task, trigger: .manual) }
            return textResult("Started a run of \"\(task.name)\". Its subagent reports back here when it finishes.")
        default:
            throw IDEToolError.invalidArguments("action must be list, create, update, delete or run_now.")
        }
    }

    private func agentSchedule(_ arguments: JSONValue, agent: AgentProfile) throws -> ScheduledTask {
        let id = try uuidArgument(arguments["schedule_id"], name: "schedule_id")
        guard let task = scheduledTasks.first(where: { $0.id == id }), task.agentId == agent.id else {
            throw AgentHubError.unknownSchedule
        }
        return task
    }

    private func applyScheduleTiming(_ arguments: JSONValue, to task: inout ScheduledTask, requireTiming: Bool) throws {
        if let runAt = arguments["run_at"]?.stringValue, !runAt.isEmpty {
            guard let date = Self.parseISODate(runAt) else { throw IDEToolError.invalidArguments("run_at must be an ISO 8601 date-time.") }
            task.dueAt = date
            task.timeZoneIdentifier = TimeZone.current.identifier
            task.claimedAt = nil
            task.lastRunAt = nil
        } else if let cron = arguments["cron"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !cron.isEmpty {
            do { _ = try CronExpression(cron) } catch {
                throw IDEToolError.invalidArguments("Invalid cron expression: \(error.localizedDescription)")
            }
            task.cronExpression = cron
            task.dueAt = nil
        } else if requireTiming {
            throw IDEToolError.invalidArguments("Pass cron or run_at.")
        }
    }

    private static func parseISODate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        formatter.timeZone = .current
        return formatter.date(from: value)
    }

    private func scheduleJSON(_ task: ScheduledTask) -> JSONValue {
        let formatter = ISO8601DateFormatter()
        var object: [String: JSONValue] = [
            "schedule_id": .string(task.id.uuidString),
            "name": .string(task.name),
            "prompt": .string(task.prompt),
            "enabled": .bool(task.isEnabled),
        ]
        if let dueAt = task.dueAt {
            object["run_at"] = .string(formatter.string(from: dueAt))
        } else {
            object["cron"] = .string(task.cronExpression)
        }
        if let next = task.nextRunDate(), task.isEnabled { object["next_run"] = .string(formatter.string(from: next)) }
        if let last = task.lastRunAt { object["last_run"] = .string(formatter.string(from: last)) }
        if let run = scheduledTaskRuns(for: task.id).first { object["last_status"] = .string(run.status.rawValue) }
        return .object(object)
    }

    // MARK: Phone

    private func handleNotifyUserTool(
        agent: AgentProfile,
        arguments: JSONValue,
        sessionKey: String,
        role: AgentPromptBuilder.Role
    ) throws -> JSONValue {
        guard agent.notifiesPhone else {
            throw IDEToolError.notSupported("Phone messages are turned off for \(agent.displayName).")
        }
        let message = arguments["message"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !message.isEmpty else { throw IDEToolError.invalidArguments("message is required.") }
        guard !MobileSyncService.shared.pairedDevices.isEmpty else {
            return textResult("No phone is paired with this Mac, so nothing was sent. Tell the user in your reply instead.")
        }
        // Subagents point the phone at the agent's conversation, where their report lands.
        let target = role == .conversation ? sessionKey : agentConversationSummary(agent)?.id
        notifyPhone(fromAgent: agent, title: arguments["title"]?.stringValue, message: message, sessionId: target)
        return textResult("Sent to the user's phone.")
    }

    // MARK: Computer use

    /// Marks the agent as using the computer while `body` runs, so the Mac
    /// shows its indicator and the phone offers the live screen.
    private func withAgentComputerUse(_ agent: AgentProfile, _ body: () async throws -> JSONValue) async throws -> JSONValue {
        agentComputerUseActivity[agent.id, default: 0] += 1
        ComputerUseIndicator.shared.update(workspace: activeWorkspace.id, activeAgents: activeComputerUseAgentNames(), onStop: { [weak self] in
            self?.stopAgentComputerUse()
        })
        scheduleAgentHubBroadcast()
        defer {
            let remaining = (agentComputerUseActivity[agent.id] ?? 1) - 1
            agentComputerUseActivity[agent.id] = remaining > 0 ? remaining : nil
            ComputerUseIndicator.shared.update(workspace: activeWorkspace.id, activeAgents: activeComputerUseAgentNames(), onStop: { [weak self] in
                self?.stopAgentComputerUse()
            })
            scheduleAgentHubBroadcast()
        }
        return try await body()
    }

    private func activeComputerUseAgentNames() -> [String] {
        agentComputerUseActivity.keys.compactMap { agentProfile(id: $0)?.displayName }.sorted()
    }

    /// Stops every agent turn that is using the computer right now.
    func stopAgentComputerUse() {
        let agents = Set(agentComputerUseActivity.keys)
        let sessions = allSessionSummaries.filter { summary in
            agents.contains { agentProfile(id: $0)?.owns(projectId: summary.projectId) == true }
                && sessionStates[summary.id]?.isStreaming == true
        }
        Task { [weak self] in
            for summary in sessions { await self?.stopAgentThread(summary.id) }
        }
    }

    private func displayArgument(_ arguments: JSONValue) throws -> CGDirectDisplayID? {
        guard let value = arguments["display_id"] else { return nil }
        guard let number = value.numberValue, number.isFinite, number >= 0, number <= Double(UInt32.max), number.rounded() == number else {
            throw IDEToolError.invalidArguments("display_id must be a display id from ide__computer_screenshot.")
        }
        return CGDirectDisplayID(number)
    }

    private func agentScreenshotResult(displayID: CGDirectDisplayID?, note: String?) async throws -> JSONValue {
        if !ComputerControl.hasScreenRecordingAccess { _ = ComputerControl.requestScreenRecordingAccess() }
        let capture = try await ComputerControl.capture(
            displayID: displayID, maxDimension: AgentScreenshotGeometry.maxDimension, quality: 0.72, showsCursor: true
        )
        AgentScreenshotGeometry.latest[capture.display.id] = (capture.width, capture.height, capture.display.frame)
        let displays = await ComputerControl.displays()
        var lines: [String] = []
        if let note { lines.append(note) }
        lines.append("Screenshot of display_id=\(capture.display.id) (\(capture.display.name)), \(capture.width)×\(capture.height) pixels. Use these pixel coordinates with ide__computer_action.")
        if displays.count > 1 {
            lines.append("Displays: " + displays.map { "\($0.id) \($0.name)\($0.isMain ? " (main)" : "")" }.joined(separator: ", "))
        }
        return .object(["content": .array([
            .object(["type": .string("text"), "text": .string(lines.joined(separator: "\n"))]),
            .object(["type": .string("image"), "mimeType": .string("image/jpeg"), "data": .string(capture.jpeg.base64EncodedString())]),
        ])])
    }

    private func handleComputerAction(_ arguments: JSONValue) async throws -> JSONValue {
        guard ComputerControl.hasAccessibilityAccess(prompt: true) else { throw ComputerControl.ControlError.accessibilityDenied }
        let action = arguments["action"]?.stringValue ?? ""
        let displayID = try displayArgument(arguments)
        let display = try await ComputerControl.display(id: displayID)
        let geometry = AgentScreenshotGeometry.latest[display.id]

        func point(_ xKey: String, _ yKey: String) throws -> CGPoint {
            guard let x = arguments[xKey]?.numberValue, let y = arguments[yKey]?.numberValue, x.isFinite, y.isFinite else {
                throw IDEToolError.invalidArguments("\(action) needs \(xKey) and \(yKey).")
            }
            guard let geometry else {
                throw IDEToolError.invalidArguments("Take an ide__computer_screenshot of this display first; coordinates are pixels in it.")
            }
            guard x >= 0, y >= 0, x <= Double(geometry.width), y <= Double(geometry.height) else {
                throw IDEToolError.invalidArguments("(\(xKey), \(yKey)) is outside the \(geometry.width)×\(geometry.height) screenshot.")
            }
            return ComputerControl.point(
                fractionX: x / Double(max(geometry.width, 1)), y: y / Double(max(geometry.height, 1)), in: geometry.frame
            )
        }

        switch action {
        case "click": try await ComputerControl.click(at: try point("x", "y"))
        case "double_click": try await ComputerControl.click(at: try point("x", "y"), count: 2)
        case "right_click": try await ComputerControl.click(at: try point("x", "y"), button: .right)
        case "move": try ComputerControl.move(to: try point("x", "y"))
        case "drag": try await ComputerControl.drag(from: try point("x", "y"), to: try point("to_x", "to_y"))
        case "scroll":
            let direction = arguments["direction"]?.stringValue ?? "down"
            let amount = Int32(min(max(arguments["amount"]?.numberValue ?? 400, 1), 4000))
            let at = arguments["x"] != nil ? try point("x", "y")
                : CGPoint(x: display.frame.midX, y: display.frame.midY)
            switch direction {
            case "up": try await ComputerControl.scroll(at: at, dx: 0, dy: amount)
            case "down": try await ComputerControl.scroll(at: at, dx: 0, dy: -amount)
            case "left": try await ComputerControl.scroll(at: at, dx: amount, dy: 0)
            case "right": try await ComputerControl.scroll(at: at, dx: -amount, dy: 0)
            default: throw IDEToolError.invalidArguments("direction must be up, down, left or right.")
            }
        case "type":
            let text = arguments["text"]?.stringValue ?? ""
            guard !text.isEmpty, text.count <= 4000 else { throw IDEToolError.invalidArguments("text must be 1…4000 characters.") }
            try await ComputerControl.type(text)
        case "key":
            try ComputerControl.press(arguments["keys"]?.stringValue ?? arguments["text"]?.stringValue ?? "")
        case "wait":
            let seconds = min(max(arguments["seconds"]?.numberValue ?? 1, 0), 10)
            try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
        default:
            throw IDEToolError.invalidArguments("Unknown action \(action).")
        }
        try await Task.sleep(for: .milliseconds(450))
        return try await agentScreenshotResult(displayID: display.id, note: "Did \(action). Check the new screenshot before the next step.")
    }

    // MARK: Arguments

    private func uuidArgument(_ value: JSONValue?, name: String) throws -> UUID {
        guard let raw = value?.stringValue, let id = UUID(uuidString: raw) else {
            throw IDEToolError.invalidArguments("\(name) must be an id returned by the agent tools.")
        }
        return id
    }
}
