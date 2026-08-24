import XCTest
@testable import Strand

/// #1538: what a backgrounded re-score is allowed to attempt, and how it paces itself.
///
/// The rules exist because getting them wrong is expensive in both directions. Too eager and the phone
/// pays for passes it is killed partway through — the livelock in the report, which on-device crash
/// reports showed to be iOS's background CPU limit (`cpu_resource_fatal`, 80% over 60 s). Too shy and a
/// night goes unscored while the app waits for a background task that may not arrive for hours. Neither
/// failure is visible from inside a single run, so they are pinned here rather than discovered on
/// someone's wrist.
///
/// v18 uplift note: upstream's #2296 replaced the measured-duration deferral with rest-pacing, so the
/// tests that pinned `backgroundBudgetSeconds` and `lastCompletedPassSeconds` are gone with the rule
/// they described. The fork's sleep-window rule survives that change unaltered and is pinned below.
final class RescoreBackgroundPolicyTests: XCTestCase {

    private func decide(background: Bool = true,
                        inWindow: Bool = false,
                        unfinished: Bool = false,
                        deferralOnly: Bool = false,
                        realUpdate: Bool = true,
                        running: Bool = false,
                        attemptedSecondsAgo: Double? = 60) -> RescoreBackgroundPolicy.Decision {
        RescoreBackgroundPolicy.decide(isBackground: background,
                                       inSleepWindow: inWindow,
                                       rescoreAlreadyOwed: unfinished,
                                       owedByWindowDeferralOnly: deferralOnly,
                                       isRealUpdate: realUpdate,
                                       passInProgress: running,
                                       secondsSinceLastAttempt: attemptedSecondsAgo)
    }

    private func isDeferred(_ d: RescoreBackgroundPolicy.Decision) -> Bool {
        if case .deferToBackgroundTask = d { return true }
        return false
    }

    private func isDeferredToWindowEnd(_ d: RescoreBackgroundPolicy.Decision) -> Bool {
        if case .deferUntilSleepWindowEnds = d { return true }
        return false
    }

    // MARK: - Foreground is never deferred

    /// The user is looking at the screen and there is no suspension deadline. Deferring here would be a
    /// pure regression: it would turn a pass that works today into one that waits for iOS.
    func testAForegroundPassAlwaysRuns() {
        XCTAssertEqual(decide(background: false), .run)
        XCTAssertEqual(decide(background: false, unfinished: true), .run)
        XCTAssertEqual(decide(background: false, realUpdate: false), .run)
    }

    // MARK: - Background pacing (upstream #2296)

    /// An offload in the background runs now once the spacing since the last pass has passed. It paces
    /// itself under the CPU limit and resumes across wakes, so how long it takes is no longer a reason to
    /// hand it to a processing task that iOS may not grant until the afternoon — which is when last
    /// night's scores used to appear.
    func testABackgroundOffloadRuns() {
        XCTAssertEqual(decide(attemptedSecondsAgo: RescoreBackgroundPolicy.backgroundSpacingSeconds), .run)
        // No recorded attempt (a first pass, or an install from before the attempt time existed).
        XCTAssertEqual(decide(attemptedSecondsAgo: nil), .run)
    }

    // MARK: - Spacing

    /// A strap offloads about every ten minutes, and a pass after each one re-scored the whole window in
    /// the background all day and night. Within the spacing the offload defers, and says why.
    func testABackgroundOffloadWithinTheSpacingDefers() {
        let spacing = RescoreBackgroundPolicy.backgroundSpacingSeconds
        guard case .deferToBackgroundTask(let reason) = decide(attemptedSecondsAgo: 9 * 60) else {
            return XCTFail("expected an offload 9 min after the last pass to defer")
        }
        XCTAssertEqual(reason, "the last pass started 9 min ago; a backgrounded offload re-scores at most every 30 min")
        XCTAssertTrue(isDeferred(decide(attemptedSecondsAgo: 0)))
        XCTAssertTrue(isDeferred(decide(attemptedSecondsAgo: spacing - 1)))
        XCTAssertEqual(decide(attemptedSecondsAgo: spacing), .run)
    }

    /// The spacing is for the background only: an open app re-scores every offload, as before.
    func testSpacingNeverHoldsBackAForegroundPass() {
        XCTAssertEqual(decide(background: false, attemptedSecondsAgo: 0), .run)
    }

    /// A trigger while a pass runs here still reaches the engine, which queues one follow-up. Deferring it
    /// would record a debt the running pass could not settle (#1681); the spacing leaves that path alone.
    func testSpacingLeavesATriggerDuringARunningPassAlone() {
        XCTAssertEqual(decide(running: true, attemptedSecondsAgo: 0), .run)
    }

    /// A clock set back makes the last start look like the future. That is not a recent pass, and waiting
    /// on it could hold scoring back for as long as the clock moved.
    func testALastStartInTheFutureDoesNotDefer() {
        XCTAssertEqual(decide(attemptedSecondsAgo: -600), .run)
    }

    /// The shipped spacing; pinned so a change is deliberate.
    func testTheShippedSpacing() {
        XCTAssertEqual(RescoreBackgroundPolicy.backgroundSpacingSeconds, 30 * 60)
    }

    // MARK: - The livelock

    /// An earlier pass marked itself started and never finished, and nothing is running now: that pass
    /// was killed. Attempting it again on every offload is what burned the phone in #1538.
    func testAnInterruptedPriorAttemptDefersInsteadOfRetrying() {
        XCTAssertTrue(isDeferred(decide(unfinished: true)))
    }

    /// ...but only for a while. A suspended app is routinely terminated for memory, so an unfinished pass
    /// is ordinary; deferring on it forever left a night unscored for 19 hours on one phone.
    func testAnInterruptedAttemptIsRetriedOnceTheCooldownHasPassed() {
        let cooldown = RescoreBackgroundPolicy.interruptedRetryCooldownSeconds
        XCTAssertTrue(isDeferred(decide(unfinished: true, attemptedSecondsAgo: cooldown - 1)))
        XCTAssertEqual(decide(unfinished: true, attemptedSecondsAgo: cooldown), .run)
        // No recorded attempt (an install from before the attempt time existed) is not a recent one.
        XCTAssertEqual(decide(unfinished: true, attemptedSecondsAgo: nil), .run)
    }

    /// A pass running in THIS process reads as owed through its own started-mark. That is not a killed
    /// pass, and deferring on it recorded a newer debt the running pass could then never settle (#1681),
    /// so every later offload deferred too. The engine re-arms a follow-up pass for a mid-run trigger.
    func testARunningPassIsNotMistakenForAKilledOne() {
        XCTAssertEqual(decide(unfinished: true, running: true), .run)
    }

    // MARK: - The backstop

    /// The steady-state tick cannot tell live HR from a real change, and a paced pass costs minutes, so a
    /// backgrounded tick does not run. Real updates run their own.
    func testABackgroundedBackstopDoesNotRun() {
        guard case .deferToBackgroundTask(let reason) = decide(realUpdate: false) else {
            return XCTFail("expected the backstop to be skipped")
        }
        XCTAssertTrue(reason.contains("backstop"), reason)
    }

    // MARK: - Pacing

    /// Resting as long as it worked holds a backgrounded pass near 50% CPU, under the 80% iOS kills at.
    func testABackgroundedPassRestsAsLongAsItWorked() {
        XCTAssertEqual(RescoreBackgroundPolicy.restSeconds(afterWorkSeconds: 12, isBackground: true), 12)
    }

    /// Short units run back to back until a quantum of work has built up: every rest is a chance for iOS to
    /// suspend the process until the next wake, so resting after each night advanced a pass one night a wake.
    func testWorkUnderAQuantumDoesNotRest() {
        let quantum = RescoreBackgroundPolicy.backgroundWorkQuantumSeconds
        XCTAssertEqual(RescoreBackgroundPolicy.restSeconds(afterWorkSeconds: 0.05, isBackground: true), 0)
        XCTAssertEqual(RescoreBackgroundPolicy.restSeconds(afterWorkSeconds: quantum - 0.01, isBackground: true), 0)
        XCTAssertEqual(RescoreBackgroundPolicy.restSeconds(afterWorkSeconds: quantum, isBackground: true), quantum)
    }

    /// No CPU limit applies in the foreground, and the user is waiting on the result.
    func testTheForegroundNeverRests() {
        XCTAssertEqual(RescoreBackgroundPolicy.restSeconds(afterWorkSeconds: 10, isBackground: false), 0)
    }

    /// A backgrounded pass rests for as long as the night's work took, so it sits near 50% duty.
    func testABackgroundedPassRestsForAsLongAsItWorked() {
        XCTAssertEqual(RescoreBackgroundPolicy.restSeconds(afterWorkSeconds: 4, isBackground: true), 4)
    }

    /// Capped, because `uptimeNanoseconds` keeps advancing while the process is merely suspended — an
    /// uncapped rest would stall a pass that has already been idle.
    func testTheRestIsCapped() {
        XCTAssertEqual(RescoreBackgroundPolicy.restSeconds(afterWorkSeconds: 600, isBackground: true),
                       RescoreBackgroundPolicy.maxBackgroundRestSeconds)
    }

    /// An unreadable measurement rests zero rather than stalling the pass on a value that means nothing.
    func testAnUnreadableMeasurementDoesNotRest() {
        XCTAssertEqual(RescoreBackgroundPolicy.restSeconds(afterWorkSeconds: 0, isBackground: true), 0)
        XCTAssertEqual(RescoreBackgroundPolicy.restSeconds(afterWorkSeconds: -1, isBackground: true), 0)
        XCTAssertEqual(RescoreBackgroundPolicy.restSeconds(afterWorkSeconds: .nan, isBackground: true), 0)
        XCTAssertEqual(RescoreBackgroundPolicy.restSeconds(afterWorkSeconds: .infinity, isBackground: true), 0)
    }

    /// The shipped constants are the ones the app uses; pin them so a change is deliberate.
    func testTheShippedPacingConstants() {
        XCTAssertEqual(RescoreBackgroundPolicy.backgroundRestPerWorkSecond, 1.0)
        XCTAssertEqual(RescoreBackgroundPolicy.maxBackgroundRestSeconds, 30)
    }

    // MARK: - The sleep window (the overnight storm)

    /// The motivating case: a pass the other rules would wave through — and DID, 22 times in the
    /// motivating overnight log — still defers inside the sleep window. Nobody can see the score, and
    /// the pass contends with the very offloads that keep triggering it all night.
    func testAFastPassStillDefersInsideTheSleepWindow() {
        XCTAssertTrue(isDeferredToWindowEnd(decide(inWindow: true)))
    }

    /// The window outranks the owed rule, in that exact order: an in-window pass must resolve to the
    /// post-window settle, never to a background task — a processing task favours idle, and idle on a
    /// phone worn to bed is 3 a.m.
    func testTheWindowResolvesToItsEndNotToABackgroundTask() {
        XCTAssertTrue(isDeferredToWindowEnd(decide(inWindow: true, unfinished: true)))
        XCTAssertTrue(isDeferredToWindowEnd(decide(inWindow: true, realUpdate: false)))
    }

    /// Foreground still outranks the window — opening the app at 3 a.m. is an explicit ask for fresh
    /// scores, and there is no suspension deadline.
    func testForegroundOutranksTheWindow() {
        XCTAssertEqual(decide(background: false, inWindow: true), .run)
    }

    /// Daytime (out-of-window) behaviour follows the cadence rules, whatever the lock state. This is the
    /// dogfooding ask — scoring follows the offload cadence during the day, never the lock.
    func testDaytimeBehaviourFollowsTheCadenceRules() {
        XCTAssertEqual(decide(inWindow: false), .run)
        XCTAssertTrue(isDeferred(decide(inWindow: false, realUpdate: false)))
    }

    // MARK: - The morning settle (debt kinds)

    /// The night's coalesced debt — owed ONLY by window deferrals, never attempted — runs at the first
    /// post-window trigger. This IS the "one update once sleep is done": without this rule the owed
    /// check would bounce the morning pass to a background task that may not arrive for hours.
    func testAWindowDeferralDebtRunsAtTheFirstPostWindowTrigger() {
        XCTAssertEqual(decide(unfinished: true, deferralOnly: true), .run)
    }

    /// A debt WITH attempt evidence (a killed pass) keeps the full #1538 escalation — "unfinished" is
    /// evidence about this install right now. The deferral-only flag must never leak onto it.
    func testAKilledPassDebtStillEscalates() {
        XCTAssertTrue(isDeferred(decide(unfinished: true, deferralOnly: false)))
    }

    /// A pass running in THIS process is not evidence of a killed one (#1681): its own started-mark is
    /// what reads as owed, so deferring on it recorded a newer debt the running pass never settled.
    func testAPassInProgressIsNotEvidenceOfAKilledPass() {
        XCTAssertEqual(decide(unfinished: true, running: true), .run)
    }

    /// The backstop tick does not re-score while backgrounded; every real update runs its own pass.
    func testTheBackstopTickDoesNotRescoreInTheBackground() {
        XCTAssertTrue(isDeferred(decide(realUpdate: false)))
    }
}
