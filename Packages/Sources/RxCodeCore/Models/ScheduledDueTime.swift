import Foundation

public enum ScheduledDueTime {
    public enum Invalid: Error { case timeZone, time }

    /// Relative durations become instants; local wall times retain their IANA timezone.
    public static func resolve(now: Date, afterSeconds: Double?, dueAt: String?, localTime: String?, timeZoneID: String) throws -> Date {
        guard let zone = TimeZone(identifier: timeZoneID) else { throw Invalid.timeZone }
        guard [afterSeconds != nil, dueAt != nil, localTime != nil].filter({ $0 }).count == 1 else { throw Invalid.time }
        let result: Date
        if let afterSeconds {
            guard afterSeconds.isFinite, afterSeconds > 0, afterSeconds <= 366 * 86_400 else { throw Invalid.time }
            result = now.addingTimeInterval(afterSeconds)
        } else if let dueAt {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fractional = formatter.date(from: dueAt)
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = fractional ?? formatter.date(from: dueAt) else { throw Invalid.time }
            result = date
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = zone
            formatter.isLenient = false
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            guard let localTime, let date = formatter.date(from: localTime), formatter.string(from: date) == localTime else { throw Invalid.time }
            result = date
        }
        guard result > now else { throw Invalid.time }
        return result
    }
}
