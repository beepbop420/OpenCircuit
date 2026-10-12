// "What day is it" decisions for views that read a single calendar day (#297).
//
// A SwiftUI view that builds its `@Query` predicates in `init()` freezes the day it was created
// on. These pure functions say which day a view should be showing and when to look again, so the
// app layer only has to feed them a clock and a calendar.

import Foundation

public enum DayRollover {

    /// The key for the local calendar day containing `now`: its start of day.
    public static func dayKey(at now: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: now)
    }

    /// The start of the following local day. Honours DST: on a 23 or 25 hour day this is still the
    /// next day's start, not `now + 24h`. Where DST skips midnight a day starts at 01:00; stepping
    /// a day from a 01:00 start lands on 01:00 of the next day, so the result is re-snapped to the
    /// start of the day it lands in.
    public static func nextDayStart(after now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        guard let stepped = calendar.date(byAdding: .day, value: 1, to: today) else {
            return today.addingTimeInterval(86_400)
        }
        return calendar.startOfDay(for: stepped)
    }

    /// True when the day `now` falls in is not the day the view last showed. Compares the day KEY,
    /// not the elapsed time, so a foreground 25 hours later on the same calendar day (a DST fall
    /// back) is no change and a foreground one minute after midnight is. A time-zone change moves
    /// the key too, because `calendar` carries the zone in force now.
    public static func didChange(from lastKey: Date, at now: Date, calendar: Calendar) -> Bool {
        dayKey(at: now, calendar: calendar) != lastKey
    }
}
