import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import OpenCircuit

/// The Calories card sits in the Today `List`. A `NavigationLink` inside a List row is hoisted to the
/// row, so a tap anywhere on the card would push Profile. These host the card the way Today does.
@MainActor
final class CaloriesCardHostedTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private let keys = ["userProfile.age", "userProfile.weightKg", "userProfile.heightCm", "userProfile.sex"]

    override func setUp() {
        super.setUp()
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        containers.removeAll()
        super.tearDown()
    }

    private func host<V: View>(_ view: V, size: CGSize = CGSize(width: 390, height: 800)) -> (UIWindow, UIHostingController<AnyView>) {
        let vc = UIHostingController(rootView: AnyView(view))
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = vc
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene { window.windowScene = scene }
        window.makeKeyAndVisible()
        vc.view.layoutIfNeeded()
        pump(1.5)
        vc.view.layoutIfNeeded()
        return (window, vc)
    }

    private func pump(_ seconds: TimeInterval = 0.6) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func descendants(of view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private func todayList() throws -> some View {
        let container = try ModelContainer(
            for: Schema([StoredSample.self, StoredDaily.self, StoredSleepSummary.self, StoredStepSample.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(container)
        return NavigationStack {
            List {
                Group {
                    OCCard { CaloriesCardView() }
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
            .listStyle(.plain)
        }
        .modelContainer(container)
    }

    func testCardRowIsNotSelectableWhileDefaultsShow() throws {
        let (window, _) = host(try todayList())
        let cv = try XCTUnwrap(descendants(of: window).compactMap { $0 as? UICollectionView }.first)
        let selectable = cv.delegate?.collectionView?(cv, shouldSelectItemAt: IndexPath(item: 0, section: 0))
        XCTAssertNotEqual(selectable, true, "a link inside the card made the whole row selectable")
    }

    /// A real activation of "Set Up Profile" presents the Profile sheet and does NOT push: the
    /// button is a `Button`, never a `NavigationLink`, so the navigation stack stays at one controller.
    func testSetUpProfileButtonPresentsTheSheetWithoutPushing() throws {
        AccessibilityTestSupport.enableAutomation()
        let (window, vc) = host(try todayList())
        XCTAssertNil(vc.presentedViewController)
        let found = AccessibilityTestSupport.activate(label: "Set Up Profile", in: vc.view)
        XCTAssertTrue(found, "no activatable Set Up Profile element; labels: \(AccessibilityTestSupport.labels(in: vc.view))")
        pump(1.0)
        XCTAssertNotNil(vc.presentedViewController, "activating Set Up Profile did not present the sheet")
        let nav = descendantViewControllers(of: vc).compactMap { $0 as? UINavigationController }.first
        XCTAssertEqual(nav?.viewControllers.count, 1, "Set Up Profile pushed instead of presenting")
        withExtendedLifetime(window) {}
    }

    private func descendantViewControllers(of vc: UIViewController) -> [UIViewController] {
        [vc] + vc.children.flatMap { descendantViewControllers(of: $0) }
    }

    // MARK: Stage legend at the narrowest phone

    func testLegendKeepsLongHourLabelsOnTwoRowsAtNarrowWidth() {
        func legend(_ values: [(String, Int)]) -> some View {
            StageLegendFlow(items: values.map { name, m in
                AnyView(HStack(spacing: 4) {
                    Circle().frame(width: 7, height: 7)
                    Text("\(name) \(StageDuration.label(minutes: m))").font(.caption2)
                })
            })
        }
        func height(_ values: [(String, Int)]) -> CGFloat {
            let vc = UIHostingController(rootView: legend(values))
            return vc.sizeThatFits(in: CGSize(width: 311, height: CGFloat.greatestFiniteMagnitude)).height
        }
        let one = height([("Deep", 17)])
        let a = height([("Deep", 85), ("Light", 232), ("REM", 98), ("Awake", 47)])
        let b = height([("Deep", 71), ("Light", 251), ("REM", 113), ("Awake", 62)])
        print("legend heights @311pt: single=\(one) a=\(a) b=\(b)")
        for h in [a, b] {
            XCTAssertGreaterThanOrEqual(h, one * 2 + 2, "items wrapped inside a single row")
            XCTAssertLessThanOrEqual(h, one * 2 + 6, "more than two rows")
        }
    }
}
