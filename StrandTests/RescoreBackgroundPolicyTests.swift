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
                        running: Bool = false) -> RescoreBackgroundPolicy.Decision {
        RescoreBackgroundPolicy.decide(isBackground: background,
                                       inSleepWindow: inWindow,
                                       rescoreAlreadyOwed: unfinished,
                                       owedByWindowDeferralOnly: deferralOnly,
                                       isRealUpdate: realUpdate,
                                       passInProgress: running)
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

    /// The foreground never rests: no CPU limit applies and the user is waiting on the result.
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

    // MARK: - The settle-side gate (the 260829 treadmill)

    private func settle(locked: Bool = true,
                        inWindow: Bool = false,
                        sinceLast: Double? = nil,
                        untilWindowEnd: Double? = nil,
                        spacing: Double = RescoreBackgroundPolicy.lockedSettleSpacingSeconds)
        -> RescoreBackgroundPolicy.SettleDecision {
        RescoreBackgroundPolicy.settleDecision(isLocked: locked,
                                               inSleepWindow: inWindow,
                                               secondsSinceLastLockedSettle: sinceLast,
                                               secondsUntilSleepWindowEnd: untilWindowEnd,
                                               spacingSeconds: spacing)
    }

    private func isSkip(_ d: RescoreBackgroundPolicy.SettleDecision) -> Bool {
        if case .skip = d { return true }
        return false
    }

    /// An unlocked settle is the original #1538 escalation and always runs — the gate exists for the
    /// locked treadmill, and must not slow the case the processing task was built for.
    func testAnUnlockedSettleAlwaysRuns() {
        XCTAssertEqual(settle(locked: false), .run)
        XCTAssertEqual(settle(locked: false, sinceLast: 60), .run)
    }

    /// A settle fired inside the sleep window skips — a task scheduled before the window opened can
    /// still fire mid-night — and carries the window's remaining seconds so the re-arm lands past its
    /// end rather than probing every half hour until morning.
    func testAnInWindowSettleSkipsUntilTheWindowEnds() {
        let d = settle(inWindow: true, untilWindowEnd: 7200)
        guard case .skip(_, let retry) = d else { return XCTFail("must skip inside the window") }
        XCTAssertEqual(retry, 7200)
    }

    /// One locked settle per spacing window: 38 passes in the motivating day, each completing into
    /// "debt NOT settled" because a +N locked sync landed new rows mid-pass. The first is worth having
    /// (the morning widget paint); every repeat inside the spacing is waste and skips, with the
    /// remaining spacing as the retry so the re-armed task does not probe early.
    func testALockedSettleRunsAtMostOncePerSpacing() {
        XCTAssertEqual(settle(sinceLast: nil), .run)
        let d = settle(sinceLast: 1800, spacing: 10800)
        guard case .skip(_, let retry) = d else { return XCTFail("a recent locked settle must skip") }
        XCTAssertEqual(retry, 9000)
        XCTAssertEqual(settle(sinceLast: 10800, spacing: 10800), .run)   // the boundary re-opens
    }

    /// An unreadable elapsed value (clock change, corrupted default) means "unknown", and unknown runs —
    /// same direction as the measured-cost gate: refusing to score on a value we cannot read is the
    /// worse failure.
    func testAnUnreadableElapsedRunsRatherThanSkips() {
        XCTAssertEqual(settle(sinceLast: -30), .run)
        XCTAssertEqual(settle(sinceLast: .nan), .run)
        XCTAssertEqual(settle(sinceLast: .infinity), .run)
    }

    /// The window rule outranks the spacing rule, so a mid-night settle names the window (and its end)
    /// rather than a spacing that may expire while still inside it.
    func testTheWindowOutranksTheSpacing() {
        let d = settle(inWindow: true, sinceLast: 999_999, untilWindowEnd: 3600)
        guard case .skip(let reason, let retry) = d else { return XCTFail("must skip") }
        XCTAssertTrue(reason.contains("sleep window"))
        XCTAssertEqual(retry, 3600)
    }
}
