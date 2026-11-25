import Foundation

/// A recurring agent prompt, pet reminder, or project progress check. `dueAt` makes a
/// task one-off; cron recurs. Listed in Scheduled and persisted by the existing store.
public struct ScheduledTask: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    /// The project an agent or progress check works in. Reminders always use `nil`.
    /// An ordinary agent task with `nil` runs in general Chat.
    public var projectId: UUID?
    public var name: String
    /// An agent prompt, reminder text to deliver, or progress-check context, according to kind.
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
    /// A one-off instant replaces cron. Its timezone is retained for display/editing.
    public var dueAt: Date? = nil
    public var timeZoneIdentifier: String? = nil
    /// Direct, factual project observation rather than dispatching an agent to do work.
    public var reportsPetProgress: Bool? = nil
    /// Explicit pet behavior. Missing on legacy records; `reportsPetProgress` retains its meaning.
    public var petScheduleKind: PetScheduleKind? = nil
    public var resolvedPetScheduleKind: PetScheduleKind? {
        petScheduleKind ?? (reportsPetProgress == true ? .progress : nil)
    }
    public var isPetSchedule: Bool { resolvedPetScheduleKind != nil }
    public var isPetProgressCheck: Bool { resolvedPetScheduleKind == .progress }

    /// Claimed before execution and persisted; a restart never silently reruns a claimed check.
    public var claimedAt: Date? = nil
    /// Durable notification outbox; cleared only after the pet acknowledges delivery.
    public var pendingPetReport: String? = nil
    public var petReportDeliveredAt: Date? = nil
    /// The agent that owns this schedule. Its runs are handled by one of the
    /// agent's subagents, which reports back to the agent when it finishes.
    /// `nil` for workspace schedules that run as ordinary chats.
    public var agentId: UUID? = nil

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
        case dueAt, timeZoneIdentifier, reportsPetProgress, petScheduleKind, claimedAt, pendingPetReport, petReportDeliveredAt
        case agentId
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
        dueAt = try? c.decodeIfPresent(Date.self, forKey: .dueAt)
        timeZoneIdentifier = try? c.decodeIfPresent(String.self, forKey: .timeZoneIdentifier)
        reportsPetProgress = try? c.decodeIfPresent(Bool.self, forKey: .reportsPetProgress)
        petScheduleKind = try? c.decodeIfPresent(PetScheduleKind.self, forKey: .petScheduleKind)
        claimedAt = try? c.decodeIfPresent(Date.self, forKey: .claimedAt)
        pendingPetReport = try? c.decodeIfPresent(String.self, forKey: .pendingPetReport)
        petReportDeliveredAt = try? c.decodeIfPresent(Date.self, forKey: .petReportDeliveredAt)
        agentId = try? c.decodeIfPresent(UUID.self, forKey: .agentId)
    }

    /// The parsed schedule, or `nil` when `cronExpression` is invalid.
    public var schedule: CronExpression? {
        try? CronExpression(cronExpression)
    }

    /// Pending one-offs return their due instant even if overdue, for launch/wake catch-up.
    /// Recurring schedules return their next fire after `date`, regardless of `isEnabled`.
    public func nextRunDate(after date: Date = .now, calendar: Calendar = .current) -> Date? {
        if let dueAt { return claimedAt == nil && lastRunAt == nil ? dueAt : nil }
        var calendar = calendar
        if let id = timeZoneIdentifier, let zone = TimeZone(identifier: id) { calendar.timeZone = zone }
        return schedule?.nextDate(after: date, calendar: calendar)
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

/// Pet reminders deliver their saved text; progress checks read an explicitly selected project.
public enum PetScheduleKind: String, Codable, Sendable, Hashable {
    case reminder
    case progress
}
