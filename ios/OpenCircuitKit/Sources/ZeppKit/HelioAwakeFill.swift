import Foundation
import OpenCircuitKit

// MARK: - The awake time between a strap night's fragments (decision 74)

/// Decision 74 (#278): a joined strap night (decisions 71/73) left the time between its fragments
/// blank, so a wearer lying awake in bed got neither awake time nor time in bed for it. The fill
/// marks that time awake and in bed where the strap was worn: minutes with the strap's own stored
/// heart rate. Minutes with none (strap off, nothing recorded) stay a gap, never filled. The fill is
/// measured data, never asserted time.
///
/// The fill is derived from the STORED heart rate, never a sync's fetched minutes (74b), so every
/// copy of a night derives the same fill; the caller supplies those minutes (`LocalStore`).
extension HelioSleepSelection {

    /// Decision 74a: a run of worn minutes bridges this many minutes or fewer with no heart rate; more
    /// end it. The same rule as an activity block's gap (`activityBlockMaxGapMinutes`, 73a).
    public static let awakeFillMaxHoleMinutes = 5

    /// Decision 74a: `segments` (a strap night over `window`) with the time between consecutive in-bed
    /// fragments filled where `heartRateMinutes` has the strap's heart rate.
    ///
    /// Each gap between two consecutive fragments' `.inBed` spans gets its worn minutes (a minute is
    /// `[t, t + 1 min)`, clipped to the gap), merged into runs that bridge up to `awakeFillMaxHoleMinutes`
    /// missing minutes. Each run is one `.awake` segment and one `.inBed` segment over the same span,
    /// placed before the next fragment's segments. Nothing is filled before the first fragment or
    /// after the last, and a fragment's own segments are never touched.
    ///
    /// Any fill already in `segments` (a stored night filled by an earlier save) is replaced, so the
    /// result depends only on the fragments and `heartRateMinutes`. A night with one fragment (or none,
    /// a row stored before decision 70) is returned unchanged.
    ///
    /// `heartRateMinutes` must already be the strap's own, for time it owns (decision 28): the caller
    /// filters them.
    public static func awakeFilled(_ segments: [SleepSegment], window: DateInterval,
                                   heartRateMinutes: [Date]) -> [SleepSegment] {
        let base = withoutAwakeFill(segments)
        let fragments = inBedSpans(of: base, window: window)
        guard fragments.count > 1 else { return segments }
        let minute: TimeInterval = 60
        let maxHole = TimeInterval(awakeFillMaxHoleMinutes) * minute
        let worn = Set(heartRateMinutes).sorted()
        var out = base
        for (earlier, later) in zip(fragments, fragments.dropFirst()) where later.start > earlier.end {
            let gap = DateInterval(start: earlier.end, end: later.start)
            var runs: [DateInterval] = []
            for t in worn where t < gap.end && t.addingTimeInterval(minute) > gap.start {
                let start = max(t, gap.start), end = min(t.addingTimeInterval(minute), gap.end)
                if let last = runs.last, start.timeIntervalSince(last.end) <= maxHole {
                    runs[runs.count - 1] = DateInterval(start: last.start, end: max(last.end, end))
                } else {
                    runs.append(DateInterval(start: start, end: end))
                }
            }
            for run in runs {
                let at = out.firstIndex { $0.start >= run.end } ?? out.endIndex
                out.insert(contentsOf: [SleepSegment(start: run.start, end: run.end, stage: .inBed),
                                        SleepSegment(start: run.start, end: run.end, stage: .awake)], at: at)
            }
        }
        return out
    }

    /// Decision 74a: the spans of the awake runs `awakeFilled` added to `segments`: an `.inBed` segment
    /// and an `.awake` segment over exactly the same span, with no asleep segment in it. A fragment
    /// never has that shape (a session's night holds a stage that isn't awake, `night(from:now:)`, and an
    /// activity block holds only sleep), so on a night with no fill this is empty.
    public static func awakeFillRuns(in segments: [SleepSegment]) -> [DateInterval] {
        let awake = Set(segments.filter { $0.stage == .awake }.map { DateInterval(start: $0.start, end: $0.end) })
        let asleep = segments.filter { $0.stage != .awake && $0.stage != .inBed }
        return segments.filter { $0.stage == .inBed && $0.end > $0.start }
            .map { DateInterval(start: $0.start, end: $0.end) }
            .filter { run in awake.contains(run) && !asleep.contains { $0.start < run.end && run.start < $0.end } }
    }

    /// `segments` without the awake runs `awakeFilled` added (`awakeFillRuns`): the night as its
    /// fragments describe it. Unchanged for a night with no fill.
    public static func withoutAwakeFill(_ segments: [SleepSegment]) -> [SleepSegment] {
        let runs = Set(awakeFillRuns(in: segments))
        guard !runs.isEmpty else { return segments }
        return segments.filter { segment in
            !((segment.stage == .inBed || segment.stage == .awake) && runs.contains(DateInterval(start: segment.start, end: segment.end)))
        }
    }

    /// Decision 74c: the spans of a strap night's SLEEP fragments: its in-bed spans (`inBedSpans(of:window:)`)
    /// without the awake runs of 74a. The strap-only readers that judge a night's sleep (the skin
    /// temperature gate and verdict, the overnight HRV) take these, so an awake run is never judged as
    /// sleep. On a night with no fill they are exactly `inBedSpans(of:window:)` (decision 71i).
    public static func sleepSpans(of segments: [SleepSegment], window: DateInterval) -> [DateInterval] {
        let runs = Set(awakeFillRuns(in: segments))
        let spans = inBedSpans(of: segments, window: window)
        guard !runs.isEmpty else { return spans }
        let sleep = spans.filter { !runs.contains($0) }
        return sleep.isEmpty ? [window] : sleep
    }
}

extension HelioSleepSelection.Night {
    /// Decision 74c: the night's sleep fragments' spans (`HelioSleepSelection.sleepSpans(of:window:)`).
    public var sleepSpans: [DateInterval] { HelioSleepSelection.sleepSpans(of: segments, window: window) }

    /// Decision 74a: this night with its awake fill from `heartRateMinutes`
    /// (`HelioSleepSelection.awakeFilled`). The window, score and recorded zone are unchanged.
    public func awakeFilled(heartRateMinutes: [Date]) -> HelioSleepSelection.Night {
        HelioSleepSelection.Night(segments: HelioSleepSelection.awakeFilled(segments, window: window,
                                                                            heartRateMinutes: heartRateMinutes),
                                  window: window, strapScore: strapScore, recordedTimeZone: recordedTimeZone)
    }
}
