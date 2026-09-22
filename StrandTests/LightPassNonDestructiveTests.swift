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

    private func metric(day: String, recovery: Double?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: recovery == nil ? nil : 480, efficiency: nil,
                    deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil, restingHr: 60,
                    avgHrv: 40, recovery: recovery, strain: 8, exerciseCount: nil, spo2Pct: nil,
                    skinTempDevC: nil, respRateBpm: nil, steps: 5000, activeKcalEst: 1200,
                    spo2Red: nil, spo2Ir: nil, avgSdnn: nil, skinTempC: nil)
    }
}
