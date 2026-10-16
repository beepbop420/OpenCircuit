import SwiftData
import XCTest
import OpenCircuitKit
@testable import OpenCircuit

// Decision 69 (#307): the ring's naps judged over the epoch archive, one stored row per nap, and a
// nap whose window moves after its Health write rewritten (write first, then clean). SYNTHETIC-ONLY:
// every record and window is made up here on a synthetic day.

@MainActor
final class RingNapArchiveStoreTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private let ownership = OwnershipOverride()

    override func setUp() {
        super.setUp()
        ownership.install(DeviceOwnershipLog())
    }

    override func tearDown() {
        ownership.restore()
        containers.removeAll()
        super.tearDown()
    }

    private func makeStore() throws -> LocalStore {
        let container = try ModelContainer(
            for: StoredSample.self, StoredCursor.self, StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
            StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(container)
        return LocalStore(container.mainContext)
    }

    // MARK: Synthetic records

    private enum Kind { case awake, asleep }

    /// A synthetic midnight: 2030-01-14 local.
    private let midnight = Calendar.current.date(from: DateComponents(year: 2030, month: 1, day: 14))!
    private func hour(_ h: Double) -> Date { midnight.addingTimeInterval(h * 3600) }

    /// One epoch at `date`: awake = uneven movement, activity layout; asleep = still, sleep-vitals layout.
    private func rec(at date: Date, _ kind: Kind) -> BulkRecord {
        let counter = UInt32(Int(date.timeIntervalSince1970) - Command.syncEpoch)
        var b = [UInt8](repeating: 0, count: 23)
        b[0] = UInt8(counter >> 24); b[1] = UInt8((counter >> 16) & 0xFF)
        b[2] = UInt8((counter >> 8) & 0xFF); b[3] = UInt8(counter & 0xFF)
        let awake: [UInt8] = [0, 25, 30, 20, 25]
        for k in 0..<5 { b[10 + k] = kind == .asleep ? 1 : awake[k] }
        b[8] = kind == .asleep ? 0 : 0x12
        return BulkRecord(b)!
    }

    /// Consecutive `(kind, minutes)` runs from `startHour` (hours from the synthetic midnight).
    private func timeline(from startHour: Double, _ runs: [(Kind, Int)]) -> [BulkRecord] {
        var out: [BulkRecord] = []
        var t = hour(startHour)
        for (kind, minutes) in runs {
            for _ in 0..<(minutes * 60 / BulkRecord.epochSeconds) {
                out.append(rec(at: t, kind)); t.addTimeInterval(TimeInterval(BulkRecord.epochSeconds))
            }
        }
        return out
    }

    private func rows(_ store: LocalStore) throws -> [StoredNap] {
        try store.context.fetch(FetchDescriptor<StoredNap>(sortBy: [SortDescriptor(\.start)]))
    }

    private func save(_ store: LocalStore, _ from: Double, _ to: Double,
                      family: DeviceOwnershipLog.Family = .ringConn) throws {
        try store.saveNap(start: hour(from), end: hour(to), asleepMin: Int((to - from) * 60),
                          isLongNap: false, family: family)
    }

    /// The HealthKit effects `mirrorNap` performs, in order.
    private enum Effect: Equatable {
        case write(DateInterval)
        case clean(DateInterval, kept: [String], spared: Range<Date>)
    }

    /// Mirror every pending nap the way `flushNaps` does, recording the effects instead of HealthKit.
    @discardableResult
    private func flush(_ store: LocalStore, failWrite: Bool = false) async throws -> [Effect] {
        var effects: [Effect] = []
        var n = 0
        for nap in try store.pendingNaps() {
            let segments = [SleepSegment(start: nap.effectiveStart, end: nap.effectiveEnd, stage: .inBed)]
            try await HealthKitWriter.mirrorNap(nap, segments: segments, store: store,
                write: { segs, _ in
                    if failWrite { throw CocoaError(.featureUnsupported) }
                    effects.append(.write(DateInterval(start: segs[0].start, end: segs[0].end)))
                    n += 1
                    return ["uuid-\(n)"]
                },
                deleteStale: { stale, kept, spared in effects.append(.clean(stale, kept: kept, spared: spared)) })
        }
        return effects
    }

    private func span(_ from: Double, _ to: Double) -> DateInterval { DateInterval(start: hour(from), end: hour(to)) }

    private func assertWindow(_ row: StoredNap?, _ from: Double, _ to: Double, _ message: String = "",
                              file: StaticString = #filePath, line: UInt = #line) {
        guard let row else { return XCTFail("no row " + message, file: file, line: line) }
        XCTAssertEqual(row.start.timeIntervalSince(hour(from)), 0, accuracy: 150, message, file: file, line: line)
        XCTAssertEqual(row.end.timeIntervalSince(hour(to)), 0, accuracy: 150, message, file: file, line: line)
    }

    // MARK: 69b — the archive

    /// The nap reaches the phone as an adopted orphan batch (12.5 min of it) and then drains of 1 to
    /// 6 epochs. Each pass judges the archive, so it is recorded once, and whole.
    func testANapDeliveredAsAnOrphanBatchAndSmallDrainsIsRecordedOnceAndWhole() throws {
        let store = try makeStore()
        let all = timeline(from: 13, [(.awake, 30), (.asleep, 70), (.awake, 70)])
        var pieces: [[BulkRecord]] = [Array(all[0..<17])]
        var i = 17
        for size in [5, 1, 6, 1, 4, 5, 2] { pieces.append(Array(all[i..<(i + size)])); i += size }
        pieces.append(Array(all[i...]))

        var archive: [BulkRecord] = []
        for piece in pieces {
            archive = EpochArchive.merge(existing: archive, incoming: piece)
            RingSession.persistNaps(archive: archive, drained: piece, temperatures: [], store: store)
            XCTAssertLessThanOrEqual(try rows(store).count, 1, "never two rows for one nap")
        }
        let stored = try rows(store)
        XCTAssertEqual(stored.count, 1)
        assertWindow(stored.first, 13.5, 13.5 + 70 / 60.0, "whole")
    }

    /// The archive can hold two nights (here with a lie-in tail after a short wake). Neither, nor the
    /// tail, is stored as a nap, with no stored night to fall back on.
    func testATwoNightArchiveStoresNoNap() throws {
        let store = try makeStore()
        let archive = timeline(from: -2, [
            (.asleep, 300), (.awake, 20), (.asleep, 300), (.awake, 20), (.asleep, 70),
            (.awake, 700), (.asleep, 320),
        ])
        RingSession.persistNaps(archive: archive, drained: Array(archive.suffix(24)), temperatures: [], store: store)
        XCTAssertEqual(try rows(store).count, 0)
    }

    /// A morning still block more than an hour after the night's last sleep is its own cluster with
    /// a daytime midpoint, so the detector offers it. A stored night whose in-bed window covers it
    /// (the staging absorbed it) keeps it out.
    func testAStoredNightsMorningTailIsNotANap() throws {
        let archive = timeline(from: -1, [(.asleep, 480), (.awake, 100), (.asleep, 60), (.awake, 240)])
        let tail = (start: 8 + 40 / 60.0, end: 9 + 40 / 60.0)

        let bare = try makeStore()
        RingSession.persistNaps(archive: archive, drained: archive, temperatures: [], store: bare)
        assertWindow(try rows(bare).first, tail.start, tail.end, "without the stored night the tail is a candidate")

        let store = try makeStore()
        let night = [SleepSegment(start: hour(-1), end: hour(tail.end), stage: .asleepCore)]
        var extras = LocalStore.SleepNightExtras()
        extras.hypnogram = night
        _ = try store.saveSleepSummary(SleepStaging.summary(night),
                                       night: SleepNightKey.night(inBedStart: hour(-1), inBedEnd: hour(tail.end)),
                                       inBedStart: hour(-1), inBedEnd: hour(tail.end),
                                       sleepOnset: hour(-1), sleepWake: hour(tail.end), extras: extras)
        RingSession.persistNaps(archive: archive, drained: archive, temperatures: [], store: store)
        XCTAssertEqual(try rows(store).count, 0)
    }

    /// Wall time of one nap pass over a full retained archive (30 h, two nights and a nap), on the
    /// main actor as `RingSession` runs it. Reported, with a loose ceiling.
    func testOneNapPassOverAFullArchiveCost() throws {
        let store = try makeStore()
        let archive = timeline(from: -2, [
            (.asleep, 540), (.awake, 300), (.asleep, 75), (.awake, 465), (.asleep, 420), (.awake, 3),
        ])
        XCTAssertGreaterThan(archive.count, 700)
        let clock = ContinuousClock()
        var times: [Duration] = []
        for _ in 0..<5 {
            times.append(clock.measure {
                RingSession.persistNaps(archive: archive, drained: Array(archive.suffix(24)), temperatures: [], store: store)
            })
        }
        print("[ring-naps] one nap pass over \(archive.count) epochs: \(times.map { "\($0)" }.joined(separator: ", "))")
        XCTAssertEqual(try rows(store).count, 1)
        XCTAssertLessThan(times.max()!, .seconds(5))
    }

    // MARK: 69c — one row per nap, rewritten when it moves

    /// A nap stored short and written to Health, then re-detected longer: the row is re-armed, and
    /// the flush writes the new window first, then cleans what the first write covered.
    func testGrowthAfterAHealthWriteReArmsAndTheFlushWritesThenCleans() async throws {
        let store = try makeStore()
        try save(store, 13, 13 + 40 / 60.0)
        let first = try await flush(store)
        XCTAssertEqual(first, [.write(span(13, 13 + 40 / 60.0))], "first write: nothing to clean")

        try save(store, 13, 14.25)
        XCTAssertEqual(try store.pendingNaps().map(\.start), [hour(13)], "re-armed")
        let effects = try await flush(store)
        XCTAssertEqual(effects, [
            .write(span(13, 14.25)),
            .clean(span(13, 14.25), kept: ["uuid-1"], spared: hour(13) ..< hour(13)),
        ], "write first, then clean the old span, sparing only the new samples")
        let row = try XCTUnwrap(try rows(store).first)
        XCTAssertTrue(row.healthWritten)
        XCTAssertEqual(row.healthWrittenStart, hour(13))
        XCTAssertEqual(row.healthWrittenEnd, hour(14.25))
        let again = try await flush(store)
        XCTAssertEqual(again, [], "written once")
    }

    /// A failed write cleans nothing and leaves the nap pending.
    func testAFailedRewriteCleansNothing() async throws {
        let store = try makeStore()
        try save(store, 13, 13.5)
        try await flush(store)
        try save(store, 13, 14)
        do { try await flush(store, failWrite: true); XCTFail("the write threw") } catch {}
        XCTAssertEqual(try store.pendingNaps().count, 1)
        XCTAssertEqual(try rows(store).first?.healthWrittenEnd, hour(13.5), "the old span is still what Health holds")
    }

    /// A re-detection with a different start replaces the fragment row it overlaps, and the first
    /// write of the replacement cleans the fragment's span.
    func testAFragmentRowIsReplacedNotDuplicated() async throws {
        let store = try makeStore()
        try save(store, 13.25, 13.6)
        try await flush(store)

        try save(store, 13, 14.2)
        let stored = try rows(store)
        XCTAssertEqual(stored.count, 1)
        assertWindow(stored.first, 13, 14.2)
        let effects = try await flush(store)
        XCTAssertEqual(effects.first, .write(span(13, 14.2)))
        XCTAssertEqual(effects.last, .clean(span(13, 14.2), kept: ["uuid-1"], spared: hour(13) ..< hour(13)))
    }

    /// Two written fragments merged by one whole nap: one row, rewritten, and the clean covers both.
    func testTwoWrittenFragmentsMergeIntoOneRow() async throws {
        let store = try makeStore()
        try save(store, 13, 13.4)
        try save(store, 13.6, 14)
        try await flush(store)

        try save(store, 12.9, 14.1)
        XCTAssertEqual(try rows(store).count, 1)
        let effects = try await flush(store)
        XCTAssertEqual(effects, [.write(span(12.9, 14.1)),
                                 .clean(span(12.9, 14.1), kept: ["uuid-1"], spared: hour(12.9) ..< hour(12.9))])
    }

    /// A pending (not yet rewritten) row that is replaced again keeps the span Health still holds.
    func testAReplacedPendingRowKeepsWhatHealthHolds() async throws {
        let store = try makeStore()
        try save(store, 13, 13.5)
        try await flush(store)
        try save(store, 13, 14)
        try save(store, 12.95, 14.1)
        let row = try XCTUnwrap(try rows(store).first)
        XCTAssertEqual(try rows(store).count, 1)
        XCTAssertFalse(row.healthWritten)
        XCTAssertEqual(row.healthWrittenStart, hour(13))
        XCTAssertEqual(row.healthWrittenEnd, hour(13.5))
    }

    /// An edge moving by less than one epoch (150 s) does not rewrite the nap; one epoch does.
    func testSubEpochJitterDoesNotReArm() async throws {
        let store = try makeStore()
        try save(store, 13, 14)
        try await flush(store)

        try store.saveNap(start: hour(13).addingTimeInterval(120), end: hour(14).addingTimeInterval(-149),
                          asleepMin: 57, isLongNap: false)
        XCTAssertEqual(try rows(store).count, 1)
        XCTAssertEqual(try store.pendingNaps().count, 0, "a sub-epoch move stays as written")

        try store.saveNap(start: hour(13), end: hour(14).addingTimeInterval(150), asleepMin: 62, isLongNap: false)
        XCTAssertEqual(try store.pendingNaps().count, 1, "one epoch rewrites")
    }

    // MARK: Manual naps keep precedence

    /// A nap the user added, or an auto nap the user edited, is never replaced or moved, and a
    /// detected nap overlapping one is not stored.
    func testManualAndEditedNapsKeepPrecedence() async throws {
        let store = try makeStore()
        XCTAssertTrue(try store.addManualNap(start: hour(13), end: hour(14)))
        let archive = timeline(from: 13, [(.awake, 30), (.asleep, 70), (.awake, 70)])
        RingSession.persistNaps(archive: archive, drained: archive, temperatures: [], store: store)
        XCTAssertEqual(try rows(store).map(\.isManuallyAdded), [true], "the detected nap overlapping it is skipped")
        assertWindow(try rows(store).first, 13, 14)

        let edited = try makeStore()
        try save(edited, 15, 16)
        try await flush(edited)
        XCTAssertTrue(try edited.editNap(originalStart: hour(15), newStart: hour(15.1), newEnd: hour(15.9)))
        try await flush(edited)
        try save(edited, 14.9, 16.2)
        let row = try XCTUnwrap(try rows(edited).first { $0.start == hour(15) })
        XCTAssertTrue(row.isManuallyEdited)
        XCTAssertEqual(row.end, hour(16))
        XCTAssertEqual(row.effectiveStart, hour(15.1))
        XCTAssertEqual(row.effectiveEnd, hour(15.9))
        XCTAssertTrue(row.healthWritten)
        XCTAssertEqual(row.healthWrittenEnd, hour(15.9))
        XCTAssertFalse(try edited.pendingNaps().contains { $0.start == hour(15) })
    }

    /// The clean never runs over a manual nap: when an auto row's written span reaches one, the
    /// re-detection is upserted in place as before and nothing is re-armed.
    func testNoRewriteWhoseCleanWouldReachAManualNap() async throws {
        let store = try makeStore()
        try save(store, 13, 14)
        try await flush(store)
        XCTAssertTrue(try store.addManualNap(start: hour(13.75), end: hour(14.5)))
        try await flush(store)

        try save(store, 13, 13.6)
        let auto = try XCTUnwrap(try rows(store).first { !$0.isManuallyAdded })
        XCTAssertTrue(auto.healthWritten, "not re-armed")
        XCTAssertEqual(try store.pendingNaps().count, 0)
    }

    // MARK: Ownership

    /// With an empty ownership log (a ring-only install) every rule above applies to the ring, and
    /// the strap's naps are still not stored.
    func testWithAnEmptyOwnershipLogNothingElseChanges() async throws {
        let store = try makeStore()
        try save(store, 13, 14)
        try save(store, 13, 14)
        XCTAssertEqual(try rows(store).count, 1)
        XCTAssertEqual(try store.pendingNaps().map(\.start), [hour(13)])
        try await flush(store)
        try save(store, 13, 14)
        XCTAssertEqual(try store.pendingNaps().count, 0, "the same window again is not rewritten")

        try save(store, 16, 17, family: .zeppOS)
        XCTAssertEqual(try rows(store).count, 1, "a strap nap is not the ring's time to store")
    }

    /// A strap nap never replaces a ring nap's row, and its rewrite never cleans over one; a strap nap
    /// that grows after its write, clear of other naps, is rewritten too (the one strap change
    /// decision 69 makes).
    func testAStrapNapReplacesOnlyStrapRows() async throws {
        let switchAt = hour(14.5)
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: switchAt)]))
        let store = try makeStore()
        try save(store, 13.5, 14.6)                        // the ring's, midpoint before the switch
        try save(store, 14.55, 15.5, family: .zeppOS)      // overlaps it; the strap's
        XCTAssertEqual(try rows(store).count, 2, "the ring row is not the strap's to replace")
        try save(store, 17, 17.5, family: .zeppOS)
        try await flush(store)

        try save(store, 14.55, 16, family: .zeppOS)
        XCTAssertEqual(try rows(store).count, 3)
        XCTAssertEqual(try store.pendingNaps().count, 0, "its clean would reach the ring's nap: left as written")

        try save(store, 17, 18.2, family: .zeppOS)
        XCTAssertEqual(try rows(store).count, 3)
        XCTAssertEqual(try store.pendingNaps().map(\.start), [hour(17)], "the grown strap nap is rewritten")
    }
}
