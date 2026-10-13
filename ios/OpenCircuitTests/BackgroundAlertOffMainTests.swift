import SwiftData
import XCTest
import OpenCircuitKit
@testable import OpenCircuit

// #305: the background alert passes read their ~30-day history OFF the main actor. A strap catch-up was
// killed by the 10 s scene-update watchdog while the resting-HR series materialised a month of
// minute-cadence heart rate on the main thread.
//
// Two things are pinned here, on one synthetic store sized like a strap install (45 days of HR once a
// minute, ~65 k rows, plus HRV, plus a few days of ring 150 s rows across an ownership switch):
//  1. the off-main reads return EXACTLY what the main-actor reads returned at 4e10948 (the reference
//     copies below are that code, verbatim, run on the main context);
//  2. the main actor keeps running while they read (a main-actor heartbeat keeps beating).
// Every reading, id and time is synthetic and relative to the real clock, because the series' window is
// `Date()`-relative by design.

@MainActor
final class BackgroundAlertOffMainTests: XCTestCase {

    private let ownership = OwnershipOverride()
    private let savedDefaults: [String: Any?] = [
        HealthAlertDefaults.tempFeverEnabled: UserDefaults.standard.object(forKey: HealthAlertDefaults.tempFeverEnabled),
        HeadacheDefaults.enabled: UserDefaults.standard.object(forKey: HeadacheDefaults.enabled),
    ]

    override func tearDown() {
        ownership.restore()
        for (key, value) in savedDefaults {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    // MARK: Fixture (built once; the tests only read it)

    private struct Fixture {
        let container: ModelContainer
        let store: LocalStore
        let builtAt: Date
        let hrRows: Int
    }

    private static var cached: Fixture?

    static let strap = SyncDeviceID(rawValue: "zeppos:3C0A9D51-0000-4000-8000-00000000F305")

    /// The series' window starts `maxBaselineDays + 2` days before `Date()`, read separately by each
    /// implementation. No readings are stored within an hour of that edge, so two reads a few seconds
    /// apart see the same rows (otherwise a minute-cadence row could slip out between them).
    private static let windowEdgeGap: TimeInterval = 3600

    private func fixture() throws -> Fixture {
        if let cached = Self.cached { return cached }
        let container = try ModelContainer(
            for: StoredSample.self, StoredCursor.self, StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
            StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
            StoredHeadacheEntry.self, StoredHeadacheRisk.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let now = Date()
        let minute = (now.timeIntervalSince1970 / 60).rounded(.down) * 60
        let edge = now.timeIntervalSince1970 - Double(VitalsBaseline.Config().maxBaselineDays + 2) * 86_400
        func clearOfEdge(_ t: TimeInterval) -> Bool { abs(t - edge) > Self.windowEdgeGap }

        // The strap: heart rate once a minute for 45 days (a day-shaped curve, low overnight), with an
        // occasional 0 placeholder the `value > 0` predicate must drop; HRV every 5 minutes.
        var hrRows = 0
        for i in 0..<(45 * 1440) {
            let t = minute - Double(i) * 60
            guard clearOfEdge(t) else { continue }
            let hourOfDay = Int((t.truncatingRemainder(dividingBy: 86_400)) / 3600)
            let base = (1...6).contains(hourOfDay) ? 52 : 68
            let bpm = i % 997 == 0 ? 0 : base + (i * 7919) % 23
            context.insert(StoredSample(kindRaw: MetricKind.heartRate.rawValue, start: Date(timeIntervalSince1970: t),
                                        end: Date(timeIntervalSince1970: t), value: Double(bpm),
                                        deviceID: Self.strap.rawValue))
            hrRows += 1
            if i % 5 == 0 {
                let ms = i % 505 == 0 ? 0 : 25 + (i * 31) % 50
                context.insert(StoredSample(kindRaw: MetricKind.hrvSDNN.rawValue, start: Date(timeIntervalSince1970: t),
                                            end: Date(timeIntervalSince1970: t), value: Double(ms),
                                            deviceID: Self.strap.rawValue))
            }
        }
        // The ring: 150 s epochs from 9 to 3 days ago, across the switch the logs below place 6 days ago.
        let ringFrom = minute - 9 * 86_400, ringTo = minute - 3 * 86_400
        var k = 0
        for t in stride(from: ringFrom, to: ringTo, by: 150) {
            context.insert(StoredSample(kindRaw: MetricKind.heartRate.rawValue, start: Date(timeIntervalSince1970: t),
                                        end: Date(timeIntervalSince1970: t), value: Double(56 + (k * 13) % 19),
                                        deviceID: SyncDeviceID.ringConn.rawValue))
            if k % 2 == 0 {
                context.insert(StoredSample(kindRaw: MetricKind.hrvSDNN.rawValue, start: Date(timeIntervalSince1970: t),
                                            end: Date(timeIntervalSince1970: t), value: Double(30 + (k * 7) % 40),
                                            deviceID: SyncDeviceID.ringConn.rawValue))
            }
            hrRows += 1
            k += 1
        }
        try context.save()

        // Fifteen ring nights at a steady skin temperature: the fever cross-check has an offset (0 °C),
        // and nothing about it can fire.
        let store = LocalStore(context)
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        for back in 0...14 {
            let day = cal.date(byAdding: .day, value: -back, to: today)!
            let start = day.addingTimeInterval(-3600), end = day.addingTimeInterval(7 * 3600)
            let segments = [SleepSegment(start: start, end: end, stage: .asleepCore)]
            var extras = LocalStore.SleepNightExtras()
            extras.hypnogram = segments
            extras.skinTempC = 33.0
            _ = try store.saveSleepSummary(SleepStaging.summary(segments),
                                           night: SleepNightKey.night(inBedStart: start, inBedEnd: end),
                                           inBedStart: start, inBedEnd: end, sleepOnset: start, sleepWake: end,
                                           extras: extras, device: .ringConn)
        }
        let built = Fixture(container: container, store: store, builtAt: now, hrRows: hrRows)
        Self.cached = built
        return built
    }

    /// The ownership logs the equivalence runs under: ring-only (empty), the strap current since 6 days
    /// ago (drops the strap's rows before, and every ring row), and back to the ring 6 days ago after a
    /// strap stint.
    private func logs(_ f: Fixture) -> [(name: String, log: DeviceOwnershipLog)] {
        let switchAt = f.builtAt.addingTimeInterval(-6 * 86_400)
        return [
            ("ring-only", DeviceOwnershipLog()),
            ("strap current", DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: switchAt)])),
            ("ring current", DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: f.builtAt.addingTimeInterval(-40 * 86_400)),
                                                          .init(family: .ringConn, since: switchAt)])),
        ]
    }

    // MARK: Reference: the main-actor reads as they were at 4e10948 (verbatim, not shared code)

    /// `HealthNotificationCenter.restingHRDailySeries(store:)` with `LocalStore.recentOwnSamples` inlined.
    private func mainActorSeries(_ store: LocalStore) -> [RestingHR.DailyValue] {
        let since = Date().addingTimeInterval(-Double(VitalsBaseline.Config().maxBaselineDays + 2) * 86_400)
        func recentOwnSamples(kind: MetricKind, since: Date) throws -> [QuantitySample] {
            let log = LocalStore.ownershipLog()
            let kindRaw = kind.rawValue
            let descriptor = FetchDescriptor<StoredSample>(
                predicate: #Predicate { $0.kindRaw == kindRaw && $0.start >= since && $0.value > 0 },
                sortBy: [SortDescriptor(\.start, order: .forward)])
            guard !log.isEmpty else { return try store.context.fetch(descriptor).compactMap(\.sample) }
            return try store.context.fetch(descriptor)
                .filter { log.isOwn(recordedBy: SyncDeviceID(rawValue: $0.deviceID), at: $0.start, by: log.currentFamily) }
                .compactMap(\.sample)
        }
        let hr = ((try? recentOwnSamples(kind: .heartRate, since: since)) ?? [])
            .map { HRSample(bpm: Int($0.value), start: $0.start, end: $0.end) }
        return RestingHR.dailyValues(hr: hr, daytimeCoverage: RestingHR.dayCoverage).sorted { $0.day < $1.day }
    }

    /// `HeadacheEngine.snapshot`'s HR + HRV read, through the main-actor `LocalStore.ownSamples`.
    private func mainActorSnapshotSamples(_ store: LocalStore, day: Date, asOf: Date,
                                          device: DeviceOwnershipLog.Family) -> (hr: [HRSample], hrv: [QuantitySample]) {
        let sampleStart = Calendar.current.date(byAdding: .day, value: -HeadacheEngine.sampleLookbackDays, to: day) ?? day
        let hr = ((try? store.ownSamples(kind: .heartRate, from: sampleStart, to: asOf, of: device)) ?? [])
            .map { HRSample(bpm: Int($0.value), start: $0.start, end: $0.end) }
        let hrv = ((try? store.ownSamples(kind: .hrvSDNN, from: sampleStart, to: asOf, of: device)) ?? [])
            .filter { $0.value > 0 }
        return (hr, hrv)
    }

    // MARK: Main-actor heartbeat

    /// Beats on the main actor every millisecond while it is free. A read on the main actor shows up as
    /// one long gap; a read off it leaves the beats coming.
    @MainActor
    private final class Heartbeat {
        private(set) var beats: [UInt64] = []
        private var task: Task<Void, Never>?

        func start() {
            task = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.beats.append(DispatchTime.now().uptimeNanoseconds)
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
            }
        }

        func stop() { task?.cancel() }
    }

    private struct Timing {
        let wallMS: Double
        /// The longest the main actor went without a beat between the call and its return.
        let longestStallMS: Double
        let beats: Int
    }

    private func underHeartbeat<T>(_ body: () async -> T) async -> (T, Timing) {
        let heartbeat = Heartbeat()
        heartbeat.start()
        let t0 = DispatchTime.now().uptimeNanoseconds
        let value = await body()
        let t1 = DispatchTime.now().uptimeNanoseconds
        heartbeat.stop()
        let inside = heartbeat.beats.filter { $0 >= t0 && $0 <= t1 }
        let marks = [t0] + inside + [t1]
        let stall = zip(marks, marks.dropFirst()).map { $1 - $0 }.max() ?? (t1 - t0)
        return (value, Timing(wallMS: Double(t1 - t0) / 1e6, longestStallMS: Double(stall) / 1e6, beats: inside.count))
    }

    /// The main actor kept beating through the read: at least a few beats, and no gap anywhere near the
    /// length of the read itself (a read moved back onto the main actor is ONE gap as long as the call).
    private func assertMainActorKeptRunning(_ t: Timing, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        print(String(format: "BG-ALERTS-TIMING %@: wall %.1f ms, longest main-actor stall %.1f ms, beats %d",
                     what, t.wallMS, t.longestStallMS, t.beats))
        XCTAssertGreaterThanOrEqual(t.beats, 3, "\(what): the main actor never ran during the read (\(t))", file: file, line: line)
        XCTAssertLessThan(t.longestStallMS, t.wallMS * 0.5, "\(what): the main actor was blocked for most of the read (\(t))",
                          file: file, line: line)
    }

    // MARK: 1. Same results

    func testTheOffMainRestingHRSeriesEqualsTheMainActorOneUnderEveryOwnershipLog() async throws {
        let f = try fixture()
        XCTAssertGreaterThan(f.hrRows, 65_000)
        var seen: [[RestingHR.DailyValue]] = []
        for (name, log) in logs(f) {
            ownership.install(log)
            let expected = mainActorSeries(f.store)
            let actual = await HealthNotificationCenter().restingHRDailySeries(store: f.store)
            XCTAssertFalse(expected.isEmpty, name)
            XCTAssertEqual(actual, expected, name)
            seen.append(actual)
        }
        // The ownership filter is exercised: each log yields a different series.
        XCTAssertNotEqual(seen[0], seen[1])
        XCTAssertNotEqual(seen[1], seen[2])
    }

    func testTheOffMainHeadacheSnapshotEqualsTheMainActorOneUnderEveryOwnershipLog() async throws {
        let f = try fixture()
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        let asOf = Date()
        let restingHR = [RestingHR.DailyValue(day: day, bpm: 57)]
        for (name, log) in logs(f) {
            ownership.install(log)
            let onMain = HeadacheEngine.snapshot(store: f.store, day: day, asOf: asOf, restingHR: restingHR, calendar: cal)
            let parts = HeadacheEngine.snapshotParts(store: f.store, day: day, asOf: asOf, calendar: cal)
            let reference = mainActorSnapshotSamples(f.store, day: day, asOf: asOf, device: parts.samples.device)
            let offMain = await HeadacheEngine.snapshotOffMain(store: f.store, day: day, asOf: asOf,
                                                               restingHR: restingHR, calendar: cal)
            XCTAssertGreaterThan(reference.hr.count, 1_000, name)
            XCTAssertEqual(offMain.hr, reference.hr, name)
            XCTAssertEqual(offMain.hrv, reference.hrv, name)
            XCTAssertEqual(onMain.hr, reference.hr, name)
            XCTAssertEqual(onMain.hrv, reference.hrv, name)
            XCTAssertEqual(offMain.day, onMain.day, name)
            XCTAssertEqual(offMain.now, onMain.now, name)
            XCTAssertEqual(offMain.lastRingDataAt, onMain.lastRingDataAt, name)
            XCTAssertEqual(offMain.nights, onMain.nights, name)
            XCTAssertEqual(offMain.tonight, onMain.tonight, name)
            XCTAssertEqual(offMain.providedRestingHR, restingHR, name)
            XCTAssertEqual(offMain.periods, onMain.periods, name)
            XCTAssertEqual(offMain.womensHealthEnabled, onMain.womensHealthEnabled, name)
            XCTAssertEqual(offMain.scheduledBedtime, onMain.scheduledBedtime, name)
            XCTAssertEqual(offMain.headacheAlreadyLoggedToday, onMain.headacheAlreadyLoggedToday, name)
            XCTAssertEqual(offMain.priorIndices, onMain.priorIndices, name)
        }
    }

    // MARK: 2. The main actor keeps running

    func testTheRestingHRSeriesDoesNotBlockTheMainActor() async throws {
        let f = try fixture()
        ownership.install(DeviceOwnershipLog())
        let (series, timing) = await underHeartbeat { await HealthNotificationCenter().restingHRDailySeries(store: f.store) }
        XCTAssertFalse(series.isEmpty)
        assertMainActorKeptRunning(timing, "restingHRDailySeries")
    }

    func testTheHeadacheFreezeSnapshotDoesNotBlockTheMainActor() async throws {
        let f = try fixture()
        ownership.install(DeviceOwnershipLog())
        let cal = Calendar.current
        let (snapshot, timing) = await underHeartbeat {
            await HeadacheEngine.snapshotOffMain(store: f.store, day: cal.startOfDay(for: Date()), asOf: Date(),
                                                 restingHR: [], calendar: cal)
        }
        XCTAssertGreaterThan(snapshot.hr.count, 1_000)
        assertMainActorKeptRunning(timing, "snapshotOffMain")
    }

    /// The pass with no series handed in (the foreground evaluate, or a background pass with Headache off)
    /// still reads it — temp alerts on and an offset on record — and reads it off the main actor. Nothing
    /// fires on this fixture (steady temperature, HR under every threshold), so no notification is posted.
    func testTheAlertPassReadsItsSeriesOffTheMainActorWhenNoneIsHandedIn() async throws {
        let f = try fixture()
        ownership.install(DeviceOwnershipLog())
        UserDefaults.standard.set(true, forKey: HealthAlertDefaults.tempFeverEnabled)
        UserDefaults.standard.set(false, forKey: HeadacheDefaults.enabled)
        let (_, timing) = await underHeartbeat {
            await HealthNotificationCenter().evaluate(store: f.store, session: nil)
        }
        assertMainActorKeptRunning(timing, "evaluate")
    }

    // MARK: 3. Measured: old main-actor read vs the new one (printed for the PR, not a benchmark)

    func testReportsTheMainActorStallOfTheOldAndNewReads() async throws {
        let f = try fixture()
        ownership.install(DeviceOwnershipLog())
        _ = await HealthNotificationCenter().restingHRDailySeries(store: f.store)   // warm-up
        // The new read FIRST: the old one leaves ~46 k rows registered in the main context, and their
        // teardown would land on the main actor inside whichever measurement came next.
        let (new, newTiming) = await underHeartbeat { await HealthNotificationCenter().restingHRDailySeries(store: f.store) }
        let (old, oldTiming) = await underHeartbeat { self.mainActorSeries(f.store) }
        XCTAssertEqual(new, old)
        print(String(format: "BG-ALERTS-TIMING rows=%d old(main actor): wall %.1f ms, longest main-actor stall %.1f ms; "
                     + "new(off main): wall %.1f ms, longest main-actor stall %.1f ms, beats %d",
                     f.hrRows, oldTiming.wallMS, oldTiming.longestStallMS,
                     newTiming.wallMS, newTiming.longestStallMS, newTiming.beats))
        XCTAssertLessThan(newTiming.longestStallMS, oldTiming.longestStallMS)

        // What stays on the main actor in the alert pass: everything but the series (handed in here),
        // i.e. the 2 h instant-rule reads, the sleep summaries and the small Headache tables.
        UserDefaults.standard.set(true, forKey: HealthAlertDefaults.tempFeverEnabled)
        UserDefaults.standard.set(false, forKey: HeadacheDefaults.enabled)
        let (_, passTiming) = await underHeartbeat {
            await HealthNotificationCenter().evaluate(store: f.store, session: nil, restingHRDaily: new)
        }
        print(String(format: "BG-ALERTS-TIMING evaluate with the series handed in (main-actor remainder): wall %.1f ms, "
                     + "longest main-actor stall %.1f ms", passTiming.wallMS, passTiming.longestStallMS))
    }
}
