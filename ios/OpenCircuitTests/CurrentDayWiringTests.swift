import SwiftData
import SwiftUI
import UIKit
import XCTest
import OpenCircuitKit
@testable import OpenCircuit

/// The day-rollover WIRING (#297): the views are built for the injected day, rebuild when the
/// injected clock crosses midnight, and state that must survive a day change survives it.
/// Synthetic dates; fixed UTC calendar.
@MainActor
final class CurrentDayWiringTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 5, day: d, hour: h, minute: m))!
    }

    private final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private final class Builds {
        var events: [(String, Date)] = []
        func days(_ name: String) -> [Date] { events.filter { $0.0 == name }.map(\.1) }
    }

    private func spin(_ seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private let changes = Builds()

    private func host<V: View>(_ root: V, clock: Clock, builds: Builds) -> (UIWindow, UIHostingController<AnyView>) {
        let dayClock = DayClock(now: { clock.now }, calendar: { self.cal },
                                onBuild: { builds.events.append(($0, $1)) },
                                onDayChange: { self.changes.events.append(($0, $1)) })
        let vc = UIHostingController(rootView: AnyView(root.environment(\.dayClock, dayClock)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = vc
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene { window.windowScene = scene }
        window.makeKeyAndVisible()
        vc.view.layoutIfNeeded()
        spin()
        vc.view.layoutIfNeeded()
        return (window, vc)
    }

    private func crossMidnight(_ clock: Clock, to date: Date) {
        clock.now = date
        NotificationCenter.default.post(name: .currentDayMayHaveChanged, object: nil)
        spin()
    }

    // MARK: Generic wrapper

    func testContentIsRebuiltForTheNewDayAfterMidnight() {
        let clock = Clock(at(4, 23, 50)), builds = Builds()
        let seen = Builds()
        let (window, _) = host(
            CurrentDayView("probe") { day in
                Color.clear.onAppear { seen.events.append(("content", day)) }
            }, clock: clock, builds: builds)
        XCTAssertEqual(seen.days("content"), [at(4, 0)])
        crossMidnight(clock, to: at(5, 0, 5))
        XCTAssertEqual(seen.days("content").last, at(5, 0))
        XCTAssertEqual(builds.days("probe"), [at(4, 0), at(5, 0)])
        XCTAssertEqual(changes.days("probe"), [at(5, 0)])
        withExtendedLifetime(window) {}
    }

    func testSameDayRefreshDoesNotRebuild() {
        let clock = Clock(at(4, 9)), builds = Builds()
        let (window, _) = host(CurrentDayView("probe") { _ in Color.clear }, clock: clock, builds: builds)
        crossMidnight(clock, to: at(4, 21))
        XCTAssertEqual(builds.days("probe"), [at(4, 0)])
        XCTAssertEqual(changes.days("probe"), [])
        withExtendedLifetime(window) {}
    }

    /// `DraftSetter` holds @State standing in for an open sheet or an in-progress draft.
    private struct DraftHolder: View {
        let rekey: Bool
        let report: (String) -> Void
        let setter: (@escaping () -> Void) -> Void
        var body: some View {
            CurrentDayView("draft", rekey: rekey) { _ in
                DraftSetter(report: report, setter: setter)
            }
        }
    }

    private struct DraftSetter: View {
        @State private var text = "initial"
        let report: (String) -> Void
        let setter: (@escaping () -> Void) -> Void
        var body: some View {
            Color.clear
                .onAppear { setter { text = "edited" }; report(text) }
        }
    }

    func testNonRekeyedContentKeepsItsStateAcrossADayChange() {
        let clock = Clock(at(4, 23, 50)), builds = Builds()
        var reports: [String] = []
        var edit: (() -> Void)?
        let (window, _) = host(DraftHolder(rekey: false, report: { reports.append($0) },
                                           setter: { edit = $0 }), clock: clock, builds: builds)
        edit?()
        spin(0.1)
        crossMidnight(clock, to: at(5, 0, 5))
        XCTAssertEqual(changes.days("draft"), [at(5, 0)], "the day still moved")
        XCTAssertEqual(builds.days("draft"), [at(4, 0)], "without rebuilding the content")
        XCTAssertEqual(reports, ["initial"], "content was not rebuilt, so onAppear did not fire again")
        withExtendedLifetime(window) {}
    }

    func testRekeyedContentIsRebuiltAcrossADayChange() {
        let clock = Clock(at(4, 23, 50)), builds = Builds()
        var reports: [String] = []
        var edit: (() -> Void)?
        let (window, _) = host(DraftHolder(rekey: true, report: { reports.append($0) },
                                           setter: { edit = $0 }), clock: clock, builds: builds)
        edit?()
        spin(0.1)
        crossMidnight(clock, to: at(5, 0, 5))
        XCTAssertEqual(reports, ["initial", "initial"], "re-keyed content starts again from fresh state")
        withExtendedLifetime(window) {}
    }

    // MARK: The real cards

    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: StoredSample.self, StoredCursor.self, StoredSleepSummary.self, StoredDaily.self,
            StoredNap.self, StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
            StoredHeadacheEntry.self, StoredHeadacheRisk.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    func testGoalsAndCaloriesCardsAreBuiltForTheInjectedDayAndFollowIt() throws {
        let clock = Clock(at(4, 23, 55)), builds = Builds()
        let c = try container()
        let (window, _) = host(
            VStack {
                GoalsCardView()
                CaloriesCardView()
            }.modelContainer(c), clock: clock, builds: builds)
        XCTAssertEqual(builds.days("goals"), [at(4, 0)])
        XCTAssertEqual(builds.days("calories"), [at(4, 0)])
        crossMidnight(clock, to: at(5, 0, 2))
        XCTAssertEqual(builds.days("goals"), [at(4, 0), at(5, 0)])
        XCTAssertEqual(builds.days("calories"), [at(4, 0), at(5, 0)])
        withExtendedLifetime(window) {}
    }

    /// The Today row the card sits in, so activation behaves as in the app.
    private func todayList(_ container: ModelContainer) -> some View {
        NavigationStack {
            List {
                Group { OCCard { CaloriesCardView() } }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
        }
        .modelContainer(container)
    }

    /// Opens a Calories-card sheet with a REAL activation of its button, crosses midnight, and
    /// asserts it is the very same presentation (`===`, not merely "something is presented": a sheet
    /// whose state was rebuilt under the new key re-presents as a different controller).
    private func assertSheetSurvivesTheDayChange(opening label: String) throws {
        UserDefaults.standard.removeObject(forKey: "userProfile.age")  // defaults present: the button shows
        AccessibilityTestSupport.enableAutomation()
        let clock = Clock(at(4, 23, 55)), builds = Builds()
        let (window, vc) = host(todayList(try container()), clock: clock, builds: builds)
        spin(0.5)
        XCTAssertTrue(AccessibilityTestSupport.activate(label: label, in: vc.view),
                      "no activatable \(label) element; labels: \(AccessibilityTestSupport.labels(in: vc.view))")
        spin(1.0)
        let sheetBefore = try XCTUnwrap(vc.presentedViewController, "\(label) did not present a sheet")
        crossMidnight(clock, to: at(5, 0, 2))
        spin(1.0)
        XCTAssertEqual(changes.days("calories"), [at(5, 0)], "the day moved")
        XCTAssertEqual(builds.days("calories"), [at(4, 0), at(5, 0)], "and the body was rebuilt")
        XCTAssertTrue(vc.presentedViewController === sheetBefore,
                      "a day change dismissed or re-presented the sheet opened by \(label)")
        withExtendedLifetime(window) {}
    }

    /// The Profile sheet lives on the wrapper, outside the re-keyed content, so a day change must
    /// neither dismiss it nor lose it (the user may be mid-edit).
    func testProfileSheetStaysPresentedWhileTheCaloriesDayMoves() throws {
        try assertSheetSurvivesTheDayChange(opening: "Set Up Profile")
    }

    func testEstimateInfoSheetStaysPresentedWhileTheCaloriesDayMoves() throws {
        try assertSheetSurvivesTheDayChange(opening: "How These Are Estimated")
    }

    func testHeadacheSignalsFollowsTheDayWithoutBeingRekeyed() throws {
        let clock = Clock(at(4, 23, 55)), builds = Builds()
        let c = try container()
        let (window, _) = host(NavigationStack { HeadacheSignalsView() }.modelContainer(c),
                               clock: clock, builds: builds)
        crossMidnight(clock, to: at(5, 0, 2))
        XCTAssertEqual(changes.days("headacheSignals"), [at(5, 0)])
        XCTAssertEqual(builds.days("headacheSignals"), [at(4, 0)], "the screen is not torn down")
        withExtendedLifetime(window) {}
    }
}
