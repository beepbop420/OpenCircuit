import XCTest
@testable import OpenCircuitKit

// The opt-in daytime coverage floor on a day's resting HR (#298). SYNTHETIC readings only: round
// bpm values on the device cadences the floor was set from (strap 60 s minutes, ring 150 s epochs,
// ring 600 s auto-measure spot reads).
final class RestingHRDayCoverageTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    /// A UTC midnight.
    private let day0 = Date(timeIntervalSince1970: 1_790_726_400)
    private let floor = RestingHR.dayCoverage

    /// `count` readings `step` seconds apart from `offset` seconds after `day0`, bpm from `bpm(i)`.
    private func run(_ count: Int, every step: TimeInterval, from offset: TimeInterval,
                     bpm: (Int) -> Int) -> [HRSample] {
        (0..<count).map { HRSample(bpm: bpm($0), start: day0.addingTimeInterval(offset + Double($0) * step)) }
    }

    /// A ring day from midnight to noon on 150 s epochs: 70 bpm, with a 30-minute 52 bpm block at 03:00.
    private var fullRingDay: [HRSample] {
        run(289, every: 150, from: 0) { i in (72...83).contains(i) ? 52 : 70 }
    }

    // MARK: The floor

    func testAHandfulOfAwakeReadingsHasNoValueUnderTheFloor() {
        // Five spot reads ten minutes apart: no sustained window, so the old path returns the lowest.
        let thin = run(5, every: 600, from: 8 * 3600) { 80 + $0 }
        XCTAssertEqual(RestingHR.value(hr: thin), 80)
        XCTAssertNil(RestingHR.value(hr: thin, daytimeCoverage: floor))
        XCTAssertEqual(RestingHR.dailyValues(hr: thin, calendar: cal, daytimeCoverage: floor), [])
    }

    func testScatteredReadingsSpanningHoursStillNeedTheCount() {
        // Six readings an hour apart: the span clears, the count does not.
        let scattered = run(6, every: 3600, from: 6 * 3600) { _ in 78 }
        XCTAssertNil(RestingHR.value(hr: scattered, daytimeCoverage: floor))
    }

    func testADenseShortBurstStillNeedsTheSpan() {
        // Two hours of strap minutes: plenty of readings, too short a span.
        let burst = run(120, every: 60, from: 7 * 3600) { _ in 76 }
        XCTAssertEqual(RestingHR.value(hr: burst), 76)
        XCTAssertNil(RestingHR.value(hr: burst, daytimeCoverage: floor))
    }

    func testTheFloorBoundaries() {
        let n = floor.minReadings
        /// `count` readings from 01:00 whose last one sits exactly `span` after the first.
        func spread(_ count: Int, over span: TimeInterval) -> [HRSample] {
            (0..<count).map { i in
                let t = i == count - 1 ? span : Double(i) * (span / Double(count - 1))
                return HRSample(bpm: 60, start: day0.addingTimeInterval(3600 + t))
            }
        }
        // Exactly the count over exactly the span: a value.
        XCTAssertEqual(RestingHR.value(hr: spread(n, over: floor.minSpan), daytimeCoverage: floor), 60)
        // One reading short.
        XCTAssertNil(RestingHR.value(hr: spread(n - 1, over: floor.minSpan), daytimeCoverage: floor))
        // One second short of the span.
        XCTAssertNil(RestingHR.value(hr: spread(n, over: floor.minSpan - 1), daytimeCoverage: floor))
    }

    func testImplausibleReadingsDoNotCountTowardTheFloor() {
        // Eleven real readings over five hours plus one garbage 4 bpm epoch: still below the count.
        var hr = run(11, every: 1800, from: 3600) { _ in 66 }
        hr.append(HRSample(bpm: 4, start: day0.addingTimeInterval(3600 + 900)))
        XCTAssertNil(RestingHR.value(hr: hr, daytimeCoverage: floor))
    }

    // MARK: What the floor leaves alone

    func testAFullDayOfDaytimeReadingsKeepsItsValue() {
        let day = fullRingDay
        XCTAssertEqual(RestingHR.value(hr: day), 52)
        XCTAssertEqual(RestingHR.value(hr: day, daytimeCoverage: floor), 52)
        XCTAssertEqual(RestingHR.dailyValues(hr: day, calendar: cal, daytimeCoverage: floor),
                       RestingHR.dailyValues(hr: day, calendar: cal))
    }

    func testAFullDayOfAutoMeasureSpotReadsKeepsItsValue() {
        // Ring connected all morning, auto-measure only: one read per 600 s for six hours.
        let spots = run(37, every: 600, from: 6 * 3600) { $0 == 20 ? 54 : 64 }
        XCTAssertEqual(RestingHR.value(hr: spots, daytimeCoverage: floor), RestingHR.value(hr: spots))
        XCTAssertEqual(RestingHR.value(hr: spots, daytimeCoverage: floor), 54)
    }

    func testTheSleepMeanTierIsNotSubjectToTheDaytimeFloor() {
        // Three asleep readings and nothing else: below the daytime floor, but the sleep tier has
        // its own floor (`minSleepSamples`) and answers first.
        let night = run(3, every: 600, from: 2 * 3600) { _ in 50 }
        let sleep = [SleepSegment(start: day0.addingTimeInterval(3600),
                                  end: day0.addingTimeInterval(4 * 3600), stage: .asleepCore)]
        XCTAssertEqual(RestingHR.value(hr: night, sleep: sleep), 50)
        XCTAssertEqual(RestingHR.value(hr: night, sleep: sleep, daytimeCoverage: floor), 50)
    }

    func testABelowSleepFloorNightFallsToTheDaytimeTierAndItsFloor() {
        // Two asleep readings (below `minSleepSamples`) → the daytime tier, which is thin too.
        let night = run(2, every: 600, from: 2 * 3600) { _ in 50 }
        let sleep = [SleepSegment(start: day0.addingTimeInterval(3600),
                                  end: day0.addingTimeInterval(4 * 3600), stage: .asleepCore)]
        XCTAssertEqual(RestingHR.value(hr: night, sleep: sleep), 50)
        XCTAssertNil(RestingHR.value(hr: night, sleep: sleep, daytimeCoverage: floor))
    }

    func testOnlyTheThinDayDropsOutOfTheSeries() {
        let yesterday = fullRingDay
        let today = run(5, every: 600, from: 86_400 + 8 * 3600) { 80 + $0 }
        let all = RestingHR.dailyValues(hr: yesterday + today, calendar: cal)
        let floored = RestingHR.dailyValues(hr: yesterday + today, calendar: cal, daytimeCoverage: floor)
        XCTAssertEqual(all.map(\.bpm), [52, 80])
        XCTAssertEqual(floored, [all[0]])
    }
}
