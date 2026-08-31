import XCTest
import StrandAnalytics
@testable import Strand

/// The daily-targets block (`AICoachEngine.dailyTargetsBlock`) and the bedtime line behind it.
/// Pinned because the block's whole contract is agreement: it must state the SAME numbers the
/// Lock-Screen card prints — Effort now/target on the user's scale, TOTAL calories now/target, the
/// prescribed session, tonight's sleep plan — so a formatter drift silently re-opens the "the card
/// and the coach disagree" bug class. (A Heart line with a live autonomic verdict lived here for one
/// build, 270–271, and left with the card's HR column.)
@MainActor
final class AICoachDailyTargetsBlockTests: XCTestCase {

    private func targets(kcalToday: Int? = 1830, kcalTarget: Int? = 2650,
                         sessionMinutes: Int? = 45, sessionHr: Int? = 143, restDay: Bool = false,
                         sleepNeed: Int? = 510, stepsToday: Int? = 6_214, stepsTarget: Int? = 8_000,
                         effortToday: Int? = 12,
                         effortTarget: Int? = 51) -> LiveTargets {
        LiveTargets(kcalToday: kcalToday,
                    kcalTargetKcal: kcalTarget, sessionMinutes: sessionMinutes,
                    sessionHrBpm: sessionHr, restDay: restDay,
                    sleepNeedTonightMin: sleepNeed, stepsToday: stepsToday,
                    stepsTarget: stepsTarget, effortTodayStored: effortToday,
                    effortTarget: effortTarget)
    }

    /// The full block carries the activity pair (session, effort n/t, TOTAL calories n/t) and
    /// tonight's sleep plan — the same numbers the card prints.
    func testBlockCarriesTheTargets() {
        let block = AICoachEngine.dailyTargetsBlock(
            targets: targets(), charge: 81,
            midsleepSec: 12_600, typicalSleepHours: 7)
        XCTAssertTrue(block.contains("45 min at ~143 bpm"), block)
        XCTAssertTrue(block.contains("effort 51.0 of 100"), block)
        XCTAssertTrue(block.contains("so far today: 12.0"), block)
        XCTAssertTrue(block.contains("Total-calorie target: 2650 kcal"), block)
        XCTAssertTrue(block.contains("total burned so far: 1830 kcal"), block)
        XCTAssertTrue(block.contains("Step target: 8000"), block)
        XCTAssertTrue(block.contains("steps so far: 6214"), block)
        XCTAssertTrue(block.contains("target 8h30 asleep"), block)
        // The retired Heart line must not linger: the bullet reads trends from the wider context.
        XCTAssertFalse(block.contains("Heart right now"), block)
        XCTAssertFalse(block.contains("autonomic read"), block)
    }

    /// A REST day says rest — no session, the effort target reads as a hold, and the calorie target
    /// is stated as the resting day alone.
    func testRestDaySaysRest() {
        let block = AICoachEngine.dailyTargetsBlock(
            targets: targets(kcalTarget: 1975, sessionMinutes: nil, sessionHr: nil,
                             restDay: true, effortTarget: 12),
            charge: 40,
            midsleepSec: nil, typicalSleepHours: nil)
        XCTAssertTrue(block.contains("REST"), block)
        XCTAssertTrue(block.contains("hold near 12.0"), block)
        XCTAssertTrue(block.contains("Total-calorie target: 1975 kcal"), block)
        XCTAssertTrue(block.contains("resting day alone"), block)
        XCTAssertFalse(block.contains("prescribed session"), block)
    }

    /// Effort figures render on the user's chosen display scale — "optimal effort is around 10"
    /// means the 0–21 axis, and a 0–100 figure under the same label reads as a different number.
    func testEffortRendersOnTheWhoopScaleWhenChosen() {
        let block = AICoachEngine.dailyTargetsBlock(
            targets: targets(effortToday: 10, effortTarget: 51), charge: 81,
            midsleepSec: nil, typicalSleepHours: nil, effortScale: .whoop)
        XCTAssertTrue(block.contains("effort 10.7 of 21"), block)
        XCTAssertTrue(block.contains("so far today: 2.1"), block)
    }

    /// Cold start is honest: nothing computed → no block at all.
    func testColdStartEmitsNothing() {
        let empty = LiveTargets(kcalToday: nil, kcalTargetKcal: nil,
                                sessionMinutes: nil, sessionHrBpm: nil, restDay: false,
                                sleepNeedTonightMin: nil, stepsToday: nil, stepsTarget: nil,
                                effortTodayStored: nil, effortTarget: nil)
        XCTAssertEqual(AICoachEngine.dailyTargetsBlock(
            targets: empty, charge: nil,
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
