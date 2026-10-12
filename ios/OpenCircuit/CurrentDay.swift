// Follows the local calendar day for views whose `@Query` predicates are built in `init()` (#297).
//
// A predicate built from `startOfDay(for: Date())` is frozen at the day the view was created, so a
// card that stays alive across midnight keeps reading yesterday's rows. `CurrentDayView` hands its
// content the current day start and re-creates the content (`.id`) whenever the day moves: at local
// midnight, on a significant time change or calendar-day notification, on a time-zone change, and
// when the scene becomes active on a different day than the one last shown. The decisions are the
// pure functions in `DayRollover`.

import SwiftUI
import UIKit
import OpenCircuitKit

struct CurrentDayView<Content: View>: View {
    private let content: (Date) -> Content
    @State private var dayStart: Date
    @Environment(\.scenePhase) private var scenePhase

    init(@ViewBuilder content: @escaping (Date) -> Content) {
        self.content = content
        _dayStart = State(initialValue: DayRollover.dayKey(at: Date(), calendar: .current))
    }

    var body: some View {
        content(dayStart)
            .id(dayStart)
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in refresh() }
            .onReceive(NotificationCenter.default.publisher(
                for: UIApplication.significantTimeChangeNotification)) { _ in refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name.NSSystemTimeZoneDidChange)) { _ in refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refresh() }
            }
            .task(id: dayStart) {
                // The notifications above can be missed while suspended, so also wake at the next
                // local midnight while the view is alive.
                let next = DayRollover.nextDayStart(after: dayStart, calendar: .current)
                let wait = next.timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                if !Task.isCancelled { refresh() }
            }
    }

    private func refresh() {
        let cal = Calendar.current
        let now = Date()
        if DayRollover.didChange(from: dayStart, at: now, calendar: cal) {
            dayStart = DayRollover.dayKey(at: now, calendar: cal)
        }
    }
}
