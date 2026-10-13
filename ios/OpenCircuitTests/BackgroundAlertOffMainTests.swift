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
    /// Every persisted `headache.*` / `alerts.*` value before the test: the passes driven here read and
    /// write those (the Headache monitor, the notification ledgers), and they are put back exactly.
    private var savedDefaults: [String: Any] = [:]

    private static func trackedDefaults() -> [String: Any] {
        let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        return domain.filter { $0.key.hasPrefix("headache.") || $0.key.hasPrefix("alerts.") }
    }

    override func setUp() {
        super.setUp()
        savedDefaults = Self.trackedDefaults()
    }

    override func tearDown() {
        ownership.restore()
        for key in Self.trackedDefaults().keys where savedDefaults[key] == nil {
            UserDefaults.standard.removeObject(forKey: key)
        }
        for (key, value) in savedDefaults { UserDefaults.standard.set(value, forKey: key) }
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

    /// `HeadacheEngine.snapshot(store:day:asOf:restingHR:calendar:)` as it was at 4e10948 — the synchronous,
    /// main-actor read the freeze and the card used — copied verbatim (its private `nextDay` and the
    /// engine's constants made local). Nothing in the app shares this code any more.
    private func legacySnapshot(store: LocalStore, day: Date, asOf: Date,
                                restingHR: [RestingHR.DailyValue],
                                calendar: Calendar) -> HeadacheSnapshot {
        func nextDay(after day: Date, _ calendar: Calendar) -> Date {
            calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        }
        let nightsFetchLimit = HeadacheEngine.nightsFetchLimit
        let sampleLookbackDays = HeadacheEngine.sampleLookbackDays
        let womensHealthEnabledKey = HeadacheEngine.womensHealthEnabledKey
        let defaults = UserDefaults.standard
        let end = nextDay(after: day, calendar)

        // Decision 29: the day is judged only against its own device's history: the device of the night
        // it scores (else the current one). With an empty log that is the ring for everything, and
        // every filter below keeps every row.
        let log = LocalStore.ownershipLog()
        let storedNights = (try? store.recentSleepSummaries(limit: nightsFetchLimit)) ?? []
        let device = storedNights.filter { $0.inBedEnd >= day && $0.inBedEnd < end }
            .max { $0.inBedEnd < $1.inBedEnd }
            .map { log.owner(ofNightFrom: $0.inBedStart, to: $0.inBedEnd) } ?? log.currentFamily
        let nightOwners = Dictionary(storedNights.map { (calendar.startOfDay(for: $0.night),
                                                         log.owner(ofNightFrom: $0.inBedStart, to: $0.inBedEnd)) },
                                     uniquingKeysWith: { first, _ in first })
        let nights = log.only(device, storedNights, time: \.inBedStart)
            .map(HeadacheNightRow.init)
            .sorted { $0.night < $1.night }
        let tonight = nights.filter { $0.inBedEnd >= day && $0.inBedEnd < end }
            .max { $0.inBedEnd < $1.inBedEnd }

        // Bounded by the predicate, and additionally by the 30-day sample retention.
        let sampleStart = calendar.date(byAdding: .day, value: -sampleLookbackDays, to: day) ?? day
        let hr = ((try? store.ownSamples(kind: .heartRate, from: sampleStart, to: asOf, of: device)) ?? [])
            .map { HRSample(bpm: Int($0.value), start: $0.start, end: $0.end) }
        // 0 is a placeholder, not a measured HRV — dropping it here keeps a zero out of a baseline.
        let hrv = ((try? store.ownSamples(kind: .hrvSDNN, from: sampleStart, to: asOf, of: device)) ?? [])
            .filter { $0.value > 0 }

        // The banding budget is a TRAILING-60-DAY window, not the last 60 rows: it exists to
        // re-calibrate within 60 days of a life change, and a user with gaps should not be judged
        // against months-old days (§3.7). `riskDays` is `[from, to)`, so today is excluded.
        let bandStart = calendar.date(byAdding: .day,
                                      value: -HeadacheSignals.Tuning().bandWindowDays,
                                      to: day) ?? day
        // Decision 29: only days scored on the same device's nights (each day's night, else its noon).
        let priorIndices = ((try? store.riskDays(from: bandStart, to: day)) ?? [])
            .filter { risk in
                log.isEmpty || (nightOwners[calendar.startOfDay(for: risk.nightKey)]
                    ?? log.owner(at: calendar.startOfDay(for: risk.day).addingTimeInterval(12 * 3600))) == device
            }
            .map { Int($0.index.rounded()) }

        // "Already having one" suppression. A severity-1 (`notPresent`) entry records the ABSENCE of
        // a headache — the same distinction the Apple Health import refuses to blur
        // (`HeadacheCardView.swift:235`) — so it must not suppress anything.
        let loggedToday = ((try? store.headacheEntries(from: day, to: end)) ?? [])
            .contains { $0.onset <= asOf && $0.severityRaw != 1 }

        let periods = ((try? store.allPeriodEntries()) ?? [])
            .map { CyclePredictor.PeriodEntry(start: $0.start, end: $0.end) }

        // Durable "the ring last delivered something" watermark, written by RingSession on every data
        // frame (`RingSession.swift:3423`). Stored as epoch seconds; 0 = never.
        let ringEpoch = defaults.double(forKey: ReminderDefaults.lastRingDataAt)

        // Scheduled bedtime for the truncation test — MANUAL schedule only, exactly as the sleep
        // card's truncation hint does it (`SleepCardView.swift:386-402`). No HealthKit query: this
        // runs on wake paths that must not block, and with no schedule `SleepCaptureCoverage`
        // correctly declines to guess rather than mistaking a short night for a truncated one.
        SleepScheduleDefaults.register(defaults)
        let scheduledBedtime: Date? = {
            guard defaults.bool(forKey: SleepScheduleDefaults.enabled),
                  let wake = tonight?.inBedEnd else { return nil }
            return SleepWindow.interval(
                bedMinutes: defaults.integer(forKey: SleepScheduleDefaults.bedMinutes),
                wakeMinutes: defaults.integer(forKey: SleepScheduleDefaults.wakeMinutes),
                nightEndingNear: wake, calendar: calendar)?.start
        }()

        return HeadacheSnapshot(
            day: day,
            now: asOf,
            lastRingDataAt: ringEpoch > 0 ? Date(timeIntervalSince1970: ringEpoch) : nil,
            nights: nights,
            tonight: tonight,
            hr: hr,
            hrv: hrv,
            providedRestingHR: restingHR,
            periods: periods,
            womensHealthEnabled: defaults.bool(forKey: womensHealthEnabledKey),
            scheduledBedtime: scheduledBedtime,
            headacheAlreadyLoggedToday: loggedToday,
            priorIndices: priorIndices)
    }

    /// `HeadacheEngine.todaysVerdict` as it was at 4e10948, on `legacySnapshot`.
    private func legacyTodaysVerdict(store: LocalStore, now: Date) -> HeadacheSignals.Verdict {
        let cal = Calendar.current
        let day = cal.startOfDay(for: now)
        let asOf = HeadacheEngine.frozenRow(store: store, day: day, calendar: cal)?.computedAt ?? now
        return HeadacheAssessmentBuilder.verdict(legacySnapshot(store: store, day: day, asOf: asOf, restingHR: [], calendar: cal))
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
        /// From the call to the first beat: the call's own synchronous main-actor prelude up to its first
        /// suspension, plus whatever the test host had queued on the main thread before it. Reported,
        /// not asserted: the host reacts on the main thread to `UserDefaults.register(defaults:)` and to
        /// defaults writes, which `evaluate` and `snapshotParts` make (measured on this host with no
        /// SwiftData involved: 120-400 ms after either).
        let firstBeatMS: Double
        /// The longest the main actor then went without a beat, until the call returned.
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
        guard let first = inside.first else {
            let wall = Double(t1 - t0) / 1e6
            return (value, Timing(wallMS: wall, firstBeatMS: wall, longestStallMS: wall, beats: 0))
        }
        let marks = inside + [t1]
        let stall = zip(marks, marks.dropFirst()).map { $1 - $0 }.max() ?? 0
        return (value, Timing(wallMS: Double(t1 - t0) / 1e6, firstBeatMS: Double(first - t0) / 1e6,
                              longestStallMS: Double(stall) / 1e6, beats: inside.count))
    }

    /// Waits until the main actor has gone 100 ms with no gap over 25 ms (bounded), so a measurement
    /// doesn't start inside the host's reaction to the fixture's save or to a defaults write.
    private func settleMainActor() async {
        for _ in 0..<100 {
            let (_, t) = await underHeartbeat { try? await Task.sleep(nanoseconds: 100_000_000) }
            if t.beats > 0, max(t.firstBeatMS, t.longestStallMS) < 25 { return }
        }
    }

    /// The main actor kept beating through the read:
    ///  - at least a few beats, and at least one per 20 ms of the call on average (a free main actor beats
    ///    about every 2 ms here). A heavy read on the main actor ANYWHERE in the call, including before
    ///    its first suspension, leaves a pass with almost no beats;
    ///  - no gap after the first beat anywhere near the length of the call (a read moved back onto the
    ///    main actor mid-call is ONE gap as long as the read).
    private func assertMainActorKeptRunning(_ t: Timing, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        print(String(format: "BG-ALERTS-TIMING %@: wall %.1f ms, first beat after %.1f ms, then longest main-actor stall %.1f ms, beats %d",
                     what, t.wallMS, t.firstBeatMS, t.longestStallMS, t.beats))
        XCTAssertGreaterThanOrEqual(t.beats, 3, "\(what): the main actor never ran during the read (\(t))", file: file, line: line)
        XCTAssertGreaterThanOrEqual(Double(t.beats), t.wallMS / 20,
                                    "\(what): the main actor ran for only a sliver of the call (\(t))", file: file, line: line)
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

    func testTheOffMainHeadacheSnapshotEqualsTheOldMainActorOneUnderEveryOwnershipLog() async throws {
        let f = try fixture()
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        let asOf = Date()
        let restingHR = [RestingHR.DailyValue(day: day, bpm: 57)]
        for (name, log) in logs(f) {
            ownership.install(log)
            let old = legacySnapshot(store: f.store, day: day, asOf: asOf, restingHR: restingHR, calendar: cal)
            let new = await HeadacheEngine.snapshotOffMain(store: f.store, day: day, asOf: asOf,
                                                           restingHR: restingHR, calendar: cal)
            XCTAssertGreaterThan(old.hr.count, 1_000, name)
            XCTAssertEqual(new.hr, old.hr, name)
            XCTAssertEqual(new.hrv, old.hrv, name)
            XCTAssertEqual(new.day, old.day, name)
            XCTAssertEqual(new.now, old.now, name)
            XCTAssertEqual(new.lastRingDataAt, old.lastRingDataAt, name)
            XCTAssertEqual(new.nights, old.nights, name)
            XCTAssertEqual(new.tonight, old.tonight, name)
            XCTAssertEqual(new.providedRestingHR, old.providedRestingHR, name)
            XCTAssertEqual(new.periods, old.periods, name)
            XCTAssertEqual(new.womensHealthEnabled, old.womensHealthEnabled, name)
            XCTAssertEqual(new.scheduledBedtime, old.scheduledBedtime, name)
            XCTAssertEqual(new.headacheAlreadyLoggedToday, old.headacheAlreadyLoggedToday, name)
            XCTAssertEqual(new.priorIndices, old.priorIndices, name)
        }
    }

    /// The card's verdict (`todaysVerdict`, now on `snapshotOffMain`) equals the old main-actor one.
    func testTheCardVerdictEqualsTheOldMainActorOneUnderEveryOwnershipLog() async throws {
        let f = try fixture()
        UserDefaults.standard.set(true, forKey: HeadacheDefaults.enabled)
        let now = Date()
        for (name, log) in logs(f) {
            ownership.install(log)
            let old = legacyTodaysVerdict(store: f.store, now: now)
            let new = await HeadacheEngine().todaysVerdict(store: f.store, now: now)
            XCTAssertEqual(new, old, name)
        }
    }

    // MARK: 2. The main actor keeps running

    func testTheRestingHRSeriesDoesNotBlockTheMainActor() async throws {
        let f = try fixture()
        ownership.install(DeviceOwnershipLog())
        await settleMainActor()
        let (series, timing) = await underHeartbeat { await HealthNotificationCenter().restingHRDailySeries(store: f.store) }
        XCTAssertFalse(series.isEmpty)
        assertMainActorKeptRunning(timing, "restingHRDailySeries")
    }

    func testTheHeadacheFreezeSnapshotDoesNotBlockTheMainActor() async throws {
        let f = try fixture()
        ownership.install(DeviceOwnershipLog())
        let cal = Calendar.current
        await settleMainActor()
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
        await settleMainActor()
        let (_, timing) = await underHeartbeat {
            await HealthNotificationCenter().evaluate(store: f.store, session: nil)
        }
        assertMainActorKeptRunning(timing, "evaluate")
    }

    // MARK: 2b. The real passes (the #305 crash path), not just the helpers

    /// `AppDelegate.evaluateBodyAlerts` — what the strap catch-up's `afterRun` and `bodyAlertPass` run —
    /// with Headache on, so it reads the resting-HR series. Today is already frozen here, so the freeze
    /// takes its early return and the series is the pass's one heavy read (the freeze has its own test
    /// below). Headache alerts are marked retired for this pass, so nothing can be posted.
    func testTheStrapBodyAlertPassDoesNotBlockTheMainActor() async throws {
        let f = try fixture()
        ownership.install(DeviceOwnershipLog())
        UserDefaults.standard.set(true, forKey: HeadacheDefaults.enabled)
        UserDefaults.standard.set(true, forKey: HealthNotificationCenter.headacheRetiredKey)
        try freezeToday(f)
        await settleMainActor()
        let (_, timing) = await underHeartbeat { await AppDelegate.evaluateBodyAlerts(store: f.store) }
        assertMainActorKeptRunning(timing, "evaluateBodyAlerts")
    }

    /// `HeadacheEngine.refreshToday` on a day that is not frozen yet and whose night has settled, so the
    /// freeze reads its 62 days of HR + HRV (`snapshotOffMain`).
    func testTheHeadacheFreezePassDoesNotBlockTheMainActor() async throws {
        let f = try fixture()
        ownership.install(DeviceOwnershipLog())
        UserDefaults.standard.set(true, forKey: HeadacheDefaults.enabled)
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let now = today.addingTimeInterval(11 * 3600)   // the fixture's night ends 07:00; settled after 10:00
        try unfreezeToday(f)
        // The freeze must reach the heavy read for this to mean anything.
        XCTAssertNil(HeadacheEngine.frozenRow(store: f.store, day: today, calendar: cal))
        let night = try XCTUnwrap(HeadacheEngine.nightEnding(on: today, store: f.store, calendar: cal))
        XCTAssertGreaterThanOrEqual(now, night.sleepEditCurrentInBedEnd
            .addingTimeInterval(TimeInterval(HeadacheEngine.settleMarginMinutes) * 60))
        let series = await HealthNotificationCenter().restingHRDailySeries(store: f.store)
        await settleMainActor()
        let (_, timing) = await underHeartbeat {
            await HeadacheEngine().refreshToday(store: f.store, restingHR: series, now: now)
        }
        assertMainActorKeptRunning(timing, "refreshToday")
    }

    /// The Headache card's load (`todaysVerdict`, from the card's `.task`).
    func testTheCardVerdictDoesNotBlockTheMainActor() async throws {
        let f = try fixture()
        ownership.install(DeviceOwnershipLog())
        UserDefaults.standard.set(true, forKey: HeadacheDefaults.enabled)
        await settleMainActor()
        let (verdict, timing) = await underHeartbeat { await HeadacheEngine().todaysVerdict(store: f.store) }
        XCTAssertNotNil(verdict)
        assertMainActorKeptRunning(timing, "todaysVerdict")
    }

    private func todaysRiskRows(_ f: Fixture) throws -> [StoredHeadacheRisk] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
        return try f.store.riskDays(from: today, to: tomorrow)
    }

    private func freezeToday(_ f: Fixture) throws {
        guard try todaysRiskRows(f).isEmpty else { return }
        let today = Calendar.current.startOfDay(for: Date())
        try f.store.insertRiskDayIfAbsent(StoredHeadacheRisk(day: today, nightKey: today, index: 40, bandRaw: 0,
                                                             ringFeatureCount: 4, coverageFraction: 0.9,
                                                             contributionsJSON: "{}", absentJSON: "{}",
                                                             computedAt: today.addingTimeInterval(11 * 3600)))
    }

    private func unfreezeToday(_ f: Fixture) throws {
        for row in try todaysRiskRows(f) { f.store.context.delete(row) }
        try f.store.context.save()
    }

    // MARK: 2c. The Headache arm of the prefetch (review of #306, SF1)

    /// Temp alerts OFF, Headache ON, no series handed in (the foreground pass, or any caller that doesn't
    /// run the engine), a flagged frozen day, a fever-level skin-temperature offset and resting HR 18 bpm
    /// over the usual. The fever suppresses the morning `headache.signs`, exactly as before #305: the
    /// series must be read for the fever check even though the temp alerts are off. Without it the
    /// fever check sees no series, says "no fever", and `headache.signs` is claimed and posted.
    func testFeverStillSuppressesTheHeadacheAlertWhenOnlyHeadacheNeedsTheSeries() async throws {
        ownership.install(DeviceOwnershipLog())
        UserDefaults.standard.set(false, forKey: HealthAlertDefaults.tempFeverEnabled)
        UserDefaults.standard.set(true, forKey: HeadacheDefaults.enabled)
        UserDefaults.standard.removeObject(forKey: HealthNotificationCenter.headacheRetiredKey)

        let container = try ModelContainer(
            for: StoredSample.self, StoredCursor.self, StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
            StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
            StoredHeadacheEntry.self, StoredHeadacheRisk.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = LocalStore(container.mainContext)
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        func day(_ back: Int) -> Date { cal.date(byAdding: .day, value: -back, to: today)! }

        // Ring HR, midnight to noon in 150 s epochs with a resting block at 03:00: a usual 55 bpm, then
        // today at 73 (+18). Inserted directly: today's epochs can be later than the real clock.
        for back in 0...14 {
            let usual = back == 0 ? 73 : 55
            for i in 0..<289 {
                let t = day(back).addingTimeInterval(Double(i) * 150)
                store.context.insert(StoredSample(kindRaw: MetricKind.heartRate.rawValue, start: t, end: t,
                                                  value: Double((72...83).contains(i) ? usual : usual + 12)))
            }
        }
        try store.context.save()
        // Fourteen nights at 33.0 °C, then last night at 34.6 °C: a fever-level offset.
        for back in 0...14 {
            let start = day(back).addingTimeInterval(-3600), end = day(back).addingTimeInterval(7 * 3600)
            let segments = [SleepSegment(start: start, end: end, stage: .asleepCore)]
            var extras = LocalStore.SleepNightExtras()
            extras.hypnogram = segments
            extras.skinTempC = back == 0 ? 34.6 : 33.0
            _ = try store.saveSleepSummary(SleepStaging.summary(segments),
                                           night: SleepNightKey.night(inBedStart: start, inBedEnd: end),
                                           inBedStart: start, inBedEnd: end, sleepOnset: start, sleepWake: end,
                                           extras: extras, device: .ringConn)
        }
        // 21 frozen days before today (the banding floor), then today FLAGGED.
        for back in 0...21 {
            try store.insertRiskDayIfAbsent(StoredHeadacheRisk(
                day: day(back), nightKey: day(back), index: back == 0 ? 90 : 40,
                bandRaw: back == 0 ? HeadacheSignals.Band.flagged.rawValue : HeadacheSignals.Band.typical.rawValue,
                ringFeatureCount: 4, coverageFraction: 0.9, contributionsJSON: "{}", absentJSON: "{}",
                computedAt: day(back).addingTimeInterval(10 * 3600)))
        }

        let suiteName = "bg-alerts-sf1-\(UUID().uuidString)"
        let ledger = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { ledger.removePersistentDomain(forName: suiteName) }
        let center = HealthNotificationCenter(store: HealthNotificationStore(ledger))

        // The premise: with the series, this IS a fever morning.
        let series = await center.restingHRDailySeries(store: store)
        XCTAssertEqual(series.last?.day, today)
        XCTAssertTrue(center.tempFeverCandidates(store: store, restingHRDaily: series).fever)

        // The claim (`markFired`) is written BEFORE the authorization request, and in a test host that
        // request can wait on a system prompt for good. So the ledger is judged while the pass runs,
        // instead of only after it returns: a regression fails here rather than hanging.
        let noon = today.addingTimeInterval(12 * 3600)   // inside the 07:00-21:00 delivery window
        let pass = PassBox()
        Task { await center.evaluate(store: store, session: nil, now: noon); pass.finished = true }
        let deadline = Date().addingTimeInterval(60)
        while !pass.finished, Date() < deadline,
              HealthNotificationStore(ledger).lastFired()[.headacheSigns] == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(HealthNotificationStore(ledger).lastFired()[.headacheSigns],
                     "headache.signs was claimed on a fever morning")
        XCTAssertTrue(pass.finished, "the alert pass did not return")
        XCTAssertTrue(HealthNotificationStore(ledger).lastFired().isEmpty)
    }

    @MainActor
    private final class PassBox { var finished = false }

    // MARK: 3. Measured: old main-actor read vs the new one (printed for the PR, not a benchmark)

    func testReportsTheMainActorStallOfTheOldAndNewReads() async throws {
        let f = try fixture()
        ownership.install(DeviceOwnershipLog())
        _ = await HealthNotificationCenter().restingHRDailySeries(store: f.store)   // warm-up
        // The new read FIRST: the old one leaves ~46 k rows registered in the main context, and their
        // teardown would land on the main actor inside whichever measurement came next.
        await settleMainActor()
        let (new, newTiming) = await underHeartbeat { await HealthNotificationCenter().restingHRDailySeries(store: f.store) }
        await settleMainActor()
        let (old, oldTiming) = await underHeartbeat { self.mainActorSeries(f.store) }
        XCTAssertEqual(new, old)
        print(String(format: "BG-ALERTS-TIMING rows=%d old(main actor): wall %.1f ms, main actor blocked %.1f ms (no beat at all: %d beats); "
                     + "new(off main): wall %.1f ms, first beat after %.1f ms, then longest main-actor stall %.1f ms, beats %d",
                     f.hrRows, oldTiming.wallMS, oldTiming.firstBeatMS, oldTiming.beats,
                     newTiming.wallMS, newTiming.firstBeatMS, newTiming.longestStallMS, newTiming.beats))
        XCTAssertEqual(oldTiming.beats, 0)
        XCTAssertLessThan(newTiming.longestStallMS, oldTiming.firstBeatMS)

        // What stays on the main actor in the alert pass: everything but the series (handed in here),
        // i.e. the 2 h instant-rule reads, the sleep summaries and the small Headache tables.
        UserDefaults.standard.set(true, forKey: HealthAlertDefaults.tempFeverEnabled)
        UserDefaults.standard.set(false, forKey: HeadacheDefaults.enabled)
        await settleMainActor()
        let (_, passTiming) = await underHeartbeat {
            await HealthNotificationCenter().evaluate(store: f.store, session: nil, restingHRDaily: new)
        }
        print(String(format: "BG-ALERTS-TIMING evaluate with the series handed in (main-actor remainder): wall %.1f ms, "
                     + "first beat after %.1f ms, beats %d", passTiming.wallMS, passTiming.firstBeatMS, passTiming.beats))
    }
}
