import HealthKit
import SwiftData
import XCTest
import OpenCircuitKit
import ZeppKit
@testable import OpenCircuit

// Decision 70c (#311): a strap night reaches Apple Health with its `.inBed` layer through the writer's
// existing split (`HealthKitWriter.sleepSamples`, the `healthPublication` seam every sleep write goes
// through), one In Bed sample per fragment; a ring night's samples are exactly what they were. Every
// record and time is synthetic.

/// 2026-09-20T00:00:00Z, the records' local-midnight reference.
private let wMidnight: TimeInterval = 1_789_862_400

private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8)] }
private func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xff) } }

/// Minute `m` of a record (§6.6: from the reference − 24 h; 1380 is 23:00 the evening before).
private func minute(_ m: Int) -> Date { Date(timeIntervalSince1970: wMidnight - 86_400 + TimeInterval(m) * 60) }

/// A `0x48` record: its sleep span and its stage table in wire minutes (end minutes inclusive, §6.6).
private func sessionBytes(sleep: (UInt16, UInt16), stages: [(UInt16, UInt16, UInt8)]) -> [UInt8] {
    var r = [UInt8](repeating: 0, count: ZeppSleepSession.recordLength)
    func put(_ bytes: [UInt8], at offset: Int) { for (i, b) in bytes.enumerated() { r[offset + i] = b } }
    put(le32(UInt32(wMidnight)), at: 0x000)
    put(le32(UInt32(wMidnight)), at: 0x004)
    r[0x008] = 1
    r[0x009] = 1
    put(le16(sleep.0), at: 0x00A)
    put(le16(sleep.1), at: 0x00C)
    r[0x016] = 80
    r[0x054] = UInt8(stages.count)
    for (i, s) in stages.enumerated() { put(le16(s.0) + le16(s.1) + [s.2], at: 0x056 + 5 * i) }
    return r
}

@MainActor
final class StrapInBedHealthWriteTests: XCTestCase {
    private let ownership = OwnershipOverride()
    private var containers: [ModelContainer] = []

    override func tearDown() {
        ownership.restore()
        containers.removeAll()
        super.tearDown()
    }

    /// A row of a sample, comparable: HealthKit value, start, end (Unix seconds), metadata keys.
    private func describe(_ sample: HKCategorySample) -> String {
        "\(sample.value) \(sample.startDate.timeIntervalSince1970) \(sample.endDate.timeIntervalSince1970) "
            + (sample.metadata?.keys.sorted().joined(separator: ",") ?? "-")
    }

    func testAStrapNightsWriteHasOneInBedSamplePerFragmentOverItsInBedSpan() throws {
        // 23:00–01:30 (in bed from 22:30), then 02:00–07:00: 30 minutes apart, so one stitched night.
        let first = sessionBytes(sleep: (1350, 1530), stages: [(1380, 1469, 0x04), (1470, 1529, 0x05)])
        let second = sessionBytes(sleep: (1560, 1860), stages: [(1560, 1739, 0x08), (1740, 1859, 0x04)])
        let parsed = try ZeppRecordParser.parse(.sleepSession, data: first + second, start: Date(timeIntervalSince1970: 0))
        guard case .sleepSession(let sessions) = parsed.records else { return XCTFail("not a session batch") }
        let nights = HelioSleepSelection.nights(from: sessions, now: Date(timeIntervalSince1970: wMidnight + 10 * 3600))
        let night = try XCTUnwrap(nights.first)
        XCTAssertEqual(nights.count, 1)

        let samples = HealthKitWriter.sleepSamples(night.segments, device: nil, site: "test")
        let inBed = samples.filter { $0.value == HKCategoryValueSleepAnalysis.inBed.rawValue }
        XCTAssertEqual(inBed.map { DateInterval(start: $0.startDate, end: $0.endDate) },
                       [DateInterval(start: minute(1350), end: minute(1530)), DateInterval(start: minute(1560), end: minute(1860))],
                       "exactly one In Bed sample per fragment, over its in-bed span")
        XCTAssertEqual(samples.map(describe), night.segments.map {
            "\(HealthKitWriter.sleepValue($0.stage).rawValue) \($0.start.timeIntervalSince1970) \($0.end.timeIntervalSince1970) -"
        }, "every segment as one ordinary sample, nothing else")
        XCTAssertEqual(samples.filter { $0.value != HKCategoryValueSleepAnalysis.inBed.rawValue }.map(\.startDate),
                       [1380, 1470, 1560, 1740].map(minute), "the stages as reported")
    }

    /// A ring night's samples, pinned value by value: no `.inBed` handling changed for it.
    func testARingNightsWriteIsUnchanged() throws {
        let ring = [
            SleepSegment(start: minute(1380), end: minute(1860), stage: .inBed),
            SleepSegment(start: minute(1380), end: minute(1410), stage: .awake),
            SleepSegment(start: minute(1410), end: minute(1560), stage: .asleepCore),
            SleepSegment(start: minute(1560), end: minute(1680), stage: .asleepDeep),
            SleepSegment(start: minute(1680), end: minute(1860), stage: .asleepREM),
        ]
        let samples = HealthKitWriter.sleepSamples(ring, device: nil, site: "test")
        let t = { (m: Int) in minute(m).timeIntervalSince1970 }
        XCTAssertEqual(samples.map(describe), [
            "\(HKCategoryValueSleepAnalysis.inBed.rawValue) \(t(1380)) \(t(1860)) -",
            "\(HKCategoryValueSleepAnalysis.awake.rawValue) \(t(1380)) \(t(1410)) -",
            "\(HKCategoryValueSleepAnalysis.asleepCore.rawValue) \(t(1410)) \(t(1560)) -",
            "\(HKCategoryValueSleepAnalysis.asleepDeep.rawValue) \(t(1560)) \(t(1680)) -",
            "\(HKCategoryValueSleepAnalysis.asleepREM.rawValue) \(t(1680)) \(t(1860)) -",
        ])
    }

    /// Decision 70h is the strap's alone: a ring night whose mirror record holds its stage-only shape is
    /// rewritten exactly as before (the ring's call carries no earlier shapes).
    func testTheForwardOnlyShapesNeverApplyToARingNight() async throws {
        ownership.install(DeviceOwnershipLog())
        let container = try ModelContainer(
            for: StoredSample.self, StoredCursor.self, StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
            StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(container)
        let store = LocalStore(container.mainContext)
        let ring = [SleepSegment(start: minute(1380), end: minute(1860), stage: .inBed),
                    SleepSegment(start: minute(1380), end: minute(1860), stage: .asleepCore)]
        var extras = LocalStore.SleepNightExtras()
        extras.hypnogram = ring
        let key = SleepNightKey.night(inBedStart: minute(1380), inBedEnd: minute(1860))
        XCTAssertEqual(try store.saveSleepSummary(SleepStaging.summary(ring), night: key,
                                                  inBedStart: minute(1380), inBedEnd: minute(1860),
                                                  sleepOnset: minute(1380), sleepWake: minute(1860), extras: extras), .inserted)
        let row = try XCTUnwrap(try store.sleepSummaryOverlapping(start: minute(1380), end: minute(1860)))
        let mirrorKey = "sleep.mirror.night.\(Calendar.current.startOfDay(for: row.night).timeIntervalSince1970)"
        defer { UserDefaults.standard.removeObject(forKey: mirrorKey) }
        store.setMirroredNight(night: row.night, signature: HealthKitWriter.sleepSignature(ring.filter { $0.stage != .inBed }),
                               spanStart: minute(1380), spanEnd: minute(1860))
        let outcome = await HealthKitWriter().mirrorSettledNight(local: store, segments: ring)
        if case .unchanged = outcome { XCTFail("a ring night is never the forward-only no-op") }
        if case .declined = outcome { XCTFail("nor declined") }
    }
}
