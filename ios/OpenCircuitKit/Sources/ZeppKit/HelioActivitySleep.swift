import Foundation
import OpenCircuitKit

// MARK: - Activity sleep blocks (decision 73, #278)

/// Decision 73: the strap writes one `0x48` session record per night and leaves a later sleep of that
/// night only in its per-minute activity data (`0x01` minutes of kind `0x78`, ZEPP_PROTOCOL.md §6.5,
/// 🟡 one night). These turn those minutes into sleeps a session's night can join. v1 uses a block only
/// when it joins a night built from a `0x48` session (73c); a block that would stand alone is counted,
/// never stored.
extension HelioSleepSelection {

    /// Decision 73a: non-sleep minutes inside a run, this many or fewer, are an awake gap of the block;
    /// more end it.
    public static let activityBlockMaxGapMinutes = 5

    /// Decision 73d: a block whose last sleep minute is less than this before the newest activity
    /// minute of the sync may still be going on, so it is not used until a later sync.
    public static let activityBlockSettleTime: TimeInterval = 20 * 60

    /// Decision 73b: a block's sleep minutes are generic sleep, the stage `stage(for:)` gives a stage
    /// byte it doesn't name (the byte itself plays no part).
    public static let activityBlockStage = stage(for: .other(0))

    /// Decision 73a/73b: the activity sleep blocks in one sync's activity `minutes`, oldest first, each as
    /// a strap sleep `Night`.
    ///
    /// A block is a maximal run of kind-sleep minutes outside every staged session's in-bed span
    /// (`sessions`, each session's own night from `night(from:now:)`); a run crosses no in-bed span.
    /// Up to `activityBlockMaxGapMinutes` non-sleep (or missing) minutes inside a run are an awake gap and
    /// stay a gap. A run shorter than `minNapLength` (first sleep minute … last + 1 min) is no block, and
    /// neither is one still in progress (73d), longer than `maxNightLength`, or ending more than an hour
    /// past `now` (as `night(from:now:)`).
    ///
    /// Each block has one `.inBed` segment over the block, then its sleep minutes as stage segments
    /// (consecutive minutes merged) with `activityBlockStage`, no strap score, and the recorded zone of
    /// the staged session nearest to it (the one it can join; nil without one). Measured data from the
    /// strap: no minute is filled in.
    public static func activityBlocks(from minutes: [ZeppActivityMinute], sessions: [Night], now: Date) -> [Night] {
        guard let newest = minutes.map(\.time).max() else { return [] }
        let minute: TimeInterval = 60
        let spans = sessions.flatMap(\.inBedSpans)
        func inBed(_ t: Date) -> Bool { spans.contains { $0.start <= t && t < $0.end } }
        let sleepTimes = Set(minutes.filter { $0.kind == ZeppActivityMinute.kindSleep }.map(\.time))
            .filter { !inBed($0) }
            .sorted()
        var runs: [[Date]] = []
        for t in sleepTimes {
            if let previous = runs.last?.last,
               t.timeIntervalSince(previous) <= TimeInterval(activityBlockMaxGapMinutes + 1) * minute,
               !spans.contains(where: { $0.start < t && previous.addingTimeInterval(minute) < $0.end }) {
                runs[runs.count - 1].append(t)
            } else {
                runs.append([t])
            }
        }
        return runs.compactMap { run -> Night? in
            guard let first = run.first, let last = run.last else { return nil }
            let window = DateInterval(start: first, end: last.addingTimeInterval(minute))
            guard window.duration >= minNapLength, window.duration <= maxNightLength,
                  newest.timeIntervalSince(last) >= activityBlockSettleTime,
                  window.end <= now.addingTimeInterval(3600) else { return nil }
            var stages: [SleepSegment] = []
            for t in run {
                if let previous = stages.last, previous.end == t {
                    stages[stages.count - 1] = SleepSegment(start: previous.start, end: t.addingTimeInterval(minute), stage: previous.stage)
                } else {
                    stages.append(SleepSegment(start: t, end: t.addingTimeInterval(minute), stage: activityBlockStage))
                }
            }
            let zone = sessions.min { gap($0.window, window) < gap($1.window, window) }?.recordedTimeZone
            return Night(segments: [SleepSegment(start: window.start, end: window.end, stage: .inBed)] + stages,
                         window: window, strapScore: nil, recordedTimeZone: zone)
        }
    }

    /// What `nights(sessions:activityBlocks:)` made of a sync's sleeps.
    public struct ActivityJoin: Equatable {
        /// The nights, oldest first: `stitch` over the sessions and the blocks, keeping only the nights
        /// that hold a session.
        public var nights: [Night]
        /// The blocks that joined a session's night (73c).
        public var joinedBlocks: Int
        /// The blocks that would stand alone, used nowhere (73c).
        public var aloneBlocks: Int
    }

    /// Decision 73c: the nights of a sync's (owned) session sleeps and (owned) activity blocks. They are
    /// stitched together by the one rule (`stitch`: 28f's 60 minutes, 71b's overnight sleeps of one
    /// night key), and a night is kept only when it holds a session; a block that stands alone, or with
    /// other blocks only, is dropped. Without blocks this is `stitch(sessions)`, unchanged.
    public static func nights(sessions: [Night], activityBlocks blocks: [Night]) -> ActivityJoin {
        guard !blocks.isEmpty else { return ActivityJoin(nights: stitch(sessions), joinedBlocks: 0, aloneBlocks: 0) }
        func holds(_ night: Night, _ sleep: Night) -> Bool {
            let start = stageSpan(of: sleep).start
            return night.window.start <= start && start < night.window.end
        }
        let kept = stitch(sessions + blocks).filter { night in sessions.contains { holds(night, $0) } }
        let joined = blocks.filter { block in kept.contains { holds($0, block) } }.count
        return ActivityJoin(nights: kept, joinedBlocks: joined, aloneBlocks: blocks.count - joined)
    }
}
