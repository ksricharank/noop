import XCTest
@testable import Strand

/// The background-reload budget gate.
///
/// 260906, from the first full-day measurement (`window=00:03:20-20:47:58`):
///
///     Widget background: publishes=235 reloads=66 dedup=169 unseen=0
///     Widget timelines:  requested=108 served=224 reqToBuild=169s avg / 946s max over 43
///
/// 66 background reloads is at or over the OS ceiling (~40–70/day), and `reqToBuild` shows what that
/// bought: WidgetKit deferred each request by 169 s on average, 946 s at worst. Spending MORE would
/// deepen the deferral, so the lever is spending BETTER — the same log's 172 strap syncs collapse
/// into 58 distinct moments once bursts inside two minutes are treated as one.
///
/// These pin the policy, not the plumbing: the coalescer, the urgency pre-emption, the hard cap, and
/// the pacing that stops the allowance being spent by mid-evening.
final class WidgetReloadBudgetTests: XCTestCase {

    private let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!

    private func allowed(_ d: WidgetReloadBudget.Decision) -> Bool {
        if case .allow = d { return true }
        return false
    }

    /// The first reload of a day always lands — there is nothing to coalesce against.
    func testTheFirstReloadOfTheDayIsAllowed() {
        let d = WidgetReloadBudget.decide(change: .init(), lastReloadAt: nil, usedToday: 0, now: noon)
        XCTAssertTrue(allowed(d))
    }

    /// The burst coalescer: a second ordinary change seconds later is withheld. This is the case that
    /// spent 66 reloads — nine syncs in one burst, each moving a rendered value, each reloading.
    func testASecondChangeInsideTheBurstWindowIsCoalesced() {
        let d = WidgetReloadBudget.decide(change: .init(stepsDelta: 30),
                                          lastReloadAt: noon.addingTimeInterval(-10),
                                          usedToday: 1, now: noon)
        guard case .coalesced(let wait) = d else { return XCTFail("expected coalescing, got \(d)") }
        XCTAssertGreaterThan(wait, 0, "a coalesced change must say when the next one can land")
    }

    /// Past the coalescing window an ordinary change lands.
    func testAnOrdinaryChangeAfterTheWindowIsAllowed() {
        let d = WidgetReloadBudget.decide(change: .init(stepsDelta: 30),
                                          lastReloadAt: noon.addingTimeInterval(-WidgetReloadBudget.minSpacing - 1),
                                          usedToday: 1, now: noon)
        XCTAssertTrue(allowed(d))
    }

    /// Water pre-empts the coalescer. Logging a cup is a deliberate act — often the strap double-tap,
    /// which has NO on-screen feedback — and the widget is where the wearer confirms it landed.
    func testWaterPreEmptsTheCoalescer() {
        let justNow = noon.addingTimeInterval(-Double(WidgetReloadBudget.urgentMinSpacing) - 1)
        let water = WidgetReloadBudget.decide(change: .init(waterLogged: true),
                                              lastReloadAt: justNow, usedToday: 1, now: noon)
        XCTAssertTrue(allowed(water), "a logged cup must reach the face promptly")
        // The same instant, without the water flag, is still coalesced — proving it is the urgency
        // doing the work and not the elapsed time.
        let ordinary = WidgetReloadBudget.decide(change: .init(stepsDelta: 30),
                                                 lastReloadAt: justNow, usedToday: 1, now: noon)
        XCTAssertFalse(allowed(ordinary))
    }

    /// A small step drift is NOT urgent. Re-rendering a ring for a dozen steps is the spend that
    /// emptied the budget; a threshold is what separates a visible move from noise.
    func testASmallStepDriftIsNotUrgent() {
        XCTAssertFalse(WidgetReloadBudget.Change(stepsDelta: 12).isUrgent)
        XCTAssertTrue(WidgetReloadBudget.Change(stepsDelta: WidgetReloadBudget.urgentStepsDelta).isUrgent)
    }

    /// Calories and effort drift continuously and are never urgent on their own — neither is acted on
    /// inside two minutes.
    func testDriftingMetricsAreNeverUrgentOnTheirOwn() {
        XCTAssertFalse(WidgetReloadBudget.Change().isUrgent)
    }

    /// The hard cap wins over urgency: past it a request is deferred anyway and deepens the throttle.
    func testTheCapWinsOverUrgency() {
        let d = WidgetReloadBudget.decide(change: .init(waterLogged: true),
                                          lastReloadAt: nil,
                                          usedToday: WidgetReloadBudget.dailyCap, now: noon)
        guard case .capped = d else { return XCTFail("expected capped, got \(d)") }
    }

    /// The cap sits BELOW the bottom of the OS range, which is the point: the 66 spent bought a 169 s
    /// average deferral, so the goal is to stay inside the promptly-served regime.
    func testTheCapIsBelowTheObservedCeiling() {
        XCTAssertLessThan(WidgetReloadBudget.dailyCap, 66,
                          "the cap must be below the spend that produced the 169s deferral")
    }

    /// PACING is a BACKSTOP, not the primary rate. A day that has spent nothing by noon is BEHIND
    /// pace, so the coalescer alone applies — making pace primary throttled a quiet day harder than
    /// a busy one, which is backwards.
    func testAQuietDayIsNotPaceThrottled() {
        XCTAssertFalse(WidgetReloadBudget.isAheadOfPace(usedToday: 2, now: noon),
                       "2 of 48 spent by noon is well behind pace")
        let d = WidgetReloadBudget.decide(change: .init(stepsDelta: 30),
                                          lastReloadAt: noon.addingTimeInterval(-WidgetReloadBudget.minSpacing - 1),
                                          usedToday: 2, now: noon)
        XCTAssertTrue(allowed(d), "a behind-pace day must not be slowed beyond the coalescer")
    }

    /// A day burning the allowance early IS throttled — the case that exhausted a flat 48 at 19:00
    /// and left the evening stale.
    func testADayRunningAheadOfPaceIsThrottled() {
        XCTAssertTrue(WidgetReloadBudget.isAheadOfPace(usedToday: WidgetReloadBudget.dailyCap - 4,
                                                       now: noon),
                      "44 of 48 spent by noon is far ahead of an even burn")
        let spacing = WidgetReloadBudget.paceSpacing(usedToday: WidgetReloadBudget.dailyCap - 4,
                                                     now: noon)
        XCTAssertGreaterThan(spacing, WidgetReloadBudget.minSpacing,
                             "an ahead-of-pace day must space reloads further than the coalescer")
    }

    /// Urgency is never pace-throttled: a logged cup must reach the face whatever the hour, and
    /// pacing an act the wearer just performed is the worst place to save a wake.
    func testUrgencyIsNeverPaceThrottled() {
        let d = WidgetReloadBudget.decide(
            change: .init(waterLogged: true),
            lastReloadAt: noon.addingTimeInterval(-Double(WidgetReloadBudget.urgentMinSpacing) - 1),
            usedToday: WidgetReloadBudget.dailyCap - 4, now: noon)
        XCTAssertTrue(allowed(d), "water must land even on an ahead-of-pace day")
    }

    /// Past the notional end of day pacing stops — a late walk should still reach the face with
    /// whatever is left rather than being saved for the small hours.
    func testPacingStopsAtTheEndOfTheDay() {
        let night = Calendar.current.date(bySettingHour: 23, minute: 30, second: 0, of: Date())!
        XCTAssertEqual(WidgetReloadBudget.paceSpacing(usedToday: 10, now: night), 0)
    }

    /// A clock that moved backwards must not latch the gate shut.
    func testABackwardClockDoesNotLatchTheGateShut() {
        let d = WidgetReloadBudget.decide(change: .init(),
                                          lastReloadAt: noon.addingTimeInterval(3600),
                                          usedToday: 1, now: noon)
        XCTAssertTrue(allowed(d), "a future lastReloadAt must not block reloads for an hour")
    }

    /// The extension's self-refresh interval shortens while budget remains and stretches once spent —
    /// those builds are not budget-charged, but each is a process wake.
    func testTheTimelineIntervalAdaptsToRemainingBudget() {
        let plenty = WidgetReloadBudget.nextTimelineInterval(usedToday: 0)
        let spent = WidgetReloadBudget.nextTimelineInterval(usedToday: WidgetReloadBudget.dailyCap)
        XCTAssertLessThan(plenty, spent, "a spent budget should lean on longer self-refreshes")
        XCTAssertLessThanOrEqual(plenty, 15 * 60,
                                 "while budget remains, self-builds should fill the gaps between reloads")
        XCTAssertEqual(WidgetReloadBudget.nextTimelineInterval(usedToday: 0, isDayComplete: true),
                       60 * 60, "a finished day has nothing left to show")
    }
}
