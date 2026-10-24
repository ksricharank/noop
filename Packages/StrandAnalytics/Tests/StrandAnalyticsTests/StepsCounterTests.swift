import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Unit tests for the shared windowed step kernel `StepsCounter.stepsInWindow` (#398). The same
/// wrap-aware positive-delta math the daily total uses (see StepsDailyTests), but exercised directly and
/// order-independently so a manual-workout window can reuse it. Returns the RAW motion-tick total (before
/// the caller's `stepTicksPerStep` calibration). Mirrors the Android StepsCounterTest vectors value-for-value.
final class StepsCounterTests: XCTestCase {

    private func step(_ ts: Int, _ counter: Int, _ activityClass: Int? = nil) -> StepSample {
        StepSample(ts: ts, counter: counter, activityClass: activityClass)
    }

    func testSumsPositiveConsecutiveDeltas() {
        // counters 100 -> 150 -> 220 => deltas 50 + 70 = 120
        XCTAssertEqual(StepsCounter.stepsInWindow([step(0, 100), step(60, 150), step(120, 220)]), 120)
    }

    func testSortsUnorderedInput() {
        // Same three samples shuffled — the kernel sorts by ts, so the result is identical (120).
        XCTAssertEqual(StepsCounter.stepsInWindow([step(120, 220), step(0, 100), step(60, 150)]), 120)
    }

    func testHandlesU16Wraparound() {
        // 65500 -> 20 wraps: (20 - 65500) & 0xFFFF = 56, a small real increment; then 20 -> 80 => 60.
        XCTAssertEqual(StepsCounter.stepsInWindow([step(0, 65_500), step(60, 20), step(120, 80)]), 116)
    }

    func testFewerThanTwoSamplesIsNil() {
        XCTAssertNil(StepsCounter.stepsInWindow([]))
        XCTAssertNil(StepsCounter.stepsInWindow([step(0, 100)]))
    }

    func testNoForwardMovementIsNil() {
        // Flat counter across the window => no positive delta => nil (not 0).
        XCTAssertNil(StepsCounter.stepsInWindow([step(0, 500), step(60, 500), step(120, 500)]))
    }

    func testDropsBigGapDeltaAsBoundary() {
        // A jump >= 512 (sync-gap / reboot boundary) is dropped; the real 40 + 30 survive.
        // 100 -> 140 (=40) -> 5000 (=4860, dropped) -> 5030 (=30) => 70.
        XCTAssertEqual(StepsCounter.stepsInWindow(
            [step(0, 100), step(60, 140), step(120, 5_000), step(180, 5_030)]), 70)
    }

    func testMaxStepDeltaBoundaryIsExclusive() {
        // Exactly maxStepDelta (512) is dropped; 511 counts.
        XCTAssertEqual(StepsCounter.stepsInWindow([step(0, 0), step(128, 512)]), nil)   // absolute guard
        XCTAssertEqual(StepsCounter.stepsInWindow([step(0, 0), step(128, 511)]), 511)
    }

    func testRejectsPhysicallyImpossibleOneSecondSpikeButAllowsSameTicksAcrossTime() {
        XCTAssertNil(StepsCounter.stepsInWindow([step(0, 100), step(1, 107)]))
        XCTAssertEqual(StepsCounter.stepsInWindow([step(0, 100), step(2, 107)]), 7)
        XCTAssertEqual(StepsCounter.stepsInWindow([step(0, 100), step(1, 104)]), 4)
    }

    func testClassedStreamCountsOnlyWalkAndRunDeltas() {
        // Attribute each counter delta to the later sample, matching the strap's per-record class.
        // still: +10 ignored; walk: +20; run: +15; unknown: +25 ignored => 35 locomotion ticks.
        XCTAssertEqual(StepsCounter.stepsInWindow([
            step(0, 100, 0),
            step(10, 110, 0),
            step(20, 130, 1),
            step(30, 145, 2),
            step(40, 170, nil),
        ]), 35)
    }

    func testLegacyUnclassedStreamKeepsCounterFallback() {
        // Rows written before activityClass existed must retain their historical estimate.
        XCTAssertEqual(StepsCounter.stepsInWindow([
            step(0, 100), step(10, 140), step(20, 170),
        ]), 70)
    }
}

/// `lastMovementTs` (260924): the coach's sedentary read anchors on the most recent retained
/// locomotion increment, under the same gates as `stepsInWindow`.
final class StepsCounterLastMovementTests: XCTestCase {

    private func s(_ ts: Int, _ counter: Int, _ cls: Int? = nil) -> StepSample {
        StepSample(ts: ts, counter: counter, activityClass: cls)
    }

    /// The newest pair with a real burst wins; a later one-tick blip (wrist noise, under minTicks)
    /// does not move the anchor.
    func testNewestRetainedBurstWinsAndBlipsDoNot() {
        let samples = [s(100, 0), s(160, 40), s(220, 40), s(280, 41), s(340, 41)]
        XCTAssertEqual(StepsCounter.lastMovementTs(samples), 160)
    }

    /// The u16 counter wraps; the wrap-aware delta still finds the movement.
    func testWrapAwareDeltaStillCounts() {
        let samples = [s(100, 0xFFF0), s(160, 20)]   // +48 across the wrap
        XCTAssertEqual(StepsCounter.lastMovementTs(samples), 160)
    }

    /// With activity classes present, only walk/run increments count — a classed non-locomotion
    /// burst (e.g. fidgeting classed 0) is not movement.
    func testClassedNonLocomotionIsNotMovement() {
        let samples = [s(100, 0, 1), s(160, 40, 1), s(220, 90, 0)]
        XCTAssertEqual(StepsCounter.lastMovementTs(samples), 160)
    }

    /// No retained movement, or too few samples, says nothing.
    func testQuietWindowSaysNothing() {
        XCTAssertNil(StepsCounter.lastMovementTs([s(100, 5), s(160, 5), s(220, 6)]))
        XCTAssertNil(StepsCounter.lastMovementTs([s(100, 5)]))
        XCTAssertNil(StepsCounter.lastMovementTs([]))
    }
}
