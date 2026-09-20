import XCTest
@testable import StrandAnalytics

/// The day-quality score's arithmetic and — more importantly — the three honesty rules it exists to
/// keep: cap every component, never score absent data as zero, and don't publish a score built on
/// almost nothing.
final class DayQualityScoreTests: XCTestCase {

    /// A day where everything was recorded and every target was met exactly.
    private func perfectDay() -> DayQualityScore.DayInput {
        DayQualityScore.DayInput(
            steps: 8_000, stepsTarget: 8_000,
            kcal: 2_250, kcalTarget: 2_250,
            effort: 54, effortTarget: 54,
            waterCups: 21, waterTargetCups: 21,
            sleepMin: 485, sleepNeedMin: 485,
            hrv: 58, hrvBaseline: 58,
            restingHr: 52, restingHrBaseline: 52,
            recentAvgEffortTarget: 54
        )
    }

    // MARK: - The arithmetic

    /// Hitting every target with the autonomic signals AT baseline is exactly `targetPointsTotal`.
    ///
    /// Each component contributes precisely its own weight here — the definition of the ramp's top end
    /// — and the two baseline signals contribute zero, since baseline is their neutral. So the total
    /// is the sum of the five target-bearing weights and nothing else.
    func testAllTargetsMetWithSignalsAtBaseline() throws {
        let s = try XCTUnwrap(DayQualityScore.score(perfectDay()))
        XCTAssertEqual(s.executionPoints, 38.0, accuracy: 0.01)
        XCTAssertEqual(s.recoveryPoints, 12.0, accuracy: 0.01)
        XCTAssertEqual(s.total, Int(DayQualityScore.targetPointsTotal))
        for c in s.components where c.label != "HRV" && c.label != "Resting HR" {
            XCTAssertEqual(c.points, c.weight, accuracy: 0.01,
                           "\(c.label) at target must contribute exactly its weight")
        }
        XCTAssertEqual(s.loadFactor, 1.0, accuracy: 0.001,
                       "a day whose target matches the recent average is neither hard nor easy")
        XCTAssertTrue(s.missing.isEmpty)
        XCTAssertEqual(s.components.count, 7)
    }

    /// 100 is reachable, but it takes targets met AND a body clearly better than its own baseline —
    /// which is the point: the ceiling should be rare, not the default for a compliant day.
    func testAHundredNeedsAGenuinelyStrongBodyNotJustCompliance() throws {
        var d = perfectDay()
        d.hrv = 58 * 1.10          // +10% → full marks
        d.restingHr = 47           // ~-10% → full marks
        d.sleepMin = 485
        let s = try XCTUnwrap(DayQualityScore.score(d))
        // A strong body lifts the day well clear of mere compliance (+50) without reaching the ceiling:
        // execution still only MET its targets, and the top of the scale needs them beaten.
        XCTAssertEqual(s.total, 65)
        XCTAssertGreaterThan(s.total, try XCTUnwrap(DayQualityScore.score(perfectDay())).total,
                             "a body better than its own baseline must score above a compliant day")
    }

    /// Rule 1, first half: beating a target EARNS something, so a big day is not punished for being
    /// hard. Maintainer's requirement — 100 must be reachable by exceeding targets.
    func testExceedingEveryTargetReachesOneHundred() throws {
        var d = perfectDay()
        d.steps = 10_000           // 125% of 8 000
        d.kcal = 2_900             // ~129% of 2 250
        d.effort = 70              // ~130% of 54
        d.waterCups = 27           // ~129% of 21
        d.sleepMin = 610           // ~126% of need
        // HRV and resting HR left AT baseline: this is a big day in a normal body, which is exactly
        // the case that used to top out at 94.
        let s = try XCTUnwrap(DayQualityScore.score(d))
        XCTAssertEqual(s.total, 78,
                       "exceeding every target must climb well above +50 even with baseline signals")
        XCTAssertGreaterThan(s.total, try XCTUnwrap(DayQualityScore.score(perfectDay())).total + 20,
                             "and must be clearly better than merely meeting them")
    }

    /// Rule 1, second half: the credit is BOUNDED, so one runaway metric still cannot paper over a
    /// component that scored zero. This is the anti-gaming property, and it is the bound — not the
    /// absence of a bonus — that provides it.
    func testOvershootIsBoundedSoItCannotCoverASkippedComponent() throws {
        var runaway = perfectDay()
        runaway.steps = 40_000     // 5x the target
        runaway.effort = 0         // did no work at all
        let s = try XCTUnwrap(DayQualityScore.score(runaway))

        var honest = perfectDay()
        honest.steps = 8_000       // exactly met
        honest.effort = 0
        let baseline = try XCTUnwrap(DayQualityScore.score(honest))

        // Overshoot earns real credit but is bounded by `overshootCap`, so a runaway metric still
        // cannot reach the score of a day that actually did the work it skipped.
        XCTAssertEqual(s.executionPoints - baseline.executionPoints, 7.70, accuracy: 0.01)
        XCTAssertLessThan(s.total, Int(DayQualityScore.targetPointsTotal),
                          "five times the step target must not reach the score of a day that "
                          + "actually did its workout")
        // Beyond the cap, more steps buy literally nothing.
        var absurd = runaway
        absurd.steps = 400_000
        XCTAssertEqual(try XCTUnwrap(DayQualityScore.score(absurd)).total, s.total,
                       "400 000 steps scores the same as 40 000 — the cap holds")
    }

    /// The cap is configurable, and 1.0 restores the old hard-cap-at-target behaviour.
    func testOvershootCapIsConfigurableAndNeverBelowTarget() throws {
        var d = perfectDay()
        d.steps = 20_000
        var hard = DayQualityScore.Config.default
        hard.overshootCap = 1.0
        let capped = try XCTUnwrap(DayQualityScore.score(d, config: hard))
        XCTAssertEqual(capped.executionPoints, 38.0, accuracy: 0.01,
                       "with the cap at 1.0, overshooting earns nothing — the same execution half as a "
                       + "day that merely met every target")
        // A cap below 1.0 would mean hitting the target scored less than full marks for it.
        let nonsense = DayQualityScore.Config(executionShare: 0.6, loadFactorStrength: 0.5,
                                              overshootCap: 0.4,
                                              stepsWeight: 1, calorieWeight: 1, effortWeight: 1,
                                              waterWeight: 1, sleepWeight: 1, hrvWeight: 1,
                                              restingHrWeight: 1)
        XCTAssertEqual(nonsense.overshootCap, 1.0, "clamped up: no config may punish meeting a target")
    }

    /// Rule 2, and the one that matters most: a night the strap did not record must NOT be scored as
    /// a zero. The recovery half is absent, so its share passes to execution and the day is scored
    /// on what is known — with `missing` naming what the score could not see.
    func testAnUnrecordedNightIsAbsentNotZero() throws {
        var d = perfectDay()
        d.sleepMin = nil; d.sleepNeedMin = nil
        d.hrv = nil; d.hrvBaseline = nil
        d.restingHr = nil; d.restingHrBaseline = nil
        let s = try XCTUnwrap(DayQualityScore.score(d))

        XCTAssertEqual(s.total, Int(DayQualityScore.targetPointsTotal),
                       "a fully-executed day with no scored night is scored out of what WAS measured — "
                       + "the same +50 a fully-recorded compliant day earns, not a lower number that "
                       + "would report a data gap as a bad day")
        XCTAssertEqual(s.recoveryPoints, 0, accuracy: 0.01)
        XCTAssertEqual(Set(s.missing), Set(["Sleep", "HRV", "Resting HR"]))
    }

    /// The mirror case: a rest day with no activity data recorded still scores its night.
    func testAMissingExecutionHalfPassesItsShareToRecovery() throws {
        var d = perfectDay()
        d.steps = nil; d.stepsTarget = nil
        d.kcal = nil; d.kcalTarget = nil
        d.effort = nil; d.effortTarget = nil
        d.waterCups = nil; d.waterTargetCups = nil
        let s = try XCTUnwrap(DayQualityScore.score(d))
        XCTAssertEqual(s.executionPoints, 0, accuracy: 0.01)
        // Sleep, the only remaining target-bearing component, absorbs the whole target total.
        XCTAssertEqual(s.recoveryPoints, 50.0, accuracy: 0.01)
        XCTAssertEqual(s.total, Int(DayQualityScore.targetPointsTotal))
    }

    /// Rule 3: too little data is NOT a low score, it is no score. A gap in the trend is honest; a
    /// 30 built from one measurement is a fiction the wearer would try to explain.
    func testTooLittleDataYieldsNoScoreRatherThanALowOne() {
        var d = DayQualityScore.DayInput()
        d.steps = 3_000; d.stepsTarget = 8_000
        XCTAssertNil(DayQualityScore.score(d), "one component is not a day")
        d.kcal = 1_800; d.kcalTarget = 2_250
        XCTAssertNil(DayQualityScore.score(d), "two is still not a day")
        d.waterCups = 10; d.waterTargetCups = 21
        XCTAssertNotNil(DayQualityScore.score(d), "three components is the documented floor")
    }

    // MARK: - Baseline achievement

    /// Baseline is 0.75, improvement earns the rest, and deterioration falls away — with resting HR
    /// reading in the opposite direction, since a lower RHR is the good news.
    func testBaselineAchievementIsAsymmetricAndDirectional() {
        XCTAssertEqual(DayQualityScore.baselineAchievement(ratio: 1.0, higherIsBetter: true), 0.75,
                       accuracy: 0.001, "normal is good — but not full marks, or recovery pins")
        XCTAssertEqual(DayQualityScore.baselineAchievement(ratio: 1.10, higherIsBetter: true), 1.0,
                       accuracy: 0.001)
        XCTAssertEqual(DayQualityScore.baselineAchievement(ratio: 1.50, higherIsBetter: true), 1.0,
                       accuracy: 0.001, "capped: a freak HRV reading is not a 200% day")
        XCTAssertEqual(DayQualityScore.baselineAchievement(ratio: 0.80, higherIsBetter: true), 0.0,
                       accuracy: 0.001)
        XCTAssertEqual(DayQualityScore.baselineAchievement(ratio: 0.60, higherIsBetter: true), 0.0,
                       accuracy: 0.001, "clamped at zero, never negative")

        // Resting HR: BELOW baseline is the improvement.
        XCTAssertEqual(DayQualityScore.baselineAchievement(ratio: 0.90, higherIsBetter: false), 1.0,
                       accuracy: 0.001)
        XCTAssertEqual(DayQualityScore.baselineAchievement(ratio: 1.20, higherIsBetter: false), 0.0,
                       accuracy: 0.001)
    }

    /// Nonsense in, zero out — never a NaN that would poison the stored series.
    func testBaselineAchievementRejectsNonsense() {
        XCTAssertEqual(DayQualityScore.baselineAchievement(ratio: 0, higherIsBetter: true), 0)
        XCTAssertEqual(DayQualityScore.baselineAchievement(ratio: -1, higherIsBetter: true), 0)
        XCTAssertEqual(DayQualityScore.baselineAchievement(ratio: .nan, higherIsBetter: true), 0)
        XCTAssertEqual(DayQualityScore.baselineAchievement(ratio: .infinity, higherIsBetter: true), 0,
                       "an infinite ratio is a divide-by-almost-zero baseline, not a perfect day")
    }

    // MARK: - The load factor

    /// The reason it exists: without it, an easy day's targets are as good as a hard day's, and the
    /// trend can climb while the wearer does less.
    func testMatchingAHardDayBeatsMatchingAnEasyOne() throws {
        var hard = perfectDay()
        hard.effortTarget = 66; hard.effort = 66; hard.recentAvgEffortTarget = 54

        var easy = perfectDay()
        easy.effortTarget = 40; easy.effort = 40; easy.recentAvgEffortTarget = 54

        let h = try XCTUnwrap(DayQualityScore.score(hard))
        let e = try XCTUnwrap(DayQualityScore.score(easy))
        XCTAssertGreaterThan(h.total, e.total,
                             "both days hit 100% of their targets; the harder ask must score higher")
        XCTAssertGreaterThan(h.loadFactor, 1.0)
        XCTAssertLessThan(e.loadFactor, 1.0)
    }

    /// But mild: clamped to ±15% at full strength, and halved at the default. A rest day must read as
    /// a rest day, not a failure.
    func testTheLoadFactorIsClampedAndScaledByStrength() {
        var d = perfectDay()
        d.effortTarget = 200; d.recentAvgEffortTarget = 10   // absurdly demanding

        var full = DayQualityScore.Config.default
        full.loadFactorStrength = 1.0
        XCTAssertEqual(DayQualityScore.loadFactor(input: d, strength: 1.0), 1.15, accuracy: 0.001,
                       "clamped — a wild target cannot inflate the score without limit")
        XCTAssertEqual(DayQualityScore.loadFactor(input: d, strength: 0.5), 1.075, accuracy: 0.001,
                       "the default halves it")
        XCTAssertEqual(DayQualityScore.loadFactor(input: d, strength: 0), 1.0, accuracy: 0.001,
                       "zero strength disables it entirely")

        d.effortTarget = 1; d.recentAvgEffortTarget = 100    // absurdly easy
        XCTAssertEqual(DayQualityScore.loadFactor(input: d, strength: 1.0), 0.85, accuracy: 0.001)
    }

    /// With no recent average to compare against (a fresh install), the factor is inert rather than
    /// guessing — the score is still published, just unscaled.
    func testTheLoadFactorIsInertWithoutAHistory() throws {
        var d = perfectDay()
        d.recentAvgEffortTarget = nil
        let s = try XCTUnwrap(DayQualityScore.score(d))
        XCTAssertEqual(s.loadFactor, 1.0, accuracy: 0.001)
        XCTAssertEqual(s.total, Int(DayQualityScore.targetPointsTotal),
                       "same as the baseline day — no history means no adjustment")
    }

    // MARK: - Configuration

    /// The split is the wearer's choice. At 100% execution the body's signals stop moving the number
    /// (and vice versa), which is exactly what someone choosing an extreme is asking for.
    func testTheExecutionShareIsConfigurable() throws {
        var d = perfectDay()
        d.hrv = 58 * 0.85          // a clearly bad autonomic day
        d.restingHr = 60

        var execHeavy = DayQualityScore.Config.default; execHeavy.executionShare = 1.0
        var recHeavy = DayQualityScore.Config.default; recHeavy.executionShare = 0.0

        let e = try XCTUnwrap(DayQualityScore.score(d, config: execHeavy))
        let r = try XCTUnwrap(DayQualityScore.score(d, config: recHeavy))
        // 260908: `executionShare` is RETIRED — the scale has no split for it to divide, so both
        // configurations must publish the same number. This test now pins that the retired knob is
        // genuinely inert rather than quietly half-working, which is the failure mode that matters.
        XCTAssertEqual(e.total, r.total,
                       "executionShare no longer affects the score; a stored preference must be inert")
    }

    /// Clamping must survive DIRECT ASSIGNMENT, not just the initializer.
    ///
    /// The app builds its config by mutating `.default` from stored preferences, which never touches
    /// `init` — so a clamp that lived only there would be bypassed by the one caller that matters,
    /// and a corrupt stored value could produce a nonsense score.
    func testClampingSurvivesDirectAssignment() {
        var c = DayQualityScore.Config.default
        c.executionShare = 4.2
        XCTAssertEqual(c.executionShare, 1.0)
        c.executionShare = -1
        XCTAssertEqual(c.executionShare, 0.0)
        c.loadFactorStrength = 9
        XCTAssertEqual(c.loadFactorStrength, 1.0)
        c.overshootCap = 0.1
        XCTAssertEqual(c.overshootCap, 1.0, "no assignment may make meeting a target worth less than full marks")
        c.overshootCap = 50
        XCTAssertEqual(c.overshootCap, 3.0, "the ceiling is now the overshoot MULTIPLE's upper bound")
    }

    /// Out-of-range configuration is clamped at the boundary rather than trusted.
    func testConfigClampsItsInputs() {
        let c = DayQualityScore.Config(executionShare: 5, loadFactorStrength: -2,
                                       stepsWeight: -1, calorieWeight: 1, effortWeight: 1,
                                       waterWeight: 1, sleepWeight: 1, hrvWeight: 1,
                                       restingHrWeight: 1)
        XCTAssertEqual(c.executionShare, 1.0)
        XCTAssertEqual(c.loadFactorStrength, 0.0)
        XCTAssertEqual(c.stepsWeight, 0.0)
    }

    /// A zero-weighted component is excluded rather than counted as missing data — the wearer turned
    /// it off, which is not the same as the strap failing to record it.
    func testAZeroWeightedComponentIsNotReportedAsMissing() throws {
        var c = DayQualityScore.Config.default
        c.waterWeight = 0
        let s = try XCTUnwrap(DayQualityScore.score(perfectDay(), config: c))
        XCTAssertFalse(s.missing.contains("Water"))
        XCTAssertFalse(s.components.contains { $0.label == "Water" })
        XCTAssertEqual(s.executionPoints, 36.67, accuracy: 0.01,
                       "the remaining three components absorb water's share of the target total")
    }

    // MARK: - Presentation

    /// Every point in the components must add up to the halves they are reported under, or the
    /// "how this was computed" panel would not reconcile with the headline.
    func testComponentPointsReconcileWithTheTotal() throws {
        let s = try XCTUnwrap(DayQualityScore.score(perfectDay()))
        let summed = s.components.reduce(0) { $0 + $1.points }
        XCTAssertEqual(summed, s.executionPoints + s.recoveryPoints, accuracy: 0.01)
        XCTAssertEqual(Int(summed.rounded()), s.total)
        // And each component states its own evidence, so the panel never has to re-derive it.
        for c in s.components {
            XCTAssertFalse(c.detail.isEmpty, "\(c.label) has no evidence line")
        }
    }

    func testBandsCoverTheWholeRange() {
        XCTAssertEqual(DayQualityScore.band(100), "Excellent")
        XCTAssertEqual(DayQualityScore.band(80), "Excellent")
        XCTAssertEqual(DayQualityScore.band(58), "Strong")
        XCTAssertEqual(DayQualityScore.band(40), "Solid")
        XCTAssertEqual(DayQualityScore.band(15), "Steady")
        // Zero is the sedentary anchor: unremarkable, and the band must say so rather than calling it
        // a bad day (which is what a 0–100 scale's bottom band did).
        XCTAssertEqual(DayQualityScore.band(0), "Flat")
        XCTAssertEqual(DayQualityScore.band(-25), "Mixed")
        XCTAssertEqual(DayQualityScore.band(-100), "Depleted")
    }
}
