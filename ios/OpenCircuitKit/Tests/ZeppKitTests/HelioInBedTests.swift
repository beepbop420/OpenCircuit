// A strap night's in-bed span (decisions 70a/70b/70g, #311) and the `0x48` stage's inclusive end
// minute (decision 70e, #312). Every record here is synthetic: spans on the hour or half hour, stage
// end minutes written as the record writes them (inclusive, so a stage ending at 01:00 says 00:59).

import XCTest
import OpenCircuitKit
@testable import ZeppKit

/// 2026-09-30T00:00:00Z, every record's local-midnight reference.
private let reference: TimeInterval = 1_790_726_400

/// Minute `m` of a record: §6.6 counts from the reference − 24 h, so 1380 is 23:00 the evening before.
private func at(_ m: Int) -> Date { date(reference - 86_400 + TimeInterval(m) * 60) }

private func span(_ from: Int, _ to: Int) -> DateInterval { DateInterval(start: at(from), end: at(to)) }

private let light: UInt8 = 0x04, deep: UInt8 = 0x05, awake: UInt8 = 0x07, rem: UInt8 = 0x08

/// A 594-byte `0x48` record: the record span `sleep` (0x00A/0x00C), the stage table as WIRE minutes
/// (start, end minute, stage byte), and the four totals (REM, light, deep, awake) at 0x24A–0x250.
private func record48(sleep: (UInt16, UInt16), stages: [(UInt16, UInt16, UInt8)],
                    totals: (UInt16, UInt16, UInt16, UInt16) = (0, 0, 0, 0)) -> [UInt8] {
    var r = [UInt8](repeating: 0, count: ZeppSleepSession.recordLength)
    func put(_ bytes: [UInt8], at offset: Int) { for (i, b) in bytes.enumerated() { r[offset + i] = b } }
    put(le32(UInt32(reference)), at: 0x000)
    put(le32(UInt32(reference)), at: 0x004)
    r[0x008] = 1
    r[0x009] = 1
    put(le16(sleep.0), at: 0x00A)
    put(le16(sleep.1), at: 0x00C)
    r[0x016] = 80
    r[0x054] = UInt8(stages.count)
    for (i, s) in stages.enumerated() { put(le16(s.0) + le16(s.1) + [s.2], at: 0x056 + 5 * i) }
    put(le16(totals.0), at: 0x24A)
    put(le16(totals.1), at: 0x24C)
    put(le16(totals.2), at: 0x24E)
    put(le16(totals.3), at: 0x250)
    return r
}

private func sessions(_ records: [[UInt8]]) throws -> [ZeppSleepSession] {
    let parsed = try ZeppRecordParser.parse(.sleepSession, data: records.flatMap { $0 }, start: date(0))
    guard case .sleepSession(let sessions) = parsed.records else { XCTFail("not a session batch"); return [] }
    return sessions
}

/// 23:00–07:00 in four contiguous stages, as the record writes them.
private let contiguous: [(UInt16, UInt16, UInt8)] = [(1380, 1499, light), (1500, 1559, deep), (1560, 1619, rem), (1620, 1859, light)]

final class HelioInBedSpanTests: XCTestCase {
    private let now = date(reference + 10 * 3600)   // 10:00 the morning after

    private func night(_ bytes: [UInt8]) throws -> HelioSleepSelection.Night {
        try XCTUnwrap(HelioSleepSelection.night(from: try sessions([bytes])[0], now: now))
    }

    private func inBeds(_ segments: [SleepSegment]) -> [DateInterval] {
        segments.filter { $0.stage == .inBed }.map { DateInterval(start: $0.start, end: $0.end) }
    }

    // MARK: 70a/70b

    func testARecordSpanEqualToTheStageSpanGivesOneInBedSegmentOverIt() throws {
        let night = try night(record48(sleep: (1380, 1860), stages: contiguous))
        XCTAssertEqual(inBeds(night.segments), [span(1380, 1860)])
        XCTAssertEqual(night.segments.first, SleepSegment(start: at(1380), end: at(1860), stage: .inBed), "the session's layer comes first")
        XCTAssertEqual(night.window, span(1380, 1860), "the stage span: the window is unchanged")
    }

    func testARecordSpanWiderThanTheStagesWidensTheInBedAndTheWindowToTheUnion() throws {
        let cases: [(String, (UInt16, UInt16), DateInterval)] = [
            ("a 30-minute lead-in", (1350, 1860), span(1350, 1860)),
            ("a trailing minute", (1380, 1861), span(1380, 1861)),
            ("both", (1350, 1861), span(1350, 1861)),
        ]
        for (label, sleep, expected) in cases {
            let night = try night(record48(sleep: sleep, stages: contiguous))
            XCTAssertEqual(inBeds(night.segments), [expected], label)
            XCTAssertEqual(night.window, expected, label)
            let summary = SleepStaging.summary(night.segments)
            XCTAssertEqual(summary.inBed, expected.duration, "\(label): time in bed is the union, not the staged sum")
            XCTAssertEqual(summary.totalAsleep + summary.awake, 480 * 60, "\(label): the staged sum")
        }
    }

    func testAnInvalidRecordSpanFallsBackToTheStageSpan() throws {
        let cases: [(String, (UInt16, UInt16))] = [
            ("start equals end", (1380, 1380)),
            ("start after end", (1860, 1380)),
            ("disjoint from the stages", (600, 900)),
            ("touching the stages only", (1860, 1890)),
            ("a union longer than maxNightLength", (630, 1860)),   // 20 h 30 min
        ]
        for (label, sleep) in cases {
            let night = try night(record48(sleep: sleep, stages: contiguous))
            XCTAssertEqual(inBeds(night.segments), [span(1380, 1860)], label)
            XCTAssertEqual(night.window, span(1380, 1860), label)
        }
        XCTAssertEqual(HelioSleepSelection.inBedSpan(stageSpan: span(1380, 1860), recordStart: at(660), recordEnd: at(1860)),
                       span(660, 1860), "exactly maxNightLength is still valid")
    }

    func testAStitchedNightCarriesOneInBedPerSessionAndItsGapIsNotInBed() throws {
        let first = record48(sleep: (1380, 1530), stages: [(1380, 1529, light)])                     // 23:00–01:30
        let second = record48(sleep: (1560, 1860), stages: [(1590, 1859, deep)])   // in bed 02:00, stages 02:30–07:00
        let nights = HelioSleepSelection.nights(from: try sessions([first, second]), now: now)
        XCTAssertEqual(nights.count, 1)
        XCTAssertEqual(inBeds(nights[0].segments), [span(1380, 1530), span(1560, 1860)], "one per fragment")
        XCTAssertEqual(nights[0].window, span(1380, 1860))
        XCTAssertFalse(nights[0].segments.contains { $0.start < at(1560) && $0.end > at(1530) }, "nothing covers the gap")
        let summary = SleepStaging.summary(nights[0].segments)
        XCTAssertEqual(summary.inBed, (150 + 300) * 60, "the 30-minute gap is not in bed")
        XCTAssertEqual(summary.totalAsleep, (150 + 270) * 60)
    }

    func testTheInBedLayerIsNeverAsleepOrAwakeTime() throws {
        let night = try night(record48(sleep: (1350, 1860), stages: [(1380, 1499, light), (1500, 1529, awake), (1530, 1859, rem)]))
        let summary = SleepStaging.summary(night.segments)
        XCTAssertEqual(summary.totalAsleep, (120 + 330) * 60)
        XCTAssertEqual(summary.awake, 30 * 60, "the awake stage only, never the lead-in")
        XCTAssertEqual(summary.inBed, 510 * 60)
        XCTAssertEqual(summary.efficiency, 450.0 / 510.0, accuracy: 1e-9)
        XCTAssertEqual(SleepStaging.sleepWindow(night.segments)?.onset, at(1380), "onset is the first asleep stage")
    }

    func testAnAwakeOnlyRecordWithAnInBedSpanIsStillNoNight() throws {
        XCTAssertNil(HelioSleepSelection.night(from: try sessions([record48(sleep: (1350, 1440), stages: [(1380, 1439, awake)])])[0], now: now))
    }

    // MARK: 70g

    func testAStrapNapKeepsTheInBedEnvelope() throws {
        let nightRecord = record48(sleep: (1380, 1860), stages: contiguous)
        let napRecord = record48(sleep: (2280, 2340), stages: [(2280, 2309, light), (2310, 2339, deep)])   // 14:00–15:00
        let laterNow = date(reference + 17 * 3600)
        let sleeps = try sessions([nightRecord, napRecord]).compactMap { HelioSleepSelection.night(from: $0, now: laterNow) }
        let split = HelioSleepSelection.naps(from: sleeps, mainSleeps: [], now: laterNow)
        XCTAssertEqual(split.naps.map(\.window), [span(2280, 2340)])
        XCTAssertEqual(split.naps.first?.segments, [
            SleepSegment(start: at(2280), end: at(2340), stage: .inBed),
            SleepSegment(start: at(2280), end: at(2310), stage: .asleepCore),
            SleepSegment(start: at(2310), end: at(2340), stage: .asleepDeep),
        ])
    }
}

final class HelioInclusiveStageEndTests: XCTestCase {
    private let now = date(reference + 10 * 3600)

    private func stages(_ night: HelioSleepSelection.Night) -> [SleepSegment] {
        night.segments.filter { $0.stage != .inBed }
    }

    func testContiguousStagesGiveContiguousSegmentsEndingAtTheRecordsSleepEnd() throws {
        let session = try sessions([record48(sleep: (1380, 1860), stages: contiguous)])[0]
        let segments = stages(try XCTUnwrap(HelioSleepSelection.night(from: session, now: now)))
        XCTAssertEqual(segments.map(\.start), [1380, 1500, 1560, 1620].map(at))
        XCTAssertEqual(segments.map(\.end), [1500, 1560, 1620, 1860].map(at), "no 1-minute gaps")
        XCTAssertEqual(segments.last?.end, session.sleepEnd, "the last stage ends at the record's sleep end")
        XCTAssertEqual(segments.first?.start, session.sleepStart)
        XCTAssertEqual(session.stageGaps, [])
    }

    func testPerStageTotalsEqualTheRecordsOwnTotals() throws {
        // REM 60, light 120 + 230, deep 60, awake 10: 480 minutes, the record's span.
        let table: [(UInt16, UInt16, UInt8)] = [(1380, 1499, light), (1500, 1559, deep), (1560, 1619, rem), (1620, 1629, awake), (1630, 1859, light)]
        let session = try sessions([record48(sleep: (1380, 1860), stages: table, totals: (60, 350, 60, 10))])[0]
        let totals = SleepStaging.stageTotals(try XCTUnwrap(HelioSleepSelection.night(from: session, now: now)).segments)
        XCTAssertEqual(totals[.asleepREM], TimeInterval(session.totalREMMinutes) * 60)
        XCTAssertEqual(totals[.asleepCore], TimeInterval(session.totalLightMinutes) * 60)
        XCTAssertEqual(totals[.asleepDeep], TimeInterval(session.totalDeepMinutes) * 60)
        XCTAssertEqual(totals[.awake], TimeInterval(session.totalAwakeMinutes) * 60)
        XCTAssertEqual(totals.values.reduce(0, +), session.sleepEnd.timeIntervalSince(session.sleepStart))
    }

    func testARealGapOfSeveralMinutesStaysAGap() throws {
        let session = try sessions([record48(sleep: (1380, 1860), stages: [(1380, 1499, light), (1510, 1859, deep)])])[0]
        let segments = stages(try XCTUnwrap(HelioSleepSelection.night(from: session, now: now)))
        XCTAssertEqual(segments, [
            SleepSegment(start: at(1380), end: at(1500), stage: .asleepCore),
            SleepSegment(start: at(1510), end: at(1860), stage: .asleepDeep),
        ])
        XCTAssertEqual(session.stageGaps, [at(1500)...at(1510)])
    }

    func testARecordThatAlreadyEndsAStageAtTheNextStartIsTrimmedNotOverlapped() throws {
        let session = try sessions([record48(sleep: (1380, 1860), stages: [(1380, 1500, light), (1500, 1560, deep), (1560, 1860, rem)])])[0]
        let segments = stages(try XCTUnwrap(HelioSleepSelection.night(from: session, now: now)))
        XCTAssertEqual(segments, [
            SleepSegment(start: at(1380), end: at(1501), stage: .asleepCore),
            SleepSegment(start: at(1501), end: at(1561), stage: .asleepDeep),
            SleepSegment(start: at(1561), end: at(1861), stage: .asleepREM),
        ])
        for (a, b) in zip(segments, segments.dropFirst()) { XCTAssertLessThanOrEqual(a.end, b.start, "no overlap") }
    }

    func testASingleMinuteStageCoversItsMinute() throws {
        let session = try sessions([record48(sleep: (1380, 1442), stages: [(1380, 1439, light), (1440, 1440, awake), (1441, 1441, deep)])])[0]
        XCTAssertEqual(stages(try XCTUnwrap(HelioSleepSelection.night(from: session, now: now))).map(\.duration), [3600, 60, 60])
    }

    // MARK: 70h

    /// What a build before 70b/70e made of the record: the stages, each ending at its end minute,
    /// trimmed the same way, with no `.inBed` layer.
    private func earlierBuild(_ table: [(UInt16, UInt16, UInt8)]) -> [SleepSegment] {
        var out: [SleepSegment] = []
        var previousEnd = Date.distantPast
        for (s, e, kind) in table {
            let start = max(at(Int(s)), previousEnd)
            guard at(Int(e)) > start else { continue }
            out.append(SleepSegment(start: start, end: at(Int(e)),
                                    stage: HelioSleepSelection.stage(for: ZeppSleepSession.StageKind(raw: kind))))
            previousEnd = at(Int(e))
        }
        return out
    }

    func testTheShapesBeforeTheInBedLayerAndTheInclusiveEndIncludeWhatAnEarlierBuildWrote() throws {
        let tables: [(String, [(UInt16, UInt16, UInt8)])] = [
            ("contiguous, inclusive ends", contiguous),
            ("a real gap", [(1380, 1499, light), (1510, 1859, deep)]),
            ("ends already at the next start", [(1380, 1500, light), (1500, 1560, deep), (1560, 1860, rem)]),
        ]
        for (label, table) in tables {
            let night = try XCTUnwrap(HelioSleepSelection.night(from: try sessions([record48(sleep: (1350, 1860), stages: table)])[0], now: now))
            let shapes = HelioSleepSelection.shapesBeforeInBedAndInclusiveEnd(night.segments)
            XCTAssertTrue(shapes.contains(earlierBuild(table)), label)
            XCTAssertTrue(shapes.contains(stages(night)), "\(label): the layer alone")
            XCTAssertFalse(shapes.contains { $0.contains { $0.stage == .inBed } }, label)
        }
        XCTAssertEqual(HelioSleepSelection.shapesBeforeInBedAndInclusiveEnd([]), [])
    }
}
