import Foundation

/// A prompt that runs in a project periodically on a cron schedule. Listed in
/// the sidebar's "Scheduled" route and persisted app-wide.
public struct ScheduledTask: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var projectId: UUID
    public var name: String
    /// The prompt sent to the agent on each run.
    public var prompt: String
    /// A five-field cron expression or macro; see `CronExpression`.
    public var cronExpression: String
    /// Paused tasks keep their schedule but don't run.
    public var isEnabled: Bool
    /// The model each run uses. Unassigned means the default task agent at the
    /// time of the run, so changing that default in Settings carries over.
    public var agent: TaskAgentConfig
    public var createdAt: Date
    public var updatedAt: Date
    public var lastRunAt: Date?

    public init(
        id: UUID = UUID(),
        projectId: UUID,
        name: String,
        prompt: String,
        cronExpression: String,
        isEnabled: Bool = true,
        agent: TaskAgentConfig = TaskAgentConfig(),
        createdAt: Date = .now,
        updatedAt: Date = .now,
        lastRunAt: Date? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.name = name
        self.prompt = prompt
        self.cronExpression = cronExpression
        self.isEnabled = isEnabled
        self.agent = agent
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastRunAt = lastRunAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectId, name, prompt, cronExpression, isEnabled, agent, createdAt, updatedAt, lastRunAt
    }

    /// Tolerates missing optional keys so records written by older or newer
    /// builds still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        projectId = try c.decode(UUID.self, forKey: .projectId)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        prompt = (try? c.decodeIfPresent(String.self, forKey: .prompt)) ?? ""
        cronExpression = (try? c.decodeIfPresent(String.self, forKey: .cronExpression)) ?? ""
        isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? true
        agent = (try? c.decodeIfPresent(TaskAgentConfig.self, forKey: .agent)) ?? TaskAgentConfig()
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? .now
        updatedAt = (try? c.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? createdAt
        lastRunAt = try? c.decodeIfPresent(Date.self, forKey: .lastRunAt)
    }

    /// The parsed schedule, or `nil` when `cronExpression` is invalid.
    public var schedule: CronExpression? {
        try? CronExpression(cronExpression)
    }

    /// When the schedule next fires after `date`, regardless of `isEnabled`.
    public func nextRunDate(after date: Date = .now, calendar: Calendar = .current) -> Date? {
        schedule?.nextDate(after: date, calendar: calendar)
    }
}

/// Common schedules offered as shortcuts when editing a scheduled task.
public struct CronPreset: Identifiable, Sendable {
    public let title: LocalizedStringResource
    public let expression: String
    public var id: String { expression }

    public static let all: [CronPreset] = [
        CronPreset(title: "Every 15 minutes", expression: "*/15 * * * *"),
        CronPreset(title: "Every hour", expression: "0 * * * *"),
        CronPreset(title: "Every day at 9:00", expression: "0 9 * * *"),
        CronPreset(title: "Weekdays at 9:00", expression: "0 9 * * 1-5"),
        CronPreset(title: "Every Monday at 9:00", expression: "0 9 * * 1"),
        CronPreset(title: "First day of the month at 9:00", expression: "0 9 1 * *"),
    ]
}
