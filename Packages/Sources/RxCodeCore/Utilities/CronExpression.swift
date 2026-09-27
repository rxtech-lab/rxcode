import Foundation

/// A standard five-field cron expression (`minute hour day-of-month month
/// day-of-week`), evaluated in a calendar's time zone.
///
/// Supports `*`, single values, ranges (`1-5`), lists (`1,15`), steps (`*/15`,
/// `0-30/10`, `5/10`), month and weekday names (`jan`, `mon`), `7` as Sunday,
/// and the `@yearly`, `@annually`, `@monthly`, `@weekly`, `@daily`,
/// `@midnight`, and `@hourly` macros. As in Vixie cron, when both
/// day-of-month and day-of-week are restricted, a day matching either runs.
public struct CronExpression: Sendable, Hashable {
    public enum ParseError: Error, Equatable, LocalizedError {
        case empty
        case wrongFieldCount(Int)
        case unsupportedMacro(String)
        case invalidField(name: String, value: String)

        public var errorDescription: String? {
            switch self {
            case .empty:
                return String(localized: "Enter a cron expression.")
            case .wrongFieldCount(let count):
                return String(localized: "Expected 5 fields (minute hour day month weekday), found \(count).")
            case .unsupportedMacro(let macro):
                return String(localized: "Unsupported macro \(macro).")
            case .invalidField(let name, let value):
                return String(localized: "Invalid \(name) field \"\(value)\".")
            }
        }
    }

    /// The expression as written, trimmed.
    public let source: String
    let minutes: Set<Int>
    let hours: Set<Int>
    let daysOfMonth: Set<Int>
    let months: Set<Int>
    /// 0 = Sunday … 6 = Saturday.
    let daysOfWeek: Set<Int>
    let dayOfMonthRestricted: Bool
    let dayOfWeekRestricted: Bool

    private static let macros: [String: String] = [
        "@yearly": "0 0 1 1 *",
        "@annually": "0 0 1 1 *",
        "@monthly": "0 0 1 * *",
        "@weekly": "0 0 * * 0",
        "@daily": "0 0 * * *",
        "@midnight": "0 0 * * *",
        "@hourly": "0 * * * *",
    ]

    private static let monthNames = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
        "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
    ]

    private static let weekdayNames = [
        "sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6,
    ]

    public init(_ expression: String) throws(ParseError) {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .empty }
        source = trimmed

        var body = trimmed
        if trimmed.hasPrefix("@") {
            guard let expanded = Self.macros[trimmed.lowercased()] else {
                throw .unsupportedMacro(trimmed)
            }
            body = expanded
        }

        let fields = body.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5 else { throw .wrongFieldCount(fields.count) }

        minutes = try Self.parseField(fields[0], name: "minute", range: 0...59)
        hours = try Self.parseField(fields[1], name: "hour", range: 0...23)
        daysOfMonth = try Self.parseField(fields[2], name: "day-of-month", range: 1...31)
        months = try Self.parseField(fields[3], name: "month", range: 1...12, names: Self.monthNames)
        let weekdays = try Self.parseField(fields[4], name: "day-of-week", range: 0...7, names: Self.weekdayNames)
        daysOfWeek = Set(weekdays.map { $0 == 7 ? 0 : $0 })
        dayOfMonthRestricted = daysOfMonth.count < 31
        dayOfWeekRestricted = daysOfWeek.count < 7
    }

    /// Whether `expression` parses.
    public static func isValid(_ expression: String) -> Bool {
        (try? CronExpression(expression)) != nil
    }

    /// The first minute strictly after `date` that the expression matches, or
    /// `nil` when none falls within the next eight years (e.g. `0 0 31 2 *`).
    public func nextDate(after date: Date, calendar: Calendar = .current) -> Date? {
        guard let minuteStart = calendar.dateInterval(of: .minute, for: date)?.start,
              var candidate = calendar.date(byAdding: .minute, value: 1, to: minuteStart),
              let limit = calendar.date(byAdding: .year, value: 8, to: date)
        else { return nil }

        while candidate <= limit {
            let parts = calendar.dateComponents([.month, .day, .weekday, .hour, .minute], from: candidate)
            guard let month = parts.month, let day = parts.day, let weekday = parts.weekday,
                  let hour = parts.hour, let minute = parts.minute
            else { return nil }

            let next: Date?
            if !months.contains(month) {
                next = calendar.dateInterval(of: .month, for: candidate)?.end
            } else if !dayMatches(day: day, weekday: weekday - 1) {
                next = calendar.dateInterval(of: .day, for: candidate)?.end
            } else if !hours.contains(hour) {
                next = calendar.dateInterval(of: .hour, for: candidate)?.end
            } else if !minutes.contains(minute) {
                next = calendar.date(byAdding: .minute, value: 1, to: candidate)
            } else {
                return candidate
            }
            guard let next, next > candidate else { return nil }
            candidate = next
        }
        return nil
    }

    private func dayMatches(day: Int, weekday: Int) -> Bool {
        switch (dayOfMonthRestricted, dayOfWeekRestricted) {
        case (true, true): return daysOfMonth.contains(day) || daysOfWeek.contains(weekday)
        case (true, false): return daysOfMonth.contains(day)
        case (false, true): return daysOfWeek.contains(weekday)
        case (false, false): return true
        }
    }

    private static func parseField(
        _ field: String,
        name: String,
        range: ClosedRange<Int>,
        names: [String: Int] = [:]
    ) throws(ParseError) -> Set<Int> {
        let invalid = ParseError.invalidField(name: name, value: field)
        var values = Set<Int>()

        for part in field.lowercased().split(separator: ",", omittingEmptySubsequences: false) {
            let stepParts = part.split(separator: "/", omittingEmptySubsequences: false)
            guard stepParts.count <= 2 else { throw invalid }

            var step = 1
            if stepParts.count == 2 {
                guard let parsed = Int(stepParts[1]), parsed > 0 else { throw invalid }
                step = parsed
            }

            let base = String(stepParts[0])
            let lower: Int
            let upper: Int
            if base == "*" {
                lower = range.lowerBound
                upper = range.upperBound
            } else if let dash = base.firstIndex(of: "-") {
                guard let start = value(base[..<dash], names: names),
                      let end = value(base[base.index(after: dash)...], names: names),
                      start <= end
                else { throw invalid }
                lower = start
                upper = end
            } else {
                guard let single = value(Substring(base), names: names) else { throw invalid }
                lower = single
                // `5/10` means "from 5, every 10", like `5-max/10`.
                upper = stepParts.count == 2 ? range.upperBound : single
            }

            guard range.contains(lower), range.contains(upper) else { throw invalid }
            values.formUnion(stride(from: lower, through: upper, by: step))
        }
        return values
    }

    private static func value(_ token: Substring, names: [String: Int]) -> Int? {
        Int(token) ?? names[String(token)]
    }
}
