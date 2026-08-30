import XCTest
@testable import StrandAnalytics

/// The deterministic daily targets behind the three-pillar Live Activity card. Pinned because the
/// card prints these numbers with no surrounding prose — `72/85` has to mean the same thing next
/// month — and because the synthesis cites the same figures: the two surfaces disagreeing would be
/// the parity bug this type exists to prevent.
final class DailyTargetsTests: XCTestCase {

    // MARK: - Calm ceiling

    /// Median of the recent nightly RHRs + the stated margin. Median, not mean: one feverish night
    /// must not move the "go breathe" line.
    func testCalmCeilingIsMedianPlusMargin() {
        XCTAssertEqual(DailyTargets.calmCeilingBpm(recentRestingHr: [59, 60, 66, 65, 72]), 65 + 25)
        XCTAssertEqual(DailyTargets.calmCeilingBpm(recentRestingHr: [60, 61, 62]), 61 + 25)
    }

    /// Cold start is honest: fewer than the minimum nights → no ceiling, never a guessed one. Zeros
    /// (no-data nights) do not count toward the minimum.
    func testCalmCeilingNeedsHistory() {
        XCTAssertNil(DailyTargets.calmCeilingBpm(recentRestingHr: []))
        XCTAssertNil(DailyTargets.calmCeilingBpm(recentRestingHr: [60, 62]))
        XCTAssertNil(DailyTargets.calmCeilingBpm(recentRestingHr: [60, 62, 0]))
    }

    /// The clamp holds at both ends — a 38-RHR athlete does not get a 63 ceiling that flags desk
    /// life, and corrupted highs cannot push "calm" past 110.
    func testCalmCeilingClamps() {
        XCTAssertEqual(DailyTargets.calmCeilingBpm(recentRestingHr: [38, 39, 40]), 70)
        XCTAssertEqual(DailyTargets.calmCeilingBpm(recentRestingHr: [120, 130, 140]), 110)
    }

    // MARK: - The charge bands

    /// The bands mirror the coach prompt verbatim: 67+ pushes at p75, 34–66 maintains at the median,
    /// ≤33 recovers at p25, and an unscored morning reads as maintain — neutral, never aggressive.
    func testBandsMatchTheCoachPrescription() {
        XCTAssertEqual(DailyTargets.targetPercentile(charge: 67), 0.75)
        XCTAssertEqual(DailyTargets.targetPercentile(charge: 66), 0.5)
        XCTAssertEqual(DailyTargets.targetPercentile(charge: 34), 0.5)
        XCTAssertEqual(DailyTargets.targetPercentile(charge: 33), 0.25)
        XCTAssertEqual(DailyTargets.targetPercentile(charge: nil), 0.5)
    }

    // MARK: - Calorie target

    /// A push day targets the user's own bigger recent days (p75 of their history), rounded to the
    /// stated granularity — the estimate is HR-only, and 1,187 would claim precision it lacks.
    func testCalorieTargetByBandAndRounding() {
        let history: [Double] = [400, 500, 600, 700, 800]   // p75 = 700, median = 600, p25 = 500
        XCTAssertEqual(DailyTargets.calorieTargetKcal(charge: 80, recentActiveKcal: history), 700)
        XCTAssertEqual(DailyTargets.calorieTargetKcal(charge: 50, recentActiveKcal: history), 600)
        XCTAssertEqual(DailyTargets.calorieTargetKcal(charge: 20, recentActiveKcal: history), 500)
        // Interpolated percentile rounds to 25 kcal: p75 of [400,500,610,700] = 632.5 → 625.
        XCTAssertEqual(DailyTargets.calorieTargetKcal(charge: 80,
                                                      recentActiveKcal: [400, 500, 610, 700]), 625)
    }

    /// Same cold-start honesty as the ceiling: no target until enough usable days, zero-days dropped.
    func testCalorieTargetNeedsHistory() {
        XCTAssertNil(DailyTargets.calorieTargetKcal(charge: 80, recentActiveKcal: [500, 600]))
        XCTAssertNil(DailyTargets.calorieTargetKcal(charge: 80, recentActiveKcal: [500, 600, 0]))
    }

    /// The effort twin follows the same band and history rules, rounded to a whole point.
    func testEffortTargetFollowsTheSameBands() {
        let history: [Double] = [20, 40, 60, 80]
        XCTAssertEqual(DailyTargets.effortTarget(charge: 80, recentEffort: history), 65)   // p75
        XCTAssertEqual(DailyTargets.effortTarget(charge: 50, recentEffort: history), 50)   // median
        XCTAssertNil(DailyTargets.effortTarget(charge: 80, recentEffort: [10, 20]))
    }

    // MARK: - The kcal-per-effort fit (the weight-loss calorie target)

    /// A clean linear history is recovered exactly, and the target prices the effort target on that
    /// line: baseline + slope × target, rounded like every calorie figure.
    func testFitRecoversTheLineAndPricesTheTarget() {
        let history: [(effort: Double, kcal: Double)] = (0...9).map {
            (effort: Double($0), kcal: 1400 + 22 * Double($0))
        }
        let fit = DailyTargets.effortCalorieFit(history: history)
        XCTAssertEqual(fit?.interceptKcal ?? 0, 1400, accuracy: 0.001)
        XCTAssertEqual(fit?.kcalPerEffortPoint ?? 0, 22, accuracy: 0.001)
        // 1400 + 22 × 10 = 1620 → nearest 25 = 1625.
        XCTAssertEqual(DailyTargets.calorieTargetKcal(effortTarget: 10, fit: fit!), 1625)
    }

    /// The fit refuses what it cannot support: too few paired days, a flat week (no effort
    /// variance), or a nonsense negative slope — each falls back to the percentile target instead
    /// of pricing a target on noise.
    func testFitRefusesUnsupportableHistory() {
        XCTAssertNil(DailyTargets.effortCalorieFit(history: [(1, 500), (2, 550), (3, 600)]))
        XCTAssertNil(DailyTargets.effortCalorieFit(
            history: Array(repeating: (effort: 5.0, kcal: 600.0), count: 8)))
        let inverted: [(effort: Double, kcal: Double)] = (0...9).map {
            (effort: Double($0), kcal: 1000 - 20 * Double($0))
        }
        XCTAssertNil(DailyTargets.effortCalorieFit(history: inverted))
    }

    // MARK: - Tonight's sleep need

    /// Need + half the outstanding debt, capped at 90 min — a fortnight's ledger is never scheduled
    /// into one night.
    func testSleepNeedRepaysACappedShareOfDebt() {
        XCTAssertEqual(DailyTargets.sleepNeedTonightMin(needMin: 480, debtBalanceMin: -60), 510)
        XCTAssertEqual(DailyTargets.sleepNeedTonightMin(needMin: 480, debtBalanceMin: -2000), 570)
    }

    /// A surplus never discounts the night below baseline (sleep is not bankable ahead), and a debt
    /// inside the ledger's own deadband is noise, not a prescription.
    func testSleepNeedNeverDropsBelowBaseline() {
        XCTAssertEqual(DailyTargets.sleepNeedTonightMin(needMin: 480, debtBalanceMin: 300), 480)
        XCTAssertEqual(DailyTargets.sleepNeedTonightMin(needMin: 480, debtBalanceMin: -20), 480)
    }
}
