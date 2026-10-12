// Follows the local calendar day for views whose `@Query` predicates are built in `init()` (#297).
//
// A predicate built from `startOfDay(for: Date())` is frozen at the day the view was created, so a
// card that stays alive across midnight keeps reading yesterday's rows. `CurrentDayView` hands its
// content the current day start and re-creates the content (`.id`) whenever the day moves: at local
// midnight, on a significant time change or calendar-day notification, on a time-zone change, and
// when the scene becomes active on a different day than the one last shown. The decisions are the
// pure functions in `DayRollover`.
//
// Re-creating the content discards its `@State`, so only content that holds nothing worth keeping
// (derived caches that recompute from the new queries) may be re-keyed. Content that owns a sheet,
// an alert or an in-progress edit is passed `rekey: false`: it still receives the new day, and its
// `@Query` values update from the new init arguments, but it is not torn down.

import SwiftUI
import UIKit
import OpenCircuitKit

/// The clock and calendar the day follows. Injected by tests; the app uses the system ones.
struct DayClock {
    var now: () -> Date = { Date() }
    var calendar: () -> Calendar = { .current }
    /// Test hooks: `onBuild` fires each time the content is created for a day (so a re-key shows
    /// up), `onDayChange` each time the day the view follows moves.
    var onBuild: ((String, Date) -> Void)?
    var onDayChange: ((String, Date) -> Void)?
}

private struct DayClockKey: EnvironmentKey {
    static let defaultValue = DayClock()
}

extension EnvironmentValues {
    var dayClock: DayClock {
        get { self[DayClockKey.self] }
        set { self[DayClockKey.self] = newValue }
    }
}

extension Notification.Name {
    /// Posted by the app when the day may have moved; the view re-checks the clock. Same path the
    /// system notifications take, exposed so a test can drive it without waiting for midnight.
    static let currentDayMayHaveChanged = Notification.Name("opencircuit.currentDayMayHaveChanged")
}

struct CurrentDayView<Content: View>: View {
    private let name: String
    private let rekey: Bool
    private let content: (Date) -> Content
    @State private var dayStart: Date?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dayClock) private var clock

    init(_ name: String, rekey: Bool = true, @ViewBuilder content: @escaping (Date) -> Content) {
        self.name = name
        self.rekey = rekey
        self.content = content
    }

    private var currentKey: Date { DayRollover.dayKey(at: clock.now(), calendar: clock.calendar()) }

    var body: some View {
        let day = dayStart ?? currentKey
        content(day)
            .onAppear { clock.onBuild?(name, day) }
            .id(rekey ? day : Date.distantPast)
            .onAppear { if dayStart == nil { dayStart = day } }
            .onChange(of: day) { _, new in clock.onDayChange?(name, new) }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in refresh() }
            .onReceive(NotificationCenter.default.publisher(
                for: UIApplication.significantTimeChangeNotification)) { _ in refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name.NSSystemTimeZoneDidChange)) { _ in refresh() }
            .onReceive(NotificationCenter.default.publisher(for: .currentDayMayHaveChanged)) { _ in refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refresh() }
            }
            .task(id: day) {
                // The notifications above can be missed while suspended, so also wake at each local
                // midnight while the view is alive. Re-arms after every wake.
                while !Task.isCancelled {
                    let next = DayRollover.nextDayStart(after: dayStart ?? currentKey,
                                                        calendar: clock.calendar())
                    let wait = next.timeIntervalSince(clock.now())
                    if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                    if Task.isCancelled { return }
                    refresh()
                    // Not yet past the boundary (early wake): look again shortly instead of spinning.
                    if dayStart.map({ $0 < next }) ?? true { try? await Task.sleep(for: .seconds(1)) }
                }
            }
    }

    private func refresh() {
        let cal = clock.calendar()
        let now = clock.now()
        let shown = dayStart ?? DayRollover.dayKey(at: now, calendar: cal)
        if DayRollover.didChange(from: shown, at: now, calendar: cal) {
            dayStart = DayRollover.dayKey(at: now, calendar: cal)
        } else if dayStart == nil {
            dayStart = shown
        }
    }
}
