import Foundation

/// Time window the briefing timeline is limited to. Presets are resolved
/// against the current date each time they are evaluated, so "Today" keeps
/// meaning today when the app stays open past midnight.
enum BriefingTimeFilter: Hashable {
    case all
    case today
    case yesterday
    case last7Days
    case last30Days
    case thisMonth
    /// Whole calendar days from `start` through `end`, both inclusive.
    case custom(start: Date, end: Date)

    static let presets: [BriefingTimeFilter] = [.all, .today, .yesterday, .last7Days, .last30Days, .thisMonth]

    var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }

    /// Half-open interval `[start, end)` covered by the filter, or nil for `.all`.
    func interval(now: Date = .now, calendar: Calendar = .current) -> DateInterval? {
        let today = calendar.startOfDay(for: now)
        func days(_ value: Int, from date: Date) -> Date {
            calendar.date(byAdding: .day, value: value, to: date) ?? date
        }
        switch self {
        case .all:
            return nil
        case .today:
            return DateInterval(start: today, end: days(1, from: today))
        case .yesterday:
            return DateInterval(start: days(-1, from: today), end: today)
        case .last7Days:
            return DateInterval(start: days(-6, from: today), end: days(1, from: today))
        case .last30Days:
            return DateInterval(start: days(-29, from: today), end: days(1, from: today))
        case .thisMonth:
            let start = calendar.dateInterval(of: .month, for: now)?.start ?? today
            return DateInterval(start: start, end: days(1, from: today))
        case .custom(let start, let end):
            let lower = calendar.startOfDay(for: min(start, end))
            let upper = days(1, from: calendar.startOfDay(for: max(start, end)))
            return DateInterval(start: lower, end: upper)
        }
    }

    func contains(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> Bool {
        guard let interval = interval(now: now, calendar: calendar) else { return true }
        return date >= interval.start && date < interval.end
    }

    var title: String {
        switch self {
        case .all: String(localized: "All time")
        case .today: String(localized: "Today")
        case .yesterday: String(localized: "Yesterday")
        case .last7Days: String(localized: "Last 7 days")
        case .last30Days: String(localized: "Last 30 days")
        case .thisMonth: String(localized: "This month")
        case .custom(let start, let end):
            Self.rangeTitle(start: min(start, end), end: max(start, end))
        }
    }

    var icon: String {
        isCustom ? "calendar.badge.clock" : "calendar"
    }

    private static func rangeTitle(start: Date, end: Date, calendar: Calendar = .current) -> String {
        let sameYear = calendar.isDate(start, equalTo: end, toGranularity: .year)
            && calendar.isDate(start, equalTo: .now, toGranularity: .year)
        let style: Date.FormatStyle = sameYear
            ? .dateTime.month(.abbreviated).day()
            : .dateTime.month(.abbreviated).day().year()
        if calendar.isDate(start, inSameDayAs: end) {
            return start.formatted(style)
        }
        return "\(start.formatted(style)) – \(end.formatted(style))"
    }
}
