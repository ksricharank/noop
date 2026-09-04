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

    /// Hitting every target with the autonomic signals AT baseline.
    ///
    /// Execution is full marks. Recovery is 33.75 of its 40, not 30: SLEEP met 100% of its need so it
    /// scores 1.0 like any other ratio component, while HRV and resting HR sit at baseline and score
    /// 0.75 each (baseline is good, not perfect — see `baselineAchievement`). Weighted 1.5/1.5/1:
    /// 40 × (1.5·1.0 + 1.5·0.75 + 1·0.75) / 4 = 33.75.
    func testAllTargetsMetWithSignalsAtBaseline() throws {
        let s = try XCTUnwrap(DayQualityScore.score(perfectDay()))
        XCTAssertEqual(s.executionPoints, 60, accuracy: 0.01)
        XCTAssertEqual(s.recoveryPoints, 33.75, accuracy: 0.01)
        XCTAssertEqual(s.total, 94)
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
        XCTAssertEqual(s.total, 100)
    }

    /// Rule 1: components cap at 100%, so one runaway metric cannot paper over a skipped one.
    func testOvershootingOneTargetCannotBuyBackAnotherThatWasSkipped() throws {
        var d = perfectDay()
        d.steps = 40_000           // 5x the target
        d.effort = 0               // did no work at all
        let s = try XCTUnwrap(DayQualityScore.score(d))

        var honest = perfectDay()
        honest.steps = 8_000       // exactly met
        honest.effort = 0
        let baseline = try XCTUnwrap(DayQualityScore.score(honest))

        XCTAssertEqual(s.total, baseline.total,
                       "40 000 steps scored the same as 8 000 — the cap is what stops a step count "
                       + "from disguising a skipped workout")
        // And the skipped component really did cost its full share (execution has 4 equal parts of 60).
        XCTAssertEqual(s.executionPoints, 45, accuracy: 0.01)
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

        XCTAssertEqual(s.total, 100,
                       "a fully-executed day with no scored night is a 100 out of what was measured, "
                       + "not a 60 out of 100 — the latter reports a data gap as a bad day")
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
        // Same 1.0/0.75/0.75 mix as above, now carrying the whole score: 100 × 3.375/4.
        XCTAssertEqual(s.recoveryPoints, 84.375, accuracy: 0.01)
        XCTAssertEqual(s.total, 84)
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
        XCTAssertEqual(s.total, 94, "same as the baseline day — no history means no adjustment")
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
        XCTAssertEqual(e.total, 100, "all-execution: targets met is the whole story")
        XCTAssertLessThan(r.total, 60, "all-recovery: the same day reads as a poor one")
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
        XCTAssertEqual(s.executionPoints, 60, accuracy: 0.01,
                       "the remaining three components absorb the full execution share")
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
        XCTAssertEqual(DayQualityScore.band(95), "Excellent")
        XCTAssertEqual(DayQualityScore.band(90), "Excellent")
        XCTAssertEqual(DayQualityScore.band(80), "Strong")
        XCTAssertEqual(DayQualityScore.band(60), "Solid")
        XCTAssertEqual(DayQualityScore.band(50), "Mixed")
        XCTAssertEqual(DayQualityScore.band(10), "Light")
        XCTAssertEqual(DayQualityScore.band(0), "Light")
    }
}
