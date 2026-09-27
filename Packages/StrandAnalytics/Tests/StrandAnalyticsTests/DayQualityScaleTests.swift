import XCTest
@testable import StrandAnalytics

/// The day-quality scale: 0 is a normal sedentary day, +50 is every target met, +100 is everything
/// beaten (260908, second attempt).
///
/// The first signed scale derived its origin and then spread that origin across the components, and the
/// field cards showed what that did: every row gained ~+8.7 points before any achievement was counted,
/// so a 99 %-of-target step count scored nearly half the available credit for MISSING the target, and
/// ordinary days published in the high twenties to fifties. These tests pin the properties that failure
/// violated.
final class DayQualityScaleTests: XCTestCase {

    /// Targets a typical day sets, so the anchors are expressed against realistic asks.
    private func day(steps: Int? = 4000, kcal: Int? = 1600, effort: Int? = 8, water: Int? = 8,
                     sleepMin: Double? = 420, hrv: Double? = 30, rhr: Int? = 64,
                     stepsTarget: Int? = 9550, kcalTarget: Int? = 2250, effortTarget: Int? = 54,
                     waterTarget: Int? = 21, sleepNeed: Int? = 480,
                     hrvBase: Double? = 30, rhrBase: Double? = 64) -> DayQualityScore.DayInput {
        DayQualityScore.DayInput(
            steps: steps, stepsTarget: stepsTarget, kcal: kcal, kcalTarget: kcalTarget,
            effort: effort, effortTarget: effortTarget, waterCups: water, waterTargetCups: waterTarget,
            sleepMin: sleepMin, sleepNeedMin: sleepNeed, hrv: hrv, hrvBaseline: hrvBase,
            restingHr: rhr, restingHrBaseline: rhrBase)
    }

    // MARK: - The three anchors

    /// The maintainer's own words: "a steady day with normal activity and normal sleep (not based on
    /// relative data but some absolute definition) should be 0".
    ///
    /// STRUCTURAL, not fitted: at normal input every term is literally zero, so this cannot drift when
    /// a weight changes. That is the property the derived-origin version lacked.
    func testANormalSedentaryDayScoresExactlyZero() throws {
        let s = try XCTUnwrap(DayQualityScore.score(day()))
        XCTAssertEqual(s.total, 0)
        for c in s.components where c.label != "HRV" && c.label != "Resting HR" {
            XCTAssertEqual(c.points, 0, accuracy: 1e-9,
                           "\(c.label) must contribute nothing at the normal day, not a share of an offset")
        }
    }

    /// Hitting every target with both signals at baseline is +50 — halfway up the positive half, at the
    /// maintainer's choice, leaving real room above it for beating them.
    func testHittingEveryTargetScoresFifty() throws {
        let s = try XCTUnwrap(DayQualityScore.score(day(
            steps: 9550, kcal: 2250, effort: 54, water: 21, sleepMin: 480)))
        XCTAssertEqual(s.total, Int(DayQualityScore.targetPointsTotal))
    }

    /// And +100 is reachable by beating everything.
    func testBeatingEverythingReachesOneHundred() throws {
        let s = try XCTUnwrap(DayQualityScore.score(day(
            steps: 30_000, kcal: 6000, effort: 150, water: 50, sleepMin: 1000,
            hrv: 40, rhr: 40)))
        XCTAssertEqual(s.total, DayQualityScore.publishedMaximum)
    }

    /// A genuinely bad day must be able to reach the floor.
    func testAVeryBadDayGoesWellNegative() throws {
        let s = try XCTUnwrap(DayQualityScore.score(day(
            steps: 0, kcal: 0, effort: 0, water: 0, sleepMin: 0, hrv: 12, rhr: 90)))
        XCTAssertLessThan(s.total, -60, "nothing done with poor recovery must read clearly negative")
        XCTAssertGreaterThanOrEqual(s.total, DayQualityScore.publishedMinimum)
    }

    func testTheScaleIsClampedBothEnds() throws {
        let high = try XCTUnwrap(DayQualityScore.score(day(
            steps: 10_000_000, kcal: 10_000_000, effort: 100_000, water: 10_000,
            sleepMin: 100_000, hrv: 10_000, rhr: 1)))
        let low = try XCTUnwrap(DayQualityScore.score(day(
            steps: 0, kcal: 0, effort: 0, water: 0, sleepMin: 0, hrv: 1, rhr: 10_000)))
        XCTAssertLessThanOrEqual(high.total, DayQualityScore.publishedMaximum)
        XCTAssertGreaterThanOrEqual(low.total, DayQualityScore.publishedMinimum)
    }

    // MARK: - The bug the field cards exposed

    /// A component just short of target must NOT bank most of its available credit. This is the
    /// specific failure the screenshots showed: 9489 of 9550 steps scored +9.7 of 23.4.
    func testJustMissingATargetDoesNotBankMostOfTheCredit() throws {
        let s = try XCTUnwrap(DayQualityScore.score(day(steps: 9489)))
        let steps = try XCTUnwrap(s.components.first { $0.label == "Steps" })
        // Just short of target should sit just short of the component's full weight.
        XCTAssertLessThan(steps.points, steps.weight)
        XCTAssertGreaterThan(steps.points, steps.weight * 0.9,
                             "99 % of target should earn ~99 % of the ramp, not half of it")
    }

    /// Rows must sum to the headline, by construction — there is one formula and one sum. The field
    /// cards showed +56 above rows summing to 13, because the headline came from the stored series while
    /// the breakdown was recomputed live under a different formula.
    func testRowsAlwaysSumToTheHeadline() throws {
        let cases: [(String, DayQualityScore.DayInput)] = [
            ("normal day", day()),
            ("targets met", day(steps: 9550, kcal: 2250, effort: 54, water: 21, sleepMin: 480)),
            ("everything beaten", day(steps: 20_000, kcal: 4000, effort: 100, water: 40, sleepMin: 700)),
            ("nothing done", day(steps: 0, kcal: 0, effort: 0, water: 0, sleepMin: 0)),
            ("no night recorded", day(sleepMin: nil, hrv: nil, rhr: nil,
                                      sleepNeed: nil, hrvBase: nil, rhrBase: nil)),
            ("water unrecorded", day(water: nil, waterTarget: nil)),
            ("clamped high", day(steps: 999_999, kcal: 999_999, effort: 9999, water: 999,
                                 sleepMin: 99_999, hrv: 999, rhr: 1)),
        ]
        for (name, input) in cases {
            let s = try XCTUnwrap(DayQualityScore.score(input), name)
            let summed = s.components.reduce(0) { $0 + $1.points }
            XCTAssertEqual(summed, s.executionPoints + s.recoveryPoints, accuracy: 0.01,
                           "\(name): rows must equal the two halves")
            // Only unclamped days can match the headline exactly; a clamped one is capped by design.
            if abs(summed) < 100 {
                XCTAssertEqual(summed, Double(s.total), accuracy: 0.6,
                               "\(name): rows must equal the published headline")
            }
        }
    }

    /// A target at or BELOW the normal-day reference happens for real — a low-charge day shrinks the
    /// steps target, and one field card showed a 4000-step target against a 4000-step normal. The first
    /// version dropped the row entirely, so a card showed NO Steps line on a day with 8288 steps.
    func testATargetBelowTheNormalDayStillScoresTheComponent() throws {
        let s = try XCTUnwrap(DayQualityScore.score(day(steps: 8288, stepsTarget: 4000)))
        let steps = try XCTUnwrap(s.components.first { $0.label == "Steps" },
                                  "the component must still appear — dropping it reads as a data gap")
        XCTAssertGreaterThan(steps.points, 0, "8288 steps against a 4000 target is a genuinely active day")
    }

    // MARK: - Monotonicity and absence

    /// A strictly better day can never publish a lower number. Walked over a spread so a slope error
    /// anywhere shows up.
    func testScoreIsMonotonicInSteps() throws {
        var previous = Int.min
        for steps in stride(from: 0, through: 25_000, by: 500) {
            let s = try XCTUnwrap(DayQualityScore.score(day(steps: steps)))
            XCTAssertGreaterThanOrEqual(s.total, previous, "more steps must never score lower (at \(steps))")
            previous = s.total
        }
    }

    func testScoreIsMonotonicInSleep() throws {
        var previous = Int.min
        for minutes in stride(from: 0.0, through: 900.0, by: 30.0) {
            let s = try XCTUnwrap(DayQualityScore.score(day(sleepMin: minutes)))
            XCTAssertGreaterThanOrEqual(s.total, previous, "more sleep must never score lower (at \(minutes))")
            previous = s.total
        }
    }

    /// An unrecorded component is ABSENT, never zero: the present target-bearing components share the
    /// whole target total, so the day is scored out of what was measured.
    func testAnUnrecordedComponentIsAbsentNotZero() throws {
        let full = try XCTUnwrap(DayQualityScore.score(day(
            steps: 9550, kcal: 2250, effort: 54, water: 21, sleepMin: 480)))
        let noWater = try XCTUnwrap(DayQualityScore.score(day(
            steps: 9550, kcal: 2250, effort: 54, water: nil, sleepMin: 480, waterTarget: nil)))
        XCTAssertEqual(full.total, noWater.total,
                       "meeting every MEASURED target is +50 whether or not water was recorded")
        XCTAssertTrue(noWater.missing.contains("Water"))
        XCTAssertFalse(noWater.components.contains { $0.label == "Water" })
    }

    /// Too little data is no score, not a low one.
    func testTooLittleDataYieldsNoScore() {
        var d = DayQualityScore.DayInput()
        d.steps = 3000; d.stepsTarget = 8000
        XCTAssertNil(DayQualityScore.score(d))
        d.kcal = 1800; d.kcalTarget = 2250
        XCTAssertNil(DayQualityScore.score(d))
        d.waterCups = 10; d.waterTargetCups = 21
        XCTAssertNotNil(DayQualityScore.score(d), "three components is the documented floor")
    }

    // MARK: - The normal-day anchor itself

    /// The anchor is tunable, and moving it moves the zero — that is the point of it being a setting.
    func testMovingTheNormalDayMovesTheZero() throws {
        var config = DayQualityScore.Config.default
        config.normalDay.steps = 8000        // "a normal day for me is 8000 steps"
        let s = try XCTUnwrap(DayQualityScore.score(day(steps: 4000), config: config))
        XCTAssertLessThan(s.total, 0,
                          "4000 steps is now BELOW this wearer's normal day, so it must cost points")
    }

    /// Weights are relative and renormalised, so moving one cannot break the +50 anchor.
    func testMovingAWeightPreservesTheTargetsMetAnchor() throws {
        var config = DayQualityScore.Config.default
        config.stepsWeight = 40              // steps now dominate
        let s = try XCTUnwrap(DayQualityScore.score(
            day(steps: 9550, kcal: 2250, effort: 54, water: 21, sleepMin: 480), config: config))
        XCTAssertEqual(s.total, Int(DayQualityScore.targetPointsTotal),
                       "hitting every target is +50 whatever the weights are")
    }

    /// The load factor must MOVE the score in the right direction — the multiplicative form went
    /// completely inert on a signed scale, since meeting a target scores zero credit.
    func testLoadFactorRewardsTheHarderDay() throws {
        func metTargets(effortTarget: Int) -> DayQualityScore.DayInput {
            var d = day(steps: 9550, kcal: 2250, effort: effortTarget, water: 21, sleepMin: 480,
                        effortTarget: effortTarget)
            d.recentAvgEffortTarget = 54
            return d
        }
        let hard = try XCTUnwrap(DayQualityScore.score(metTargets(effortTarget: 66)))
        let easy = try XCTUnwrap(DayQualityScore.score(metTargets(effortTarget: 40)))
        XCTAssertGreaterThan(hard.loadFactor, 1.0)
        XCTAssertLessThan(easy.loadFactor, 1.0)
        XCTAssertGreaterThan(hard.total, easy.total,
                             "both days met 100 % of their target; the harder ask must score higher")
        XCTAssertLessThan(hard.total - easy.total, 25, "but it may never dominate")
    }

    /// Zero must read as unremarkable rather than as a bad day, and every reachable value needs a band.
    func testBandsCoverTheScaleAndZeroIsNeutral() {
        for total in DayQualityScore.publishedMinimum...DayQualityScore.publishedMaximum {
            XCTAssertFalse(DayQualityScore.band(total).isEmpty, "no band for \(total)")
        }
        XCTAssertEqual(DayQualityScore.band(0), "Flat")
    }
}
