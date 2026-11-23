import XCTest
import WhoopStore
@testable import Strand

/// The RE-SCORE POLICY (261018 — documented on `RescoreBackgroundScheduler`). The maintainer's
/// rule: the quick pass moves only the numerators and compares the night against the stored one;
/// a full pass runs only when they differ (or a debt is owed, or inside the sleep window).
@MainActor
final class RescorePolicyTests: XCTestCase {

    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: RescoreBackgroundScheduler.nightMovedPendingKey)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: RescoreBackgroundScheduler.nightMovedPendingKey)
        UserDefaults.standard.removeObject(forKey: RescoreBackgroundScheduler.lastFullPassCompletedAtKey)
    }

    // MARK: - When a routine trigger runs a full pass

    /// The daytime default: the quick pass found the stored nights current — no full pass.
    func testAQuietDaytimeSyncRunsNoFullPass() {
        XCTAssertFalse(RescoreBackgroundScheduler.routineFullPassWanted(
            inSleepWindow: false, owed: false, nightMovedPending: false))
    }

    /// The morning night landing, a late sync, a nap: the quick pass saw the night move.
    func testAMovedNightRunsAFullPass() {
        XCTAssertTrue(RescoreBackgroundScheduler.routineFullPassWanted(
            inSleepWindow: false, owed: false, nightMovedPending: true))
    }

    /// An interrupted earlier pass leaves a debt — the next sync tries again, no timer.
    func testAnOwedDebtRunsAFullPass() {
        XCTAssertTrue(RescoreBackgroundScheduler.routineFullPassWanted(
            inSleepWindow: false, owed: true, nightMovedPending: false))
    }

    /// Inside the sleep window the full pass's own deferral policy decides (it defers to the window's
    /// end, which is what schedules the morning's full pass).
    func testInsideTheSleepWindowTheFullPassPolicyDecides() {
        XCTAssertTrue(RescoreBackgroundScheduler.routineFullPassWanted(
            inSleepWindow: true, owed: false, nightMovedPending: false))
    }

    /// The flag is raised by the quick pass and served by a completed full pass.
    func testACompletedFullPassServesTheRequest() {
        RescoreBackgroundScheduler.markNightMoved()
        XCTAssertTrue(RescoreBackgroundScheduler.nightMovedPending)
        RescoreBackgroundScheduler.noteFullPassCompleted()
        XCTAssertFalse(RescoreBackgroundScheduler.nightMovedPending)
    }

    // MARK: - "Did the night move?"

    private func night(sleep: Double = 542, hrv: Double = 46.3, rhr: Int = 57,
                       recovery: Double? = 91) -> DailyMetric {
        DailyMetric(day: "2026-10-18", totalSleepMin: sleep, efficiency: 0.90, deepMin: 120,
                    remMin: 227, lightMin: 195, disturbances: nil, restingHr: rhr, avgHrv: hrv,
                    recovery: recovery, strain: nil, exerciseCount: nil, respRateBpm: 15.0)
    }

    /// The 91 ↔ 92 afternoon: identical night figures, Charge a point apart from a differently folded
    /// baseline. Charge is not a night input — not moved.
    func testTheSameNightJudgedAgainstAnotherBaselineHasNotMoved() {
        XCTAssertFalse(DailyMetric.nightInputsMoved(night(recovery: 92), from: night(recovery: 91)))
    }

    func testALengtheningNightHasMoved() {
        XCTAssertTrue(DailyMetric.nightInputsMoved(night(sleep: 542), from: night(sleep: 504)))
        XCTAssertTrue(DailyMetric.nightInputsMoved(night(hrv: 46.3), from: night(hrv: 45.5)))
    }

    /// No stored row compares against a blank night: a night only the fresh score has has moved; a
    /// morning before the night has landed (blank on both sides) has not.
    func testNoStoredRowComparesAgainstABlankNight() {
        XCTAssertTrue(DailyMetric.nightInputsMoved(night(), from: nil))
        XCTAssertFalse(DailyMetric.nightInputsMoved(DailyMetric.blankNight(day: "2026-10-18"), from: nil))
    }

    /// A light pass over no row writes the numerators and no night.
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
