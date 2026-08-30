import XCTest
@testable import Strand

/// The three-pillar targets block (`AICoachEngine.dailyTargetsBlock`) and the bedtime line behind it.
/// Pinned because the block's whole contract is agreement: it must state the SAME numbers the
/// Lock-Screen card prints, and the synthesis prompt forbids the model to invent alternatives — so a
/// formatter drift here silently re-opens the "the card and the coach disagree" bug class.
@MainActor
final class AICoachDailyTargetsBlockTests: XCTestCase {

    private func targets(ceiling: Int? = 85, kcalToday: Int? = 320, kcalTarget: Int? = 700,
                         kcalBaseline: Int? = nil, sleepNeed: Int? = 510,
                         effortTarget: Int? = 62) -> LiveTargets {
        LiveTargets(hrCeilingBpm: ceiling, kcalToday: kcalToday, kcalTargetKcal: kcalTarget,
                    kcalBaseline: kcalBaseline, sleepNeedTonightMin: sleepNeed,
                    effortTarget: effortTarget)
    }

    /// The full block names all three pillars' numbers; without a fit baseline the calorie line
    /// falls back to naming its band, and the effort line names its readiness basis.
    func testBlockCarriesAllThreePillars() {
        let block = AICoachEngine.dailyTargetsBlock(
            targets: targets(kcalBaseline: nil), charge: 81, effortToday: 34, currentBpm: 72,
            midsleepSec: 12_600, typicalSleepHours: 7)
        XCTAssertTrue(block.contains("85 bpm"), block)
        XCTAssertTrue(block.contains("within the calm range"), block)
        XCTAssertTrue(block.contains("700 kcal (a push day)"), block)
        XCTAssertTrue(block.contains("so far today: 320"), block)
        XCTAssertTrue(block.contains("Effort target: 62.0 of 100"), block)
        XCTAssertTrue(block.contains("READINESS"), block)
        XCTAssertTrue(block.contains("target 8h30 asleep"), block)
    }

    /// A fit-based calorie target carries its decomposition — the coach must be able to EXPLAIN the
    /// number as baseline + the effort target's exercise, not present it bare (the 260829 "how am I
    /// close to target at effort 0" question is exactly what this line answers).
    func testFitBasedCalorieTargetExplainsItself() {
        let block = AICoachEngine.dailyTargetsBlock(
            targets: targets(kcalTarget: 2650, kcalBaseline: 1400, effortTarget: 57),
            charge: 50, effortToday: 0, currentBpm: nil,
            midsleepSec: nil, typicalSleepHours: nil)
        XCTAssertTrue(block.contains("2650 kcal"), block)
        XCTAssertTrue(block.contains("1400 kcal zero-effort baseline"), block)
        XCTAssertTrue(block.contains("readiness-derived effort target of 57.0"), block)
        XCTAssertFalse(block.contains("maintain day"), "a fit-based target must not also claim a band basis")
    }

    /// Effort figures render on the user's chosen display scale — "optimal effort is around 10"
    /// means the 0–21 axis, and a 0–100 figure under the same label reads as a different number.
    func testEffortRendersOnTheWhoopScaleWhenChosen() {
        let block = AICoachEngine.dailyTargetsBlock(
            targets: targets(effortTarget: 57), charge: 50, effortToday: 10, currentBpm: nil,
            midsleepSec: nil, typicalSleepHours: nil, effortScale: .whoop)
        XCTAssertTrue(block.contains("Effort target: 12.0 of 21"), block)
        XCTAssertTrue(block.contains("so far today: 2.1"), block)
    }

    /// Over the ceiling reads as ELEVATED with the breathing prescription — the pillar-2 cue.
    func testElevatedHeartRateIsNamed() {
        let block = AICoachEngine.dailyTargetsBlock(
            targets: targets(), charge: 50, effortToday: nil, currentBpm: 96,
            midsleepSec: nil, typicalSleepHours: nil)
        XCTAssertTrue(block.contains("ELEVATED"), block)
        XCTAssertTrue(block.contains("96 bpm"), block)
        XCTAssertTrue(block.contains("maintain"), block)
    }

    /// Cold start is honest: nothing computed → no block at all, and an unscored charge names the
    /// neutral band rather than guessing an aggressive one.
    func testColdStartEmitsNothing() {
        let empty = LiveTargets(hrCeilingBpm: nil, kcalToday: nil, kcalTargetKcal: nil,
                                kcalBaseline: nil, sleepNeedTonightMin: nil, effortTarget: nil)
        XCTAssertEqual(AICoachEngine.dailyTargetsBlock(
            targets: empty, charge: nil, effortToday: nil, currentBpm: nil,
            midsleepSec: nil, typicalSleepHours: nil), "")
        let block = AICoachEngine.dailyTargetsBlock(
            targets: targets(), charge: nil, effortToday: nil, currentBpm: nil,
            midsleepSec: nil, typicalSleepHours: nil)
        XCTAssertTrue(block.contains("charge not scored yet"), block)
    }

    // MARK: - The bedtime line

    /// Midsleep 03:30 on a typical 7 h night puts the learned wake at 07:00; a 8h30 target tonight
    /// therefore means asleep by 22:30 — including the wrap across midnight.
    func testBedtimeDerivesFromTheLearnedWake() {
        let line = AICoachEngine.sleepPlanLine(needTonightMin: 510, midsleepSec: 12_600,
                                               typicalSleepHours: 7)
        XCTAssertTrue(line.contains("asleep by 22:30"), line)
        XCTAssertTrue(line.contains("wake of about 07:00"), line)
    }

    /// Cold start states only the duration — a fixed-clock bedtime would be wrong for exactly the
    /// shift/late sleepers the sleep learner exists for (#547).
    func testBedtimeIsOmittedWithoutTheLearnedModel() {
        let line = AICoachEngine.sleepPlanLine(needTonightMin: 480, midsleepSec: nil,
                                               typicalSleepHours: nil)
        XCTAssertEqual(line, "Sleep tonight: target 8h00 asleep.")
        XCTAssertFalse(line.contains("asleep by"))
    }
}
