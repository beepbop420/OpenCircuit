import XCTest
@testable import OpenCircuitKit

// Pins the DEFAULT `RestingHR.dailyValues` output (#298), thin days included. The basal-energy
// scaling (`HealthKitWriter.dailyRestingHR`, sleep omitted) calls it without a coverage floor and must
// keep producing exactly these values. The Apple Health resting-HR write (`flushRestingHR`, with the
// night's sleep segments) now applies `RestingHR.dayCoverage` (Juan, 2026-10-12) and writes nothing
// for a thin day, but every value it does write is this unfloored derivation's for that day; the
// write itself is pinned in the app's `RestingHRHealthWriteTests`. This file uses only the API that
// predates the floor, so it compiles and passes unchanged against the code before it.
final class RestingHRDefaultPathPinTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    /// A UTC midnight.
    private let day0 = Date(timeIntervalSince1970: 1_790_726_400)

    private func run(_ count: Int, every step: TimeInterval, from offset: TimeInterval,
                     bpm: (Int) -> Int) -> [HRSample] {
        (0..<count).map { HRSample(bpm: bpm($0), start: day0.addingTimeInterval(offset + Double($0) * step)) }
    }

    /// Four days: a full ring day, a thin day of five spot reads, a short dense strap burst, and a
    /// day whose night carries three asleep readings below otherwise thin daytime coverage.
    private var corpus: (hr: [HRSample], sleep: [SleepSegment]) {
        let d = 86_400.0
        let full = run(289, every: 150, from: 0) { i in (72...83).contains(i) ? 52 : 70 }
        let thin = run(5, every: 600, from: d + 8 * 3600) { 80 + $0 }
        let burst = run(120, every: 60, from: 2 * d + 7 * 3600) { _ in 76 }
        let night = run(3, every: 600, from: 3 * d + 2 * 3600) { _ in 50 }
        let awake = run(4, every: 600, from: 3 * d + 9 * 3600) { _ in 75 }
        let sleep = [SleepSegment(start: day0.addingTimeInterval(3 * d + 3600),
                                  end: day0.addingTimeInterval(3 * d + 4 * 3600), stage: .asleepCore)]
        return (full + thin + burst + night + awake, sleep)
    }

    private func days(_ n: Int) -> [Date] {
        (0..<n).map { cal.date(byAdding: .day, value: $0, to: day0)! }
    }

    /// The sleep-passed shape `flushRestingHR` derives from. Its written days are the subset of these
    /// above the coverage floor, each with exactly this value.
    func testTheDerivationWithSleepIsPinned() {
        let c = corpus
        let out = RestingHR.dailyValues(hr: c.hr, sleep: c.sleep, calendar: cal)
        XCTAssertEqual(out.map(\.day), days(4))
        XCTAssertEqual(out.map(\.bpm), [52, 80, 76, 50])
    }

    /// `dailyRestingHR`'s call shape: no sleep, so the last day falls to its lowest sustained window.
    func testTheBasalEnergyPathValuesArePinned() {
        let c = corpus
        let out = RestingHR.dailyValues(hr: c.hr, sleep: [], calendar: cal)
        XCTAssertEqual(out.map(\.day), days(4))
        XCTAssertEqual(out.map(\.bpm), [52, 80, 76, 50])
    }
}
