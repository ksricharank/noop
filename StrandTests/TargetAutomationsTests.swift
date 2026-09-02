import XCTest
@testable import Strand

/// Pins the pure decisions behind the 260901 target automations: the morning brief (A) fires once
/// per day after the first post-wake score, and the pacing check-ins (E) nudge at most once per
/// checkpoint per day, only when behind pace, with a concrete catch-up ask.
final class TargetAutomationsTests: XCTestCase {

    // MARK: - A: morning brief

    func testBriefFiresOncePerDayAfterTheMorningScore() {
        // The anchor is still YESTERDAY's row → the targets are carried, no brief.
        XCTAssertFalse(TargetAutomations.briefWanted(enabled: true, anchorDay: "2026-08-31",
                                                     todayKey: "2026-09-01", minuteOfDay: 8 * 60,
                                                     earliestMinute: 6 * 60, lastFiredDay: nil))
        // Morning score landed (anchor = today) and it's past the earliest time → fire.
        XCTAssertTrue(TargetAutomations.briefWanted(enabled: true, anchorDay: "2026-09-01",
                                                    todayKey: "2026-09-01", minuteOfDay: 8 * 60,
                                                    earliestMinute: 6 * 60, lastFiredDay: "2026-08-31"))
        // Already fired today → never twice.
        XCTAssertFalse(TargetAutomations.briefWanted(enabled: true, anchorDay: "2026-09-01",
                                                     todayKey: "2026-09-01", minuteOfDay: 9 * 60,
                                                     earliestMinute: 6 * 60, lastFiredDay: "2026-09-01"))
        // Scored early (a 4:30 sync) but before the user's earliest-delivery time → held.
        XCTAssertFalse(TargetAutomations.briefWanted(enabled: true, anchorDay: "2026-09-01",
                                                     todayKey: "2026-09-01", minuteOfDay: 4 * 60 + 40,
                                                     earliestMinute: 6 * 60, lastFiredDay: nil))
        XCTAssertFalse(TargetAutomations.briefWanted(enabled: false, anchorDay: "2026-09-01",
                                                     todayKey: "2026-09-01", minuteOfDay: 8 * 60,
                                                     earliestMinute: 6 * 60, lastFiredDay: nil))
    }

    func testBriefTextCarriesThePlanAndDegradesPerPiece() {
        let full = TargetAutomations.briefText(charge: 80, sessionMinutes: 45, sessionHrBpm: 139,
                                               restDay: false, sleepNeedMin: 501, stepsTarget: 10_000)
        XCTAssertEqual(full.body, "Charge 80 · 45 min workout @ ~139 bpm · 10000 steps · sleep 8h21 tonight")
        let rest = TargetAutomations.briefText(charge: 20, sessionMinutes: nil, sessionHrBpm: nil,
                                               restDay: true, sleepNeedMin: 540, stepsTarget: 4_000)
        XCTAssertEqual(rest.body, "Charge 20 · rest day — no workout · 4000 steps · sleep 9h00 tonight")
    }

    // MARK: - E: pacing (260901 rewire: interval cadence, true prorated pace, deficit-sized ask)

    private func decide(minuteOfDay: Int, firedMask: Int = 0, steps: Int?, stepsTarget: Int? = 10_000,
                        effortToday: Int? = 0, effortTarget: Int? = 59, sessionMinutes: Int? = 45,
                        intervalHours: Int = 2)
        -> (nudge: TargetAutomations.PacingNudge?, newMask: Int) {
        TargetAutomations.pacingDecision(enabled: true, minuteOfDay: minuteOfDay,
                                         intervalHours: intervalHours, firedMask: firedMask,
                                         steps: steps, stepsTarget: stepsTarget,
                                         effortToday: effortToday, effortTarget: effortTarget,
                                         sessionMinutes: sessionMinutes)
    }

    func testCheckpointsAreTheTopOfEveryNHoursAcrossTheWakingWindow() {
        XCTAssertEqual(TargetAutomations.checkpointMinutes(intervalHours: 2),
                       [600, 720, 840, 960, 1_080, 1_200, 1_320])   // 10:00 … 22:00
        XCTAssertEqual(TargetAutomations.checkpointMinutes(intervalHours: 6),
                       [840, 1_200])                                 // 14:00, 20:00
    }

    func testBehindPaceNudgesWithTheDeficitSizedAsk() {
        // 14:00, every-2h cadence: 6 of the 14 waking hours elapsed → expected ≈ 4285 of 10000.
        // 1,500 is 2,785 behind → the ask is the DEFICIT (back on pace ≈ 27 min), not the day.
        let (nudge, mask) = decide(minuteOfDay: 14 * 60, steps: 1_500)
        XCTAssertEqual(mask, 0b111, "the 10:00/12:00/14:00 checkpoints are all consumed")
        XCTAssertEqual(nudge?.checkpointIndex, 2, "only the latest due checkpoint is evaluated")
        XCTAssertTrue(nudge!.body.contains("1500 steps — 2785 behind the 4285 you'd be at on pace for 10000"),
                      nudge!.body)
        XCTAssertTrue(nudge!.body.contains("~27 min of walking catches you up"), nudge!.body)
        XCTAssertTrue(nudge!.body.contains("your 45 min workout is still open (effort 0 of 59)"), nudge!.body)
    }

    func testOnPaceIsSilentAndAnUndoneWorkoutAloneNeverNudges() {
        // 5,000 at 14:10 is ahead of the ~4400 pace → silent even though the workout is untouched.
        let (nudge, mask) = decide(minuteOfDay: 14 * 60 + 10, steps: 5_000)
        XCTAssertNil(nudge)
        XCTAssertEqual(mask, 0b111, "on-pace checkpoints are consumed so later syncs can't re-litigate")
        // Same cadence 30 min later: nothing newly due, still silent.
        let again = decide(minuteOfDay: 14 * 60 + 40, firedMask: mask, steps: 5_000)
        XCTAssertNil(again.nudge)
        XCTAssertEqual(again.newMask, 0b111)
    }

    func testALaterCheckpointFiresIndependently() {
        // 18:05 from the 14:00 mask: 16:00 + 18:00 consumed; expected ≈ 7202, 3000 is behind.
        let (nudge, mask) = decide(minuteOfDay: 18 * 60 + 5, firedMask: 0b111, steps: 3_000,
                                   effortToday: 59)
        XCTAssertEqual(mask, 0b11111)
        XCTAssertEqual(nudge?.checkpointIndex, 4)
        XCTAssertTrue(nudge!.body.contains("3000 steps — 4202 behind the 7202"), nudge!.body)
        XCTAssertFalse(nudge!.body.contains("workout"), "a finished workout must not be nagged about")
    }

    func testBeforeTheFirstCheckpointNothingHappens() {
        let (nudge, mask) = decide(minuteOfDay: 9 * 60, steps: 100)
        XCTAssertNil(nudge)
        XCTAssertEqual(mask, 0)
    }

    func testDisabledPacingTouchesNothing() {
        let (nudge, mask) = TargetAutomations.pacingDecision(
            enabled: false, minuteOfDay: 20 * 60, intervalHours: 2, firedMask: 0,
            steps: 0, stepsTarget: 10_000, effortToday: 0, effortTarget: 59, sessionMinutes: 45)
        XCTAssertNil(nudge)
        XCTAssertEqual(mask, 0)
    }

    /// A rest day (no session, effort target 0) never mentions a workout — only steps can nudge.
    func testRestDayNudgesOnlyOnSteps() {
        let (nudge, _) = decide(minuteOfDay: 14 * 60, steps: 500, effortToday: 3,
                                effortTarget: 0, sessionMinutes: nil)
        XCTAssertNotNil(nudge)
        XCTAssertFalse(nudge!.body.contains("workout"), nudge!.body)
    }

    /// With no step target at all, effort becomes the primary pace check, prorated the same way.
    func testEffortIsThePrimaryCheckWhenThereIsNoStepTarget() {
        // 14:00: effort pace = 59 × 0.4286 ≈ 25; 3 is behind → nudge names the open workout.
        let behind = decide(minuteOfDay: 14 * 60, steps: nil, stepsTarget: nil, effortToday: 3)
        XCTAssertNotNil(behind.nudge)
        XCTAssertTrue(behind.nudge!.body.contains("effort 3 of 59"), behind.nudge!.body)
        // Effort ahead of its prorated pace → silent.
        let onPace = decide(minuteOfDay: 14 * 60, steps: nil, stepsTarget: nil, effortToday: 30)
        XCTAssertNil(onPace.nudge)
    }
}

/// Pins the day-keyed breathe-cue counter (the calibration evidence for the sensitivity knobs).
@MainActor
final class BreatheCueStatsTests: XCTestCase {

    override func setUp() { super.setUp(); BreatheCueStats.reset() }
    override func tearDown() { BreatheCueStats.reset(); super.tearDown() }

    func testLineFormat() {
        XCTAssertEqual(BreatheCueStats.line(live: 2, retro: 3, lastAt: "16:02:11"),
                       "Breathe cues today: fired=5 (live=2 retro=3) last=16:02:11")
        XCTAssertEqual(BreatheCueStats.line(live: 1, retro: 0, lastAt: nil),
                       "Breathe cues today: fired=1 (live=1 retro=0)")
    }

    func testCountsAccumulateAndRollAtTheLocalDay() {
        let day1 = Date(timeIntervalSince1970: 1_790_000_000)
        BreatheCueStats.recordFire(retro: false, now: day1)
        BreatheCueStats.recordFire(retro: true, now: day1)
        XCTAssertTrue(BreatheCueStats.summaryLines(now: day1).first?.contains("fired=2") ?? false)
        // Two days later: the counters have rolled, the line goes silent until a fresh fire.
        let day3 = day1.addingTimeInterval(2 * 86_400)
        XCTAssertTrue(BreatheCueStats.summaryLines(now: day3).isEmpty)
    }
}
