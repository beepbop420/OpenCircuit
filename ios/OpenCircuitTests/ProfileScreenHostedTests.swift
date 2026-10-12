import SwiftUI
import UIKit
import XCTest
@testable import OpenCircuit

/// The real Profile screen, hosted, in imperial units. Seeding the ft/in fields from the default
/// height lands in `commitHeight()`; an unchanged value must not write `userProfile.heightCm`, or
/// the "default height" flag would clear without the user entering anything.
@MainActor
final class ProfileScreenHostedTests: XCTestCase {
    private let keys = ["userProfile.heightCm", "userProfile.weightKg", "userProfile.weightSetAt",
                        "units.body"]
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        let d = UserDefaults.standard
        for k in keys { if let v = d.object(forKey: k) { saved[k] = v } }
        keys.forEach { d.removeObject(forKey: $0) }
        d.set("imperial", forKey: "units.body")
    }

    override func tearDown() {
        let d = UserDefaults.standard
        keys.forEach { d.removeObject(forKey: $0) }
        for (k, v) in saved { d.set(v, forKey: k) }
        saved = [:]
        super.tearDown()
    }

    private func pump(_ seconds: TimeInterval = 0.6) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func host() -> (UIWindow, UIHostingController<AnyView>) {
        let vc = UIHostingController(rootView: AnyView(NavigationStack { UserProfileSettingsView() }))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 1200))
        window.rootViewController = vc
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene { window.windowScene = scene }
        window.makeKeyAndVisible()
        vc.view.layoutIfNeeded()
        pump(1.5)
        vc.view.layoutIfNeeded()
        return (window, vc)
    }

    private func textFields(in view: UIView) -> [UITextField] {
        (view as? UITextField).map { [$0] } ?? view.subviews.flatMap { textFields(in: $0) }
    }

    func testSeedingFeetAndInchesFromTheDefaultHeightWritesNothing() {
        let (window, vc) = host()
        pump(1.0)
        let fields = textFields(in: vc.view).compactMap(\.placeholder)
        XCTAssertTrue(fields.contains("ft") && fields.contains("in"),
                      "the imperial height fields did not render (placeholders: \(fields))")
        XCTAssertNil(UserDefaults.standard.object(forKey: "userProfile.heightCm"),
                     "seeding the ft/in fields wrote the height")
        XCTAssertTrue(ProfileDefaultsStatus.current().height, "the height stopped reading as a default")
        withExtendedLifetime(window) {}
    }

    /// Control: a real edit through the same screen does write, so the assertion above can fail.
    func testATypedHeightChangeThroughTheScreenWrites() throws {
        let (window, vc) = host()
        let inches = try XCTUnwrap(textFields(in: vc.view).first { $0.placeholder == "in" },
                                   "no inches field")
        // 170 cm seeds as 5 ft 7 in; type 10 in.
        inches.becomeFirstResponder()
        inches.text = "10"
        inches.sendActions(for: .editingChanged)
        inches.sendActions(for: .editingDidEnd)
        inches.resignFirstResponder()
        pump(1.0)
        let written = UserDefaults.standard.object(forKey: "userProfile.heightCm") as? Double
        XCTAssertEqual(try XCTUnwrap(written, "a typed height did not reach userProfile.heightCm"),
                       (5 * 12 + 10) * 2.54, accuracy: 0.01)
        XCTAssertFalse(ProfileDefaultsStatus.current().height)
        withExtendedLifetime(window) {}
    }

    // MARK: Strain sheet wiring

    private func strainLabels(ageIsDefault: Bool) -> [String] {
        AccessibilityTestSupport.enableAutomation()
        let vc = UIHostingController(rootView: AnyView(
            NavigationStack { StrainInfoSheet(reading: nil, ageIsDefault: ageIsDefault) }))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 1200))
        window.rootViewController = vc
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene { window.windowScene = scene }
        window.makeKeyAndVisible()
        vc.view.layoutIfNeeded()
        pump(1.5)
        vc.view.layoutIfNeeded()
        let labels = AccessibilityTestSupport.labels(in: vc.view)
        withExtendedLifetime(window) {}
        return labels
    }

    /// The sheet shows the default-age note when the age is unset and hides it when set: the view
    /// wiring, not just the string constant.
    func testStrainSheetShowsTheDefaultAgeNoteOnlyWhenAgeIsUnset() {
        let unset = strainLabels(ageIsDefault: true)
        XCTAssertTrue(unset.contains { $0.contains("default age of 35") }, "note missing: \(unset)")
        let set = strainLabels(ageIsDefault: false)
        XCTAssertFalse(set.contains { $0.contains("default age of 35") }, "note shown with age set")
        XCTAssertFalse(set.isEmpty, "the sheet rendered nothing, so the absence proves nothing")
    }
}
