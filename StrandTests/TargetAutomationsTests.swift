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

    // MARK: - E: pacing (260902 compact format: n/pace/goal lines, 8:00-24:00 window)

    private func decide(minuteOfDay: Int, firedMask: Int = 0, steps: Int?, stepsTarget: Int? = 10_000,
                        kcalToday: Int? = nil, kcalTarget: Int? = nil,
                        effortToday: Int? = 0, effortTarget: Int? = 59, sessionMinutes: Int? = 45,
                        intervalHours: Int = 2, dayStartMinute: Int = 8 * 60)
        -> (nudge: TargetAutomations.PacingNudge?, newMask: Int) {
        TargetAutomations.pacingDecision(enabled: true, minuteOfDay: minuteOfDay,
                                         intervalHours: intervalHours,
                                         dayStartMinute: dayStartMinute, firedMask: firedMask,
                                         steps: steps, stepsTarget: stepsTarget,
                                         kcalToday: kcalToday, kcalTarget: kcalTarget,
                                         effortToday: effortToday, effortTarget: effortTarget,
                                         sessionMinutes: sessionMinutes)
    }

    func testCheckpointsRunEveryNHoursFromTheWake() {
        XCTAssertEqual(TargetAutomations.checkpointMinutes(intervalHours: 2, dayStartMinute: 8 * 60),
                       [600, 720, 840, 960, 1_080, 1_200, 1_320])   // 10:00 … 22:00; 24:00 excluded
        // A 6:15 wake anchors the grid on the wake, not the clock: 8:15, 10:15, …
        XCTAssertEqual(TargetAutomations.checkpointMinutes(intervalHours: 2, dayStartMinute: 375).prefix(2),
                       [495, 615])
        XCTAssertEqual(TargetAutomations.checkpointMinutes(intervalHours: 6, dayStartMinute: 8 * 60),
                       [840, 1_200])                                 // 14:00, 20:00
    }

    func testWakeMinuteClampGuardsMisScoredNights() {
        XCTAssertEqual(TargetAutomations.clampWakeMinute(2 * 60), 4 * 60)
        XCTAssertEqual(TargetAutomations.clampWakeMinute(6 * 60 + 15), 6 * 60 + 15)
        XCTAssertEqual(TargetAutomations.clampWakeMinute(15 * 60), 12 * 60)
    }

    func testBehindOnAllThreeIsOneNudgeInTheCompactFormat() {
        // 14:00: steps/effort prorate over 8:00-24:00 (fraction 0.375), cal over the 24 h clock
        // (fraction 0.583). Every line is actual/pace/goal; steps' trailing number is the walk
        // minutes closing the DEFICIT, effort's is the prescribed workout's minutes.
        let (nudge, mask) = decide(minuteOfDay: 14 * 60, steps: 1_500,
                                   kcalToday: 980, kcalTarget: 2_525)
        XCTAssertEqual(mask, 0b111, "the 10:00/12:00/14:00 checkpoints are all consumed")
        XCTAssertEqual(nudge?.checkpointIndex, 2, "only the latest due checkpoint is evaluated")
        XCTAssertEqual(nudge?.title, "Behind pace")
        // Every trailing figure carries its unit (260903), and Cal quotes the PRESCRIBED WORKOUT
        // while one is still open — 123 min of walking is an absurd ask for a gap the plan already
        // answers with 45 min of exercise.
        XCTAssertEqual(nudge?.body, """
        Steps 1500/3750/10000  22 min walk
        Cal 980/1472/2525  45 min workout
        Effort 0/22/59  45 min workout
        """.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testOnPaceIsSilentAndConsumed() {
        // 14:10 paces: steps ~3854, effort ~22, cal ~1490 — all met → silent, checkpoint consumed.
        let (nudge, mask) = decide(minuteOfDay: 14 * 60 + 10, steps: 5_000,
                                   kcalToday: 2_000, kcalTarget: 2_525, effortToday: 30)
        XCTAssertNil(nudge)
        XCTAssertEqual(mask, 0b111, "on-pace checkpoints are consumed so later syncs can't re-litigate")
        let again = decide(minuteOfDay: 14 * 60 + 40, firedMask: mask, steps: 5_000,
                           kcalToday: 2_000, kcalTarget: 2_525, effortToday: 30)
        XCTAssertNil(again.nudge)
        XCTAssertEqual(again.newMask, 0b111)
    }

    func testALaterCheckpointFiresIndependently() {
        // 18:05: steps pace = 10000 × 605/960 = 6302; 3000 is behind (deficit 3302 → 33 min walk);
        // effort done → no Effort line.
        let (nudge, mask) = decide(minuteOfDay: 18 * 60 + 5, firedMask: 0b111, steps: 3_000,
                                   effortToday: 59)
        XCTAssertEqual(mask, 0b11111)
        XCTAssertEqual(nudge?.checkpointIndex, 4)
        XCTAssertEqual(nudge?.body, "Steps 3000/6302/10000  33 min walk")
    }

    func testBeforeTheFirstCheckpointNothingHappens() {
        let (nudge, mask) = decide(minuteOfDay: 9 * 60, steps: 100)
        XCTAssertNil(nudge)
        XCTAssertEqual(mask, 0)
    }

    func testDisabledPacingTouchesNothing() {
        let (nudge, mask) = TargetAutomations.pacingDecision(
            enabled: false, minuteOfDay: 20 * 60, intervalHours: 2, dayStartMinute: 8 * 60, firedMask: 0,
            steps: 0, stepsTarget: 10_000, kcalToday: 0, kcalTarget: 2_525,
            effortToday: 0, effortTarget: 59, sessionMinutes: 45)
        XCTAssertNil(nudge)
        XCTAssertEqual(mask, 0)
    }

    /// Effort is a first-class prorated check (260902): behind its own pace it nudges alone, with
    /// the workout's minutes as the trailing catch-up number; a rest day (target 0) never appears.
    func testEffortNudgesAloneWhenBehindItsProratedPace() {
        let behind = decide(minuteOfDay: 14 * 60, steps: 5_000, effortToday: 3)
        XCTAssertEqual(behind.nudge?.body, "Effort 3/22/59  45 min workout")
        let restDay = decide(minuteOfDay: 14 * 60, steps: 500, effortToday: 3,
                             effortTarget: 0, sessionMinutes: nil)
        XCTAssertNotNil(restDay.nudge)
        XCTAssertFalse(restDay.nudge!.body.contains("Effort"), restDay.nudge!.body)
    }


    /// The waking window starts at the day's ACTUAL wake: an early riser's 14:00 pace is steeper
    /// (more of their day has passed) than the fixed-8:00 assumption would claim.
    func testPaceAnchorsOnTheWake() {
        // Wake 6:00 → by 14:00, 8 of 18 waking hours passed → steps pace 4444, not 3750.
        let (nudge, _) = decide(minuteOfDay: 14 * 60, steps: 4_000, effortToday: 59,
                                dayStartMinute: 6 * 60)
        XCTAssertEqual(nudge?.body, "Steps 4000/4444/10000  5 min walk")
    }

    /// Calories prorate over the 24 h clock, not the waking window — resting burn accrues while
    /// asleep, so a waking-window proration would cry "behind" every morning.
    func testCalProratesOverTheFullClock() {
        // 10:00: clock fraction 0.4167 → cal pace 1052; waking fraction would claim 2525×0.125=315.
        // 800 kcal is comfortably past the waking-window number but behind the clock pace → the
        // line proves the clock proration is the one in force.
        // Effort MET (59 of 59) ⇒ no workout left to quote, so Cal falls back to the walk
        // equivalent — which is the proration under test here.
        let (nudge, _) = decide(minuteOfDay: 10 * 60, steps: 5_000, kcalToday: 800,
                                kcalTarget: 2_525, effortToday: 59)
        XCTAssertEqual(nudge?.body, "Cal 800/1052/2525  63 min walk")
    }
}

/// 260903: NOOP's own nudges can also buzz the strap. Default off, and the coverage is uneven for
/// a stated reason — the buzz needs an encrypted bond AND a running process, so a scheduled
/// calendar notification (the water reminder) cannot buzz as it lands.
final class NudgeWristBuzzTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: TargetAutomations.K.wristBuzz)
        super.tearDown()
    }

    func testDefaultsOffSoAFreshInstallIsSilent() {
        XCTAssertFalse(TargetAutomations.wristBuzzEnabled)
    }

    func testReadsTheToggleTheAutomationsScreenWrites() {
        UserDefaults.standard.set(true, forKey: TargetAutomations.K.wristBuzz)
        XCTAssertTrue(TargetAutomations.wristBuzzEnabled)
        UserDefaults.standard.set(false, forKey: TargetAutomations.K.wristBuzz)
        XCTAssertFalse(TargetAutomations.wristBuzzEnabled)
    }

    /// The buzz sites are the nudges the app posts while AWAKE. Structural, like the recovery
    /// guard: a new NOOP-posted nudge that forgets the buzz shows up here rather than as a cue the
    /// user expected and never felt.
    func testEveryAppPostedNudgeBuzzes() throws {
        let source = try String(contentsOfFile: Self.appModelPath, encoding: .utf8)
        for post in ["auto-morning-brief", "auto-pace-check"] {
            guard let idx = source.components(separatedBy: "\n")
                .firstIndex(where: { $0.contains(post) }) else {
                XCTFail("nudge post site not found: \(post)"); continue
            }
            let lines = source.components(separatedBy: "\n")
            let window = lines[idx...min(idx + 2, lines.count - 1)].joined(separator: " ")
            XCTAssertTrue(window.contains("buzzForNudgeIfEnabled"),
                          "\(post) posts a notification but never offers the wrist buzz")
        }
    }

    private static var appModelPath: String {
        var dir = URL(fileURLWithPath: #filePath)
        dir.deleteLastPathComponent()
        dir.deleteLastPathComponent()
        return dir.appendingPathComponent("Strand/App/AppModel.swift").path
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
