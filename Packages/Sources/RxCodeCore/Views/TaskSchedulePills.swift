import SwiftUI

/// A card's schedule fields as pills: deadline, size, delay count and
/// reviewer. Shared by the desktop and mobile boards so both read the same.
@MainActor
public struct TaskSchedulePills: View {
    public var deadline: Date?
    /// Whether the card is finished, so a passed deadline stops warning.
    public var isDone: Bool
    public var size: TaskSize?
    public var delays: [TaskDelay]
    public var reviewer: CardAssignee?

    public init(
        deadline: Date?,
        isDone: Bool,
        size: TaskSize?,
        delays: [TaskDelay],
        reviewer: CardAssignee? = nil
    ) {
        self.deadline = deadline
        self.isDone = isDone
        self.size = size
        self.delays = delays
        self.reviewer = reviewer
    }

    public var hasContent: Bool {
        deadline != nil || size != nil || !delays.isEmpty || reviewer != nil
    }

    public var body: some View {
        if let deadline {
            let state = TaskDeadlineState.of(deadline: deadline, isDone: isDone)
            TaskPill(
                text: deadline.formatted(Self.deadlineFormat(for: deadline)),
                icon: state == .overdue ? "calendar.badge.exclamationmark" : "calendar",
                tint: Self.tint(for: state)
            )
            .help(Self.deadlineHelp(deadline: deadline, state: state))
            .accessibilityLabel(Self.deadlineHelp(deadline: deadline, state: state))
        }
        if let size {
            TaskPill(text: size.shortName, icon: "ruler", tint: ClaudeTheme.textSecondary)
                .help(String(localized: "Size: \(size.displayNameText)"))
                .accessibilityLabel(String(localized: "Size: \(size.displayNameText)"))
        }
        if let latest = delays.last {
            let label = delays.count == 1
                ? String(localized: "Delayed")
                : String(localized: "Delayed ×\(delays.count)")
            TaskPill(text: label, icon: "clock.badge.exclamationmark", tint: ClaudeTheme.statusWarning)
                .help(latest.reason)
                .accessibilityLabel(String(localized: "\(label): \(latest.reason)"))
        }
        if let reviewer {
            TaskPill(text: reviewer.displayName, icon: "checkmark.seal", tint: ClaudeTheme.statusSuccess)
                .help(String(localized: "Reviewed by \(reviewer.displayName)"))
                .accessibilityLabel(String(localized: "Reviewed by \(reviewer.displayName)"))
        }
    }

    private static func tint(for state: TaskDeadlineState) -> Color {
        switch state {
        case .overdue: return ClaudeTheme.statusError
        case .dueSoon: return ClaudeTheme.statusWarning
        case .upcoming, .met: return ClaudeTheme.textSecondary
        }
    }

    /// Dates in the current year drop the year to keep the pill short.
    private static func deadlineFormat(for date: Date) -> Date.FormatStyle {
        let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        return sameYear
            ? .dateTime.month(.abbreviated).day()
            : .dateTime.year().month(.abbreviated).day()
    }

    private static func deadlineHelp(deadline: Date, state: TaskDeadlineState) -> String {
        let text = deadline.formatted(date: .abbreviated, time: .shortened)
        switch state {
        case .overdue: return String(localized: "Overdue since \(text)")
        case .dueSoon: return String(localized: "Due soon: \(text)")
        case .upcoming, .met: return String(localized: "Deadline: \(text)")
        }
    }
}
