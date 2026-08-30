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

    // MARK: - Effort target (readiness ladder)

    /// The ladder over the maintain band (10–14 of 21): rundown prescribes BELOW the band, strained
    /// its floor, balanced (and insufficient) the midpoint, primed just under the top. History plays
    /// no part — the target is the body's state, by explicit design.
    func testEffortLadderOverTheMaintainBand() {
        let band = 10...14
        XCTAssertEqual(DailyTargets.effortTarget21(band: band, readiness: .rundown, restScore: nil), 7)
        XCTAssertEqual(DailyTargets.effortTarget21(band: band, readiness: .strained, restScore: nil), 10)
        XCTAssertEqual(DailyTargets.effortTarget21(band: band, readiness: .balanced, restScore: nil), 12)
        XCTAssertEqual(DailyTargets.effortTarget21(band: band, readiness: .insufficient, restScore: nil), 12)
        XCTAssertEqual(DailyTargets.effortTarget21(band: band, readiness: .primed, restScore: nil), 13)
    }

    /// Rest shifts the ladder one notch: a poor night drags a balanced read to the band floor, an
    /// excellent one lifts it toward primed — and the shifts clamp at the ladder's ends.
    func testRestShiftsTheLadderOneNotch() {
        let band = 10...14
        XCTAssertEqual(DailyTargets.effortTarget21(band: band, readiness: .balanced, restScore: 40), 10)
        XCTAssertEqual(DailyTargets.effortTarget21(band: band, readiness: .balanced, restScore: 90), 13)
        XCTAssertEqual(DailyTargets.effortTarget21(band: band, readiness: .rundown, restScore: 40), 7)
        XCTAssertEqual(DailyTargets.effortTarget21(band: band, readiness: .primed, restScore: 90), 13)
    }

    /// The recover band's below-band notch floors at the stated minimum — a prescription of 1 of 21
    /// would just be noise dressed as a target.
    func testTheBelowBandNotchFloors() {
        XCTAssertEqual(DailyTargets.effortTarget21(band: 4...10, readiness: .rundown, restScore: nil), 2)
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

    /// Tonight's need composes the body's day: base (p75 of the user's nights) + the charge band's
    /// ask + last night's Rest + the capped junior debt term — the drivers that CHANGE nightly, by
    /// design (v1's debt-capped constant read the same maxed number for weeks).
    func testSleepNeedComposesChargeRestAndJuniorDebt() {
        let steady = Array(repeating: 480.0, count: 10)
        XCTAssertEqual(DailyTargets.sleepNeedTonightMin(
            nightlyMinutes: steady, charge: 20, restScore: 40, debtBalanceMin: -200),
            480 + 40 + 30 + 45)
        XCTAssertEqual(DailyTargets.sleepNeedTonightMin(
            nightlyMinutes: steady, charge: 50, restScore: 60, debtBalanceMin: 0), 500)
        XCTAssertEqual(DailyTargets.sleepNeedTonightMin(
            nightlyMinutes: steady, charge: 80, restScore: 90, debtBalanceMin: 0), 465)
    }

    /// The user's stated bounds hold at both ends: a chronic short sleeper's base floors at 7 h, and
    /// a long sleeper with every adjustment stacked still caps at 10 h.
    func testSleepNeedClampsToTheStatedBounds() {
        XCTAssertEqual(DailyTargets.sleepNeedTonightMin(
            nightlyMinutes: Array(repeating: 330, count: 10),
            charge: 80, restScore: nil, debtBalanceMin: 0), 420)
        XCTAssertEqual(DailyTargets.sleepNeedTonightMin(
            nightlyMinutes: Array(repeating: 590, count: 10),
            charge: 10, restScore: 30, debtBalanceMin: -400), 600)
    }

    /// A surplus never discounts below the base (sleep is not bankable ahead), an in-deadband debt is
    /// noise, and a cold start (too few nights) uses the 8 h default base rather than guessing.
    func testSleepNeedSurplusDeadbandAndColdStart() {
        let steady = Array(repeating: 480.0, count: 10)
        XCTAssertEqual(DailyTargets.sleepNeedTonightMin(
            nightlyMinutes: steady, charge: 80, restScore: 60, debtBalanceMin: 300), 480)
        XCTAssertEqual(DailyTargets.sleepNeedTonightMin(
            nightlyMinutes: steady, charge: 80, restScore: 60, debtBalanceMin: -20), 480)
        XCTAssertEqual(DailyTargets.sleepNeedTonightMin(
            nightlyMinutes: [480, 500], charge: nil, restScore: nil, debtBalanceMin: 0), 480)
    }
}
