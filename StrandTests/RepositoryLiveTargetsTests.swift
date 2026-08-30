import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

/// `Repository.liveTargets` — the derivation that feeds the three-pillar Live Activity card and the
/// coach's TODAY'S TARGETS block from the same day rows. Pinned over fixtures because the wiring
/// (which rows feed which rule, today excluded from its own target history, need + ledger agreeing
/// with the debt surfaces) is exactly what a refactor would silently bend.
@MainActor
final class RepositoryLiveTargetsTests: XCTestCase {

    private func metric(day: String, sleepMin: Double? = 480, rhr: Int? = 60,
                        recovery: Double? = nil, strain: Double? = nil,
                        kcal: Double? = nil) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: sleepMin, efficiency: nil, deepMin: nil,
                    remMin: nil, lightMin: nil, disturbances: nil, restingHr: rhr,
                    avgHrv: nil, recovery: recovery, strain: strain, exerciseCount: nil,
                    activeKcalEst: kcal)
    }

    /// A steady fortnight: the ceiling is the RHR median + margin, the calorie target reads the
    /// history EXCLUDING today (today's partial row must not skew its own target), today's kcal rides
    /// separately, and a no-debt sleeper's tonight-need is the plain 8 h baseline.
    func testTargetsDeriveFromTheRows() {
        var days: [DailyMetric] = []
        for i in 1...14 {
            days.append(metric(day: String(format: "2026-08-%02d", i),
                               rhr: 60, kcal: Double(400 + i * 25)))   // 425…750, ascending
        }
        // Today: a partial row — 120 kcal so far, an absurdly high kcal that would skew p75 if the
        // exclusion broke.
        days.append(metric(day: "2026-08-15", sleepMin: nil, rhr: nil, kcal: 120))

        let t = Repository.liveTargets(days: days, charge: 80, todayKey: "2026-08-15")
        XCTAssertEqual(t.hrCeilingBpm, 60 + DailyTargets.calmMarginBpm)
        XCTAssertEqual(t.kcalToday, 120)
        // p75 of 425…750 (14 values, step 25): pos 9.75 → 668.75 → rounded to 25 = 675.
        XCTAssertEqual(t.kcalTargetKcal, 675)
        // 8 h nights against the 8 h adult-target need: no debt, so tonight is the plain need.
        XCTAssertEqual(t.sleepNeedTonightMin, 480)
    }

    /// Days carrying BOTH effort and kcal switch the calorie target to the fit path: the effort
    /// target priced in the user's own calories, with the baseline carried for the coach to explain.
    /// The 260829 motivating case: at effort 0 the count sits near baseline and the gap IS the
    /// exercise still owed — not a percentile a sedentary day drifts into.
    func testPairedHistorySwitchesToTheFitTarget() {
        var days: [DailyMetric] = []
        for i in 0...13 {
            days.append(metric(day: String(format: "2026-08-%02d", i + 1),
                               strain: Double(i), kcal: 1400 + 22 * Double(i)))   // effort 0…13
        }
        let t = Repository.liveTargets(days: days, charge: 50, todayKey: "2026-08-15")
        XCTAssertEqual(t.kcalBaseline, 1400)
        // Maintain band → effort target = median of 0…13 = 6.5 → 6 or 7 by rounding; the target is
        // 1400 + 22 × effortTarget rounded to 25. Pin the exact chain rather than re-deriving:
        let effortTarget = DailyTargets.effortTarget(charge: 50, recentEffort: (0...13).map(Double.init))
        XCTAssertEqual(t.effortTarget, effortTarget)
        let fit = DailyTargets.EffortCalorieFit(interceptKcal: 1400, kcalPerEffortPoint: 22)
        XCTAssertEqual(t.kcalTargetKcal,
                       DailyTargets.calorieTargetKcal(effortTarget: effortTarget!, fit: fit))
    }

    /// A short-sleeping week accrues ledger debt, and tonight's need carries the capped repayment.
    func testSleepDebtRaisesTonightsNeed() {
        var days: [DailyMetric] = []
        for i in 1...14 {
            days.append(metric(day: String(format: "2026-08-%02d", i), sleepMin: 360))   // 6 h nights
        }
        let t = Repository.liveTargets(days: days, charge: nil, todayKey: "2026-08-15")
        // Need floors at the 8 h adult target; 14 nights × 2 h short = far past the 90 min cap.
        XCTAssertEqual(t.sleepNeedTonightMin, 480 + 90)
    }
}
