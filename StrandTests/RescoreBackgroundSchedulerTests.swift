import XCTest
@testable import Strand

/// #1538: the bookkeeping that makes a deferred re-score actually happen.
///
/// The durable mark is the whole mechanism. If it is not set when work is handed to a background task,
/// the task wakes, finds nothing owed, and returns having done nothing — the deferral would silently DROP
/// the pass rather than move it, which is strictly worse than the livelock it replaced. That failure is
/// invisible on macOS (where the app is never backgrounded, so the branch is never taken) and invisible in
/// a single run on iOS (the score just never appears), which is why it is pinned here.
@MainActor
final class RescoreBackgroundSchedulerTests: XCTestCase {

    private var savedOwed: Any?
    private var savedDeferralOnly: Any?
    private var savedSeconds: Any?
    private var savedToken: Any?
    private var savedLockedSettle: Any?

    override func setUp() {
        super.setUp()
        // These live in UserDefaults.standard, shared with every other test in the target. Save and
        // restore rather than assume this suite owns them.
        savedOwed = UserDefaults.standard.object(forKey: RescoreBackgroundScheduler.owedKey)
        savedDeferralOnly = UserDefaults.standard.object(
            forKey: RescoreBackgroundScheduler.owedByWindowDeferralOnlyKey)
        savedSeconds = UserDefaults.standard.object(forKey: RescoreBackgroundScheduler.lastPassSecondsKey)
        savedToken = UserDefaults.standard.object(forKey: RescoreBackgroundScheduler.owedTokenKey)
        savedLockedSettle = UserDefaults.standard.object(
            forKey: RescoreBackgroundScheduler.lastLockedSettleAtKey)
        UserDefaults.standard.removeObject(forKey: RescoreBackgroundScheduler.owedKey)
        UserDefaults.standard.removeObject(forKey: RescoreBackgroundScheduler.owedByWindowDeferralOnlyKey)
        UserDefaults.standard.removeObject(forKey: RescoreBackgroundScheduler.lastPassSecondsKey)
        UserDefaults.standard.removeObject(forKey: RescoreBackgroundScheduler.owedTokenKey)
        UserDefaults.standard.removeObject(forKey: RescoreBackgroundScheduler.lastLockedSettleAtKey)
    }

    override func tearDown() {
        restore(savedOwed, RescoreBackgroundScheduler.owedKey)
        restore(savedDeferralOnly, RescoreBackgroundScheduler.owedByWindowDeferralOnlyKey)
        restore(savedSeconds, RescoreBackgroundScheduler.lastPassSecondsKey)
        restore(savedToken, RescoreBackgroundScheduler.owedTokenKey)
        restore(savedLockedSettle, RescoreBackgroundScheduler.lastLockedSettleAtKey)
        super.tearDown()
    }

    private func restore(_ value: Any?, _ key: String) {
        if let value { UserDefaults.standard.set(value, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    // MARK: - The durable mark

    /// A pass that starts owes a re-score until it finishes. The mark is what a LATER process reads to
    /// discover that an earlier one was killed — the killed process never gets to report anything itself.
    func testAStartedPassOwesUntilItCompletes() {
        XCTAssertFalse(RescoreBackgroundScheduler.isRescoreOwed)
        let token = RescoreBackgroundScheduler.markRescoreOwed()
        XCTAssertTrue(RescoreBackgroundScheduler.isRescoreOwed)
        RescoreBackgroundScheduler.markRescoreCompleted(seconds: 12, owedToken: token)
        XCTAssertFalse(RescoreBackgroundScheduler.isRescoreOwed)
    }

    /// Only a completed pass banks a duration, and only a usable one — the policy reads this to decide
    /// whether a background wake can finish the work, so a garbage value must read as "no measurement"
    /// rather than as a number.
    func testOnlyAUsableDurationIsBanked() {
        RescoreBackgroundScheduler.markRescoreCompleted(seconds: 474.778, owedToken: nil)   // fixture: bank a duration, settle nothing
        XCTAssertEqual(RescoreBackgroundScheduler.lastCompletedPassSeconds ?? 0, 474.778, accuracy: 0.001)

        RescoreBackgroundScheduler.markRescoreCompleted(seconds: .nan, owedToken: nil)   // fixture: bank a duration, settle nothing
        XCTAssertEqual(RescoreBackgroundScheduler.lastCompletedPassSeconds ?? 0, 474.778, accuracy: 0.001,
                       "a NaN must not overwrite a good measurement")

        UserDefaults.standard.removeObject(forKey: RescoreBackgroundScheduler.lastPassSecondsKey)
        XCTAssertNil(RescoreBackgroundScheduler.lastCompletedPassSeconds)
    }

    // MARK: - Deferral must move the work, never drop it

    /// The bug this file exists for: deferring has to record the debt, or the background task it defers
    /// to has nothing to find.
    func testDeferringMarksTheWorkOwedAndDoesNotRunIt() async {
        // A measured pass far over the background budget, so the policy defers.
        RescoreBackgroundScheduler.markRescoreCompleted(seconds: 474.778, owedToken: nil)   // fixture: bank a duration, settle nothing
        XCTAssertFalse(RescoreBackgroundScheduler.isRescoreOwed)

        var ran = false
        var logged: [String] = []
        await RescoreBackgroundScheduler.run(isBackground: true, inSleepWindow: false, log: { logged.append($0) }) {
            ran = true
        }

        XCTAssertFalse(ran, "the pass must not be started in a context that cannot finish it")
        XCTAssertTrue(RescoreBackgroundScheduler.isRescoreOwed,
                      "the deferred work must be recorded, or the background task does nothing")
        XCTAssertEqual(logged.count, 1)
        XCTAssertTrue(logged[0].contains("deferred"), logged[0])
        XCTAssertTrue(logged[0].contains("475"), logged[0])
    }

    /// A foregrounded pass runs, whatever the measurement says. This is the case the mechanism must not
    /// break: there is no suspension deadline, so deferring would be a pure regression.
    func testAForegroundPassRunsEvenWhenSlow() async {
        RescoreBackgroundScheduler.markRescoreCompleted(seconds: 474.778, owedToken: nil)   // fixture: bank a duration, settle nothing

        var ran = false
        var logged: [String] = []
        await RescoreBackgroundScheduler.run(isBackground: false, log: { logged.append($0) }) {
            ran = true
        }

        XCTAssertTrue(ran)
        XCTAssertTrue(logged.isEmpty, "a pass that simply runs should not narrate itself")
    }

    /// A background pass with no measurement yet is allowed to run — that is how the measurement is
    /// acquired, and a first attempt costs at most one pass.
    func testAnUnmeasuredBackgroundPassRuns() async {
        var ran = false
        await RescoreBackgroundScheduler.run(isBackground: true, inSleepWindow: false, log: { _ in }) { ran = true }
        XCTAssertTrue(ran)
    }

    /// Once work is owed, a further background trigger defers instead of starting a duplicate pass. This
    /// is the livelock fix: #1538 paid for a full eight-minute pass on every offload because nothing
    /// remembered that the previous one had not finished.
    func testASecondBackgroundTriggerDoesNotStartADuplicatePass() async {
        RescoreBackgroundScheduler.markRescoreOwed()

        var ran = false
        await RescoreBackgroundScheduler.run(isBackground: true, inSleepWindow: false, log: { _ in }) { ran = true }
        XCTAssertFalse(ran)
    }

    // MARK: - The backstop tick owes nothing

    /// The steady-state tick is a backstop: every real update forces its own pass, so a tick that cannot
    /// run here is simply skipped. Recording a debt for it would send a processing task off to run a
    /// forced full pass when most likely nothing changed — the churn #1146 exists to avoid.
    func testASkippedBackstopDoesNotConjureADebt() async {
        RescoreBackgroundScheduler.markRescoreCompleted(seconds: 474.778, owedToken: nil)   // fixture: bank a duration, settle nothing

        var ran = false
        var logged: [String] = []
        await RescoreBackgroundScheduler.run(isBackground: true, inSleepWindow: false, owesOnDefer: false,
                                             log: { logged.append($0) }) { ran = true }

        XCTAssertFalse(ran, "a backstop that cannot finish here must not start")
        XCTAssertFalse(RescoreBackgroundScheduler.isRescoreOwed,
                       "a skipped backstop owes nothing — no real update went unscored")
        XCTAssertEqual(logged.count, 1)
        XCTAssertTrue(logged[0].contains("backstop"), logged[0])
        XCTAssertFalse(logged[0].contains("deferred"),
                       "must not promise a background task that is not coming: \(logged[0])")
    }

    /// ...but a debt a REAL pass already recorded survives a skipped backstop untouched. Clearing it
    /// here would strand the very work the mechanism exists to rescue.
    func testASkippedBackstopLeavesAnExistingDebtAlone() async {
        RescoreBackgroundScheduler.markRescoreOwed()

        await RescoreBackgroundScheduler.run(isBackground: true, inSleepWindow: false, owesOnDefer: false, log: { _ in }) {}

        XCTAssertTrue(RescoreBackgroundScheduler.isRescoreOwed)
    }

    /// A backstop still RUNS in the foreground, and in a background that can afford it — the flag changes
    /// only what a deferral records, never whether the pass happens.
    func testABackstopStillRunsWhenItCan() async {
        var foreground = false
        await RescoreBackgroundScheduler.run(isBackground: false, owesOnDefer: false,
                                             log: { _ in }) { foreground = true }
        XCTAssertTrue(foreground)

        var affordable = false
        RescoreBackgroundScheduler.markRescoreCompleted(seconds: 3, owedToken: nil)   // fixture: bank a duration, settle nothing
        await RescoreBackgroundScheduler.run(isBackground: true, inSleepWindow: false, owesOnDefer: false,
                                             log: { _ in }) { affordable = true }
        XCTAssertTrue(affordable)
    }

    // MARK: - #1681: whose debt is it?

    /// The reported bug. A pass records its debt, and while it is running a LATER trigger records another
    /// — for data that arrived after this pass had already read its inputs. Completion used to clear one
    /// global boolean unconditionally, erasing that newer debt before the correction it was recorded for
    /// ever ran. The night stayed scored from a partial sync until something unrelated happened to
    /// re-score it.
    func testADebtRecordedMidPassSurvivesThatPassCompleting() {
        let mine = RescoreBackgroundScheduler.markRescoreOwed()
        _ = RescoreBackgroundScheduler.markRescoreOwed()   // a later trigger, while the pass is still running

        RescoreBackgroundScheduler.markRescoreCompleted(seconds: 9, owedToken: mine)

        XCTAssertTrue(RescoreBackgroundScheduler.isRescoreOwed,
                      "the newer debt must outlive the pass that did not pay it")
    }

    /// …and the pass that DOES hold the current token still settles, or the flag would never clear and
    /// every launch would re-score forever.
    func testTheHolderOfTheCurrentTokenSettles() {
        _ = RescoreBackgroundScheduler.markRescoreOwed()
        let latest = RescoreBackgroundScheduler.markRescoreOwed()
        RescoreBackgroundScheduler.markRescoreCompleted(seconds: 9, owedToken: latest)
        XCTAssertFalse(RescoreBackgroundScheduler.isRescoreOwed)
    }

    /// The duration is telemetry about THIS pass and is banked either way — it is true regardless of
    /// whose debt is now outstanding, and the policy needs it to size a background wake.
    func testAPassThatCannotSettleStillBanksItsDuration() {
        let mine = RescoreBackgroundScheduler.markRescoreOwed()
        _ = RescoreBackgroundScheduler.markRescoreOwed()
        RescoreBackgroundScheduler.markRescoreCompleted(seconds: 33.5, owedToken: mine)
        XCTAssertEqual(RescoreBackgroundScheduler.lastCompletedPassSeconds ?? 0, 33.5, accuracy: 0.001)
    }

    // MARK: - the settlement rule itself

    /// A pass with NO token never settles. That costs one extra pass; the other direction costs a night's
    /// scores until something unrelated re-scores it, which is the failure being fixed.
    func testNoTokenNeverSettles() {
        XCTAssertFalse(RescoreBackgroundScheduler.maySettleDebt(capturedToken: nil, currentToken: "a"))
        XCTAssertFalse(RescoreBackgroundScheduler.maySettleDebt(capturedToken: "", currentToken: ""))
    }

    func testOnlyTheCurrentTokenSettles() {
        XCTAssertTrue(RescoreBackgroundScheduler.maySettleDebt(capturedToken: "a", currentToken: "a"))
        XCTAssertFalse(RescoreBackgroundScheduler.maySettleDebt(capturedToken: "a", currentToken: "b"))
        XCTAssertFalse(RescoreBackgroundScheduler.maySettleDebt(capturedToken: "a", currentToken: nil))
    }

    /// Each mark stamps a DISTINCT token. A counter would need read-modify-write, and two triggers marking
    /// at the same moment could both read N and both write N+1 — losing exactly the debt this protects.
    func testEveryMarkStampsADistinctToken() {
        let seen = Set((0..<50).map { _ in RescoreBackgroundScheduler.markRescoreOwed() })
        XCTAssertEqual(seen.count, 50)
    }

    // MARK: - the outcome has to be reportable

    /// Declining is the interesting outcome, and the caller can only SAY so if it is told. #1538 cost
    /// three nights because the log recorded that scoring had not happened without recording why; a pass
    /// that completes while leaving the mark set looks identical in a capture to one that cleared it.
    func testCompletionReportsWhetherItSettled() {
        let mine = RescoreBackgroundScheduler.markRescoreOwed()
        _ = RescoreBackgroundScheduler.markRescoreOwed()
        XCTAssertFalse(RescoreBackgroundScheduler.markRescoreCompleted(seconds: 1, owedToken: mine),
                       "a pass that could not settle must report that, or the log cannot explain itself")

        let latest = RescoreBackgroundScheduler.markRescoreOwed()
        XCTAssertTrue(RescoreBackgroundScheduler.markRescoreCompleted(seconds: 1, owedToken: latest))
    }

    // MARK: - The sleep window

    /// The overnight storm: a pass the measured rule would wave through (fast last pass) must not start
    /// inside the sleep window — the debt is recorded as DEFERRAL-ONLY, so the first post-window trigger
    /// simply runs it. No background task is scheduled for an in-window deferral.
    func testAnInWindowDeferralMarksADeferralOnlyDebt() async {
        RescoreBackgroundScheduler.markRescoreCompleted(seconds: 3, owedToken: nil)   // fast: would run outside the window
        XCTAssertFalse(RescoreBackgroundScheduler.isRescoreOwed)

        var ran = false
        var logged: [String] = []
        await RescoreBackgroundScheduler.run(isBackground: true, inSleepWindow: true,
                                             log: { logged.append($0) }) { ran = true }

        XCTAssertFalse(ran, "the sleep window must not pay for a pass nobody can see")
        XCTAssertTrue(RescoreBackgroundScheduler.isRescoreOwed,
                      "the deferred work must be recorded, or the morning settle finds nothing")
        XCTAssertTrue(RescoreBackgroundScheduler.isOwedByWindowDeferralOnly,
                      "an in-window deferral is never-attempted work — the post-window trigger may run it")
        XCTAssertEqual(logged.count, 1)
        XCTAssertTrue(logged[0].contains("sleep window"), logged[0])
    }

    /// The full night → morning arc: in-window triggers coalesce into one deferral-only debt, and the
    /// first post-window background trigger RUNS the pass (the morning settle) instead of bouncing it
    /// to a background task.
    func testTheMorningSettleRunsAtTheFirstPostWindowTrigger() async {
        RescoreBackgroundScheduler.markRescoreCompleted(seconds: 3, owedToken: nil)
        // Three overnight offloads, one debt.
        for _ in 0..<3 {
            await RescoreBackgroundScheduler.run(isBackground: true, inSleepWindow: true, log: { _ in }) {}
        }
        XCTAssertTrue(RescoreBackgroundScheduler.isOwedByWindowDeferralOnly)

        var ran = false
        await RescoreBackgroundScheduler.run(isBackground: true, inSleepWindow: false, log: { _ in }) {
            ran = true
        }
        XCTAssertTrue(ran, "the first post-window trigger IS the morning settle")
    }

    /// A killed-pass debt keeps its meaning through the night: overnight deferrals piling on top must
    /// not downgrade it to deferral-only, or the morning trigger would re-attempt in the background a
    /// pass the phone has already proved it cannot finish there (#1538's exact livelock).
    func testOvernightDeferralsNeverDowngradeAKilledPassDebt() async {
        RescoreBackgroundScheduler.markRescoreOwed()   // attempt evidence (a pass started and was killed)
        RescoreBackgroundScheduler.markRescoreDeferredForSleepWindow()
        XCTAssertTrue(RescoreBackgroundScheduler.isRescoreOwed)
        XCTAssertFalse(RescoreBackgroundScheduler.isOwedByWindowDeferralOnly,
                       "the stronger killed-pass meaning must survive any number of deferrals")
    }

    /// The in-window backstop owes nothing, same contract as the backgrounded backstop: every real
    /// update records its own debt, so the tick skipping quietly must not conjure a forced morning pass.
    func testAnInWindowBackstopSkipsWithoutOwing() async {
        var ran = false
        var logged: [String] = []
        await RescoreBackgroundScheduler.run(isBackground: true, inSleepWindow: true, owesOnDefer: false,
                                             log: { logged.append($0) }) { ran = true }

        XCTAssertFalse(ran)
        XCTAssertFalse(RescoreBackgroundScheduler.isRescoreOwed)
        XCTAssertEqual(logged.count, 1)
        XCTAssertTrue(logged[0].contains("skipped"), logged[0])
    }

    // MARK: - The locked-settle pacing stamp (the 260829 treadmill)

    /// The stamp survives a round trip and only a readable value counts — the accessor's nil is what
    /// lets the settle gate run when the history is unknown, so garbage must read as nil, not as "just
    /// settled" (which would silence the very pass the debt is waiting on).
    func testTheLockedSettleStampRoundTrips() {
        XCTAssertNil(RescoreBackgroundScheduler.lastLockedSettleAt)
        let now = Date()
        RescoreBackgroundScheduler.markLockedSettleCompleted(now: now)
        XCTAssertEqual(RescoreBackgroundScheduler.lastLockedSettleAt?.timeIntervalSince1970 ?? 0,
                       now.timeIntervalSince1970, accuracy: 0.001)
        UserDefaults.standard.set(-5.0, forKey: RescoreBackgroundScheduler.lastLockedSettleAtKey)
        XCTAssertNil(RescoreBackgroundScheduler.lastLockedSettleAt)
    }

    /// The re-armed task must land past the window's END, including across midnight — an 22:00–07:00
    /// window probed at 23:30 has 7.5 h left, not −16.5 h. The buffer keeps it off the exact edge.
    func testSecondsUntilWindowEndWrapsMidnight() {
        XCTAssertEqual(RescoreBackgroundScheduler.secondsUntilWindowEnd(
            minuteOfDay: 23 * 60 + 30, endMinute: 7 * 60, bufferSeconds: 300),
            7.5 * 3600 + 300)
        XCTAssertEqual(RescoreBackgroundScheduler.secondsUntilWindowEnd(
            minuteOfDay: 6 * 60, endMinute: 7 * 60, bufferSeconds: 300),
            3600 + 300)
    }

    // 260901 light-pass battery fix, maintainer-bounded: the post-offload light pass runs while
    // the debt is owed EXCEPT during the after-midnight leg of the sleep window (00:00 → window
    // end). The evening leg (window start → midnight) still updates — the user is awake and the
    // day rolls at local midnight — so for the default 22:00–06:15 window the blackout is
    // exactly 00:00–06:15, and the first post-window sync picks the work straight back up.
    func testLightPassSkipsOnlyTheAfterMidnightLegOfTheSleepWindow() {
        let end = 6 * 60 + 15   // 06:15
        // Evening leg: in-window but before midnight — still updates.
        XCTAssertTrue(RescoreBackgroundScheduler.lightPassWanted(
            owed: true, inSleepWindow: true, minuteOfDay: 23 * 60 + 30, windowEndMinute: end),
            "22:00–24:00 keeps updating — the numerators still move and the user is awake")
        // After-midnight leg: blacked out.
        XCTAssertFalse(RescoreBackgroundScheduler.lightPassWanted(
            owed: true, inSleepWindow: true, minuteOfDay: 1 * 60, windowEndMinute: end),
            "00:00 → window end must not burn a light pass on numerators that cannot move")
        XCTAssertFalse(RescoreBackgroundScheduler.lightPassWanted(
            owed: true, inSleepWindow: true, minuteOfDay: 0, windowEndMinute: end),
            "midnight exactly is the cutoff the maintainer chose")
        // Outside the window: normal daytime operation.
        XCTAssertTrue(RescoreBackgroundScheduler.lightPassWanted(
            owed: true, inSleepWindow: false, minuteOfDay: 14 * 60, windowEndMinute: end))
        // A non-wrapped window (01:00–06:00) lies entirely after midnight: all of it skips.
        XCTAssertFalse(RescoreBackgroundScheduler.lightPassWanted(
            owed: true, inSleepWindow: true, minuteOfDay: 3 * 60, windowEndMinute: 6 * 60))
        // No debt means the full pass already ran — the day rows are fresh, nothing to do.
        XCTAssertFalse(RescoreBackgroundScheduler.lightPassWanted(
            owed: false, inSleepWindow: false, minuteOfDay: 14 * 60, windowEndMinute: end))
    }
}
