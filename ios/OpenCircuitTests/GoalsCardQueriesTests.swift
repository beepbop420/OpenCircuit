import SwiftData
import XCTest
import OpenCircuitKit
@testable import OpenCircuit

/// The Daily Goals card's day-bound query (#297): a day's heart-rate descriptor returns that day
/// only. Synthetic fixtures; fixed zone so the day boundaries are deterministic.
@MainActor
final class GoalsCardQueriesTests: XCTestCase {
    private var containers: [ModelContainer] = []

    override func tearDown() {
        containers.removeAll()
        super.tearDown()
    }

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func day(_ d: Int, _ h: Int = 0, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 5, day: d, hour: h, minute: m))!
    }

    private func store(_ rows: [(Date, Double)]) throws -> ModelContext {
        let container = try ModelContainer(
            for: StoredSample.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(container)
        for (start, value) in rows {
            container.mainContext.insert(StoredSample(
                kindRaw: MetricKind.heartRate.rawValue, start: start,
                end: start.addingTimeInterval(60), value: value))
        }
        try container.mainContext.save()
        return container.mainContext
    }

    func testHeartRateDescriptorExcludesThePreviousAndNextDay() throws {
        let ctx = try store([
            (day(3, 23, 59), 70),   // yesterday
            (day(4, 0, 0), 71),     // first instant of the day
            (day(4, 12, 0), 72),
            (day(4, 23, 59), 73),   // last minute of the day
            (day(5, 0, 0), 74),     // tomorrow
            (day(5, 8, 0), 75),
        ])
        let rows = try ctx.fetch(GoalsCardQueries.heartRate(dayStart: day(4), calendar: cal))
        XCTAssertEqual(rows.map(\.value), [71, 72, 73])
    }

    func testHeartRateDescriptorFollowsTheDayItIsGiven() throws {
        let ctx = try store([(day(4, 9), 70), (day(5, 9), 80)])
        let next = try ctx.fetch(GoalsCardQueries.heartRate(dayStart: day(5), calendar: cal))
        XCTAssertEqual(next.map(\.value), [80])
    }

    func testHeartRateDescriptorDropsNonPositiveValues() throws {
        let ctx = try store([(day(4, 9), 0), (day(4, 10), 65)])
        let rows = try ctx.fetch(GoalsCardQueries.heartRate(dayStart: day(4), calendar: cal))
        XCTAssertEqual(rows.map(\.value), [65])
    }
}
