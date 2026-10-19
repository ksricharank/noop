import XCTest
import WhoopStore
@testable import Strand

/// 261018, the maintainer: Charge "moving subtly up and down — between 92 to 91"; the quick pass
/// should move only the numerators; and fewer full passes during the day.
@MainActor
final class DaytimeRescoreSpacingTests: XCTestCase {

    // MARK: - Routine full-pass spacing

    private let end = 6 * 60 + 30          // the 06:30 sleep-window end
    private let now = 1_000_000.0

    func testInsideTheSleepWindowEverySyncMayRunAFullPass() {
        XCTAssertTrue(RescoreBackgroundScheduler.routineFullPassAllowed(
            minuteOfDay: 2 * 60, windowEndMinute: end, inSleepWindow: true,
            now: now, lastFullPassAt: now - 60))
    }

    /// The morning settle: the night's offloads are still landing, so every sync re-scores.
    func testTheMorningSettleIsNotSpaced() {
        XCTAssertTrue(RescoreBackgroundScheduler.routineFullPassAllowed(
            minuteOfDay: 8 * 60, windowEndMinute: end, inSleepWindow: false,
            now: now, lastFullPassAt: now - 60))
        XCTAssertTrue(RescoreBackgroundScheduler.routineFullPassAllowed(
            minuteOfDay: 9 * 60 + 29, windowEndMinute: end, inSleepWindow: false,
            now: now, lastFullPassAt: now - 60))
    }

    /// After the settle, at most one routine full pass per three hours.
    func testDaytimeFullPassesAreSpacedThreeHours() {
        XCTAssertFalse(RescoreBackgroundScheduler.routineFullPassAllowed(
            minuteOfDay: 14 * 60, windowEndMinute: end, inSleepWindow: false,
            now: now, lastFullPassAt: now - 2 * 3600))
        XCTAssertTrue(RescoreBackgroundScheduler.routineFullPassAllowed(
            minuteOfDay: 14 * 60, windowEndMinute: end, inSleepWindow: false,
            now: now, lastFullPassAt: now - 3 * 3600))
        // Never completed one: allowed.
        XCTAssertTrue(RescoreBackgroundScheduler.routineFullPassAllowed(
            minuteOfDay: 14 * 60, windowEndMinute: end, inSleepWindow: false,
            now: now, lastFullPassAt: nil))
    }

    // MARK: - A settled night is not re-judged by a partial pass

    private func night(sleep: Double = 542, hrv: Double = 46.3, rhr: Int = 57,
                       recovery: Double? = 91) -> DailyMetric {
        DailyMetric(day: "2026-10-18", totalSleepMin: sleep, efficiency: 0.90, deepMin: 120,
                    remMin: 227, lightMin: 195, disturbances: nil, restingHr: rhr, avgHrv: hrv,
                    recovery: recovery, strain: nil, exerciseCount: nil, respRateBpm: 15.0)
    }

    /// The 91 ↔ 92 afternoon: identical night figures, a recovery a point apart from a differently
    /// folded baseline. Not a moved night — the stored Charge stands.
    func testTheSameNightJudgedAgainstAnotherBaselineHasNotMoved() {
        XCTAssertFalse(DailyMetric.nightInputsMoved(night(recovery: 92), from: night(recovery: 91)))
    }

    /// The morning: offloads lengthen the night — moved, so it is refreshed.
    func testALengtheningNightHasMoved() {
        XCTAssertTrue(DailyMetric.nightInputsMoved(night(sleep: 542), from: night(sleep: 504)))
        XCTAssertTrue(DailyMetric.nightInputsMoved(night(hrv: 46.3), from: night(hrv: 45.5)))
        XCTAssertTrue(DailyMetric.nightInputsMoved(night(), from: nil))
    }

    /// A light pass with no stored row writes the numerators and no night — it cannot create today's
    /// Charge or sleep.
    func testALightPassOverNoRowCarriesNoNight() {
        let scored = DailyMetric(day: "2026-10-18", totalSleepMin: 542, efficiency: 0.9, deepMin: 120,
                                 remMin: 227, lightMin: 195, disturbances: nil, restingHr: 57,
                                 avgHrv: 46.3, recovery: 92, strain: 12.4, exerciseCount: 1,
                                 steps: 6904, activeKcalEst: 410)
        let merged = scored.lightPassMerged(over: DailyMetric.blankNight(day: "2026-10-18"))
        XCTAssertNil(merged.recovery)
        XCTAssertNil(merged.totalSleepMin)
        XCTAssertNil(merged.avgHrv)
        XCTAssertEqual(merged.steps, 6904)
        XCTAssertEqual(merged.strain, 12.4)
        XCTAssertEqual(merged.activeKcalEst, 410)
    }
}
