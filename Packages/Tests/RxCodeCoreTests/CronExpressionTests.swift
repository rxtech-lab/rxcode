import Foundation
import Testing
@testable import RxCodeCore

@Suite("Cron expressions")
struct CronExpressionTests {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func next(_ expression: String, after: Date) throws -> Date? {
        try CronExpression(expression).nextDate(after: after, calendar: calendar)
    }

    // MARK: - Parsing

    @Test("Valid expressions parse", arguments: [
        "* * * * *", "*/15 * * * *", "0 9 * * 1-5", "0,30 8-18/2 1,15 jan-jun mon,fri",
        "5/10 * * * *", "0 0 * * 7", "@daily", "@HOURLY", "  0 9 * * *  ",
    ])
    func validExpressions(_ expression: String) {
        #expect(CronExpression.isValid(expression))
    }

    @Test("Invalid expressions are rejected", arguments: [
        "", "* * * *", "* * * * * *", "60 * * * *", "* 24 * * *", "* * 0 * *",
        "* * * 13 *", "* * * * 8", "*/0 * * * *", "5-1 * * * *", "a * * * *", "@reboot", "1,,2 * * * *",
    ])
    func invalidExpressions(_ expression: String) {
        #expect(!CronExpression.isValid(expression))
    }

    @Test("Field count error names the count")
    func fieldCountError() {
        #expect(throws: CronExpression.ParseError.wrongFieldCount(4)) {
            try CronExpression("* * * *")
        }
    }

    // MARK: - Next date

    @Test("Every minute fires at the next whole minute")
    func everyMinute() throws {
        let start = date(2026, 3, 10, 12, 0).addingTimeInterval(30)
        #expect(try next("* * * * *", after: start) == date(2026, 3, 10, 12, 1))
    }

    @Test("Next date is strictly after a matching instant")
    func strictlyAfter() throws {
        #expect(try next("0 9 * * *", after: date(2026, 3, 10, 9, 0)) == date(2026, 3, 11, 9, 0))
    }

    @Test("Steps pick the next slot in the hour")
    func steps() throws {
        #expect(try next("*/15 * * * *", after: date(2026, 3, 10, 12, 16)) == date(2026, 3, 10, 12, 30))
        #expect(try next("*/15 * * * *", after: date(2026, 3, 10, 12, 50)) == date(2026, 3, 10, 13, 0))
    }

    @Test("Weekday ranges skip the weekend")
    func weekdays() throws {
        // 2026-03-13 is a Friday.
        #expect(try next("0 9 * * 1-5", after: date(2026, 3, 13, 10, 0)) == date(2026, 3, 16, 9, 0))
    }

    @Test("Seven means Sunday")
    func sundayAsSeven() throws {
        // 2026-03-15 is a Sunday.
        #expect(try next("0 0 * * 7", after: date(2026, 3, 10)) == date(2026, 3, 15))
    }

    @Test("Restricted day-of-month and day-of-week match either")
    func dayOrWeekday() throws {
        // The 20th is a Friday; the first Monday after the 10th is the 16th.
        #expect(try next("0 0 20 * mon", after: date(2026, 3, 10)) == date(2026, 3, 16))
    }

    @Test("Month rollover crosses the year")
    func yearRollover() throws {
        #expect(try next("@yearly", after: date(2026, 3, 10)) == date(2027, 1, 1))
        #expect(try next("0 0 1 feb *", after: date(2026, 3, 10)) == date(2027, 2, 1))
    }

    @Test("Leap day schedules find the next leap year")
    func leapDay() throws {
        #expect(try next("0 0 29 2 *", after: date(2026, 3, 10)) == date(2028, 2, 29))
    }

    @Test("Impossible dates never fire")
    func impossibleDate() throws {
        #expect(try next("0 0 31 2 *", after: date(2026, 3, 10)) == nil)
    }

    // MARK: - ScheduledTask

    @Test("ScheduledTask decodes records missing optional keys")
    func tolerantDecoding() throws {
        let id = UUID()
        let projectId = UUID()
        let json = #"{"id":"\#(id.uuidString)","projectId":"\#(projectId.uuidString)","cronExpression":"@daily"}"#
        let task = try JSONDecoder().decode(ScheduledTask.self, from: Data(json.utf8))
        #expect(task.id == id)
        #expect(task.projectId == projectId)
        #expect(task.isEnabled)
        #expect(task.name.isEmpty)
        #expect(task.lastRunAt == nil)
        #expect(task.nextRunDate(after: date(2026, 3, 10, 5), calendar: calendar) == date(2026, 3, 11))
    }

    @Test("Every preset parses")
    func presetsParse() {
        for preset in CronPreset.all {
            #expect(CronExpression.isValid(preset.expression))
        }
    }
}
