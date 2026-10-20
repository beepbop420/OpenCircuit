import XCTest
@testable import OpenCircuit

/// A background run's budget covers the WHOLE run, not just the capture: the ring's pre-flush, capture
/// and post-capture flush used to add up past the ~30 s app-refresh window, and the strap's wake
/// catch-up left its alert passes no time inside a ~30 s assertion, so iOS expired both.
@MainActor
final class BackgroundRunBudgetTests: XCTestCase {
    func testTheRingCaptureLeavesTheFlushItsReserve() {
        let start = Date(timeIntervalSince1970: 1_000)
        let timeout = RingBackgroundSyncService.defaultTimeout
        XCTAssertEqual(RingBackgroundSyncService.captureBudget(timeout: timeout, runStart: start, now: start),
                       timeout - RingBackgroundSyncService.flushReserve)
        XCTAssertEqual(RingBackgroundSyncService.captureBudget(timeout: timeout, runStart: start,
                                                               now: start.addingTimeInterval(6)),
                       timeout - 6 - RingBackgroundSyncService.flushReserve, "the pre-flush comes out of it")
        XCTAssertEqual(RingBackgroundSyncService.captureBudget(timeout: timeout, runStart: start,
                                                               now: start.addingTimeInterval(40)),
                       RingBackgroundSyncService.minimumCapture, "never below the floor")
        XCTAssertEqual(RingBackgroundSyncService.captureBudget(timeout: RingBackgroundSyncService.processingTimeout,
                                                               runStart: start, now: start),
                       RingBackgroundSyncService.processingTimeout - RingBackgroundSyncService.flushReserve)
    }

    func testTheStrapCatchUpFitsInsideWhatIsLeftOfItsAssertion() {
        XCTAssertEqual(HelioWakePolicy.catchUpTimeout(backgroundTimeRemaining: 30), 26)
        XCTAssertEqual(HelioWakePolicy.catchUpTimeout(backgroundTimeRemaining: 5), HelioWakePolicy.minimumCatchUp)
        XCTAssertEqual(HelioWakePolicy.catchUpTimeout(backgroundTimeRemaining: .greatestFiniteMagnitude),
                       RingBackgroundSyncService.defaultTimeout, "capped at the old fixed budget")
    }
}
