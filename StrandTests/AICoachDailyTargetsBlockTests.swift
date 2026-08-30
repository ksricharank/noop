import XCTest
@testable import Strand

/// The three-pillar targets block (`AICoachEngine.dailyTargetsBlock`) and the bedtime line behind it.
/// Pinned because the block's whole contract is agreement: it must state the SAME numbers the
/// Lock-Screen card prints, and the synthesis prompt forbids the model to invent alternatives — so a
/// formatter drift here silently re-opens the "the card and the coach disagree" bug class.
@MainActor
final class AICoachDailyTargetsBlockTests: XCTestCase {

    private func targets(ceiling: Int? = 85, kcalToday: Int? = 320, kcalTarget: Int? = 700,
                         sleepNeed: Int? = 510, effortTarget: Int? = 62) -> LiveTargets {
        LiveTargets(hrCeilingBpm: ceiling, kcalToday: kcalToday, kcalTargetKcal: kcalTarget,
                               sleepNeedTonightMin: sleepNeed, effortTarget: effortTarget)
    }

    /// The full block names all three pillars' numbers and the band that set the activity targets.
    func testBlockCarriesAllThreePillars() {
        let block = AICoachEngine.dailyTargetsBlock(
            targets: targets(), charge: 81, effortToday: 34, currentBpm: 72,
            midsleepSec: 12_600, typicalSleepHours: 7)
        XCTAssertTrue(block.contains("85 bpm"), block)
        XCTAssertTrue(block.contains("within the calm range"), block)
        XCTAssertTrue(block.contains("700 kcal (a push day)"), block)
        XCTAssertTrue(block.contains("so far today: 320"), block)
        XCTAssertTrue(block.contains("Effort target (0-100): 62"), block)
        XCTAssertTrue(block.contains("target 8h30 asleep"), block)
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
                                           sleepNeedTonightMin: nil, effortTarget: nil)
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
