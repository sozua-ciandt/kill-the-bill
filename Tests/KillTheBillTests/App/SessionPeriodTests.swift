import XCTest
@testable import KillTheBill

final class SessionPeriodTests: XCTestCase {
    func testCustomPeriodIncludesTheWholeLastDayAndOrdersDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let later = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 14, hour: 18
        )))
        let earlier = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 10, hour: 12
        )))

        let interval = try XCTUnwrap(SessionPeriodPreset.custom.interval(
            customStart: later,
            customEnd: earlier,
            calendar: calendar
        ))

        XCTAssertEqual(
            interval.start,
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 10))
        )
        XCTAssertEqual(
            interval.end,
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 15))
        )
    }

    func testAllHasNoInterval() {
        XCTAssertNil(SessionPeriodPreset.all.interval(
            customStart: Date(),
            customEnd: Date()
        ))
    }
}
