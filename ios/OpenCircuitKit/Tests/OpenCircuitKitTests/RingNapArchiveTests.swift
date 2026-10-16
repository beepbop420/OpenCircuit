import XCTest
@testable import OpenCircuitKit

/// Decision 69 (#307): the ring's nap pass over the epoch archive. SYNTHETIC-ONLY: every record is
/// built here from a motion byte and a layout tag on a made-up day, anchored by local wall-clock so
/// the overnight rule (`SleepWindow.isOvernightBlock`) sees the hours the test names.
final class RingNapArchiveTests: XCTestCase {

    private enum Kind { case awake, asleep }

    private let step = UInt32(BulkRecord.epochSeconds)
    private let base: UInt32 = 1_000_000

    /// A synthetic midnight: 2030-01-14 local (no DST change near it).
    private var midnight: Date {
        Calendar.current.date(from: DateComponents(year: 2030, month: 1, day: 14))!
    }

    /// One epoch: awake = movement with the activity layout (`[8]=0x12`), asleep = still with the
    /// sleep-vitals layout (`[8]=0`), the shapes `NapDetectionTests` uses. Awake motion is uneven
    /// (one quiet slot per epoch): the detector measures motion above a rolling 30-min low
    /// percentile, so hours of perfectly uniform movement would read as its own idle floor.
    private func rec(_ counter: UInt32, _ kind: Kind) -> BulkRecord {
        var b = [UInt8](repeating: 0, count: 23)
        b[0] = UInt8(counter >> 24); b[1] = UInt8((counter >> 16) & 0xFF)
        b[2] = UInt8((counter >> 8) & 0xFF); b[3] = UInt8(counter & 0xFF)
        let awake: [UInt8] = [0, 25, 30, 20, 25]
        for k in 0..<5 { b[10 + k] = kind == .asleep ? 1 : awake[k] }
        b[8] = kind == .asleep ? 0 : 0x12
        return BulkRecord(b)!
    }

    /// Records for consecutive `(kind, minutes)` runs, the first epoch at `startHour` local (hours
    /// from the synthetic midnight; negative = the evening before), and the `epoch` that puts it there.
    private func timeline(from startHour: Double, _ runs: [(Kind, Int)]) -> (records: [BulkRecord], epoch: Int) {
        let start = midnight.addingTimeInterval(startHour * 3600)
        var out: [BulkRecord] = []
        var c = base
        for (kind, minutes) in runs {
            for _ in 0..<(minutes * 60 / Int(step)) { out.append(rec(c, kind)); c += step }
        }
        return (out, Int(start.timeIntervalSince1970) - Int(base))
    }

    private func hour(_ h: Double) -> Date { midnight.addingTimeInterval(h * 3600) }

    /// The naps start at these hours, give or take an epoch (the detector's edge lands a few
    /// 30-s samples into a block).
    private func assertStarts(_ naps: [NapDetection.Nap], _ hours: [Double], _ message: String = "",
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(naps.count, hours.count, message, file: file, line: line)
        for (nap, h) in zip(naps, hours) {
            XCTAssertEqual(nap.start.timeIntervalSince(hour(h)), 0, accuracy: 150, message, file: file, line: line)
        }
    }

    // MARK: 69a, the production pairing

    /// The exclusion is derived from the SAME daytime slice the nap is judged over, as the ring's
    /// pass does. On master a 75, 90 or 120 min nap became that slice's "main sleep" and excluded
    /// itself; every length is one nap now.
    func testANapIsDetectedWhenItsMainSleepComesFromTheSameDaytimeSlice() {
        for minutes in [30, 75, 90, 120] {
            let (records, epoch) = timeline(from: 13, [(.awake, 30), (.asleep, minutes), (.awake, 30)])
            let input = NapDetection.ringNapInput(archive: records, drained: records)
            let naps = NapDetection.ringNaps(from: input, epoch: epoch)
            XCTAssertEqual(naps.count, 1, "\(minutes) min nap")
            XCTAssertEqual(naps.first?.duration ?? 0, TimeInterval(minutes * 60), accuracy: 3 * 150, "\(minutes) min nap, whole")
        }
    }

    // MARK: 69b, the archive

    /// A nap reaching the phone as an adopted orphan batch and then 1 to 6 epoch drains is judged
    /// whole on the pass that first holds all of it, whatever each drain held.
    func testANapSplitAcrossAnOrphanBatchAndSmallDrainsIsJudgedWholeOverTheArchive() {
        let (all, epoch) = timeline(from: 13, [(.awake, 30), (.asleep, 70), (.awake, 30)])
        let whole = NapDetection.naps(from: all, mainSleep: nil, epoch: epoch)
        XCTAssertEqual(whole.count, 1)

        // Pieces: everything up to 12.5 min into the nap (the adopted orphan batch), then drains of
        // 5, 1, 1, 4, 5, 5, 3 epochs, then the rest.
        var pieces: [[BulkRecord]] = []
        var i = 12 + 5
        pieces.append(Array(all[0..<i]))
        for size in [5, 1, 1, 4, 5, 5, 3] { pieces.append(Array(all[i..<(i + size)])); i += size }
        pieces.append(Array(all[i...]))

        var archive: [BulkRecord] = []
        var slicesAlone = 0
        var last: [NapDetection.Nap] = []
        for piece in pieces {
            archive = EpochArchive.merge(existing: archive, incoming: piece)
            last = NapDetection.ringNaps(from: NapDetection.ringNapInput(archive: archive, drained: piece),
                                         epoch: epoch)
            slicesAlone += NapDetection.ringNaps(from: NapDetection.ringNapInput(archive: piece, drained: piece),
                                                 epoch: epoch).count
        }
        XCTAssertEqual(last, whole, "the pass holding the whole nap judges it whole")
        XCTAssertEqual(slicesAlone, 0, "no drain slice alone held a 15-min nap: judged slice by slice it was lost")
    }

    /// The archive can hold two nights. Neither becomes a nap, nor does a night's fragment: here the
    /// first night ends in a lie-in tail after a short wake, a still block whose own midpoint is
    /// daytime, which only the overnight cluster around it keeps out.
    func testATwoNightArchiveGivesNoNapFromEitherNight() {
        // 22:00 → 08:20 asleep (a wake at 03:00), 08:20 → 08:40 awake, 08:40 → 09:50 asleep, awake
        // all day, 21:30 → 02:50 asleep. 28.8 h.
        let (records, epoch) = timeline(from: -2, [
            (.asleep, 300), (.awake, 20), (.asleep, 300), (.awake, 20), (.asleep, 70),
            (.awake, 700), (.asleep, 320),
        ])
        XCTAssertLessThan(TimeInterval(records.last!.counter - records.first!.counter), EpochArchive.retention)
        let tail = NapDetection.naps(from: records, excluding: [], epoch: epoch)
        assertStarts(tail, [8 + 40 / 60.0],
                     "unguarded, the lie-in tail is a candidate (daytime midpoint): the exclusion is what keeps it out")

        let input = NapDetection.ringNapInput(archive: records, drained: Array(records.suffix(24)))
        XCTAssertFalse(input.headIsRetentionCut)
        XCTAssertEqual(NapDetection.ringNaps(from: input, epoch: epoch), [], "no nap from either night")
    }

    /// The same nights with a real afternoon nap between them: the nap is still found.
    func testANapBetweenTwoArchivedNightsIsStillFound() {
        let (records, epoch) = timeline(from: -2, [
            (.asleep, 600), (.awake, 360), (.asleep, 60), (.awake, 360), (.asleep, 360),
        ])
        let input = NapDetection.ringNapInput(archive: records, drained: Array(records.suffix(24)))
        let naps = NapDetection.ringNaps(from: input, epoch: epoch)
        assertStarts(naps, [14])
    }

    // MARK: The archive's head

    /// When retention cut the archive inside a lie-in, the tail left at the head has a daytime
    /// midpoint and nothing before it to cluster with. It is not judged: it was judged whole while
    /// the night was still in the archive.
    func testALieInTailLeftAtARetentionCutIsNotANap() {
        // Head at 08:40 inside the night's tail: 08:40 → 10:10 asleep, then awake to 14:40 the next day.
        let (records, epoch) = timeline(from: 8 + 40 / 60.0, [(.asleep, 90), (.awake, 1_710)])
        let cut = NapDetection.ringNapInput(archive: records, drained: Array(records.suffix(4)),
                                            retention: 30 * 3600)
        XCTAssertTrue(cut.headIsRetentionCut)
        XCTAssertEqual(NapDetection.ringNaps(from: cut, epoch: epoch), [])

        let uncut = NapDetection.RingNapInput(records: records, headIsRetentionCut: false)
        XCTAssertEqual(NapDetection.ringNaps(from: uncut, epoch: epoch).count, 1,
                       "judged as if the head were the start of the data, the tail is a 'nap'")
    }

    /// A head is a retention cut only when retention pruned near it and this pass did not drain it.
    func testTheHeadIsACutOnlyWhenRetentionPrunedNearItAndThisPassDidNotDrainIt() {
        let (full, _) = timeline(from: 0, [(.awake, 30 * 60 - 30)])
        let (short, _) = timeline(from: 0, [(.awake, 20 * 60)])
        XCTAssertTrue(NapDetection.ringNapInput(archive: full, drained: Array(full.suffix(6))).headIsRetentionCut)
        XCTAssertFalse(NapDetection.ringNapInput(archive: short, drained: Array(short.suffix(6))).headIsRetentionCut,
                       "nothing pruned: the head is where the data starts")
        XCTAssertFalse(NapDetection.ringNapInput(archive: full, drained: full).headIsRetentionCut,
                       "this pass drained the head itself (a backlog): judged as its own slice would be")
    }

    /// A backlog over 30 h: the archive keeps only the newest 30 h, and the drain's own older
    /// records are still judged, so the archive never loses a nap the drain alone would have found.
    func testABacklogOlderThanTheArchiveIsStillJudged() {
        let (drained, epoch) = timeline(from: 9, [(.awake, 240), (.asleep, 60), (.awake, 2_400)])
        let archive = EpochArchive.merge(existing: [], incoming: drained)
        XCTAssertGreaterThan(archive.first!.counter, drained[100].counter, "retention dropped the nap from the archive")
        let input = NapDetection.ringNapInput(archive: archive, drained: drained)
        assertStarts(NapDetection.ringNaps(from: input, epoch: epoch), [13])
    }
}
