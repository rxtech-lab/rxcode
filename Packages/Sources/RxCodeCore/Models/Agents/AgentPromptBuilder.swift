import Foundation

/// Builds the background context every turn of an agent (or one of its
/// subagents) receives: identity, personality, memory, running jobs,
/// schedules and how to use the agent tools.
public enum AgentPromptBuilder {
    /// Which side of the agent a turn runs on.
    public enum Role: Sendable, Equatable {
        /// The agent's own conversation with the user.
        case conversation
        /// A subagent or scheduled run working for the agent.
        case subagent
    }

    /// A schedule as the agent sees it.
    public struct ScheduleLine: Sendable, Equatable {
        public let id: UUID
        public let name: String
        public let schedule: String
        public let isEnabled: Bool
        public let nextRun: Date?

        public init(id: UUID, name: String, schedule: String, isEnabled: Bool, nextRun: Date?) {
            self.id = id
            self.name = name
            self.schedule = schedule
            self.isEnabled = isEnabled
            self.nextRun = nextRun
        }
    }

    /// Another agent this agent can contact with `ide__agent_contact`.
    public struct TeammateLine: Sendable, Equatable {
        public let id: UUID
        public let name: String
        public let summary: String
        public let isBusy: Bool

        public init(id: UUID, name: String, summary: String, isBusy: Bool) {
            self.id = id
            self.name = name
            self.summary = summary
            self.isBusy = isBusy
        }
    }

    /// What the agent needs to carry one never-ending conversation: when the
    /// user last wrote, and — when the turn starts a fresh model session on
    /// the existing thread (after a model or provider change) — the recent
    /// exchanges it would otherwise not see.
    public struct Continuity: Sendable, Equatable {
        public struct Line: Sendable, Equatable {
            public let fromUser: Bool
            public let text: String
            public let timestamp: Date

            public init(fromUser: Bool, text: String, timestamp: Date) {
                self.fromUser = fromUser
                self.text = text
                self.timestamp = timestamp
            }
        }

        /// The user's message before this turn's, if any.
        public let previousUserMessageAt: Date?
        /// Earlier messages, oldest first. Empty when the model resumes its own session.
        public let recap: [Line]

        public init(previousUserMessageAt: Date?, recap: [Line]) {
            self.previousUserMessageAt = previousUserMessageAt
            self.recap = recap
        }
    }

    /// Characters of earlier conversation replayed to a fresh model session.
    public static let recapCharacterBudget = 12000
    /// Longest single message in the recap.
    public static let recapMessageLimit = 1500

    /// Characters of memory injected per turn; older notes beyond it are listed
    /// by the memory tool instead.
    public static let memoryCharacterBudget = 8000

    /// Prefix of every IDE tool as Claude Code sees it.
    public static func toolName(_ name: String, provider: AgentProvider?) -> String {
        provider == .claudeCode ? "mcp__rxcode-ide__\(name)" : name
    }

    public static func context(
        agent: AgentProfile,
        role: Role,
        memory: [AgentMemoryNote],
        jobs: [AgentJob],
        schedules: [ScheduleLine],
        teammates: [TeammateLine] = [],
        continuity: Continuity? = nil,
        provider: AgentProvider?,
        model: String?,
        hasIDETools: Bool,
        hasPairedPhone: Bool,
        now: Date = .now
    ) -> String {
        var sections: [String] = []
        sections.append(identitySection(agent: agent, role: role))
        if role == .conversation {
            sections.append(nowSection(
                now: now, previousUserMessageAt: continuity?.previousUserMessageAt, knowsHistory: continuity != nil
            ))
            if let recap = continuity.flatMap({ recapSection($0.recap) }) { sections.append(recap) }
        }
        if let memorySection = memorySection(memory) { sections.append(memorySection) }
        if role == .conversation {
            if let jobsSection = jobsSection(jobs) { sections.append(jobsSection) }
            if let schedulesSection = schedulesSection(schedules, now: now) { sections.append(schedulesSection) }
            if hasIDETools, let teamSection = teammatesSection(teammates) { sections.append(teamSection) }
        }
        if hasIDETools {
            sections.append(toolsSection(
                agent: agent, role: role, provider: provider, hasPairedPhone: hasPairedPhone,
                hasTeammates: !teammates.isEmpty
            ))
            if let computer = computerUseSection(agent: agent, provider: provider, model: model) {
                sections.append(computer)
            }
        }
        return sections.joined(separator: "\n\n")
    }

    static func identitySection(agent: AgentProfile, role: Role) -> String {
        var lines: [String] = []
        switch role {
        case .conversation:
            lines.append("# You are \(agent.displayName)")
            lines.append("You are \(agent.displayName), a personal agent the user created in RxCode. You talk with the user on their Mac and on their phone, remember what matters, and get work done with subagents, background tasks and schedules.")
            lines.append("You and the user share one ongoing conversation that never starts over, like talking with a colleague or friend over months. Pick up where you left off, refer back to earlier things naturally, and notice when time has passed. Older parts of the conversation may be summarized away, so save anything worth keeping to your memory.")
        case .subagent:
            lines.append("# You are a subagent of \(agent.displayName)")
            lines.append("\(agent.displayName) delegated one job to you. Complete it on your own, without asking the user questions unless you are blocked. Your final message is delivered to \(agent.displayName) as the job's report, so end with a concise summary of what you did, what you found, and anything that still needs attention.")
        }
        lines.append("Tone: \(agent.tone.promptDescription)")
        let personality = agent.personality.trimmingCharacters(in: .whitespacesAndNewlines)
        if !personality.isEmpty { lines.append("Personality:\n\(personality)") }
        let instructions = agent.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instructions.isEmpty { lines.append("Standing instructions:\n\(instructions)") }
        return lines.joined(separator: "\n\n")
    }

    static func nowSection(
        now: Date,
        previousUserMessageAt: Date?,
        knowsHistory: Bool = true,
        timeZone: TimeZone = .current
    ) -> String {
        // Hour precision keeps this text stable across a sitting, so prompt
        // caches survive consecutive turns.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let hour = calendar.component(.hour, from: now)
        let hourText = hour == 0 ? "12 AM" : hour < 12 ? "\(hour) AM" : hour == 12 ? "12 PM" : "\(hour - 12) PM"
        var text = "# Now\n\nIt is \(formatter.string(from: now)), around \(hourText) (\(timeZone.identifier))."
        if let gap = previousUserMessageAt.flatMap({ gapDescription(from: $0, to: now) }) {
            text += " The user's previous message was \(gap)."
        } else if knowsHistory, previousUserMessageAt == nil {
            text += " This is the first message of your conversation with the user."
        }
        return text
    }

    /// A coarse description of the time between two messages, or `nil` when
    /// it is under an hour (a conversation in progress).
    static func gapDescription(from earlier: Date, to now: Date) -> String? {
        let seconds = now.timeIntervalSince(earlier)
        guard seconds >= 3600 else { return nil }
        let hours = Int(seconds / 3600)
        if hours < 24 { return hours == 1 ? "about an hour ago" : "about \(hours) hours ago" }
        let days = hours / 24
        if days < 14 { return days == 1 ? "yesterday or about a day ago" : "\(days) days ago" }
        let weeks = days / 7
        if days < 60 { return "\(weeks) weeks ago" }
        return "\(days / 30) months ago"
    }

    static func recapSection(_ lines: [Continuity.Line]) -> String? {
        var used = 0
        var kept: [String] = []
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, HH:mm"
        for line in lines.reversed() {
            var text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if text.count > recapMessageLimit { text = String(text.prefix(recapMessageLimit - 1)) + "…" }
            let entry = "[\(formatter.string(from: line.timestamp))] \(line.fromUser ? "User" : "You"): \(text)"
            guard used + entry.count <= recapCharacterBudget else { break }
            used += entry.count
            kept.append(entry)
        }
        guard !kept.isEmpty else { return nil }
        var section = "# Earlier in this conversation\n\nYou are continuing on a different model session, so here are the most recent messages of your conversation with the user. Continue from them seamlessly; don't mention the switch.\n"
        let available = lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        if kept.count < available { section += "(Older messages are not shown.)\n" }
        return section + kept.reversed().joined(separator: "\n")
    }

    static func memorySection(_ memory: [AgentMemoryNote]) -> String? {
        guard !memory.isEmpty else { return nil }
        var used = 0
        var lines: [String] = []
        for note in memory.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let line = "- [\(note.kind.rawValue)] \(note.content.replacingOccurrences(of: "\n", with: " ")) (id: \(note.id.uuidString))"
            guard used + line.count <= memoryCharacterBudget else { break }
            used += line.count
            lines.append(line)
        }
        let omitted = memory.count - lines.count
        var section = "# Your memory\n\nThese are notes you saved earlier. Treat them as true unless the user corrects them.\n" + lines.joined(separator: "\n")
        if omitted > 0 { section += "\n(\(omitted) older notes are not shown; list them with the memory tool.)" }
        return section
    }

    static func jobsSection(_ jobs: [AgentJob]) -> String? {
        let active = jobs.filter(\.status.isActive)
        guard !active.isEmpty else { return nil }
        let lines = active.prefix(20).map { job in
            "- \(job.kind.rawValue) \"\(job.displayTitle)\" — \(job.status.rawValue) (job_id: \(job.id.uuidString))"
        }
        return "# Jobs running for you\n\nYou are told in this conversation when each one ends.\n" + lines.joined(separator: "\n")
    }

    static func schedulesSection(_ schedules: [ScheduleLine], now: Date) -> String? {
        guard !schedules.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        let lines = schedules.prefix(30).map { line in
            var text = "- \"\(line.name)\" \(line.schedule) — \(line.isEnabled ? "enabled" : "paused") (schedule_id: \(line.id.uuidString))"
            if line.isEnabled, let next = line.nextRun, next > now { text += ", next run \(formatter.string(from: next))" }
            return text
        }
        return "# Your schedules\n\nA subagent runs each schedule and reports back here when it finishes.\n" + lines.joined(separator: "\n")
    }

    static func teammatesSection(_ teammates: [TeammateLine]) -> String? {
        guard !teammates.isEmpty else { return nil }
        let lines = teammates.prefix(30).map { mate in
            var text = "- \(mate.name) (agent_id: \(mate.id.uuidString))"
            if !mate.summary.isEmpty { text += " — \(mate.summary)" }
            if mate.isBusy { text += " [busy]" }
            return text
        }
        return "# Your teammates\n\nOther agents the user created. Ask one for help when the work fits what it is for better than you; it answers in its own thread and its reply comes back here.\n" + lines.joined(separator: "\n")
    }

    static func toolsSection(
        agent: AgentProfile,
        role: Role,
        provider: AgentProvider?,
        hasPairedPhone: Bool,
        hasTeammates: Bool = false
    ) -> String {
        func tool(_ name: String) -> String { "`\(toolName(name, provider: provider))`" }
        var lines = ["# Agent tools", ""]
        lines.append("- \(tool("ide__agent_memory")) — list, add, update or delete your memory notes. Save durable preferences, facts and decisions the user shares, and keep notes current instead of duplicating them.")
        if role == .conversation {
            lines.append("- \(tool("ide__agent_spawn_subagent")) — delegate a self-contained job to a subagent that works in the background in its own thread. Use it for research, long tasks, or work that can run in parallel. You are told here when it finishes.")
            lines.append("- \(tool("ide__agent_run_background_task")) — run a shell command in the background (builds, downloads, long scripts). You are told here when it exits, with its output tail.")
            lines.append("- \(tool("ide__agent_jobs")) — list your subagents and background tasks, read one job's result, or cancel a job.")
            lines.append("- \(tool("ide__agent_schedule")) — list, create, update, delete or run your own schedules. Each run is handled by a subagent that reports back to you.")
            if hasTeammates {
                lines.append("- \(tool("ide__agent_contact")) — list your teammate agents or send one a request. It works on the request as itself, with its own memory and tools, and its reply is delivered here. Write requests that can be answered without follow-up questions. Don't ask a teammate to send the same request back to you.")
            }
        }
        if agent.notifiesPhone && hasPairedPhone {
            lines.append("- \(tool("ide__agent_notify_user")) — send a short message to the user's phone with a push notification. Use it when a result, failure or question needs their attention while they may be away, for example after a scheduled run or a long job. Don't use it for every reply.")
        }
        return lines.joined(separator: "\n")
    }

    static func computerUseSection(agent: AgentProfile, provider: AgentProvider?, model: String?) -> String? {
        guard let driver = agent.computerUse.resolvedDriver(provider: provider, model: model) else { return nil }
        func tool(_ name: String) -> String { "`\(toolName(name, provider: provider))`" }
        switch driver {
        case .native:
            return """
            # Computer use

            You can operate this Mac. Call \(tool("ide__computer_screenshot")) to see a display, then \(tool("ide__computer_action")) \
            to click, double-click, right-click, move, drag, scroll, type text or press keys. Coordinates are pixels in the most \
            recent screenshot of that display. Every action returns a fresh screenshot; check it before the next step. \
            Prefer keyboard shortcuts and opening apps by name over hunting for small targets. Never enter passwords, \
            payment details or other secrets, and stop to ask the user before anything destructive or irreversible. \
            The user can watch the screen live from their phone.
            """
        case .openSource:
            return """
            # Computer use

            You can operate this Mac through an open-source computer-use agent that sees the screen for you. Call \
            \(tool("ide__computer_delegate")) with one concrete GUI task, such as "open Safari and search for flights to \
            Tokyo on May 3". It returns what the agent did and saw. Break large goals into several small tasks. Never ask \
            it to enter passwords, payment details or other secrets, and ask the user before anything destructive or \
            irreversible. The user can watch the screen live from their phone.
            """
        }
    }
}
