import XCTest
import StrandAnalytics
@testable import Strand

/// The three-pillar targets block (`AICoachEngine.dailyTargetsBlock`) and the bedtime line behind it.
/// Pinned because the block's whole contract is agreement: it must state the SAME numbers the
/// Lock-Screen card prints — and name the real basis for each (Karvonen for the ceiling, the
/// prescribed session for the activity pair) — so a formatter drift silently re-opens the "the card
/// and the coach disagree" bug class.
@MainActor
final class AICoachDailyTargetsBlockTests: XCTestCase {

    private func targets(exerciseKcal: Int? = 120, kcalTarget: Int? = 450,
                         sessionMinutes: Int? = 45, sessionHr: Int? = 143, restDay: Bool = false,
                         sleepNeed: Int? = 510, effortTarget: Int? = 51) -> LiveTargets {
        LiveTargets(exerciseKcalToday: exerciseKcal,
                    kcalTargetKcal: kcalTarget, sessionMinutes: sessionMinutes,
                    sessionHrBpm: sessionHr, restDay: restDay,
                    sleepNeedTonightMin: sleepNeed, effortTarget: effortTarget)
    }

    /// The full block names all three pillars: the live autonomic read (the card's # marker), the
    /// prescribed session with its effort and exercise-calorie targets, and tonight's sleep plan.
    func testBlockCarriesAllThreePillars() {
        let block = AICoachEngine.dailyTargetsBlock(
            targets: targets(), charge: 81, effortToday: 12, currentBpm: 72, breatheNow: false,
            midsleepSec: 12_600, typicalSleepHours: 7)
        XCTAssertTrue(block.contains("Heart right now: 72 bpm"), block)
        XCTAssertTrue(block.contains("calm"), block)
        XCTAssertTrue(block.contains("45 min at ~143 bpm"), block)
        XCTAssertTrue(block.contains("effort 51.0 of 100"), block)
        XCTAssertTrue(block.contains("450 kcal"), block)
        XCTAssertTrue(block.contains("so far today: 120 kcal"), block)
        XCTAssertTrue(block.contains("target 8h30 asleep"), block)
    }

    /// The stressed verdict names the # marker and the breathing prescription — and an unjudgeable
    /// minute is stated as such, never guessed either way.
    func testAutonomicVerdictsAreNamed() {
        let stressed = AICoachEngine.dailyTargetsBlock(
            targets: targets(), charge: 50, effortToday: nil, currentBpm: 84, breatheNow: true,
            midsleepSec: nil, typicalSleepHours: nil)
        XCTAssertTrue(stressed.contains("STRESSED"), stressed)
        XCTAssertTrue(stressed.contains("# breathe marker"), stressed)
        let unknown = AICoachEngine.dailyTargetsBlock(
            targets: targets(), charge: 50, effortToday: nil, currentBpm: 84, breatheNow: nil,
            midsleepSec: nil, typicalSleepHours: nil)
        XCTAssertTrue(unknown.contains("not judgeable"), unknown)
    }

    /// A REST day says rest — no session, no calorie ask, and the effort target reads as a hold.
    func testRestDaySaysRest() {
        let block = AICoachEngine.dailyTargetsBlock(
            targets: targets(kcalTarget: nil, sessionMinutes: nil, sessionHr: nil,
                             restDay: true, effortTarget: 12),
            charge: 40, effortToday: 12, currentBpm: nil, breatheNow: nil,
            midsleepSec: nil, typicalSleepHours: nil)
        XCTAssertTrue(block.contains("REST"), block)
        XCTAssertTrue(block.contains("hold near 12.0"), block)
        XCTAssertFalse(block.contains("prescribed session"), block)
    }

    /// Effort figures render on the user's chosen display scale — "optimal effort is around 10"
    /// means the 0–21 axis, and a 0–100 figure under the same label reads as a different number.
    func testEffortRendersOnTheWhoopScaleWhenChosen() {
        let block = AICoachEngine.dailyTargetsBlock(
            targets: targets(effortTarget: 51), charge: 81, effortToday: 10, currentBpm: nil,
            breatheNow: nil, midsleepSec: nil, typicalSleepHours: nil, effortScale: .whoop)
        XCTAssertTrue(block.contains("effort 10.7 of 21"), block)
        XCTAssertTrue(block.contains("so far today: 2.1"), block)
    }

    /// Cold start is honest: nothing computed → no block at all.
    func testColdStartEmitsNothing() {
        let empty = LiveTargets(exerciseKcalToday: nil, kcalTargetKcal: nil,
                                sessionMinutes: nil, sessionHrBpm: nil, restDay: false,
                                sleepNeedTonightMin: nil, effortTarget: nil)
        XCTAssertEqual(AICoachEngine.dailyTargetsBlock(
            targets: empty, charge: nil, effortToday: nil, currentBpm: nil, breatheNow: nil,
            midsleepSec: nil, typicalSleepHours: nil), "")
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
