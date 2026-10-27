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

    /// 260907: THIS TEST ENCODED A FALSIFIED THEORY, and is inverted rather than deleted.
    ///
    /// It asserted the cap must sit below 66 — the spend that "produced" the 169 s deferral. The
    /// 260907 log disproved the causation: spend fell to 42 and the deferral got WORSE (169 s → 186 s
    /// avg, 946 s → 2044 s max). WidgetKit was never throttling us for overspending, so a tight cap
    /// cost freshness and bought nothing.
    ///
    /// The cap now exists only as a runaway guard, so what is worth pinning is the opposite: it must
    /// be high enough NOT to ration normal traffic. The strap produces ~58 sync moments a day and the
    /// coalescer collapses them to ~62 reloads, so anything at or above ~70 never binds.
    ///
    /// Kept as a test rather than removed, because the wrong version of it is exactly what a future
    /// reader would otherwise re-derive from the 16.16 notes.
    func testTheCapDoesNotRationNormalTraffic() {
        XCTAssertGreaterThan(WidgetReloadBudget.dailyCap, 70,
                             "the cap is a runaway guard, not a budget: the 260907 log showed that "
                             + "spending less made the deferral worse, so rationing normal traffic "
                             + "costs freshness for no measured gain")
    }

    /// 260907: the pace backstop is NO LONGER CONSULTED, and this pins that.
    ///
    /// It existed to stop a busy morning exhausting a tight 48 by 19:00. With the cap retired to a
    /// runaway guard there is no scarce allowance to spread, and keeping the term would throttle a
    /// normal day for no benefit — the same mistake as the tight cap, one layer down.
    ///
    /// A day sitting well past an even burn must therefore still be admitted at the coalescer's rate.
    func testTheCoalescerIsTheOnlyRateLimitNow() {
        // Deliberately a spend that the OLD pace term would have throttled hard.
        let d = WidgetReloadBudget.decide(
            change: .init(stepsDelta: 30),
            lastReloadAt: noon.addingTimeInterval(-WidgetReloadBudget.minSpacing - 1),
            usedToday: 40, now: noon)
        XCTAssertTrue(allowed(d),
                      "past the coalescer's floor a reload must land; pacing is retired")
    }

    /// The pace helpers are RETAINED (they are the right shape if a real budget ever returns) but
    /// nothing consults them. Asserted on the source, because "is it wired in" is not observable
    /// from the outputs once the answer is no.
    func testThePaceHelpersAreNoLongerWiredIn() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent()
        let src = try String(
            contentsOf: root.appendingPathComponent("StrandiOSShared/WidgetReloadBudget.swift"),
            encoding: .utf8)
        guard let decideRange = src.range(of: "public static func decide(") else {
            return XCTFail("decide() has moved; this guard needs re-pointing")
        }
        let body = String(src[decideRange.upperBound...].prefix(1600))
        XCTAssertFalse(body.contains("isAheadOfPace(usedToday:"),
                       "decide() must not consult the pace backstop any more: \(body.prefix(200))")
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

    /// The extension's self-refresh interval stretches as the day accumulates reloads.
    ///
    /// 260907: keyed on ABSOLUTE spend, not on headroom under the cap. The old form was
    /// `dailyCap - usedToday`, which with the cap at 200 would report "plenty left" every hour of
    /// every day and never reach the longer intervals — a threshold silently detuned by a change
    /// somewhere else. This test now uses absolute counts for the same reason the code does.
    func testTheTimelineIntervalStretchesAsTheDayFills() {
        let early = WidgetReloadBudget.nextTimelineInterval(usedToday: 0)
        let late = WidgetReloadBudget.nextTimelineInterval(usedToday: 150)
        XCTAssertLessThan(early, late, "a day that has already reloaded a lot can self-refresh slower")
        XCTAssertLessThanOrEqual(early, 15 * 60,
                                 "early in the day the self-builds fill the gaps between reloads")
        XCTAssertEqual(WidgetReloadBudget.nextTimelineInterval(usedToday: 0, isDayComplete: true),
                       60 * 60, "a finished day has nothing left to show")
    }
}
