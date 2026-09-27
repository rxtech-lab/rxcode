import Foundation

/// Schedules the visual editor can round-trip. Other valid cron syntax
/// stays editable as text without being rewritten by the builder.
public struct CronVisualSchedule: Equatable, Sendable {
    public enum Frequency: String, CaseIterable, Sendable {
        case custom, everyMinute, everyNMinutes, everyHour, everyNHours
        case daily, specificDays, weekly, monthly
    }

    public var frequency: Frequency = .daily
    public var minute = 0
    public var hour = 9
    public var interval = 15
    public var weekdays: Set<Int> = [1, 2, 3, 4, 5]
    public var dayOfMonth = 1

    public init() {}

    public var expression: String? {
        switch frequency {
        case .custom: nil
        case .everyMinute: "* * * * *"
        case .everyNMinutes: "*/\(interval) * * * *"
        case .everyHour: "0 * * * *"
        case .everyNHours: "0 */\(interval) * * *"
        case .daily: "\(minute) \(hour) * * *"
        case .specificDays: "\(minute) \(hour) * * \(Self.weekdayField(weekdays))"
        case .weekly: "\(minute) \(hour) * * \(weekdays.sorted().first ?? 1)"
        case .monthly: "\(minute) \(hour) \(dayOfMonth) * *"
        }
    }

    public static func parse(_ expression: String) -> Self {
        var result = Self()
        result.frequency = .custom
        guard CronExpression.isValid(expression) else { return result }
        let fields = expression.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5, fields[3] == "*" else { return result }
        let (minute, hour, day, weekday) = (fields[0], fields[1], fields[2], fields[4])

        if minute == "*", hour == "*", day == "*", weekday == "*" {
            result.frequency = .everyMinute
        } else if minute.hasPrefix("*/"), hour == "*", day == "*", weekday == "*",
                  let step = Int(minute.dropFirst(2)), (1...59).contains(step) {
            result.frequency = .everyNMinutes
            result.interval = step
        } else if minute == "0", hour == "*", day == "*", weekday == "*" {
            result.frequency = .everyHour
        } else if minute == "0", hour.hasPrefix("*/"), day == "*", weekday == "*",
                  let step = Int(hour.dropFirst(2)), (1...23).contains(step) {
            result.frequency = .everyNHours
            result.interval = step
        } else if let m = Int(minute), let h = Int(hour) {
            result.minute = m
            result.hour = h
            if day == "*", weekday == "*" {
                result.frequency = .daily
            } else if day == "*", let days = parseWeekdays(weekday) {
                result.weekdays = days
                result.frequency = days.count == 1 ? .weekly : .specificDays
            } else if weekday == "*", let number = Int(day) {
                result.frequency = .monthly
                result.dayOfMonth = number
            }
        }
        return result
    }

    private static func parseWeekdays(_ field: String) -> Set<Int>? {
        var days = Set<Int>()
        for item in field.split(separator: ",") {
            let bounds = item.split(separator: "-")
            if bounds.count == 1, let value = Int(bounds[0]), (0...7).contains(value) {
                days.insert(value == 7 ? 0 : value)
            } else if bounds.count == 2, let first = Int(bounds[0]), let last = Int(bounds[1]),
                      (0...6).contains(first), (0...6).contains(last), first <= last {
                days.formUnion(first...last)
            } else {
                return nil
            }
        }
        return days.isEmpty ? nil : days
    }

    private static func weekdayField(_ days: Set<Int>) -> String {
        let sorted = days.sorted()
        guard !sorted.isEmpty else { return "1" }
        if sorted.count > 1, sorted == Array(sorted.first!...sorted.last!) {
            return "\(sorted.first!)-\(sorted.last!)"
        }
        return sorted.map(String.init).joined(separator: ",")
    }
}
