import XCTest
@testable import OpenCircuit

@MainActor
final class ProfileDefaultsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "ProfileDefaultsTests"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    // MARK: Defaults helper

    func testEveryFieldIsADefaultUntilItsKeyIsWritten() {
        let status = ProfileDefaultsStatus.current(defaults: defaults)
        XCTAssertEqual(status, ProfileDefaultsStatus(age: true, weight: true, height: true, sex: true))
        XCTAssertTrue(status.anyDefault)
        XCTAssertEqual(status.defaultBMRInputs, ["age", "weight", "height", "sex"])
        // Display only: reading must not write a key.
        XCTAssertNil(defaults.object(forKey: "userProfile.age"))
    }

    func testAgeSetToThirtyFiveIsNotADefault() {
        defaults.set(35, forKey: "userProfile.age")
        XCTAssertFalse(ProfileDefaultsStatus.current(defaults: defaults).age)
    }

    func testAgreesWithTheProfileAgeRow() {
        XCTAssertEqual(ProfileDefaultsStatus.current(defaults: defaults).age,
                       UserProfileSettingsView.ageRowValue(age: 35, defaults: defaults) == "Not set")
        defaults.set(35, forKey: "userProfile.age")
        XCTAssertEqual(ProfileDefaultsStatus.current(defaults: defaults).age,
                       UserProfileSettingsView.ageRowValue(age: 35, defaults: defaults) == "Not set")
    }

    func testFullProfileHasNoDefaults() {
        defaults.set(41, forKey: "userProfile.age")
        defaults.set(70.0, forKey: "userProfile.weightKg")
        defaults.set(170.0, forKey: "userProfile.heightCm")
        defaults.set("male", forKey: "userProfile.sex")
        let status = ProfileDefaultsStatus.current(defaults: defaults)
        XCTAssertFalse(status.anyDefault)
        XCTAssertEqual(status.defaultBMRInputs, [])
    }

    func testHealthBodyMassCountsAsAWeightSource() {
        defaults.set(64.0, forKey: "userProfile.weightKg.health")
        defaults.set(1_700_000_000.0, forKey: "userProfile.weightKg.health.at")
        XCTAssertFalse(ProfileDefaultsStatus.current(defaults: defaults).weight)
    }

    // MARK: Calories line

    func testLineIsUnchangedWhenTheProfileIsSet() {
        let none = ProfileDefaultsStatus(age: false, weight: false, height: false, sex: false)
        XCTAssertEqual(CaloriesReferenceLine.text(bmr: 1700, maxHR: 180, age: 40, status: none),
                       "BMR 1700 kcal/day · est. max HR 180 bpm (220 − age)")
    }

    func testLineNamesTheDefaultInputs() {
        let s = ProfileDefaultsStatus(age: true, weight: false, height: true, sex: false)
        XCTAssertEqual(CaloriesReferenceLine.text(bmr: 1700, maxHR: 185, age: 35, status: s),
                       "BMR 1700 kcal/day (default age and height) · est. max HR 185 bpm (220 − default age 35)")
    }

    func testLineFlagsOnlyBMRWhenAgeIsSetButWeightIsNot() {
        let s = ProfileDefaultsStatus(age: false, weight: true, height: false, sex: false)
        XCTAssertEqual(CaloriesReferenceLine.text(bmr: 1700, maxHR: 180, age: 40, status: s),
                       "BMR 1700 kcal/day (default weight) · est. max HR 180 bpm (220 − age)")
    }

    func testListJoinsNaturally() {
        XCTAssertEqual(CaloriesReferenceLine.list(["age", "weight", "sex"]), "age, weight and sex")
    }

    func testSexAloneBeingUnsetCountsAsADefault() {
        defaults.set(41, forKey: "userProfile.age")
        defaults.set(70.0, forKey: "userProfile.weightKg")
        defaults.set(170.0, forKey: "userProfile.heightCm")
        let status = ProfileDefaultsStatus.current(defaults: defaults)
        XCTAssertEqual(status, ProfileDefaultsStatus(age: false, weight: false, height: false, sex: true))
        XCTAssertTrue(status.anyDefault)
        XCTAssertTrue(CaloriesReferenceLine.text(bmr: 1700, maxHR: 179, age: 41, status: status)
            .contains("(default sex)"))
    }

    // MARK: Imperial height seeding

    func testSeedingFeetAndInchesFromTheDefaultHeightWritesNothing() {
        // 170 cm seeds as 5 ft 7 in; committing that unchanged must not store a height.
        XCTAssertNil(UserProfileSettingsView.heightCmToWrite(feet: 5, inches: 7, currentCm: 170))
        XCTAssertNil(defaults.object(forKey: "userProfile.heightCm"))
        XCTAssertTrue(ProfileDefaultsStatus.current(defaults: defaults).height)
    }

    func testARealHeightChangeStillWrites() throws {
        let cm = try XCTUnwrap(UserProfileSettingsView.heightCmToWrite(feet: 5, inches: 10, currentCm: 170))
        XCTAssertEqual(cm, 70 * 2.54, accuracy: 0.001)
    }

    // MARK: Strain sheet

    func testStrainSheetDisclosesDefaultAge() {
        XCTAssertTrue(StrainInfoSheet.defaultAgeNote.contains("default age of 35"))
        XCTAssertTrue(ProfileDefaultsStatus.current(defaults: defaults).age)
    }

    // MARK: Stage durations

    func testStageDurationLabels() {
        // Same form as the sleep headline: "8h 0m", not "8h".
        let expected = [0: "0m", 59: "59m", 60: "1h 0m", 89: "1h 29m", 120: "2h 0m", 149: "2h 29m"]
        for (minutes, label) in expected {
            XCTAssertEqual(StageDuration.label(minutes: minutes), label, "\(minutes)")
        }
        XCTAssertEqual(StageDuration.label(minutes: -5), "0m")
    }

    func testStageDurationSpokenForm() {
        XCTAssertEqual(StageDuration.spoken(minutes: 1), "1 minute")
        XCTAssertEqual(StageDuration.spoken(minutes: 59), "59 minutes")
        XCTAssertEqual(StageDuration.spoken(minutes: 60), "1 hour")
        XCTAssertEqual(StageDuration.spoken(minutes: 89), "1 hour 29 minutes")
        XCTAssertEqual(StageDuration.spoken(minutes: 120), "2 hours")
    }
}
