import Foundation

/// A prompt that runs in a project periodically on a cron schedule. Listed in
/// the sidebar's "Scheduled" route and persisted app-wide.
public struct ScheduledTask: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    /// The project each run's agent works in. `nil` runs it outside any
    /// project, in the general Chat.
    public var projectId: UUID?
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
    /// Whether a notification is sent once a run finishes.
    public var notification: ScheduledTaskNotification
    public var createdAt: Date
    public var updatedAt: Date
    public var lastRunAt: Date?

    public init(
        id: UUID = UUID(),
        projectId: UUID? = nil,
        name: String,
        prompt: String,
        cronExpression: String,
        isEnabled: Bool = true,
        agent: TaskAgentConfig = TaskAgentConfig(),
        notification: ScheduledTaskNotification = .none,
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
        self.notification = notification
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastRunAt = lastRunAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectId, name, prompt, cronExpression, isEnabled, agent, notification, createdAt, updatedAt, lastRunAt
    }

    /// Tolerates missing optional keys so records written by older or newer
    /// builds still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        projectId = try? c.decodeIfPresent(UUID.self, forKey: .projectId)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        prompt = (try? c.decodeIfPresent(String.self, forKey: .prompt)) ?? ""
        cronExpression = (try? c.decodeIfPresent(String.self, forKey: .cronExpression)) ?? ""
        isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? true
        agent = (try? c.decodeIfPresent(TaskAgentConfig.self, forKey: .agent)) ?? TaskAgentConfig()
        notification = (try? c.decodeIfPresent(ScheduledTaskNotification.self, forKey: .notification)) ?? .none
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

    /// The prompt a run sends: `prompt`, plus how to handle notifications.
    /// When RxCode sends the completion report itself, the agent is told not
    /// to send one, so the user doesn't get two emails.
    public var runPrompt: String {
        switch notification {
        case .none:
            return prompt
        case .agentDecides:
            return prompt + """


            When you finish, decide whether the result is worth notifying the user about \
            (for example, something failed, needs their attention, or they asked for a report). \
            If it is, call `ide__send_notification` once with a short subject and a concise \
            markdown summary, or with `briefing_id` if you published a briefing. Otherwise \
            don't send anything.
            """
        case .completionReport:
            return prompt + """


            RxCode emails your final message to the user as this run's completion report, \
            so end with a concise markdown summary of what you did and found. Don't call \
            `ide__send_notification` yourself.
            """
        }
    }

    /// Subject and markdown body of the completion report for a run whose
    /// final assistant message is `finalMessage`.
    public func completionReport(finalMessage: String?, finishedAt: Date = .now) -> (subject: String, body: String) {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = title.isEmpty ? String(localized: "Scheduled task finished") : title
        let summary = finalMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let when = finishedAt.formatted(date: .abbreviated, time: .shortened)
        let body = """
        **\(subject)** finished \(when).

        \(summary.isEmpty ? String(localized: "The run finished without a final message.") : summary)
        """
        return (subject, body)
    }
}

/// What a scheduled task does about notifications once a run finishes.
public enum ScheduledTaskNotification: String, Codable, Sendable, CaseIterable, Hashable {
    /// No notification.
    case none
    /// The agent is asked to call `ide__send_notification` only when the
    /// result deserves the user's attention.
    case agentDecides
    /// RxCode sends the run's final message as a completion report.
    case completionReport
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
