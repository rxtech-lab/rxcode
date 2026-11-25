import Foundation
import Testing
@testable import RxCodeCore

@Suite("Agent hub models")
struct AgentHubModelTests {
    @Test("a profile decodes from a record that only has an id")
    func tolerantProfileDecoding() throws {
        let id = UUID()
        let data = Data(#"{"id":"\#(id.uuidString)","tone":"pirate"}"#.utf8)
        let profile = try JSONDecoder().decode(AgentProfile.self, from: data)
        #expect(profile.id == id)
        #expect(profile.tone == .friendly)
        #expect(profile.notifiesPhone)
        #expect(profile.computerUse == AgentComputerUseSettings())
        #expect(profile.displayName == "Untitled Agent")
        #expect(profile.subagentProjectId != id)
    }

    @Test("a profile round trips and owns both virtual projects")
    func profileRoundTrip() throws {
        let profile = AgentProfile(
            name: "  Atlas ",
            personality: "Dry humour",
            agent: TaskAgentConfig(provider: .codex, model: "gpt-5.5"),
            computerUse: AgentComputerUseSettings(isEnabled: true, mode: .openSource)
        )
        let decoded = try JSONDecoder().decode(AgentProfile.self, from: JSONEncoder().encode(profile))
        #expect(decoded == profile)
        #expect(decoded.displayName == "Atlas")
        #expect(decoded.owns(projectId: profile.id))
        #expect(decoded.owns(projectId: profile.subagentProjectId))
        #expect(!decoded.owns(projectId: UUID()))
    }

    @Test("automatic computer use picks the open-source agent for models without computer use")
    func computerUseDriverResolution() {
        var settings = AgentComputerUseSettings(isEnabled: true, mode: .automatic)
        #expect(settings.resolvedDriver(provider: .claudeCode, model: "claude-opus-5-5") == .native)
        #expect(settings.resolvedDriver(provider: .codex, model: nil) == .native)
        #expect(settings.resolvedDriver(provider: .acp, model: "gemini::gemini-3-pro") == .native)
        #expect(settings.resolvedDriver(provider: .acp, model: "opencode::deepseek-coder") == .openSource)
        #expect(settings.resolvedDriver(provider: .localAgent, model: "mlx-community/Qwen3-8B") == .openSource)
        #expect(settings.resolvedDriver(provider: .localAgent, model: "mlx-community/Qwen2.5-VL-7B") == .native)
        #expect(settings.resolvedDriver(provider: .flowcy, model: "default") == .openSource)

        settings.mode = .openSource
        #expect(settings.resolvedDriver(provider: .claudeCode, model: nil) == .openSource)
        settings.mode = .native
        #expect(settings.resolvedDriver(provider: .flowcy, model: nil) == .native)
        settings.isEnabled = false
        #expect(settings.resolvedDriver(provider: .claudeCode, model: nil) == nil)
    }

    @Test("an empty open-source model falls back to the default")
    func emptyOpenSourceModel() throws {
        let data = Data(#"{"isEnabled":true,"mode":"openSource","openSourceModel":""}"#.utf8)
        let settings = try JSONDecoder().decode(AgentComputerUseSettings.self, from: data)
        #expect(settings.openSourceModel == AgentComputerUseSettings.defaultOpenSourceModel)
    }

    @Test("active jobs are interrupted on restore and never pruned")
    func jobRestoreAndPrune() {
        let agentId = UUID()
        let running = AgentJob(agentId: agentId, kind: .subagent, title: "Research", prompt: "Find", status: .running)
        let done = AgentJob(agentId: agentId, kind: .shell, title: "Build", prompt: "make", status: .succeeded, parentNotified: true)
        let restored = AgentJob.restored([running, done])
        #expect(restored[0].status == .interrupted)
        #expect(restored[0].finishedAt != nil)
        #expect(restored[0].parentNotified)
        #expect(restored[1] == done)

        var jobs = (0..<(AgentJob.historyLimit + 5)).map { index in
            AgentJob(agentId: agentId, kind: .shell, title: "\(index)", prompt: "true", status: .succeeded,
                     createdAt: Date(timeIntervalSince1970: TimeInterval(index)))
        }
        jobs.append(AgentJob(agentId: agentId, kind: .subagent, title: "old but active", prompt: "x",
                             status: .queued, createdAt: .distantPast))
        let pruned = AgentJob.pruned(jobs)
        #expect(pruned.count == AgentJob.historyLimit + 1)
        #expect(pruned.contains { $0.title == "old but active" })
        #expect(!pruned.contains { $0.title == "0" })
    }

    @Test("job results keep their ending when trimmed")
    func jobSummaryTrimming() {
        var job = AgentJob(agentId: UUID(), kind: .shell, title: "Logs", prompt: "cat log")
        let long = String(repeating: "a", count: AgentJob.summaryLimit) + "THE END"
        job.finish(.failed, summary: long, error: "exit 1")
        #expect(job.resultSummary?.hasSuffix("THE END") == true)
        #expect(job.resultSummary?.hasPrefix("…") == true)
        #expect(job.status == .failed)
        #expect(job.completionReport.contains(job.id.uuidString))
        #expect(job.completionReport.contains("Error: exit 1"))
    }

    @Test("a profile keeps its pet look and summarizes its role")
    func profileLookAndRole() throws {
        let profile = AgentProfile(
            name: "Scout", petLookId: "cat-buddy",
            personality: "Curious", instructions: "\nResearch libraries and compare options.\nCite sources."
        )
        let decoded = try JSONDecoder().decode(AgentProfile.self, from: JSONEncoder().encode(profile))
        #expect(decoded.petLookId == "cat-buddy")
        #expect(decoded.roleSummary == "Research libraries and compare options.")
        #expect(AgentProfile(name: "Bare", personality: "Calm").roleSummary == "Calm")
        #expect(AgentProfile(name: "Empty").roleSummary.isEmpty)
        let legacy = try JSONDecoder().decode(AgentProfile.self, from: Data(#"{"id":"\#(UUID().uuidString)"}"#.utf8))
        #expect(legacy.petLookId == nil)
    }

    @Test("collaboration jobs round trip and report the teammate's reply")
    func collaborationJob() throws {
        let target = UUID()
        var job = AgentJob(
            agentId: UUID(), kind: .collaboration, title: "Compare ORMs", prompt: "Which ORM?",
            targetAgentId: target, targetAgentName: "Scout", hopCount: 1
        )
        let decoded = try JSONDecoder().decode(AgentJob.self, from: JSONEncoder().encode(job))
        #expect(decoded == job)
        #expect(decoded.kind.runsSubagent)
        job.finish(.succeeded, summary: "Use Drizzle.")
        #expect(job.completionReport.contains("[Teammate reply] Scout"))
        #expect(job.completionReport.contains("Reply:\nUse Drizzle."))

        let legacy = try JSONDecoder().decode(
            AgentJob.self,
            from: Data(#"{"id":"\#(UUID().uuidString)","agentId":"\#(UUID().uuidString)","kind":"collaboration"}"#.utf8)
        )
        #expect(legacy.kind == .collaboration)
        #expect(legacy.hopCount == 0)
        #expect(legacy.targetAgentId == nil)
    }

    @Test("teammates appear in the conversation context with the contact tool")
    func teammatesPrompt() {
        let agent = AgentProfile(name: "Atlas")
        let mate = AgentPromptBuilder.TeammateLine(id: UUID(), name: "Scout", summary: "Researches libraries", isBusy: true)
        let prompt = AgentPromptBuilder.context(
            agent: agent, role: .conversation, memory: [], jobs: [], schedules: [], teammates: [mate],
            provider: .codex, model: nil, hasIDETools: true, hasPairedPhone: false
        )
        #expect(prompt.contains("# Your teammates"))
        #expect(prompt.contains("Scout (agent_id: \(mate.id.uuidString)) — Researches libraries [busy]"))
        #expect(prompt.contains("`ide__agent_contact`"))

        let alone = AgentPromptBuilder.context(
            agent: agent, role: .conversation, memory: [], jobs: [], schedules: [],
            provider: .codex, model: nil, hasIDETools: true, hasPairedPhone: false
        )
        #expect(!alone.contains("ide__agent_contact"))
        let subagent = AgentPromptBuilder.context(
            agent: agent, role: .subagent, memory: [], jobs: [], schedules: [], teammates: [mate],
            provider: .codex, model: nil, hasIDETools: true, hasPairedPhone: false
        )
        #expect(!subagent.contains("ide__agent_contact"))

        let names = { (tools: [IDETool]) in tools.map(\.name) }
        #expect(names(IDEToolRegistry.agentHubTools(isConversation: true, notifiesPhone: false, computerUse: nil, hasTeammates: true))
            .contains("ide__agent_contact"))
        #expect(!names(IDEToolRegistry.agentHubTools(isConversation: false, notifiesPhone: false, computerUse: nil, hasTeammates: true))
            .contains("ide__agent_contact"))
        #expect(IDEToolRegistry.agentHubToolNames.contains("ide__agent_contact"))
    }

    @Test("the conversation knows the time and how long the user was away")
    func nowSection() {
        let zone = TimeZone(identifier: "America/New_York")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 15, minute: 40))!
        let text = AgentPromptBuilder.nowSection(now: now, previousUserMessageAt: now.addingTimeInterval(-3 * 86400), timeZone: zone)
        #expect(text.contains("Wednesday, November 25, 2026, around 3 PM (America/New_York)"))
        #expect(text.contains("previous message was 3 days ago"))
        let first = AgentPromptBuilder.nowSection(now: now, previousUserMessageAt: nil, timeZone: zone)
        #expect(first.contains("first message"))
        let inProgress = AgentPromptBuilder.nowSection(now: now, previousUserMessageAt: now.addingTimeInterval(-120), timeZone: zone)
        #expect(!inProgress.contains("previous message"))
        #expect(AgentPromptBuilder.gapDescription(from: now.addingTimeInterval(-7200), to: now) == "about 2 hours ago")
        #expect(AgentPromptBuilder.gapDescription(from: now.addingTimeInterval(-21 * 86400), to: now) == "3 weeks ago")
    }

    @Test("a fresh model session gets the recent conversation replayed within budget")
    func recapOnFreshSession() {
        let agent = AgentProfile(name: "Atlas")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let lines = (0..<40).map { index in
            AgentPromptBuilder.Continuity.Line(
                fromUser: index.isMultiple(of: 2), text: "message \(index) " + String(repeating: "x", count: 600),
                timestamp: start.addingTimeInterval(TimeInterval(index * 60))
            )
        }
        let prompt = AgentPromptBuilder.context(
            agent: agent, role: .conversation, memory: [], jobs: [], schedules: [],
            continuity: .init(previousUserMessageAt: lines[38].timestamp, recap: lines),
            provider: .codex, model: nil, hasIDETools: false, hasPairedPhone: false, now: start.addingTimeInterval(3000)
        )
        #expect(prompt.contains("# Earlier in this conversation"))
        #expect(prompt.contains("message 39"))
        #expect(!prompt.contains("message 0 "))
        #expect(prompt.contains("(Older messages are not shown.)"))
        #expect(prompt.contains("one ongoing conversation that never starts over"))
        let section = AgentPromptBuilder.recapSection(lines) ?? ""
        #expect(section.count < AgentPromptBuilder.recapCharacterBudget + 600)
        #expect(section.range(of: "message 38")!.lowerBound < section.range(of: "message 39")!.lowerBound)

        let resumed = AgentPromptBuilder.context(
            agent: agent, role: .conversation, memory: [], jobs: [], schedules: [],
            continuity: .init(previousUserMessageAt: nil, recap: []),
            provider: .codex, model: nil, hasIDETools: false, hasPairedPhone: false
        )
        #expect(!resumed.contains("Earlier in this conversation"))
        let subagent = AgentPromptBuilder.context(
            agent: agent, role: .subagent, memory: [], jobs: [], schedules: [],
            provider: .codex, model: nil, hasIDETools: false, hasPairedPhone: false
        )
        #expect(!subagent.contains("# Now"))
    }

    @Test("memory is pruned per agent, newest first")
    func memoryPruning() {
        let a = UUID(), b = UUID()
        var notes = (0..<(AgentMemoryNote.perAgentLimit + 3)).map { index in
            AgentMemoryNote(agentId: a, content: "a\(index)", updatedAt: Date(timeIntervalSince1970: TimeInterval(index)))
        }
        notes.append(AgentMemoryNote(agentId: b, content: "b"))
        let pruned = AgentMemoryNote.pruned(notes)
        #expect(pruned.filter { $0.agentId == a }.count == AgentMemoryNote.perAgentLimit)
        #expect(pruned.contains { $0.agentId == b })
        #expect(!pruned.contains { $0.content == "a0" })
    }

    @Test("conversation context carries identity, memory, jobs, schedules and tools")
    func conversationPrompt() {
        let agent = AgentProfile(
            name: "Atlas", tone: .concise, personality: "Calls the user captain.",
            instructions: "Watch my inbox.",
            computerUse: AgentComputerUseSettings(isEnabled: true, mode: .automatic)
        )
        let note = AgentMemoryNote(agentId: agent.id, content: "Prefers metric units", kind: .preference)
        let job = AgentJob(agentId: agent.id, kind: .subagent, title: "Flight search", prompt: "Find flights", status: .running)
        let finished = AgentJob(agentId: agent.id, kind: .shell, title: "Old build", prompt: "make", status: .succeeded)
        let schedule = AgentPromptBuilder.ScheduleLine(id: UUID(), name: "Morning brief", schedule: "0 8 * * *",
                                                       isEnabled: true, nextRun: .now.addingTimeInterval(3600))
        let prompt = AgentPromptBuilder.context(
            agent: agent, role: .conversation, memory: [note], jobs: [job, finished], schedules: [schedule],
            provider: .claudeCode, model: "claude-opus-5-5", hasIDETools: true, hasPairedPhone: true
        )
        #expect(prompt.contains("You are Atlas"))
        #expect(prompt.contains("Calls the user captain."))
        #expect(prompt.contains("Watch my inbox."))
        #expect(prompt.contains("Prefers metric units"))
        #expect(prompt.contains("Flight search"))
        #expect(!prompt.contains("Old build"))
        #expect(prompt.contains("Morning brief"))
        #expect(prompt.contains("mcp__rxcode-ide__ide__agent_spawn_subagent"))
        #expect(prompt.contains("mcp__rxcode-ide__ide__agent_notify_user"))
        #expect(prompt.contains("mcp__rxcode-ide__ide__computer_screenshot"))
        #expect(!prompt.contains("ide__computer_delegate"))
    }

    @Test("subagent context omits spawn tools, and text-only models delegate GUI work")
    func subagentPrompt() {
        let agent = AgentProfile(name: "Atlas",
                                 computerUse: AgentComputerUseSettings(isEnabled: true, mode: .automatic),
                                 notifiesPhone: false)
        let prompt = AgentPromptBuilder.context(
            agent: agent, role: .subagent, memory: [], jobs: [], schedules: [],
            provider: .localAgent, model: "mlx-community/Qwen3-8B", hasIDETools: true, hasPairedPhone: true
        )
        #expect(prompt.contains("subagent of Atlas"))
        #expect(prompt.contains("ide__agent_memory"))
        #expect(!prompt.contains("ide__agent_spawn_subagent"))
        #expect(!prompt.contains("ide__agent_notify_user"))
        #expect(prompt.contains("`ide__computer_delegate`"))
        #expect(!prompt.contains("mcp__rxcode-ide__"))
    }

    @Test("memory context respects its character budget")
    func memoryBudget() {
        let agentId = UUID()
        let notes = (0..<400).map { AgentMemoryNote(agentId: agentId, content: String(repeating: "x", count: 100) + "\($0)") }
        let section = AgentPromptBuilder.memorySection(notes) ?? ""
        #expect(section.count < AgentPromptBuilder.memoryCharacterBudget + 600)
        #expect(section.contains("older notes are not shown"))
    }

    @Test("remote keys parse combinations and reject unknown names")
    func remoteKeyParsing() {
        #expect(RemoteKey.parse("return")?.code == 0x24)
        let tab = RemoteKey.parse("Cmd+Shift+T")
        #expect(tab?.code == 0x11)
        #expect(tab?.modifiers == ["command", "shift"])
        #expect(RemoteKey.parse("ctrl+esc")?.modifiers == ["control"])
        #expect(RemoteKey.parse("cmd++")?.code == 0x18)
        #expect(RemoteKey.parse("hyper+a") == nil)
        #expect(RemoteKey.parse("cmd+nope") == nil)
    }

    @Test("control is never allowed without viewing")
    func remoteAccessPolicy() throws {
        #expect(!AgentRemoteAccessPolicy(allowsViewing: false, allowsControl: true).allowsControl)
        let data = Data(#"{"allowsViewing":false,"allowsControl":true}"#.utf8)
        #expect(try !JSONDecoder().decode(AgentRemoteAccessPolicy.self, from: data).allowsControl)
        #expect(try JSONDecoder().decode(AgentRemoteAccessPolicy.self, from: Data("{}".utf8)) == AgentRemoteAccessPolicy())
    }

    @Test("schedules keep their owning agent across encoding")
    func scheduleOwnership() throws {
        var task = ScheduledTask(name: "Brief", prompt: "Summarize", cronExpression: "0 8 * * *")
        task.agentId = UUID()
        let decoded = try JSONDecoder().decode(ScheduledTask.self, from: JSONEncoder().encode(task))
        #expect(decoded.agentId == task.agentId)
        let legacy = try JSONDecoder().decode(ScheduledTask.self, from: Data(#"{"id":"\#(UUID().uuidString)"}"#.utf8))
        #expect(legacy.agentId == nil)
    }

    @Test("the agents route hosts a chat; the legacy scheduled route does not")
    func routeHostsChat() {
        #expect(GeneralRoute.agents.hostsChat)
        #expect(GeneralRoute.chat.hostsChat)
        #expect(!GeneralRoute.scheduled.hostsChat)
        #expect(!GeneralRoute.tasks.hostsChat)
    }
}
