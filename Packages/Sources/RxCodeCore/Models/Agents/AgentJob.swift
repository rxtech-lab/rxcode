import Foundation

/// Work an agent runs in the background: a subagent thread, a shell command,
/// or a scheduled run. When a job ends, the owning agent is told in its
/// conversation so it can follow up and message the user.
public struct AgentJob: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var agentId: UUID
    public var kind: Kind
    public var title: String
    /// The subagent's instructions, or the shell command line.
    public var prompt: String
    public var status: Status
    /// The subagent's thread. `nil` for shell commands.
    public var sessionKey: String?
    /// The agent conversation that started the job and receives its report.
    public var parentSessionId: String?
    /// The scheduled task that triggered a `.scheduled` job.
    public var scheduleId: UUID?
    /// The teammate agent a `.collaboration` job asked for help. Its reply
    /// thread lives in that agent's conversation project.
    public var targetAgentId: UUID?
    /// The teammate's name when the request was sent, for display after a
    /// rename or delete.
    public var targetAgentName: String?
    /// How many agent-to-agent hops led to this request. Requests from a
    /// collaboration thread add one, so chains between agents stay bounded.
    public var hopCount: Int
    /// Folder a shell command runs in.
    public var workingDirectory: String?
    /// Model override of a subagent. Unassigned inherits the agent's model.
    public var agent: TaskAgentConfig
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    /// The subagent's final message or the command's output tail.
    public var resultSummary: String?
    public var errorMessage: String?
    /// Shell exit status.
    public var exitCode: Int32?
    /// Whether the agent has been told how the job ended.
    public var parentNotified: Bool

    public enum Kind: String, Codable, Sendable, CaseIterable, Hashable {
        /// Another agent thread working on a delegated task.
        case subagent
        /// A shell command running in the background.
        case shell
        /// A subagent dispatched by one of the agent's schedules.
        case scheduled
        /// A request sent to another agent, which answers in its own thread.
        case collaboration

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .subagent
        }

        public var displayName: LocalizedStringResource {
            switch self {
            case .subagent: "Subagent"
            case .shell: "Background Task"
            case .scheduled: "Scheduled Run"
            case .collaboration: "Agent Request"
            }
        }

        public var systemImage: String {
            switch self {
            case .subagent: "person.2.wave.2"
            case .shell: "terminal"
            case .scheduled: "calendar.badge.clock"
            case .collaboration: "bubble.left.and.bubble.right"
            }
        }

        /// Whether the job runs in its own agent thread.
        public var runsSubagent: Bool { self != .shell }
    }

    public enum Status: String, Codable, Sendable, CaseIterable, Hashable {
        case queued
        case running
        case succeeded
        case failed
        case cancelled
        /// The app quit while the job was running.
        case interrupted

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .interrupted
        }

        public var isActive: Bool { self == .queued || self == .running }

        public var displayName: LocalizedStringResource {
            switch self {
            case .queued: "Queued"
            case .running: "Running"
            case .succeeded: "Succeeded"
            case .failed: "Failed"
            case .cancelled: "Cancelled"
            case .interrupted: "Interrupted"
            }
        }

        public var systemImage: String {
            switch self {
            case .queued: "clock"
            case .running: "arrow.triangle.2.circlepath"
            case .succeeded: "checkmark.circle.fill"
            case .failed: "xmark.octagon.fill"
            case .cancelled: "stop.circle"
            case .interrupted: "exclamationmark.triangle.fill"
            }
        }
    }

    /// Thread label stamped on subagent threads so they read as child threads.
    public static let subagentThreadLabel = "agent-subagent"
    /// Thread label of a teammate's reply thread, kept out of its conversation list.
    public static let collaborationThreadLabel = "agent-collaboration"
    /// Longest chain of agent-to-agent requests.
    public static let maxCollaborationHops = 3
    /// Longest `resultSummary` kept.
    public static let summaryLimit = 4000
    /// Finished jobs kept per agent; active jobs are always kept.
    public static let historyLimit = 100

    public init(
        id: UUID = UUID(),
        agentId: UUID,
        kind: Kind,
        title: String,
        prompt: String,
        status: Status = .queued,
        sessionKey: String? = nil,
        parentSessionId: String? = nil,
        scheduleId: UUID? = nil,
        targetAgentId: UUID? = nil,
        targetAgentName: String? = nil,
        hopCount: Int = 0,
        workingDirectory: String? = nil,
        agent: TaskAgentConfig = TaskAgentConfig(),
        createdAt: Date = .now,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        resultSummary: String? = nil,
        errorMessage: String? = nil,
        exitCode: Int32? = nil,
        parentNotified: Bool = false
    ) {
        self.id = id
        self.agentId = agentId
        self.kind = kind
        self.title = title
        self.prompt = prompt
        self.status = status
        self.sessionKey = sessionKey
        self.parentSessionId = parentSessionId
        self.scheduleId = scheduleId
        self.targetAgentId = targetAgentId
        self.targetAgentName = targetAgentName
        self.hopCount = hopCount
        self.workingDirectory = workingDirectory
        self.agent = agent
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.resultSummary = resultSummary
        self.errorMessage = errorMessage
        self.exitCode = exitCode
        self.parentNotified = parentNotified
    }

    private enum CodingKeys: String, CodingKey {
        case id, agentId, kind, title, prompt, status, sessionKey, parentSessionId, scheduleId, workingDirectory, agent
        case targetAgentId, targetAgentName, hopCount
        case createdAt, startedAt, finishedAt, resultSummary, errorMessage, exitCode, parentNotified
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        agentId = try c.decode(UUID.self, forKey: .agentId)
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .subagent
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        prompt = (try? c.decodeIfPresent(String.self, forKey: .prompt)) ?? ""
        status = (try? c.decodeIfPresent(Status.self, forKey: .status)) ?? .interrupted
        sessionKey = try? c.decodeIfPresent(String.self, forKey: .sessionKey)
        parentSessionId = try? c.decodeIfPresent(String.self, forKey: .parentSessionId)
        scheduleId = try? c.decodeIfPresent(UUID.self, forKey: .scheduleId)
        targetAgentId = try? c.decodeIfPresent(UUID.self, forKey: .targetAgentId)
        targetAgentName = try? c.decodeIfPresent(String.self, forKey: .targetAgentName)
        hopCount = (try? c.decodeIfPresent(Int.self, forKey: .hopCount)) ?? 0
        workingDirectory = try? c.decodeIfPresent(String.self, forKey: .workingDirectory)
        agent = (try? c.decodeIfPresent(TaskAgentConfig.self, forKey: .agent)) ?? TaskAgentConfig()
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? .now
        startedAt = try? c.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try? c.decodeIfPresent(Date.self, forKey: .finishedAt)
        resultSummary = try? c.decodeIfPresent(String.self, forKey: .resultSummary)
        errorMessage = try? c.decodeIfPresent(String.self, forKey: .errorMessage)
        exitCode = try? c.decodeIfPresent(Int32.self, forKey: .exitCode)
        parentNotified = (try? c.decodeIfPresent(Bool.self, forKey: .parentNotified)) ?? true
    }

    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return String(prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
    }

    /// Marks the job finished with `status`, trimming the stored result.
    public mutating func finish(_ status: Status, summary: String?, error: String? = nil, at date: Date = .now) {
        self.status = status
        finishedAt = date
        resultSummary = summary.map { Self.trimmed($0) }
        errorMessage = error.map { Self.trimmed($0) }
    }

    /// Text trimmed to `summaryLimit`, keeping the end, where reports and
    /// command output conclude.
    public static func trimmed(_ text: String) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > summaryLimit else { return clean }
        return "…" + String(clean.suffix(summaryLimit))
    }

    /// Jobs restored at launch: anything still active was cut off by the quit.
    public static func restored(_ jobs: [AgentJob], at date: Date = .now) -> [AgentJob] {
        jobs.map { job in
            guard job.status.isActive else { return job }
            var copy = job
            copy.finish(.interrupted, summary: job.resultSummary, error: "RxCode quit while this job was running.", at: date)
            copy.parentNotified = true
            return copy
        }
    }

    /// Keeps every active job and the newest `historyLimit` finished jobs per agent.
    public static func pruned(_ jobs: [AgentJob]) -> [AgentJob] {
        var finishedCounts: [UUID: Int] = [:]
        return jobs.sorted { $0.createdAt > $1.createdAt }.filter { job in
            guard !job.status.isActive else { return true }
            finishedCounts[job.agentId, default: 0] += 1
            return finishedCounts[job.agentId, default: 0] <= historyLimit
        }
    }

    /// The message the owning agent receives when the job ends.
    public var completionReport: String {
        var lines: [String]
        if kind == .collaboration {
            let teammate = targetAgentName ?? "Your teammate"
            lines = [
                "[Teammate reply] \(teammate) answered your request \"\(displayTitle)\" (job_id: \(id.uuidString))",
                "Status: \(status.rawValue)",
            ]
        } else {
            lines = [
                "[Background job finished] \(kind == .shell ? "Background task" : "Subagent") \"\(displayTitle)\" (job_id: \(id.uuidString))",
                "Status: \(status.rawValue)",
            ]
        }
        if let exitCode { lines.append("Exit code: \(exitCode)") }
        if let sessionKey { lines.append("Thread: \(sessionKey)") }
        if let errorMessage, !errorMessage.isEmpty { lines.append("Error: \(errorMessage)") }
        let result = resultSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let label = kind == .collaboration ? "Reply" : "Result"
        lines.append(result.isEmpty ? "\(label): (no output)" : "\(label):\n\(result)")
        lines.append("Decide what to do next. If the user should know, tell them in your reply, and message their phone when it matters.")
        return lines.joined(separator: "\n")
    }
}
