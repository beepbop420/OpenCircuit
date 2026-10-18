// Decision 71 (#278): a long mid-night awakening no longer splits a strap night. Two overnight sleeps
// of one night key are one night whatever the gap between them (71b); the 60-min rule (28f) still
// decides everything else. Every record here is synthetic: spans on the hour or half hour.

import XCTest
import OpenCircuitKit
@testable import ZeppKit

/// 2026-09-30T00:00:00Z, every record's local-midnight reference (UTC).
private let reference: TimeInterval = 1_790_726_400

/// Minute `m` of a record: §6.6 counts from the reference − 24 h, so 1380 is 23:00 the evening before
/// and 1440 is midnight.
private func at(_ m: Int) -> Date { date(reference - 86_400 + TimeInterval(m) * 60) }

private func span(_ from: Int, _ to: Int) -> DateInterval { DateInterval(start: at(from), end: at(to)) }

private let light: UInt8 = 0x04, deep: UInt8 = 0x05, rem: UInt8 = 0x08

/// A 594-byte `0x48` record. `stages` are (start, end) minutes with the end exclusive, written as the
/// record writes it (inclusive, end − 1, decision 70e). The record span (0x00A/0x00C) is `sleep`, or
/// the stage span when nil.
private func sleepRecord(_ stages: [(Int, Int, UInt8)], sleep: (Int, Int)? = nil) -> [UInt8] {
    var r = [UInt8](repeating: 0, count: ZeppSleepSession.recordLength)
    func put(_ bytes: [UInt8], at offset: Int) { for (i, b) in bytes.enumerated() { r[offset + i] = b } }
    put(le32(UInt32(reference)), at: 0x000)
    put(le32(UInt32(reference)), at: 0x004)
    r[0x008] = 1
    r[0x009] = 1
    let recordSpan = sleep ?? (stages.first!.0, stages.last!.1)
    put(le16(UInt16(recordSpan.0)), at: 0x00A)
    put(le16(UInt16(recordSpan.1)), at: 0x00C)
    r[0x016] = 80
    r[0x054] = UInt8(stages.count)
    for (i, s) in stages.enumerated() { put(le16(UInt16(s.0)) + le16(UInt16(s.1 - 1)) + [s.2], at: 0x056 + 5 * i) }
    return r
}

final class HelioMidNightWakeTests: XCTestCase {
    private typealias Selection = HelioSleepSelection

    /// 10:00 the morning after.
    private let morning = date(reference + 10 * 3600)

    private func sleeps(_ records: [[UInt8]], now: Date) throws -> [Selection.Night] {
        let parsed = try ZeppRecordParser.parse(.sleepSession, data: records.flatMap { $0 }, start: date(0))
        guard case .sleepSession(let sessions) = parsed.records else { XCTFail("not a session batch"); return [] }
        let nights = sessions.compactMap { Selection.night(from: $0, now: now) }
        XCTAssertEqual(nights.count, records.count, "every record is a sleep of its own")
        return nights
    }

    private func nights(_ records: [[UInt8]], now: Date) throws -> [Selection.Night] {
        Selection.stitch(try sleeps(records, now: now))
    }

    private func inBeds(_ night: Selection.Night) -> [DateInterval] {
        night.segments.filter { $0.stage == .inBed }.map { DateInterval(start: $0.start, end: $0.end) }
    }

    private func stages(_ night: Selection.Night) -> [DateInterval] {
        night.segments.filter { $0.stage != .inBed }.map { DateInterval(start: $0.start, end: $0.end) }
    }

    // MARK: 71b: joined

    /// #278's shape: asleep 23:00–02:00, up for three hours, asleep again 05:00–07:00. One night over
    /// the union, one `.inBed` per sleep, asleep the sum of both, and the gap is neither asleep nor in bed.
    func testTwoOvernightSleepsOfOneNightThreeHoursApartAreOneNight() throws {
        let first = sleepRecord([(1380, 1440, light), (1440, 1560, deep)])    // 23:00–02:00
        let second = sleepRecord([(1740, 1800, rem), (1800, 1860, light)])    // 05:00–07:00
        let parts = try sleeps([first, second], now: morning)
        XCTAssertTrue(parts.allSatisfy(Selection.isOvernightSleep), "each sleep is an overnight sleep on its own")
        XCTAssertEqual(Selection.nightKey(of: parts[0]), Selection.nightKey(of: parts[1]), "of one night key")

        let joined = try nights([first, second], now: morning)
        XCTAssertEqual(joined.count, 1)
        let night = try XCTUnwrap(joined.first)
        XCTAssertEqual(night.window, span(1380, 1860), "the union")
        XCTAssertEqual(inBeds(night), [span(1380, 1560), span(1740, 1860)])
        XCTAssertEqual(stages(night), [span(1380, 1440), span(1440, 1560), span(1740, 1800), span(1800, 1860)],
                       "the stages as reported")
        let summary = SleepStaging.summary(night.segments)
        XCTAssertEqual(summary.minutes.asleep, 300, "180 + 120")
        XCTAssertEqual(summary.inBed, 300 * 60, "the gap is not in bed")
        let gap = span(1560, 1740)
        XCTAssertFalse(night.segments.contains { $0.start < gap.end && gap.start < $0.end }, "no segment for the gap")
    }

    /// Three fragments: 23:00–23:50, 00:30–03:00 (28f stitches it, 40 min on) and 06:00–07:30 (three
    /// hours on). The first fragment alone ends before midnight, so it is no overnight sleep: the join is
    /// judged on the night accumulated so far, which is. One night, whatever order they arrive in.
    func testThreeFragmentsOfOneNightAreOneNight() throws {
        let a = sleepRecord([(1380, 1430, light)])                         // 23:00–23:50
        let b = sleepRecord([(1470, 1560, deep), (1560, 1620, light)])     // 00:30–03:00
        let c = sleepRecord([(1800, 1890, rem)])                           // 06:00–07:30
        XCTAssertFalse(Selection.isOvernightSleep(try sleeps([a], now: morning)[0]), "the first fragment alone ends before midnight")
        for order in [[a, b, c], [c, a, b], [b, c, a]] {
            let joined = try nights(order, now: morning)
            XCTAssertEqual(joined.count, 1)
            XCTAssertEqual(joined.first?.window, span(1380, 1890))
            XCTAssertEqual(joined.first.map(inBeds), [span(1380, 1430), span(1470, 1620), span(1800, 1890)])
            XCTAssertEqual(joined.first.map { SleepStaging.summary($0.segments).minutes.asleep }, 290)
        }
    }

    /// 71c in the nap split: neither part of a night with a mid-night awakening is a nap, before or
    /// after the night is stored.
    func testAnOvernightSecondSleepIsNeverANap() throws {
        let parts = try sleeps([sleepRecord([(1380, 1560, light)]), sleepRecord([(1740, 1860, light)])], now: morning)
        let unstored = Selection.naps(from: parts, mainSleeps: [], now: morning)
        XCTAssertEqual(unstored.mainSleeps.map(\.window), [span(1380, 1860)])
        XCTAssertTrue(unstored.naps.isEmpty && unstored.unsettled.isEmpty && unstored.nearMainSleep.isEmpty)

        let stored = Selection.naps(from: parts, mainSleeps: [span(1380, 1560)], now: morning)
        XCTAssertEqual(stored.nearMainSleep.map(\.window), [span(1380, 1860)], "the first part as a stored night")
        XCTAssertTrue(stored.naps.isEmpty && stored.mainSleeps.isEmpty)
    }

    // MARK: 71b: not joined

    /// The known gap kept (decision 71): an evening doze that ends before midnight (20:30–22:00, its
    /// midpoint in the night) doesn't end in a wake window, so it is no overnight sleep, and 90 minutes
    /// before the night it stays a sleep of its own.
    func testAnEveningDozeEndingBeforeMidnightIsNotJoinedOverAnHourAway() throws {
        let doze = sleepRecord([(1230, 1320, light)])                      // 20:30–22:00
        let night = sleepRecord([(1410, 1620, deep), (1620, 1860, light)]) // 23:30–07:00
        XCTAssertEqual(Selection.overnightVerdict(try sleeps([doze], now: morning)[0]), .endsOutsideWakeWindow)
        XCTAssertEqual(try nights([doze, night], now: morning).map(\.window), [span(1230, 1320), span(1410, 1860)])
    }

    /// A sleep after the night whose midpoint is at or after 09:00 (07:30–11:00) is no overnight sleep:
    /// not joined, and a nap once settled (60 min after it ended), as before.
    func testALateMorningSleepIsNotJoinedAndIsANapOnceSettled() throws {
        let night = sleepRecord([(1380, 1560, deep), (1560, 1740, light)]) // 23:00–05:00
        let late = sleepRecord([(1890, 2100, light)])                      // 07:30–11:00
        let noon = date(reference + 12.5 * 3600)
        XCTAssertEqual(Selection.overnightVerdict(try sleeps([late], now: noon)[0]), .notOvernight)
        let parts = try sleeps([night, late], now: noon)
        XCTAssertEqual(Selection.stitch(parts).map(\.window), [span(1380, 1740), span(1890, 2100)])
        let split = Selection.naps(from: parts, mainSleeps: [], now: noon)
        XCTAssertEqual(split.mainSleeps.map(\.window), [span(1380, 1740)])
        XCTAssertEqual(split.naps.map(\.window), [span(1890, 2100)])
    }

    /// One night ending in the morning (05:00–07:00) and the next evening's sleep (21:00–00:30): both
    /// overnight sleeps, 19.5 hours end to end, but of different night keys. Never joined.
    func testSleepsOfDifferentNightsAreNeverJoined() throws {
        let earlyMorning = sleepRecord([(1740, 1860, light)])              // 05:00–07:00
        let evening = sleepRecord([(2700, 2910, deep)])                    // 21:00–00:30 the next night
        let nextMorning = date(reference + 34 * 3600)
        let parts = try sleeps([earlyMorning, evening], now: nextMorning)
        XCTAssertTrue(parts.allSatisfy(Selection.isOvernightSleep))
        XCTAssertNotEqual(Selection.nightKey(of: parts[0]), Selection.nightKey(of: parts[1]))
        XCTAssertLessThanOrEqual(parts[1].window.end.timeIntervalSince(parts[0].window.start), Selection.maxNightLength)
        XCTAssertEqual(Selection.stitch(parts).map(\.window), [span(1740, 1860), span(2700, 2910)])
    }

    /// Two overnight sleeps of one key whose joined window would be longer than `maxNightLength`
    /// (15:00–03:00 and 05:00–11:30, 20.5 hours end to end) stay two.
    func testAJoinLongerThanTheLongestNightIsNotMade() throws {
        let long = sleepRecord([(900, 1620, light)])                       // 15:00–03:00
        let late = sleepRecord([(1740, 2130, deep)])                       // 05:00–11:30
        let parts = try sleeps([long, late], now: date(reference + 13 * 3600))
        XCTAssertTrue(parts.allSatisfy(Selection.isOvernightSleep))
        XCTAssertEqual(Selection.nightKey(of: parts[0]), Selection.nightKey(of: parts[1]))
        XCTAssertGreaterThan(parts[1].window.end.timeIntervalSince(parts[0].window.start), Selection.maxNightLength)
        XCTAssertEqual(Selection.stitch(parts).map(\.window), [span(900, 1620), span(1740, 2130)])
    }

    // MARK: 70j still comes first

    /// A re-delivered copy of the first sleep (its stages overlap the first's) is dropped before the
    /// join is considered: counted once. A re-delivery of the second sleep whose record span reaches
    /// back into the first's in-bed span is no duplicate (its stages don't overlap): kept, with one
    /// non-overlapping `.inBed` per fragment.
    func testTheDuplicateCheckStillComesBeforeTheJoin() throws {
        let first = sleepRecord([(1380, 1560, light)])                     // 23:00–02:00
        let firstAgain = sleepRecord([(1390, 1565, light)])                // its stages overlap the first's
        let second = sleepRecord([(1740, 1860, deep)])                     // 05:00–07:00
        let withDuplicate = try nights([first, firstAgain, second], now: morning)
        XCTAssertEqual(withDuplicate.count, 1)
        XCTAssertEqual(withDuplicate.first.map(stages), [span(1380, 1560), span(1740, 1860)])
        XCTAssertEqual(withDuplicate.first.map { SleepStaging.summary($0.segments).minutes.asleep }, 300, "counted once")

        let reachingBack = sleepRecord([(1740, 1860, deep)], sleep: (1500, 1860))   // in bed from 01:00
        let kept = try nights([first, reachingBack], now: morning)
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first.map(stages), [span(1380, 1560), span(1740, 1860)], "not dropped")
        XCTAssertEqual(kept.first.map(inBeds), [span(1380, 1560), span(1560, 1860)])
        XCTAssertEqual(kept.first?.window, span(1380, 1860))
    }

    // MARK: 71i: the awake gap is no sleep window

    /// A joined night's in-bed spans are its fragments; a night that wasn't joined has one, its window;
    /// segments with no `.inBed` (a row stored before decision 70) fall back to the window.
    func testTheInBedSpansOfAJoinedNightLeaveTheGapOut() throws {
        let joined = try XCTUnwrap(try nights([sleepRecord([(1380, 1560, light)]), sleepRecord([(1740, 1860, deep)])], now: morning).first)
        XCTAssertEqual(joined.inBedSpans, [span(1380, 1560), span(1740, 1860)])
        let single = try XCTUnwrap(try nights([sleepRecord([(1380, 1860, light)])], now: morning).first)
        XCTAssertEqual(single.inBedSpans, [single.window])
        let stagesOnly = [SleepSegment(start: at(1380), end: at(1860), stage: .asleepCore)]
        XCTAssertEqual(Selection.inBedSpans(of: stagesOnly, window: span(1380, 1860)), [span(1380, 1860)])
    }

    /// One reading every 5 minutes at `celsius` from `from` to `to` (minutes).
    private func readings(_ from: Int, _ to: Int, celsius: Double) -> [TemperatureSample] {
        stride(from: from, to: to, by: 5).map { TemperatureSample(time: at($0), celsius: celsius) }
    }

    /// The verdict over the fragments: readings in the awake gap are not in it, and the gap's empty
    /// hours don't count against the coverage. Over one span it is `SkinTempBaseline.nightlyVerdict`.
    func testTheSkinTemperatureVerdictIsJudgedOverTheFragments() {
        let fragments = [span(1380, 1560), span(1740, 1860)]                 // 23:00–02:00, 05:00–07:00
        let asleep = readings(1380, 1560, celsius: 34) + readings(1740, 1860, celsius: 34)
        let gap = readings(1565, 1740, celsius: 31)                         // 02:05–04:55
        XCTAssertEqual(HelioSkinTemperatureGate.nightlyVerdict(samples: asleep + gap, inBedSpans: fragments), .published(34),
                       "the gap's readings are not in the mean")
        XCTAssertEqual(HelioSkinTemperatureGate.nightlyVerdict(samples: asleep, inBedSpans: fragments), .published(34),
                       "the gap's empty hours are no missing coverage")
        // Two-hour fragments four hours apart: published over them, withheld over the union (4 of 8 hours).
        let shortAsleep = readings(1380, 1500, celsius: 34) + readings(1740, 1860, celsius: 34)
        XCTAssertEqual(HelioSkinTemperatureGate.nightlyVerdict(samples: shortAsleep, inBedSpans: [span(1380, 1500), span(1740, 1860)]),
                       .published(34))
        XCTAssertEqual(SkinTempBaseline.nightlyVerdict(samples: shortAsleep, in: span(1380, 1860)), .rejectedCoverage(0.5))
        // Too few in the fragments: not measured, whatever the gap holds.
        XCTAssertEqual(HelioSkinTemperatureGate.nightlyVerdict(samples: Array(asleep.prefix(3)) + gap, inBedSpans: fragments), .notMeasured)
        // Half the hours of each fragment empty: withheld.
        let thin = readings(1380, 1440, celsius: 34) + readings(1740, 1800, celsius: 34)
        XCTAssertEqual(HelioSkinTemperatureGate.nightlyVerdict(samples: thin, inBedSpans: fragments), .rejectedCoverage(2.0 / 5))

        let window = span(1380, 1860)
        for samples in [readings(1380, 1860, celsius: 33.5), readings(1380, 1500, celsius: 33.5), Array(readings(1380, 1860, celsius: 33.5).prefix(4))] {
            XCTAssertEqual(HelioSkinTemperatureGate.nightlyVerdict(samples: samples, inBedSpans: [window]),
                           SkinTempBaseline.nightlyVerdict(samples: samples, in: window), "one span: the shared verdict")
        }
    }
}
