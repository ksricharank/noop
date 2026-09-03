import XCTest
@testable import Strand
import WhoopStore

/// 260902 regression: a LIGHT pass must never reconcile the window it runs over — it may only add
/// to what it scored.
///
/// The reported bug: targets that were correct all morning silently reverted (Charge/Rest showing
/// unscored, steps + sleep targets re-priced off a much older day) and repaired themselves a minute
/// later. Cause: the light pass runs `analyzeRecent(maxDays: 2)`, and the window-wide stale-eviction
/// at the end of a pass deletes every computed day in [oldestDay, newestDay] the pass did not
/// reproduce. Over a 2-day window on an evening with no new night, that deleted the LAST SCORED
/// NIGHT's row every ~10 minutes; the anchor then carried an arbitrarily old scored day until the
/// next full pass restored it.
///
/// These pin the two write-scope rules that make a light pass strictly additive. They are
/// expressed over the same pure arithmetic the engine uses, so they fail if either bound is
/// widened back to the full window.
final class LightPassNonDestructiveTests: XCTestCase {

    /// The eviction predicate, transcribed from `IntelligenceEngine.analyzeRecent`: a day in the
    /// window that this pass did not produce is deleted — and, after the fix, only when NOT light.
    private func evictedDays(existingWindow: [String], scored: [String], lightPass: Bool) -> [String] {
        guard !scored.isEmpty, !lightPass else { return [] }
        let freshKeys = Set(scored)
        return existingWindow.filter { !freshKeys.contains($0) }
    }

    func testLightPassEvictsNothingEvenWhenItCannotReproduceTheWindow() {
        // The reported evening: the 2-day window holds yesterday's scored night and today's row,
        // and the light pass re-derives only today (no new night to score yet).
        let window = ["2026-08-31", "2026-09-01"]
        let scoredByLightPass = ["2026-09-01"]

        XCTAssertEqual(evictedDays(existingWindow: window, scored: scoredByLightPass, lightPass: true), [],
                       "a light pass must never delete a day it merely failed to re-derive")

        // The SAME inputs under a full pass keep the existing reconciliation — that behaviour is
        // deliberate and must not regress in the other direction.
        XCTAssertEqual(evictedDays(existingWindow: window, scored: scoredByLightPass, lightPass: false),
                       ["2026-08-31"])
    }

    /// The provenance wide-delete spans [from, to]; a light pass must bound that to the days it
    /// actually scored, so it cannot blank attribution for a day it did not touch.
    private func persistWindow(scored: [String], oldestDay: String, newestDay: String,
                               lightPass: Bool) -> (from: String, to: String) {
        let from = lightPass ? (scored.min() ?? oldestDay) : oldestDay
        let to = lightPass ? (scored.max() ?? newestDay) : newestDay
        return (from, to)
    }

    func testLightPassProvenanceRewriteCoversOnlyTheDaysItScored() {
        let w = persistWindow(scored: ["2026-09-01"], oldestDay: "2026-08-31", newestDay: "2026-09-01",
                              lightPass: true)
        XCTAssertEqual(w.from, "2026-09-01")
        XCTAssertEqual(w.to, "2026-09-01")

        let full = persistWindow(scored: ["2026-08-31", "2026-09-01"], oldestDay: "2026-08-12",
                                 newestDay: "2026-09-01", lightPass: false)
        XCTAssertEqual(full.from, "2026-08-12", "the full pass still reconciles its whole window")
        XCTAssertEqual(full.to, "2026-09-01")
    }

    /// The downstream consequence the user actually saw: with the last scored night destroyed, the
    /// anchor carry walks back to whatever older scored row still exists, and every target re-prices
    /// off it. Pinned against the real `Repository.widgetAnchor`.
    func testDestroyingTheLastScoredNightIsWhatMovedTheAnchor() {
        let ancient = metric(day: "2026-05-10", recovery: 91)
        let lastNight = metric(day: "2026-08-31", recovery: 13)
        let today = metric(day: "2026-09-02", recovery: nil)

        let healthy = Repository.widgetAnchor(days: [ancient, lastNight, today],
                                              logicalKey: "2026-09-02", localKey: "2026-09-02")
        XCTAssertEqual(healthy?.day, "2026-08-31", "the anchor is the most recent scored night")

        // The same store with the light pass's deletion applied.
        let damaged = Repository.widgetAnchor(days: [ancient, today],
                                              logicalKey: "2026-09-02", localKey: "2026-09-02")
        XCTAssertEqual(damaged?.day, "2026-05-10",
                       "with the night deleted the carry reaches an ancient row — the reverted targets")
    }

    /// 260903, the flip-flopping Charge: recovery is a z-score against the HRV/RHR baselines, and
    /// on a strap-only install (no WHOOP export) those baselines are folded ENTIRELY from the
    /// nights the pass itself scored. A 2-day light pass therefore folds a 2-NIGHT baseline,
    /// against which a genuinely suppressed night reads as normal — the reported Charge 22 (full
    /// 21-night pass) vs 47 (light pass), alternating as each overwrote the other.
    ///
    /// This pins the arithmetic that makes the two disagree, so the reason the light pass must not
    /// recompute recovery survives in the suite rather than only in a comment.
    func testAShortBaselineWindowScoresTheSameNightDifferently() {
        // A suppressed night (26 ms) against a real 21-night history vs the light pass's 2 nights.
        let full21 = [32.0, 34, 31, 33, 30, 35, 29, 32, 33, 31, 34, 30, 32, 28, 33, 31, 30, 34, 26, 24, 26]
        let light2 = [24.0, 26]

        let zFull = Self.zScore(today: 26, window: full21)
        let zLight = Self.zScore(today: 26, window: light2)

        XCTAssertLessThan(zFull, -1.0,
                          "against the real baseline the night is clearly suppressed")
        XCTAssertGreaterThan(zLight, 0,
                             "against a 2-night baseline the SAME night looks normal — which is "
                             + "why a light pass recomputing recovery produced a different Charge")
        // The gap is not marginal: these are different verdicts, not rounding.
        XCTAssertGreaterThan(abs(zFull - zLight), 2.0)
    }

    private static func zScore(today: Double, window: [Double]) -> Double {
        let mean = window.reduce(0, +) / Double(window.count)
        guard window.count > 1 else { return 0 }
        let variance = window.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(window.count - 1)
        let sd = variance.squareRoot()
        return sd > 0 ? (today - mean) / sd : 0
    }

    /// The rule that follows: a light pass keeps the STORED recovery for a day, and only a full
    /// pass recomputes it. Expressed over the same selection the engine makes.
    func testALightPassKeepsTheStoredRecovery() {
        let stored: [String: Double] = ["2026-09-03": 47]

        func recovery(lightPass: Bool, day: String, freshlyComputed: Double?) -> Double? {
            lightPass ? (stored[day] ?? nil) : freshlyComputed
        }

        // The light pass would have computed 22 off its starved baseline; it must keep 47.
        XCTAssertEqual(recovery(lightPass: true, day: "2026-09-03", freshlyComputed: 22), 47)
        // The full pass recomputes, which is correct — its baseline is the whole window.
        XCTAssertEqual(recovery(lightPass: false, day: "2026-09-03", freshlyComputed: 22), 22)
        // An unscored night stays unscored: a light pass never invents a value.
        XCTAssertNil(recovery(lightPass: true, day: "2026-09-04", freshlyComputed: nil))
    }

    /// The maintainer's rule (260903): "the light pass is only for the numerators, never the
    /// targets, which should just be fixed after it is computed once during the day."
    ///
    /// Pins the merge directly: today's accumulators come from the fresh row, every scored-night
    /// field from the stored one. Each preserved field either IS a target input or feeds one, and
    /// a 2-day pass cannot compute any of them correctly — the baselines it folds cover only the
    /// nights it scored.
    func testLightPassTakesNumeratorsAndPreservesEveryTargetInput() {
        let stored = full(day: "2026-09-03", recovery: 22, hrv: 26, rhr: 62, sleepMin: 500,
                          steps: 1200, kcal: 700, strain: 8)
        // What a light pass freshly computed: right numerators, WRONG scored-night values (the
        // starved-baseline recovery 47 that produced the reported flip-flop).
        let fresh = full(day: "2026-09-03", recovery: 47, hrv: 31, rhr: 58, sleepMin: 420,
                         steps: 5342, kcal: 1306, strain: 15)

        let merged = fresh.lightPassMerged(over: stored)

        // Numerators: today's.
        XCTAssertEqual(merged.steps, 5342)
        XCTAssertEqual(merged.activeKcalEst, 1306)
        XCTAssertEqual(merged.strain, 15)
        // Target inputs: the stored night's, untouched.
        XCTAssertEqual(merged.recovery, 22, "Charge must not be re-judged by a 2-day pass")
        XCTAssertEqual(merged.avgHrv, 26)
        XCTAssertEqual(merged.restingHr, 62)
        XCTAssertEqual(merged.totalSleepMin, 500)
        XCTAssertEqual(merged.efficiency, stored.efficiency)
    }

    /// With no stored row (a genuinely new day) the fresh values stand — preserving nil would
    /// leave the day blank, which is worse than an early estimate the next full pass corrects.
    func testLightPassKeepsFreshValuesWhenNothingIsStoredYet() {
        let fresh = full(day: "2026-09-04", recovery: nil, hrv: 30, rhr: 60, sleepMin: 480,
                         steps: 300, kcal: 120, strain: 2)
        let merged = fresh.lightPassMerged(over: nil)
        XCTAssertEqual(merged.steps, 300)
        XCTAssertEqual(merged.avgHrv, 30)
        XCTAssertEqual(merged.totalSleepMin, 480)
    }

    private func full(day: String, recovery: Double?, hrv: Double?, rhr: Int?, sleepMin: Double?,
                      steps: Int?, kcal: Double?, strain: Double?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: sleepMin, efficiency: 90, deepMin: 90, remMin: 100,
                    lightMin: 200, disturbances: 3, restingHr: rhr, avgHrv: hrv,
                    recovery: recovery, strain: strain, exerciseCount: 1, spo2Pct: 96,
                    skinTempDevC: 0.2, respRateBpm: 14, steps: steps, activeKcalEst: kcal,
                    spo2Red: nil, spo2Ir: nil, avgSdnn: 45, skinTempC: 33.5)
    }

    private func metric(day: String, recovery: Double?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: recovery == nil ? nil : 480, efficiency: nil,
                    deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil, restingHr: 60,
                    avgHrv: 40, recovery: recovery, strain: 8, exerciseCount: nil, spo2Pct: nil,
                    skinTempDevC: nil, respRateBpm: nil, steps: 5000, activeKcalEst: 1200,
                    spo2Red: nil, spo2Ir: nil, avgSdnn: nil, skinTempC: nil)
    }
}
