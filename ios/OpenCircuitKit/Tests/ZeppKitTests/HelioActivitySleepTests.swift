// Decision 73 (#278): a later sleep the strap marks only in its per-minute activity data (kind `0x78`)
// joins its night. Every minute and session here is synthetic: spans on the hour or half hour.

import XCTest
import OpenCircuitKit
@testable import ZeppKit

/// 2026-09-30T00:00:00Z: minute 1440 of every span below is this midnight (UTC).
private let reference: TimeInterval = 1_790_726_400

/// Minute `m` counted from the midnight before `reference`: 1380 is 23:00 the evening before, 1440 is
/// midnight and 1800 is 06:00.
private func at(_ m: Int) -> Date { date(reference - 86_400 + TimeInterval(m) * 60) }

private func span(_ from: Int, _ to: Int) -> DateInterval { DateInterval(start: at(from), end: at(to)) }

private let utcZone = TimeZone(secondsFromGMT: 0)!

/// One activity minute of `kind` at minute `m`.
private func minute(_ m: Int, _ kind: UInt8) -> ZeppActivityMinute {
    ZeppActivityMinute(time: at(m), kind: kind, intensity: 8, steps: 0, rawHeartRate: 55, unknown4: 0,
                       sleep: 0, deepSleep: 0, rem: 0)
}

/// Kind-sleep minutes `from ..< to`.
private func asleep(_ from: Int, _ to: Int) -> [ZeppActivityMinute] {
    (from..<to).map { minute($0, ZeppActivityMinute.kindSleep) }
}

/// Minutes `from ..< to` of an ordinary (non-sleep) kind.
private func up(_ from: Int, _ to: Int) -> [ZeppActivityMinute] { (from..<to).map { minute($0, 0x01) } }

/// A session's night as `night(from:now:)` builds it: one `.inBed` over `from ..< to`, asleep all of it,
/// the strap's score 80, recorded in UTC.
private func session(_ from: Int, _ to: Int, score: UInt8 = 80) -> HelioSleepSelection.Night {
    HelioSleepSelection.Night(segments: [SleepSegment(start: at(from), end: at(to), stage: .inBed),
                                         SleepSegment(start: at(from), end: at(to), stage: .asleepCore)],
                              window: span(from, to), strapScore: score, recordedTimeZone: utcZone)
}

final class HelioActivitySleepTests: XCTestCase {
    private typealias Selection = HelioSleepSelection

    /// 10:00 the morning after.
    private let morning = at(1440 + 600)
    /// Sleep A, 23:00–02:00.
    private let sleepA = session(1380, 1560)

    private func blocks(_ minutes: [ZeppActivityMinute], sessions: [Selection.Night] = [],
                        now: Date? = nil) -> [Selection.Night] {
        Selection.activityBlocks(from: minutes, sessions: sessions, now: now ?? morning)
    }

    private func inBeds(_ night: Selection.Night) -> [DateInterval] {
        night.segments.filter { $0.stage == .inBed }.map { DateInterval(start: $0.start, end: $0.end) }
    }

    private func stages(_ night: Selection.Night) -> [DateInterval] {
        night.segments.filter { $0.stage != .inBed }.map { DateInterval(start: $0.start, end: $0.end) }
    }

    // MARK: 73a/73b: blocks

    /// One clean run, 05:30–07:00, then up: one block, one `.inBed` over it, its minutes merged into one
    /// generic-asleep stage, no strap score, and the zone of the session beside it.
    func testOneCleanRunOfSleepMinutesIsOneBlock() throws {
        let found = blocks(asleep(1770, 1860) + up(1860, 1900), sessions: [sleepA])
        XCTAssertEqual(found.count, 1)
        let block = try XCTUnwrap(found.first)
        XCTAssertEqual(block.window, span(1770, 1860))
        XCTAssertEqual(inBeds(block), [span(1770, 1860)])
        XCTAssertEqual(stages(block), [span(1770, 1860)])
        XCTAssertEqual(block.segments.filter { $0.stage != .inBed }.map(\.stage), [Selection.stage(for: .other(0))])
        XCTAssertNil(block.strapScore)
        XCTAssertEqual(block.recordedTimeZone, utcZone)
    }

    /// Five non-sleep minutes inside a run are an awake gap of the block (no segment for them); six end it.
    func testRunsJoinAcrossAFiveMinuteGapAndSplitAtASixMinuteOne() throws {
        let five = blocks(asleep(1740, 1770) + up(1770, 1775) + asleep(1775, 1805) + up(1805, 1840))
        XCTAssertEqual(five.map(\.window), [span(1740, 1805)])
        XCTAssertEqual(five.first.map(stages), [span(1740, 1770), span(1775, 1805)], "the gap stays a gap")
        XCTAssertEqual(five.first.map(inBeds), [span(1740, 1805)])

        let six = blocks(asleep(1740, 1770) + up(1770, 1776) + asleep(1776, 1806) + up(1806, 1840))
        XCTAssertEqual(six.map(\.window), [span(1740, 1770), span(1776, 1806)])

        let missing = blocks(asleep(1740, 1770) + asleep(1776, 1806) + up(1806, 1840))
        XCTAssertEqual(missing.map(\.window), [span(1740, 1770), span(1776, 1806)], "missing minutes count as non-sleep")
    }

    /// A run under 20 minutes (first sleep minute to last + 1) is no block; 20 minutes is.
    func testARunUnderTwentyMinutesIsNoBlock() {
        XCTAssertEqual(blocks(asleep(1740, 1759) + up(1759, 1800)), [])
        XCTAssertEqual(blocks(asleep(1740, 1760) + up(1760, 1800)).map(\.window), [span(1740, 1760)])
    }

    /// Sleep minutes inside a staged session's in-bed span are the session's: only the ones outside it
    /// make a block, and a run never crosses a session.
    func testSleepMinutesInsideASessionsInBedSpanAreNoBlock() {
        XCTAssertEqual(blocks(asleep(1380, 1560) + up(1560, 1620), sessions: [sleepA]), [], "all inside")
        XCTAssertEqual(blocks(asleep(1440, 1620) + up(1620, 1680), sessions: [sleepA]).map(\.window), [span(1560, 1620)],
                       "only the part after the session")
        let short = session(1600, 1603)
        XCTAssertEqual(blocks(asleep(1560, 1660) + up(1660, 1700), sessions: [short]).map(\.window),
                       [span(1560, 1600), span(1603, 1660)], "split at the session it would cross")
    }

    /// Decision 73d: a block whose last sleep minute is less than 20 minutes before the newest minute of
    /// the sync may still be going on; it is judged again by the next sync.
    func testABlockStillInProgressIsHeldUntilTwentyMinutesHavePassed() {
        XCTAssertEqual(blocks(asleep(1770, 1860), sessions: [sleepA]), [], "asleep to the newest minute")
        XCTAssertEqual(blocks(asleep(1770, 1860) + up(1860, 1879), sessions: [sleepA]), [], "19 minutes on")
        XCTAssertEqual(blocks(asleep(1770, 1860) + up(1860, 1880), sessions: [sleepA]).map(\.window), [span(1770, 1860)],
                       "20 minutes on: settled")
    }

    /// No activity minutes (the activity round failed or ran out of time): the nights are the sessions'
    /// own stitch, exactly.
    func testWithoutActivityMinutesTheNightsAreTheSessionsStitchUnchanged() {
        let cases: [[Selection.Night]] = [[], [sleepA], [sleepA, session(1770, 1860)], [session(1200, 1290), sleepA],
                                          [sleepA, session(2100, 2160)]]
        for sessions in cases {
            let found = blocks([], sessions: sessions)
            XCTAssertEqual(found, [])
            let join = Selection.nights(sessions: sessions, activityBlocks: found)
            XCTAssertEqual(join.nights, Selection.stitch(sessions))
            XCTAssertEqual(join.joinedBlocks, 0)
            XCTAssertEqual(join.aloneBlocks, 0)
        }
    }

    // MARK: 73c: joining

    /// #278's shape: the session 23:00–02:00, the strap's sleep minutes 05:30–07:00 (3.5 h later, an
    /// overnight sleep of the same night key, 71b). One night over both, one `.inBed` each, the gap a gap,
    /// the session's score.
    func testABlockHoursAfterTheSessionJoinsItsNight() throws {
        let found = blocks(asleep(1770, 1860) + up(1860, 1900), sessions: [sleepA])
        let join = Selection.nights(sessions: [sleepA], activityBlocks: found)
        XCTAssertEqual(join.nights.count, 1)
        let night = try XCTUnwrap(join.nights.first)
        XCTAssertEqual(night.window, span(1380, 1860))
        XCTAssertEqual(night.inBedSpans, [span(1380, 1560), span(1770, 1860)])
        XCTAssertFalse(night.segments.contains { $0.start < at(1770) && at(1560) < $0.end }, "the gap stays a gap")
        XCTAssertEqual(night.strapScore, 80)
        XCTAssertEqual(night.recordedTimeZone, utcZone)
        XCTAssertEqual(join.joinedBlocks, 1)
        XCTAssertEqual(join.aloneBlocks, 0)
    }

    /// A block longer than the session it joins doesn't take the night's score away: the night keeps
    /// the session's.
    func testAJoinedNightKeepsTheSessionsScoreWhenTheBlockIsLonger() throws {
        let short = session(1380, 1470)
        let join = Selection.nights(sessions: [short], activityBlocks: blocks(asleep(1560, 1800) + up(1800, 1840), sessions: [short]))
        XCTAssertEqual(join.nights.map(\.window), [span(1380, 1800)])
        XCTAssertEqual(join.nights.first?.strapScore, 80)
    }

    /// 28f: a block 30 minutes after the session joins it, whatever it is.
    func testABlockHalfAnHourAfterTheSessionJoinsIt() {
        let join = Selection.nights(sessions: [sleepA], activityBlocks: blocks(asleep(1590, 1650) + up(1650, 1700), sessions: [sleepA]))
        XCTAssertEqual(join.nights.map(\.window), [span(1380, 1650)])
        XCTAssertEqual(join.nights.first?.inBedSpans, [span(1380, 1560), span(1590, 1650)])
        XCTAssertEqual(join.joinedBlocks, 1)
    }

    /// A daytime block (13:00–14:00 after a 23:00–07:00 session) stands alone: dropped, counted.
    func testAStandaloneDaytimeBlockIsDropped() {
        let night = session(1380, 1860)
        let join = Selection.nights(sessions: [night], activityBlocks: blocks(asleep(2220, 2280) + up(2280, 2320),
                                                                                     sessions: [night], now: at(2400)))
        XCTAssertEqual(join.nights, [night])
        XCTAssertEqual(join.joinedBlocks, 0)
        XCTAssertEqual(join.aloneBlocks, 1)
    }

    /// An evening doze block (20:00–21:00, two hours before a 23:00–07:00 session) is no overnight sleep
    /// and too far to stitch: dropped, counted.
    func testAnEveningDozeBlockIsDropped() {
        let night = session(1380, 1860)
        let join = Selection.nights(sessions: [night], activityBlocks: blocks(asleep(1200, 1260) + up(1260, 1300), sessions: [night]))
        XCTAssertEqual(join.nights, [night])
        XCTAssertEqual(join.aloneBlocks, 1)
    }

    /// A night with no session record: its blocks are no night in v1, together or apart.
    func testBlocksOnANightWithNoSessionRecordAreDropped() {
        let minutes = asleep(1380, 1560) + up(1560, 1600) + asleep(1600, 1800) + up(1800, 1840)
        let alone = Selection.nights(sessions: [], activityBlocks: blocks(minutes))
        XCTAssertEqual(alone.nights, [])
        XCTAssertEqual(alone.aloneBlocks, 2)

        let lastNight = session(1380 - 1440, 1860 - 1440)
        let found = blocks(minutes, sessions: [lastNight])
        let join = Selection.nights(sessions: [lastNight], activityBlocks: found)
        XCTAssertEqual(join.nights, [lastNight], "a session of another night is no anchor")
        XCTAssertEqual(join.aloneBlocks, 2)
    }
}
