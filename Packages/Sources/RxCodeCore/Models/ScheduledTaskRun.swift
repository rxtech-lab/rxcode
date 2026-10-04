import Foundation

/// One run of a `ScheduledTask`: when it ran, how it ended, and the chat
/// thread holding the agent's log. Persisted app-wide so a task's history
/// survives relaunches.
public struct ScheduledTaskRun: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var taskId: UUID
    /// The project the run's thread lives in; `nil` for the general Chat.
    public var projectId: UUID?
    /// The chat thread the run opened. Updated to the resolved id once the
    /// run finishes, since CLI sessions rename `pending-…` keys.
    public var sessionKey: String?
    public var trigger: Trigger
    public var status: Status
    public var startedAt: Date
    public var finishedAt: Date?
    /// The final assistant message, trimmed, so the history shows a result
    /// even when the thread was deleted.
    public var summary: String?
    public var errorMessage: String?

    public enum Status: String, Codable, Sendable, Hashable {
        case running
        case succeeded
        case failed
        /// The app quit while the run was still streaming.
        case interrupted
    }

    public enum Trigger: String, Codable, Sendable, Hashable {
        /// Fired by the cron schedule.
        case schedule
        /// Started by the user with "Run Now".
        case manual
    }

    /// Longest `summary` kept on disk.
    public static let summaryLimit = 2000
    /// Runs kept per task; older ones are dropped.
    public static let historyLimit = 50

    public init(
        id: UUID = UUID(),
        taskId: UUID,
        projectId: UUID? = nil,
        sessionKey: String? = nil,
        trigger: Trigger = .schedule,
        status: Status = .running,
        startedAt: Date = .now,
        finishedAt: Date? = nil,
        summary: String? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.taskId = taskId
        self.projectId = projectId
        self.sessionKey = sessionKey
        self.trigger = trigger
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.summary = summary
        self.errorMessage = errorMessage
    }

    private enum CodingKeys: String, CodingKey {
        case id, taskId, projectId, sessionKey, trigger, status, startedAt, finishedAt, summary, errorMessage
    }

    /// Tolerates missing or unknown values so records written by older or
    /// newer builds still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        taskId = try c.decode(UUID.self, forKey: .taskId)
        projectId = try? c.decodeIfPresent(UUID.self, forKey: .projectId)
        sessionKey = try? c.decodeIfPresent(String.self, forKey: .sessionKey)
        trigger = (try? c.decodeIfPresent(Trigger.self, forKey: .trigger)) ?? .schedule
        status = (try? c.decodeIfPresent(Status.self, forKey: .status)) ?? .interrupted
        startedAt = (try? c.decodeIfPresent(Date.self, forKey: .startedAt)) ?? .distantPast
        finishedAt = try? c.decodeIfPresent(Date.self, forKey: .finishedAt)
        summary = try? c.decodeIfPresent(String.self, forKey: .summary)
        errorMessage = try? c.decodeIfPresent(String.self, forKey: .errorMessage)
    }

    /// How long the run took, or `nil` while it's running.
    public var duration: TimeInterval? {
        finishedAt.map { $0.timeIntervalSince(startedAt) }
    }

    /// `text` trimmed and capped at `summaryLimit`, or `nil` when empty.
    public static func makeSummary(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        guard trimmed.count > summaryLimit else { return trimmed }
        return String(trimmed.prefix(summaryLimit)) + "…"
    }

    /// Runs loaded from disk: any still marked running were cut off by the
    /// app quitting, so they become interrupted.
    public static func restored(_ runs: [ScheduledTaskRun]) -> [ScheduledTaskRun] {
        runs.map { run in
            var run = run
            if run.status == .running { run.status = .interrupted }
            return run
        }
    }

    /// Keeps the newest `limit` runs of each task, newest first.
    public static func pruned(_ runs: [ScheduledTaskRun], limit: Int = historyLimit) -> [ScheduledTaskRun] {
        var counts: [UUID: Int] = [:]
        return runs
            .sorted { $0.startedAt > $1.startedAt }
            .filter { run in
                counts[run.taskId, default: 0] += 1
                return counts[run.taskId]! <= limit
            }
    }
}
