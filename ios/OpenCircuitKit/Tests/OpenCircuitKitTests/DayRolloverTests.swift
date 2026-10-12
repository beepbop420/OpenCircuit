import XCTest
@testable import OpenCircuitKit

/// The day-key decisions behind views that must follow the calendar day (#297).
final class DayRolloverTests: XCTestCase {

    private func calendar(_ zone: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, in cal: Calendar) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func testKeyIsStartOfLocalDay() {
        let cal = calendar("America/New_York")
        let now = date(2026, 5, 4, 15, 30, in: cal)
        XCTAssertEqual(DayRollover.dayKey(at: now, calendar: cal), date(2026, 5, 4, in: cal))
    }

    func testMidnightCrossingChangesTheDay() {
        let cal = calendar("UTC")
        let key = date(2026, 5, 4, in: cal)
        XCTAssertFalse(DayRollover.didChange(from: key, at: date(2026, 5, 4, 23, 59, in: cal), calendar: cal))
        XCTAssertTrue(DayRollover.didChange(from: key, at: date(2026, 5, 5, 0, 0, in: cal), calendar: cal))
        XCTAssertTrue(DayRollover.didChange(from: key, at: date(2026, 5, 5, 0, 1, in: cal), calendar: cal))
    }

    func testForegroundOnTheSameDayIsNoChange() {
        let cal = calendar("UTC")
        let key = date(2026, 5, 4, in: cal)
        XCTAssertFalse(DayRollover.didChange(from: key, at: date(2026, 5, 4, 0, 0, in: cal), calendar: cal))
        XCTAssertFalse(DayRollover.didChange(from: key, at: date(2026, 5, 4, 12, 0, in: cal), calendar: cal))
    }

    func testForegroundDaysLaterIsAChange() {
        let cal = calendar("UTC")
        let key = date(2026, 5, 4, in: cal)
        XCTAssertTrue(DayRollover.didChange(from: key, at: date(2026, 5, 9, 8, 0, in: cal), calendar: cal))
    }

    func testNextDayStartIsTheFollowingMidnight() {
        let cal = calendar("UTC")
        XCTAssertEqual(DayRollover.nextDayStart(after: date(2026, 5, 4, 13, 0, in: cal), calendar: cal),
                       date(2026, 5, 5, in: cal))
        // Exactly at midnight, the next boundary is a full day away, not now.
        XCTAssertEqual(DayRollover.nextDayStart(after: date(2026, 5, 4, in: cal), calendar: cal),
                       date(2026, 5, 5, in: cal))
    }

    func testSpringForwardDayIsTwentyThreeHours() {
        let cal = calendar("America/New_York")
        let start = date(2026, 3, 8, in: cal)
        let next = DayRollover.nextDayStart(after: start.addingTimeInterval(3600), calendar: cal)
        XCTAssertEqual(next, date(2026, 3, 9, in: cal))
        XCTAssertEqual(next.timeIntervalSince(start), 23 * 3600)
        XCTAssertFalse(DayRollover.didChange(from: start, at: next.addingTimeInterval(-60), calendar: cal))
        XCTAssertTrue(DayRollover.didChange(from: start, at: next, calendar: cal))
    }

    func testFallBackDayIsTwentyFiveHours() {
        let cal = calendar("America/New_York")
        let start = date(2026, 11, 1, in: cal)
        let next = DayRollover.nextDayStart(after: start.addingTimeInterval(3600), calendar: cal)
        XCTAssertEqual(next, date(2026, 11, 2, in: cal))
        XCTAssertEqual(next.timeIntervalSince(start), 25 * 3600)
        // 24 hours in is still the same calendar day on a fall-back day.
        XCTAssertFalse(DayRollover.didChange(from: start, at: start.addingTimeInterval(24 * 3600), calendar: cal))
        XCTAssertTrue(DayRollover.didChange(from: start, at: next, calendar: cal))
    }

    func testTimeZoneChangeMovesTheKey() {
        // The same instant is a different calendar day after the traveller changes zone.
        let ny = calendar("America/New_York")
        let tokyo = calendar("Asia/Tokyo")
        let now = date(2026, 5, 4, 20, 0, in: ny)
        let keyInNewYork = DayRollover.dayKey(at: now, calendar: ny)
        XCTAssertTrue(DayRollover.didChange(from: keyInNewYork, at: now, calendar: tokyo))
        XCTAssertFalse(DayRollover.didChange(from: DayRollover.dayKey(at: now, calendar: tokyo),
                                             at: now, calendar: tokyo))
    }

    func testDayThatStartsAtOneAmEndsAtTheNextDaysStart() {
        // DST skipped midnight on this day, so it starts at 01:00 local. The next day starts at 00:00.
        let cal = calendar("America/Santiago")
        let start = DayRollover.dayKey(at: date(2026, 9, 6, 12, 0, in: cal), calendar: cal)
        XCTAssertEqual(cal.component(.hour, from: start), 1)
        let next = DayRollover.nextDayStart(after: start.addingTimeInterval(3600), calendar: cal)
        XCTAssertEqual(next, date(2026, 9, 7, in: cal))
        XCTAssertEqual(cal.component(.hour, from: next), 0)
        XCTAssertTrue(DayRollover.didChange(from: start, at: next, calendar: cal))
        // The day before ends at the 01:00 start.
        XCTAssertEqual(DayRollover.nextDayStart(after: date(2026, 9, 5, 12, 0, in: cal), calendar: cal), start)
    }
}
