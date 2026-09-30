import XCTest
@testable import RxCode

final class BriefingTimeFilterTests: XCTestCase {
    private let calendar = Calendar.current

    /// Mid-afternoon on a fixed day, so presets resolve deterministically.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 15))!
    }

    private func date(_ day: Int, hour: Int = 12, month: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    func testAllContainsEverything() {
        XCTAssertNil(BriefingTimeFilter.all.interval(now: now, calendar: calendar))
        XCTAssertTrue(BriefingTimeFilter.all.contains(.distantPast, now: now, calendar: calendar))
    }

    func testTodayAndYesterday() {
        XCTAssertTrue(BriefingTimeFilter.today.contains(date(15, hour: 0), now: now, calendar: calendar))
        XCTAssertTrue(BriefingTimeFilter.today.contains(date(15, hour: 23), now: now, calendar: calendar))
        XCTAssertFalse(BriefingTimeFilter.today.contains(date(14, hour: 23), now: now, calendar: calendar))
        XCTAssertTrue(BriefingTimeFilter.yesterday.contains(date(14), now: now, calendar: calendar))
        XCTAssertFalse(BriefingTimeFilter.yesterday.contains(date(15, hour: 0), now: now, calendar: calendar))
    }

    func testLast7DaysIncludesTodayAndSixPriorDays() {
        XCTAssertTrue(BriefingTimeFilter.last7Days.contains(date(9, hour: 0), now: now, calendar: calendar))
        XCTAssertFalse(BriefingTimeFilter.last7Days.contains(date(8, hour: 23), now: now, calendar: calendar))
        XCTAssertTrue(BriefingTimeFilter.last7Days.contains(date(15, hour: 23), now: now, calendar: calendar))
    }

    func testThisMonthStartsOnFirstDay() {
        XCTAssertTrue(BriefingTimeFilter.thisMonth.contains(date(1, hour: 0), now: now, calendar: calendar))
        XCTAssertFalse(BriefingTimeFilter.thisMonth.contains(date(31, month: 8), now: now, calendar: calendar))
    }

    func testCustomRangeIsInclusiveOfWholeDaysAndOrderIndependent() {
        let filter = BriefingTimeFilter.custom(start: date(12, hour: 18), end: date(10, hour: 9))
        XCTAssertTrue(filter.contains(date(10, hour: 0), now: now, calendar: calendar))
        XCTAssertTrue(filter.contains(date(12, hour: 23), now: now, calendar: calendar))
        XCTAssertFalse(filter.contains(date(13, hour: 0), now: now, calendar: calendar))
        XCTAssertFalse(filter.contains(date(9, hour: 23), now: now, calendar: calendar))
    }
}
