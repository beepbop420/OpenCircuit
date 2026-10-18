// Decision 74 (#278): the time between a strap night's fragments is awake and in bed where the strap
// was worn (its own stored heart rate), and stays a gap where it wasn't. Every minute, night and heart
// rate here is synthetic: spans on the hour or half hour.

import XCTest
import OpenCircuitKit
@testable import ZeppKit

/// 2026-09-30T00:00:00Z: minute 1440 of every span below is this midnight (UTC).
private let reference: TimeInterval = 1_790_726_400

/// Minute `m` counted from the midnight before `reference`: 1380 is 23:00 the evening before, 1560 is
/// 02:00 and 1770 is 05:30.
private func at(_ m: Int) -> Date { date(reference - 86_400 + TimeInterval(m) * 60) }

private func span(_ from: Int, _ to: Int) -> DateInterval { DateInterval(start: at(from), end: at(to)) }

/// Heart-rate minutes `from ..< to`.
private func worn(_ from: Int, _ to: Int) -> [Date] { (from..<to).map(at) }

final class HelioAwakeFillTests: XCTestCase {
    private typealias Selection = HelioSleepSelection

    /// Sleep A (23:00–02:00, light then deep) and the sleep after the awakening (05:30–07:00), joined
    /// as `stitched` joins them: one `.inBed` per fragment, the gap 02:00–05:30 covered by nothing.
    private let joined: [SleepSegment] = [
        SleepSegment(start: at(1380), end: at(1560), stage: .inBed),
        SleepSegment(start: at(1380), end: at(1500), stage: .asleepCore),
        SleepSegment(start: at(1500), end: at(1530), stage: .awake),
        SleepSegment(start: at(1530), end: at(1560), stage: .asleepDeep),
        SleepSegment(start: at(1770), end: at(1860), stage: .inBed),
        SleepSegment(start: at(1770), end: at(1860), stage: .asleepCore),
    ]
    private var window: DateInterval { span(1380, 1860) }

    private func filled(_ minutes: [Date], _ segments: [SleepSegment]? = nil) -> [SleepSegment] {
        Selection.awakeFilled(segments ?? joined, window: window, heartRateMinutes: minutes)
    }

    private func spans(_ segments: [SleepSegment], _ stage: SleepStage) -> [DateInterval] {
        segments.filter { $0.stage == stage }.map { DateInterval(start: $0.start, end: $0.end) }
    }

    func testTheHoleLimitIsFiveMinutes() {
        XCTAssertEqual(Selection.awakeFillMaxHoleMinutes, 5)
    }

    func testAWornGapIsAwakeAndInBed() {
        let out = filled(worn(1560, 1770))
        XCTAssertEqual(Selection.awakeFillRuns(in: out), [span(1560, 1770)])
        XCTAssertEqual(spans(out, .inBed), [span(1380, 1560), span(1560, 1770), span(1770, 1860)])
        XCTAssertEqual(spans(out, .awake), [span(1500, 1530), span(1560, 1770)])
        XCTAssertEqual(Array(out.prefix(4)), Array(joined.prefix(4)), "the first fragment is untouched")
        XCTAssertEqual(Array(out.suffix(2)), Array(joined.suffix(2)), "the later fragment is untouched")
        let summary = SleepStaging.summary(out)
        XCTAssertEqual(summary.inBed, 480 * 60, "time in bed = the fragments + the run")
        XCTAssertEqual(summary.awake, (30 + 210) * 60)
        XCTAssertEqual(summary.totalAsleep, SleepStaging.summary(joined).totalAsleep, "no sleep is added")
        XCTAssertTrue(out.allSatisfy { $0.provenance == .measured }, "measured, never asserted")
    }

    func testAnUnwornGapStaysAGap() {
        XCTAssertEqual(filled([]), joined)
        XCTAssertEqual(filled([at(1300), at(1900)]), joined, "worn minutes outside the gap fill nothing")
    }

    func testAMixedGapFillsOnlyItsWornMinutes() {
        let out = filled(worn(1560, 1620) + worn(1700, 1770))
        XCTAssertEqual(Selection.awakeFillRuns(in: out), [span(1560, 1620), span(1700, 1770)])
        XCTAssertFalse(out.contains { $0.start < at(1700) && at(1620) < $0.end }, "the unworn hour stays a gap")
        XCTAssertEqual(SleepStaging.summary(out).inBed, (180 + 60 + 70 + 90) * 60)
    }

    func testAFiveMinuteHoleIsBridgedAndASixMinuteHoleIsNot() {
        // Worn 02:00–02:10, then a hole of 5 (or 6) minutes, then worn to 03:00.
        XCTAssertEqual(Selection.awakeFillRuns(in: filled(worn(1560, 1570) + worn(1575, 1620))), [span(1560, 1620)])
        XCTAssertEqual(Selection.awakeFillRuns(in: filled(worn(1560, 1570) + worn(1576, 1620))),
                       [span(1560, 1570), span(1576, 1620)])
    }

    func testANightWithOneFragmentIsReturnedUnchanged() {
        let single = Array(joined.prefix(4))
        XCTAssertEqual(Selection.awakeFilled(single, window: span(1380, 1560), heartRateMinutes: worn(1300, 1900)), single)
        let legacy = joined.filter { $0.stage != .inBed }   // a row stored before decision 70: no `.inBed`
        XCTAssertEqual(Selection.awakeFilled(legacy, window: window, heartRateMinutes: worn(1300, 1900)), legacy)
    }

    func testTheFillNeverReachesBeforeTheFirstFragmentOrAfterTheLast() {
        let out = filled(worn(1200, 2000))
        XCTAssertEqual(Selection.awakeFillRuns(in: out), [span(1560, 1770)])
        XCTAssertEqual(out.map(\.start).min(), at(1380))
        XCTAssertEqual(out.map(\.end).max(), at(1860))
    }

    func testEveryGapOfANightOfThreeFragmentsIsFilled() {
        let three = joined + [SleepSegment(start: at(1900), end: at(1950), stage: .inBed),
                              SleepSegment(start: at(1900), end: at(1950), stage: .asleepREM)]
        let out = Selection.awakeFilled(three, window: span(1380, 1950), heartRateMinutes: worn(1300, 2000))
        XCTAssertEqual(Selection.awakeFillRuns(in: out), [span(1560, 1770), span(1860, 1900)])
        XCTAssertEqual(out.filter { $0.stage == .inBed }.map(\.start), [at(1380), at(1560), at(1770), at(1860), at(1900)],
                       "each run sits before the fragment after it")
    }

    /// A stored night already filled is filled again from the minutes given, never twice: the result
    /// depends only on the fragments and the minutes.
    func testFillingAFilledNightReplacesItsFill() {
        let once = filled(worn(1560, 1770))
        XCTAssertEqual(filled(worn(1560, 1770), once), once)
        XCTAssertEqual(filled(worn(1560, 1620), once), filled(worn(1560, 1620)))
        XCTAssertEqual(filled([], once), joined)
        XCTAssertEqual(Selection.withoutAwakeFill(once), joined)
    }

    func testAFragmentsOwnAwakeStageIsNoRun() {
        XCTAssertEqual(Selection.awakeFillRuns(in: joined), [])
        XCTAssertEqual(Selection.withoutAwakeFill(joined), joined)
        // A fragment whose stages begin with an awake stage: its `.inBed` isn't that stage's span.
        let leadIn = [SleepSegment(start: at(1380), end: at(1440), stage: .inBed),
                      SleepSegment(start: at(1380), end: at(1400), stage: .awake),
                      SleepSegment(start: at(1400), end: at(1440), stage: .asleepCore)]
        XCTAssertEqual(Selection.awakeFillRuns(in: leadIn), [])
    }

    /// Decision 74c: the readers that judge sleep take the fragments' spans, never a run; on a night
    /// with no fill they are its in-bed spans, as decision 71i judged them.
    func testTheSleepSpansAreTheFragmentsNeverTheAwakeRuns() {
        let fragments = [span(1380, 1560), span(1770, 1860)]
        XCTAssertEqual(Selection.sleepSpans(of: joined, window: window), Selection.inBedSpans(of: joined, window: window))
        XCTAssertEqual(Selection.sleepSpans(of: joined, window: window), fragments)
        let out = filled(worn(1560, 1620) + worn(1700, 1770))
        XCTAssertEqual(Selection.sleepSpans(of: out, window: window), fragments)
        XCTAssertEqual(Selection.inBedSpans(of: out, window: window).count, 4, "the runs are in bed")
        let night = Selection.Night(segments: joined, window: window, strapScore: 80)
        let filledNight = night.awakeFilled(heartRateMinutes: worn(1560, 1770))
        XCTAssertEqual(filledNight.sleepSpans, fragments)
        XCTAssertEqual(filledNight.window, night.window)
        XCTAssertEqual(filledNight.strapScore, 80)
        XCTAssertEqual(Selection.sleepSpans(of: [], window: window), [window], "no in-bed layer: the window, as before")
    }
}
