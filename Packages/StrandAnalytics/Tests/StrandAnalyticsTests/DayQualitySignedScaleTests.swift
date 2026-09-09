import XCTest
@testable import StrandAnalytics

/// The −100…+100 scale (260908), pinned at the three anchors the maintainer defined.
///
/// These are the tests that would have caught the two mistakes this rescale could plausibly make: an
/// anchor that does not actually land where it was promised, and a scale that reaches one end but not
/// the other (a fixed bias term does exactly that — it puts the sedentary day at 0 and leaves the worst
/// possible day at −63).
final class DayQualitySignedScaleTests: XCTestCase {

    /// The maintainer's own words: "a sedentary day with no exercise and normal sleep should be a 0".
    func testSedentaryDayWithNormalSleepScoresZero() throws {
        let s = try XCTUnwrap(DayQualityScore.score(DayQualityScore.referenceNeutralDay))
        XCTAssertEqual(s.total, 0,
                       "the sedentary anchor must publish exactly 0 — it is the definition of the scale's origin")
    }

    /// "a good day should start rising and go up to a 100".
    func testBestDayScoresOneHundred() throws {
        let s = try XCTUnwrap(DayQualityScore.score(DayQualityScore.referenceBestDay))
        XCTAssertEqual(s.total, DayQualityScore.publishedMaximum)
    }

    /// "a poor day should go down to −100". The end a bias-only rescale cannot reach.
    func testWorstDayScoresMinusOneHundred() throws {
        let s = try XCTUnwrap(DayQualityScore.score(DayQualityScore.referenceWorstDay))
        XCTAssertEqual(s.total, DayQualityScore.publishedMinimum)
    }

    /// Nothing may publish outside the promised range, whatever the inputs do.
    func testScaleIsClampedBothEnds() {
        let absurdHigh = DayQualityScore.DayInput(
            steps: 10_000_000, stepsTarget: 1, kcal: 10_000_000, kcalTarget: 1,
            effort: 10_000_000, effortTarget: 1, waterCups: 10_000, waterTargetCups: 1,
            sleepMin: 100_000, sleepNeedMin: 1, hrv: 10_000, hrvBaseline: 1,
            restingHr: 1, restingHrBaseline: 10_000)
        let absurdLow = DayQualityScore.DayInput(
            steps: 0, stepsTarget: 100_000, kcal: 0, kcalTarget: 100_000,
            effort: 0, effortTarget: 100_000, waterCups: 0, waterTargetCups: 100,
            sleepMin: 0, sleepNeedMin: 100_000, hrv: 1, hrvBaseline: 10_000,
            restingHr: 10_000, restingHrBaseline: 1)
        for input in [absurdHigh, absurdLow] {
            let s = DayQualityScore.score(input)
            let total = try? XCTUnwrap(s).total
            XCTAssertNotNil(total)
            XCTAssertLessThanOrEqual(total ?? 0, DayQualityScore.publishedMaximum)
            XCTAssertGreaterThanOrEqual(total ?? 0, DayQualityScore.publishedMinimum)
        }
    }

    /// Hitting every target with both signals at baseline must be clearly POSITIVE — it is a better day
    /// than the sedentary anchor — but not full marks, since the scale's top is reserved for beating them.
    func testTargetMetDayIsPositiveButNotMaximal() throws {
        let s = try XCTUnwrap(DayQualityScore.score(DayQualityScore.DayInput(
            steps: 6400, stepsTarget: 6400, kcal: 2000, kcalTarget: 2000,
            effort: 40, effortTarget: 40, waterCups: 8, waterTargetCups: 8,
            sleepMin: 480, sleepNeedMin: 480, hrv: 40, hrvBaseline: 40,
            restingHr: 60, restingHrBaseline: 60)))
        XCTAssertGreaterThan(s.total, 10, "meeting every target beats a sedentary day by a clear margin")
        XCTAssertLessThan(s.total, DayQualityScore.publishedMaximum,
                          "and leaves room above it, or beating a target would be worth nothing")
    }

    /// The scale must be MONOTONIC: a strictly better day can never publish a lower number. Walked over
    /// a spread of step counts rather than asserted at one point, so a slope error anywhere shows up.
    func testScaleIsMonotonicInSteps() throws {
        var previous = Int.min
        for steps in stride(from: 0, through: 16_000, by: 500) {
            let s = try XCTUnwrap(DayQualityScore.score(DayQualityScore.DayInput(
                steps: steps, stepsTarget: 6400, kcal: 2000, kcalTarget: 2000,
                effort: 40, effortTarget: 40, waterCups: 8, waterTargetCups: 8,
                sleepMin: 480, sleepNeedMin: 480, hrv: 40, hrvBaseline: 40,
                restingHr: 60, restingHrBaseline: 60)))
            XCTAssertGreaterThanOrEqual(s.total, previous,
                                        "more steps must never score lower (at steps=\(steps))")
            previous = s.total
        }
    }

    /// The sedentary anchor is only honest if it is not knife-edged on the sleep need it assumes. Across
    /// 7–9 h it must stay near zero rather than swinging into either verdict.
    func testZeroAnchorIsRobustToSleepNeed() throws {
        for need in [420, 450, 480, 510, 540] {
            var input = DayQualityScore.referenceNeutralDay
            input.sleepNeedMin = need
            let s = try XCTUnwrap(DayQualityScore.score(input))
            XCTAssertLessThanOrEqual(abs(s.total), 6,
                                     "sedentary with a \(need)-minute need should stay ~0, got \(s.total)")
        }
    }

    /// Likewise across a plausible span of what "no deliberate activity" means.
    func testZeroAnchorIsRobustToActivityDefinition() throws {
        for fraction in [0.15, 0.25, 0.40] {
            var input = DayQualityScore.referenceNeutralDay
            input.steps = Int(6400 * fraction)
            input.kcal = Int(2000 * (0.25 + fraction * 0.4))
            let s = try XCTUnwrap(DayQualityScore.score(input))
            XCTAssertLessThanOrEqual(abs(s.total), 10,
                                     "sedentary at \(fraction) of target should stay near 0, got \(s.total)")
        }
    }

    /// Signed credit: zero at neutral, −1 at zero output, and the overshoot allowance above — measured
    /// in the SAME units on both sides, which is where the anti-gaming asymmetry comes from.
    func testSignedCreditEndpoints() {
        // Ratio components: neutral 1.0, cap 1.25.
        XCTAssertEqual(DayQualityScore.signedCredit(achieved: 1.0, neutral: 1.0, cap: 1.25), 0, accuracy: 1e-9)
        XCTAssertEqual(DayQualityScore.signedCredit(achieved: 0.0, neutral: 1.0, cap: 1.25), -1, accuracy: 1e-9)
        XCTAssertEqual(DayQualityScore.signedCredit(achieved: 1.25, neutral: 1.0, cap: 1.25), 0.25, accuracy: 1e-9,
                       "beating a target by the full allowance is worth 0.25 — a QUARTER of what "
                       + "skipping a component costs. That ratio is the anti-gaming bound.")
        XCTAssertEqual(DayQualityScore.signedCredit(achieved: 5.0, neutral: 1.0, cap: 1.25), 0.25, accuracy: 1e-9,
                       "past the cap, more buys nothing")
        // Baseline signals: neutral 0.75, ceiling 1.0.
        XCTAssertEqual(DayQualityScore.signedCredit(achieved: 0.75, neutral: 0.75, cap: 1.0), 0, accuracy: 1e-9)
        XCTAssertEqual(DayQualityScore.signedCredit(achieved: 0.0, neutral: 0.75, cap: 1.0), -1, accuracy: 1e-9)
        XCTAssertEqual(DayQualityScore.signedCredit(achieved: 1.0, neutral: 0.75, cap: 1.0), 1.0 / 3.0, accuracy: 1e-9)
    }

    /// The property the asymmetry exists for, stated directly: one metric run to its cap must not cover
    /// a component that scored zero.
    func testOneRunawayMetricCannotCoverASkippedComponent() throws {
        func day(steps: Int, effort: Int) -> DayQualityScore.DayInput {
            DayQualityScore.DayInput(
                steps: steps, stepsTarget: 8000, kcal: 2250, kcalTarget: 2250,
                effort: effort, effortTarget: 54, waterCups: 21, waterTargetCups: 21,
                sleepMin: 480, sleepNeedMin: 480, hrv: 58, hrvBaseline: 58,
                restingHr: 52, restingHrBaseline: 52, recentAvgEffortTarget: 54)
        }
        let compliant = try XCTUnwrap(DayQualityScore.score(day(steps: 8000, effort: 54)))
        let runaway = try XCTUnwrap(DayQualityScore.score(day(steps: 40_000, effort: 0)))
        XCTAssertLessThan(runaway.total, compliant.total,
                          "40 000 steps with no workout must not reach the score of a day that did it")
        // And past the cap the extra steps buy nothing at all.
        let absurd = try XCTUnwrap(DayQualityScore.score(day(steps: 400_000, effort: 0)))
        XCTAssertEqual(absurd.total, runaway.total, "400 000 scores the same as 40 000 — the cap holds")
    }

    /// The load factor must actually MOVE the score, in the right direction. On the signed scale a
    /// multiplier on credit is inert (meeting a target scores zero credit, and zero times anything is
    /// zero), so this pins the tilt that replaced it: two days that both hit 100 % of very different
    /// targets must not publish the same number.
    func testLoadFactorRewardsTheHarderDay() throws {
        func day(effortTarget: Int) -> DayQualityScore.DayInput {
            DayQualityScore.DayInput(
                steps: 8000, stepsTarget: 8000, kcal: 2250, kcalTarget: 2250,
                effort: effortTarget, effortTarget: effortTarget,
                waterCups: 21, waterTargetCups: 21, sleepMin: 480, sleepNeedMin: 480,
                hrv: 58, hrvBaseline: 58, restingHr: 52, restingHrBaseline: 52,
                recentAvgEffortTarget: 54)
        }
        let hard = try XCTUnwrap(DayQualityScore.score(day(effortTarget: 66)))
        let easy = try XCTUnwrap(DayQualityScore.score(day(effortTarget: 40)))
        XCTAssertGreaterThan(hard.loadFactor, 1.0)
        XCTAssertLessThan(easy.loadFactor, 1.0)
        XCTAssertGreaterThan(hard.total, easy.total,
                             "both days met 100 % of their target; the harder ask must score higher")
        // Mild, not dominant — a rest day must still read as a rest day.
        XCTAssertLessThan(hard.total - easy.total, 20,
                          "the load factor may nudge the score, never dominate it")
    }

    /// A band must exist for every reachable value, and zero must read as unremarkable rather than bad.
    func testBandCoversTheWholeScale() {
        for total in DayQualityScore.publishedMinimum...DayQualityScore.publishedMaximum {
            XCTAssertFalse(DayQualityScore.band(total).isEmpty, "no band for \(total)")
        }
        XCTAssertEqual(DayQualityScore.band(0), "Flat")
    }

    /// The breakdown panel must reconcile with the headline on the SIGNED scale, at both clamps and — the
    /// case that broke two earlier attempts at this — on a day whose raw signed sum is exactly zero
    /// (every target met, both signals at baseline). A multiplicative-only publish zeroes every row there
    /// while the headline reads +27; an offset added to the SUM leaves the rows adding to a number the
    /// screen never shows. Folding the origin shift into each component before summing is what makes all
    /// three agree, and this is the test that says so.
    func testBreakdownReconcilesWithTheHeadlineEverywhere() throws {
        let cases: [(String, DayQualityScore.DayInput)] = [
            ("sedentary anchor", DayQualityScore.referenceNeutralDay),
            ("best (clamped)", DayQualityScore.referenceBestDay),
            ("worst (clamped)", DayQualityScore.referenceWorstDay),
            ("target-met (raw sum is zero)", DayQualityScore.DayInput(
                steps: 6400, stepsTarget: 6400, kcal: 2000, kcalTarget: 2000,
                effort: 40, effortTarget: 40, waterCups: 8, waterTargetCups: 8,
                sleepMin: 480, sleepNeedMin: 480, hrv: 40, hrvBaseline: 40,
                restingHr: 60, restingHrBaseline: 60)),
            ("no night recorded", DayQualityScore.DayInput(
                steps: 6400, stepsTarget: 6400, kcal: 2000, kcalTarget: 2000,
                effort: 40, effortTarget: 40, waterCups: 8, waterTargetCups: 8)),
            ("only three components", DayQualityScore.DayInput(
                steps: 6400, stepsTarget: 6400, kcal: 2000, kcalTarget: 2000,
                sleepMin: 480, sleepNeedMin: 480)),
        ]
        for (name, input) in cases {
            let s = try XCTUnwrap(DayQualityScore.score(input), name)
            let summed = s.components.reduce(0) { $0 + $1.points }
            XCTAssertEqual(summed, s.executionPoints + s.recoveryPoints, accuracy: 0.01,
                           "\(name): rows must add up to the two halves")
            XCTAssertEqual(summed, Double(s.total), accuracy: 0.6,
                           "\(name): rows must add up to the published headline")
        }
    }
}
