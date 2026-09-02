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

    // MARK: - E: pacing

    private func decide(minuteOfDay: Int, firedMask: Int = 0, steps: Int?, stepsTarget: Int? = 10_000,
                        effortToday: Int? = 0, effortTarget: Int? = 59, sessionMinutes: Int? = 45)
        -> (nudge: TargetAutomations.PacingNudge?, newMask: Int) {
        TargetAutomations.pacingDecision(enabled: true, minuteOfDay: minuteOfDay,
                                         checkMinutes: [14 * 60, 18 * 60], firedMask: firedMask,
                                         thresholdPct: 60,
                                         steps: steps, stepsTarget: stepsTarget,
                                         effortToday: effortToday, effortTarget: effortTarget,
                                         sessionMinutes: sessionMinutes)
    }

    func testBehindPaceAtACheckpointNudgesWithTheCatchUpAsk() {
        // 14:00: 6h of the 8:00–22:00 window elapsed (fraction 3/7) → expected ≈ 4285; 60% ≈ 2571.
        // 1,500 steps is behind → nudge, with the walk-minutes ask (8,500 left ≈ 85 min) and the
        // still-open workout.
        let (nudge, mask) = decide(minuteOfDay: 14 * 60, steps: 1_500)
        XCTAssertEqual(mask, 1)
        XCTAssertNotNil(nudge)
        XCTAssertEqual(nudge?.checkpointIndex, 0)
        XCTAssertTrue(nudge!.body.contains("1500 of 10000 steps — about 85 min of walking"), nudge!.body)
        XCTAssertTrue(nudge!.body.contains("your 45 min workout is still open (effort 0 of 59)"), nudge!.body)
    }

    func testOnPaceCheckpointIsConsumedSilently() {
        // 5,000 steps at 14:00 is ahead of the 60% bar, workout done (effort 59 of 59) → no nudge,
        // but the checkpoint is consumed so a later sync can't re-litigate it.
        let (nudge, mask) = decide(minuteOfDay: 14 * 60 + 10, steps: 5_000, effortToday: 59)
        XCTAssertNil(nudge)
        XCTAssertEqual(mask, 1)
        // Same sync cadence 20 min later: checkpoint 0 already handled, checkpoint 1 not yet due.
        let again = decide(minuteOfDay: 14 * 60 + 30, firedMask: mask, steps: 5_000, effortToday: 59)
        XCTAssertNil(again.nudge)
        XCTAssertEqual(again.newMask, 1)
    }

    func testSecondCheckpointFiresIndependently() {
        // Evening check-in (18:00, fraction 5/7 → expected ≈ 7142; 60% ≈ 4285): 3,000 is behind.
        let (nudge, mask) = decide(minuteOfDay: 18 * 60 + 5, firedMask: 1, steps: 3_000, effortToday: 59)
        XCTAssertEqual(mask, 3)
        XCTAssertEqual(nudge?.checkpointIndex, 1)
        XCTAssertTrue(nudge!.body.contains("3000 of 10000 steps"), nudge!.body)
        XCTAssertFalse(nudge!.body.contains("workout"), "a finished workout must not be nagged about")
    }

    func testBeforeTheFirstCheckpointNothingHappens() {
        let (nudge, mask) = decide(minuteOfDay: 11 * 60, steps: 100)
        XCTAssertNil(nudge)
        XCTAssertEqual(mask, 0)
    }

    func testDisabledPacingTouchesNothing() {
        let (nudge, mask) = TargetAutomations.pacingDecision(
            enabled: false, minuteOfDay: 20 * 60, checkMinutes: [14 * 60, 18 * 60], firedMask: 0,
            thresholdPct: 60, steps: 0, stepsTarget: 10_000, effortToday: 0, effortTarget: 59,
            sessionMinutes: 45)
        XCTAssertNil(nudge)
        XCTAssertEqual(mask, 0)
    }

    /// A rest day (no session, effort target 0) never nags about a workout — only steps can nudge.
    func testRestDayNudgesOnlyOnSteps() {
        let (nudge, _) = decide(minuteOfDay: 14 * 60, steps: 500, effortToday: 3,
                                effortTarget: 0, sessionMinutes: nil)
        XCTAssertNotNil(nudge)
        XCTAssertFalse(nudge!.body.contains("workout"), nudge!.body)
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
