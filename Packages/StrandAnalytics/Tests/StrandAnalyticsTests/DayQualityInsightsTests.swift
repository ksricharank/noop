import XCTest
@testable import StrandAnalytics

/// The three Insights reads (260908): attribution, counterfactuals and consistency.
final class DayQualityInsightsTests: XCTestCase {

    private func day(steps: Int = 8000, effort: Int = 54, water: Int = 21,
                     sleepMin: Double = 480, hrv: Double = 58) -> DayQualityScore {
        DayQualityScore.score(DayQualityScore.DayInput(
            steps: steps, stepsTarget: 8000, kcal: 2250, kcalTarget: 2250,
            effort: effort, effortTarget: 54, waterCups: water, waterTargetCups: 21,
            sleepMin: sleepMin, sleepNeedMin: 480, hrv: hrv, hrvBaseline: 58,
            restingHr: 52, restingHrBaseline: 52, recentAvgEffortTarget: 54))!
    }

    // MARK: - Attribution

    /// The component that is actually dragging must rank last, and be identified as the drag.
    func testAttributionRanksTheDragLast() {
        // Effort at zero across a week; everything else exactly at target.
        let week = (0..<7).map { _ in day(effort: 0) }
        let ranked = DayQualityInsights.attribution(breakdowns: week)
        XCTAssertEqual(ranked.last?.label, "Effort",
                       "the component scoring zero must rank last")
        XCTAssertLessThan(try! XCTUnwrap(ranked.last).meanPoints, 0, "and read as a negative contribution")
        let drag = DayQualityInsights.biggestDrag(breakdowns: week)
        XCTAssertEqual(drag?.label, "Effort")
    }

    /// A stretch with nothing dragging must not invent one.
    func testNoDragIsReportedWhenEveryComponentContributesPositively() {
        let week = (0..<7).map { _ in day(steps: 10_000, effort: 70, water: 27, sleepMin: 600, hrv: 66) }
        XCTAssertNil(DayQualityInsights.biggestDrag(breakdowns: week),
                     "a genuinely good stretch has no drag, and naming one would be noise")
    }

    /// Ranking is by POINTS, not bare achievement — so at equal achievement the more heavily weighted
    /// component dominates. This is the property that makes the card worth reading rather than a
    /// re-listing of percentages.
    ///
    /// Compared WITHIN the recovery half deliberately. Sleep (weight 1.5) and Water (1.0) look like the
    /// obvious pair, but under the default config they both renormalise to exactly 15 points — the
    /// execution half's 60/4 and the recovery half's 40×1.5/4 coincide — so that comparison would
    /// prove nothing. Sleep against resting HR (15 vs 10, same half) is the real test.
    func testRankingUsesWeightedPointsNotBareAchievement() {
        // Sleep at 2/3 of need and resting HR two-thirds of the way from baseline to its zero point,
        // so both components sit at the same achievement and only weight can separate them.
        let input = DayQualityScore.DayInput(
            steps: 8000, stepsTarget: 8000, kcal: 2250, kcalTarget: 2250,
            effort: 54, effortTarget: 54, waterCups: 21, waterTargetCups: 21,
            sleepMin: 320, sleepNeedMin: 480,
            hrv: 58, hrvBaseline: 58,
            restingHr: 52, restingHrBaseline: 52, recentAvgEffortTarget: 54)
        let ranked = DayQualityInsights.attribution(breakdowns: [DayQualityScore.score(input)!])
        let sleep = try! XCTUnwrap(ranked.first { $0.label == "Sleep" })
        let rhr = try! XCTUnwrap(ranked.first { $0.label == "Resting HR" })
        // Sleep is short of need and therefore negative; RHR is exactly at baseline and therefore
        // neutral. The heavier, genuinely-missed component must rank below the untroubled one.
        XCTAssertLessThan(sleep.meanPoints, rhr.meanPoints)
        XCTAssertLessThan(sleep.meanAchieved, rhr.meanAchieved)
        // And the ranking is ordered by points throughout.
        XCTAssertEqual(ranked.map(\.meanPoints), ranked.map(\.meanPoints).sorted(by: >))
    }

    /// The weight coincidence above is worth pinning in its own right: if a future config change makes
    /// the two halves' per-component weights differ, the test above stops being a within-half
    /// comparison and this says so directly.
    func testSleepAndWaterCarryEqualWeightUnderTheDefaultConfig() {
        let s = day()
        let sleep = try! XCTUnwrap(s.components.first { $0.label == "Sleep" })
        let water = try! XCTUnwrap(s.components.first { $0.label == "Water" })
        XCTAssertEqual(sleep.weight, water.weight, accuracy: 1e-9,
                       "60/4 and 40×1.5/4 both come to 15 — a coincidence of the default config, and "
                       + "the reason the ranking test compares within one half instead")
    }

    /// A component absent on some days is averaged over the days it appeared, never zeroed on the rest.
    func testAnAbsentComponentIsAveragedOverThePresentDaysOnly() {
        var withoutWater = DayQualityScore.DayInput(
            steps: 8000, stepsTarget: 8000, kcal: 2250, kcalTarget: 2250,
            effort: 54, effortTarget: 54, sleepMin: 480, sleepNeedMin: 480,
            hrv: 58, hrvBaseline: 58, restingHr: 52, restingHrBaseline: 52)
        withoutWater.waterCups = nil
        let mixed = [day(), DayQualityScore.score(withoutWater)!, day()]
        let water = try! XCTUnwrap(DayQualityInsights.attribution(breakdowns: mixed).first { $0.label == "Water" })
        XCTAssertEqual(water.days, 2, "water appeared on two of the three days")
    }

    func testAttributionOfAnEmptyWindowIsEmpty() {
        XCTAssertTrue(DayQualityInsights.attribution(breakdowns: []).isEmpty)
        XCTAssertNil(DayQualityInsights.biggestDrag(breakdowns: []))
    }

    // MARK: - Counterfactuals

    /// Only components genuinely short of target appear, richest first.
    func testCounterfactualsNameOnlyUnmetComponentsRichestFirst() {
        let s = day(steps: 4000, water: 10)       // steps and water short; effort/sleep met
        let cf = DayQualityInsights.counterfactuals(
            for: s,
            actuals: ["Steps": 4000, "Water": 10, "Effort": 54, "Sleep": 480],
            targets: ["Steps": 8000, "Water": 21, "Effort": 54, "Sleep": 480])
        let labels = cf.map(\.label)
        XCTAssertTrue(labels.contains("Steps"))
        XCTAssertTrue(labels.contains("Water"))
        XCTAssertFalse(labels.contains("Effort"), "a met component has no gap to close")
        XCTAssertFalse(labels.contains("Sleep"), "nor does a met sleep need")
        // Richest first.
        XCTAssertEqual(cf.map(\.pointsGained), cf.map(\.pointsGained).sorted(by: >))
    }

    /// The quoted shortfall must be the real distance to target, in the component's own units.
    func testShortfallIsTheActualDistanceToTarget() {
        let s = day(steps: 4000)
        let cf = DayQualityInsights.counterfactuals(
            for: s, actuals: ["Steps": 4000], targets: ["Steps": 8000])
        let steps = try! XCTUnwrap(cf.first { $0.label == "Steps" })
        XCTAssertEqual(steps.shortfall, 4000, accuracy: 0.01)
        XCTAssertEqual(steps.target, 8000, accuracy: 0.01)
        XCTAssertGreaterThan(steps.pointsGained, 0, "closing a real gap must be worth real points")
    }

    /// A day with everything met has nothing to suggest — the card should be silent rather than
    /// manufacturing an overshoot nag.
    func testAFullyMetDayHasNoSuggestions() {
        let s = day()
        let cf = DayQualityInsights.counterfactuals(
            for: s,
            actuals: ["Steps": 8000, "Water": 21, "Effort": 54, "Sleep": 480],
            targets: ["Steps": 8000, "Water": 21, "Effort": 54, "Sleep": 480])
        XCTAssertTrue(cf.isEmpty)
    }

    /// The quoted gain is in PUBLISHED points, so it can be compared with the headline the user sees.
    func testGainIsQuotedInPublishedPoints() {
        let s = day(effort: 0)
        let cf = DayQualityInsights.counterfactuals(
            for: s, actuals: ["Effort": 0], targets: ["Effort": 54])
        let effort = try! XCTUnwrap(cf.first)
        // Doing the workout must move the day by a plausible, published-scale amount — not a raw
        // credit figure (which would be roughly a fifth of this) and not more than the whole scale.
        XCTAssertGreaterThan(effort.pointsGained, 1)
        XCTAssertLessThan(effort.pointsGained, 100)
    }

    // MARK: - Consistency

    func testConsistencyCountsDaysAtOrAboveZero() {
        let series = ["2026-09-01": 20.0, "2026-09-02": -5.0, "2026-09-03": 0.0,
                      "2026-09-04": 40.0, "2026-09-05": 10.0]
        let c = DayQualityInsights.consistency(valuesByDay: series)
        XCTAssertEqual(c.totalDays, 5)
        XCTAssertEqual(c.positiveDays, 4, "zero counts as non-negative — it is the neutral day")
        XCTAssertEqual(c.currentStreak, 3, "09-03…09-05")
        XCTAssertEqual(c.longestStreak, 3)
        XCTAssertEqual(try! XCTUnwrap(c.positiveShare), 0.8, accuracy: 1e-9)
    }

    /// A negative day at the very end means no current streak, even after a long good run.
    func testANegativeMostRecentDayEndsTheStreak() {
        let series = ["2026-09-01": 30.0, "2026-09-02": 30.0, "2026-09-03": 30.0, "2026-09-04": -1.0]
        let c = DayQualityInsights.consistency(valuesByDay: series)
        XCTAssertEqual(c.currentStreak, 0)
        XCTAssertEqual(c.longestStreak, 3, "the run that ended is still the longest one seen")
    }

    /// Streaks walk SCORED days in date order. An unscored day is an absence of evidence, so it must
    /// neither extend nor break a run — otherwise a night the strap was off silently destroys a streak.
    func testAnUnscoredGapDoesNotBreakAStreak() {
        // 09-03 is simply absent from the series.
        let series = ["2026-09-01": 10.0, "2026-09-02": 10.0, "2026-09-04": 10.0, "2026-09-05": 10.0]
        let c = DayQualityInsights.consistency(valuesByDay: series)
        XCTAssertEqual(c.currentStreak, 4, "the gap is not a bad day")
        XCTAssertEqual(c.totalDays, 4, "and it is not a day at all in the count")
    }

    func testConsistencyOfAnEmptySeriesIsZeroEverywhere() {
        let c = DayQualityInsights.consistency(valuesByDay: [:])
        XCTAssertEqual(c.totalDays, 0)
        XCTAssertEqual(c.positiveDays, 0)
        XCTAssertEqual(c.currentStreak, 0)
        XCTAssertEqual(c.longestStreak, 0)
        XCTAssertNil(c.positiveShare)
    }

    /// Days are ordered by their KEY, not by dictionary iteration order — a streak computed in hash
    /// order would be meaningless and would vary between runs.
    func testStreakIsIndependentOfDictionaryOrder() {
        let ascending = ["2026-09-01": -1.0, "2026-09-02": 5.0, "2026-09-03": 5.0]
        let same = ["2026-09-03": 5.0, "2026-09-01": -1.0, "2026-09-02": 5.0]
        XCTAssertEqual(DayQualityInsights.consistency(valuesByDay: ascending).currentStreak, 2)
        XCTAssertEqual(DayQualityInsights.consistency(valuesByDay: same).currentStreak, 2)
    }
}
