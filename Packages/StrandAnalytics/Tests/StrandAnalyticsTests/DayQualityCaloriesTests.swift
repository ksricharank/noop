import XCTest
@testable import StrandAnalytics

/// The recap's calorie row (261028). The maintainer: "I got -13.9 out of 11 for accruing 1321 of 1840
/// cals which seems harsh". Calories are a whole day's burn and the target is resting burn + session,
/// so the ramp's zero is the resting burn and a total under it (an incompletely recorded day) scores
/// zero, never a penalty.
final class DayQualityCaloriesTests: XCTestCase {

    private func input(kcal: Int, resting: Int?) -> DayQualityScore.DayInput {
        .init(steps: 6000, stepsTarget: 8000, kcal: kcal, kcalTarget: 1840, effort: 12, effortTarget: 20,
              sleepMin: 420, sleepNeedMin: 480, recentAvgEffortTarget: 20, kcalResting: resting)
    }

    private func calories(_ s: DayQualityScore) -> DayQualityScore.Component {
        s.components.first { $0.label == "Calories" }!
    }

    func testAnIncompleteDayIsZeroNotAPenalty() {
        let s = DayQualityScore.score(input(kcal: 1321, resting: 1700))!
        XCTAssertEqual(calories(s).points, 0, accuracy: 1e-9)
        XCTAssertTrue(calories(s).detail.contains("day not fully recorded"), calories(s).detail)
        // The old anchor (1600, no resting burn): the same day was a deep penalty.
        let old = DayQualityScore.score(input(kcal: 1321, resting: nil))!
        XCTAssertLessThan(calories(old).points, -10)
    }

    func testRestingBurnIsZeroAndTheTargetIsTheFullWeight() {
        let atRest = DayQualityScore.score(input(kcal: 1700, resting: 1700))!
        XCTAssertEqual(calories(atRest).points, 0, accuracy: 1e-9, "doing nothing earns nothing")
        let atTarget = DayQualityScore.score(input(kcal: 1840, resting: 1700))!
        XCTAssertEqual(calories(atTarget).points, calories(atTarget).weight, accuracy: 1e-9)
        let halfway = DayQualityScore.score(input(kcal: 1770, resting: 1700))!
        XCTAssertEqual(calories(halfway).points, calories(halfway).weight / 2, accuracy: 1e-9)
    }

    func testNormalKcalFallsBackToTheConfiguredNormal() {
        XCTAssertEqual(DayQualityScore.normalKcal(input(kcal: 0, resting: 1700), config: .default), 1700)
        XCTAssertEqual(DayQualityScore.normalKcal(input(kcal: 0, resting: nil), config: .default),
                       DayQualityScore.NormalDay.default.kcal)
    }
}
