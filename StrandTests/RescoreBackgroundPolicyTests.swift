import XCTest
@testable import Strand

/// #1538: what a backgrounded re-score is allowed to attempt.
///
/// The rules exist because getting them wrong is expensive in both directions. Too eager and the phone
/// pays for a full eight-minute pass on every offload that it will never be allowed to finish — the
/// livelock in the report. Too shy and a night goes unscored while the app waits for a background task
/// that may not arrive for hours. Neither failure is visible from inside a single run, so they are pinned
/// here rather than discovered on someone's wrist.
final class RescoreBackgroundPolicyTests: XCTestCase {

    private func decide(background: Bool = true,
                        inWindow: Bool = false,
                        unfinished: Bool = false,
                        deferralOnly: Bool = false,
                        lastSeconds: Double? = nil,
                        budget: Double = 20) -> RescoreBackgroundPolicy.Decision {
        RescoreBackgroundPolicy.decide(isBackground: background,
                                       inSleepWindow: inWindow,
                                       rescoreAlreadyOwed: unfinished,
                                       owedByWindowDeferralOnly: deferralOnly,
                                       lastCompletedPassSeconds: lastSeconds,
                                       budgetSeconds: budget)
    }

    private func isDeferred(_ d: RescoreBackgroundPolicy.Decision) -> Bool {
        if case .deferToBackgroundTask = d { return true }
        return false
    }

    // MARK: - Foreground is never deferred

    /// The user is looking at the screen and there is no suspension deadline. Deferring here would be a
    /// pure regression: it would turn a pass that works today into one that waits for iOS.
    func testAForegroundPassAlwaysRuns() {
        XCTAssertEqual(decide(background: false), .run)
        XCTAssertEqual(decide(background: false, unfinished: true), .run)
        XCTAssertEqual(decide(background: false, lastSeconds: 9_999), .run)
    }

    // MARK: - The livelock

    /// The core fix. An earlier pass marked itself started and never finished, which survives process
    /// death — so the phone has already proved once that it cannot complete this work in the background.
    /// Attempting it again is what burned nearly eight minutes per offload in #1538 while producing
    /// nothing.
    func testAnInterruptedPriorAttemptDefersInsteadOfRetrying() {
        XCTAssertTrue(isDeferred(decide(unfinished: true)))
    }

    /// ...and it defers even when the last COMPLETED pass looks fast, because "unfinished" is evidence
    /// about this install right now, whereas the measurement may predate the history that made it slow.
    func testAnInterruptedAttemptOutranksAFastMeasurement() {
        XCTAssertTrue(isDeferred(decide(unfinished: true, lastSeconds: 2)))
    }

    // MARK: - The measurement

    /// A pass measured well inside the budget is exactly what SHOULD run in the background — that is the
    /// case this whole mechanism must not break.
    func testAPassThatFitsTheBudgetRuns() {
        XCTAssertEqual(decide(lastSeconds: 5), .run)
    }

    /// The reporter's install: 474.778 s against a 20 s budget.
    func testTheReportedPassDefers() {
        XCTAssertTrue(isDeferred(decide(lastSeconds: 474.778)))
    }

    /// The boundary is stated rather than inherited: equal to the budget still runs, over it defers.
    func testTheBudgetBoundary() {
        XCTAssertEqual(decide(lastSeconds: 20, budget: 20), .run)
        XCTAssertTrue(isDeferred(decide(lastSeconds: 20.001, budget: 20)))
    }

    /// The reason is carried into the strap log, so it has to name the numbers that drove the decision.
    /// #1538 was three nights of chasing BLE because the log recorded that scoring had not happened
    /// without ever recording why.
    func testTheDeferralReasonNamesTheMeasurementAndTheBudget() {
        guard case .deferToBackgroundTask(let reason) = decide(lastSeconds: 475, budget: 20) else {
            return XCTFail("expected a deferral")
        }
        XCTAssertTrue(reason.contains("475"), reason)
        XCTAssertTrue(reason.contains("20"), reason)
    }

    // MARK: - Unknown is not "too slow"

    /// Nothing has ever completed on this install, so there is no measurement to defer on. Running is the
    /// only way to acquire one, and a first attempt costs at most one pass.
    func testAnInstallWithNoMeasurementRuns() {
        XCTAssertEqual(decide(lastSeconds: nil), .run)
    }

    /// A corrupted or absent default must never be read as "slow". Refusing to score on the strength of
    /// a value that cannot be interpreted is a far worse failure than one wasted pass.
    func testUnreadableMeasurementsRunRatherThanDefer() {
        XCTAssertEqual(decide(lastSeconds: 0), .run)
        XCTAssertEqual(decide(lastSeconds: -1), .run)
        XCTAssertEqual(decide(lastSeconds: .nan), .run)
        XCTAssertEqual(decide(lastSeconds: .infinity), .run)
    }

    /// A nonsensical budget disables the measurement rule rather than deferring everything — the same
    /// principle, applied to the other input.
    func testANonPositiveBudgetDoesNotDeferEverything() {
        XCTAssertEqual(decide(lastSeconds: 9_999, budget: 0), .run)
        XCTAssertEqual(decide(lastSeconds: 9_999, budget: -5), .run)
    }

    /// The shipped budget is the one the app actually uses; pin it so a change is deliberate.
    func testTheDefaultBudgetIsTheShippedOne() {
        XCTAssertEqual(RescoreBackgroundPolicy.backgroundBudgetSeconds, 20)
        XCTAssertTrue(isDeferred(RescoreBackgroundPolicy.decide(
            isBackground: true, inSleepWindow: false,
            rescoreAlreadyOwed: false, owedByWindowDeferralOnly: false,
            lastCompletedPassSeconds: 21)))
    }

    // MARK: - The sleep window (the overnight storm)

    private func isDeferredToWindowEnd(_ d: RescoreBackgroundPolicy.Decision) -> Bool {
        if case .deferUntilSleepWindowEnds = d { return true }
        return false
    }

    /// The motivating case: a pass measured comfortably inside the budget — which the measured rule
    /// would wave through, and DID, 22 times in the motivating overnight log — still defers inside the
    /// sleep window. Nobody can see the score, and the pass contends with the very offloads that keep
    /// triggering it all night.
    func testAFastPassStillDefersInsideTheSleepWindow() {
        XCTAssertTrue(isDeferredToWindowEnd(decide(inWindow: true, lastSeconds: 5)))
    }

    /// The window outranks the owed and measured rules, in that exact order: an in-window pass must
    /// resolve to the post-window settle, never to a background task — a processing task favours idle,
    /// and idle on a phone worn to bed is 3 a.m.
    func testTheWindowResolvesToItsEndNotToABackgroundTask() {
        XCTAssertTrue(isDeferredToWindowEnd(decide(inWindow: true, unfinished: true)))
        XCTAssertTrue(isDeferredToWindowEnd(decide(inWindow: true, lastSeconds: 475)))
        XCTAssertTrue(isDeferredToWindowEnd(decide(inWindow: true)))
    }

    /// Foreground still outranks the window — opening the app at 3 a.m. is an explicit ask for fresh
    /// scores, and there is no suspension deadline. Same invariant as `testAForegroundPassAlwaysRuns`,
    /// extended to the new input.
    func testForegroundOutranksTheWindow() {
        XCTAssertEqual(decide(background: false, inWindow: true), .run)
    }

    /// Daytime (out-of-window) background behaviour is byte-identical to the pre-window rules: the fast
    /// pass runs on its trigger whatever the lock state, the slow one defers to a background task. This
    /// is the dogfooding ask — scoring follows the offload cadence during the day, never the lock.
    func testDaytimeBehaviourFollowsTheCadenceRules() {
        XCTAssertEqual(decide(inWindow: false, lastSeconds: 5), .run)
        XCTAssertTrue(isDeferred(decide(inWindow: false, lastSeconds: 475)))
    }

    // MARK: - The morning settle (debt kinds)

    /// The night's coalesced debt — owed ONLY by window deferrals, never attempted — runs at the first
    /// post-window trigger. This IS the "one update once sleep is done": without this rule the owed
    /// check would bounce the morning pass to a background task that may not arrive for hours.
    func testAWindowDeferralDebtRunsAtTheFirstPostWindowTrigger() {
        XCTAssertEqual(decide(unfinished: true, deferralOnly: true, lastSeconds: 5), .run)
        XCTAssertEqual(decide(unfinished: true, deferralOnly: true), .run)
    }

    /// ...but the measured rule still applies to it: a deferral-only debt on an install whose passes
    /// can't finish in a background wake escalates honestly instead of being killed mid-run.
    func testAWindowDeferralDebtStillHonoursTheMeasuredRule() {
        XCTAssertTrue(isDeferred(decide(unfinished: true, deferralOnly: true, lastSeconds: 475)))
    }

    /// A debt WITH attempt evidence (a killed pass) keeps the full #1538 escalation even when fast —
    /// "unfinished" is evidence about this install right now. The deferral-only flag must never leak
    /// onto it.
    func testAKilledPassDebtStillEscalates() {
        XCTAssertTrue(isDeferred(decide(unfinished: true, deferralOnly: false, lastSeconds: 2)))
    }
}
