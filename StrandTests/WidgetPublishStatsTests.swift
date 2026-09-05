import XCTest
@testable import Strand

/// Pins the 260831 widget-publish evidence line: the frozen-widget report showed offloads landing
/// every ~10 minutes while the widgets sat stale, and the exported log carried NOTHING about the
/// publish half — ran / starved / deduped / WidgetKit-deferred were indistinguishable. The line's
/// begun-vs-finished split and the reload/dedup split are what make the next log decisive, so the
/// format and the counting are pinned here.
@MainActor
final class WidgetPublishStatsTests: XCTestCase {

    override func setUp() { super.setUp(); WidgetPublishStats.reset() }
    override func tearDown() { WidgetPublishStats.reset(); super.tearDown() }

    /// The pure formatter: begun/finished split (starvation signature), reloads vs dedup, and the
    /// last-published glance so a stale widget can be compared against what the snapshot said.
    func testLineFormat() {
        XCTAssertEqual(
            WidgetPublishStats.line(begun: 41, finished: 40, live: 6, reloads: 31, dedup: 15,
                                    last: "11:09:15", glance: "steps=5123/8000 cal=1712/2075"),
            "Widget publish today: full=40/41 live=6 reloads=31 dedup=15 last=11:09:15 "
                + "steps=5123/8000 cal=1712/2075")
    }

    /// Silent until a publish ever runs — a macOS or fresh-install log must not carry a zeros line.
    func testSilentWhenNeverRan() {
        XCTAssertEqual(WidgetPublishStats.summaryLines(), [])
    }

    /// Counting: two full publishes (one reload, one dedup skip) and a live tick that reloaded.
    /// The summary reflects all of it, and the glance carries the LAST completed publish's values.
    func testCountsAndGlance() {
        let t = Date(timeIntervalSince1970: 1_788_200_000)
        WidgetPublishStats.recordFullBegun(now: t)
        WidgetPublishStats.recordFullFinished(glance: "steps=100/8000", reloadRequested: true, now: t)
        WidgetPublishStats.recordFullBegun(now: t)
        WidgetPublishStats.recordFullFinished(glance: "steps=200/8000", reloadRequested: false, now: t)
        WidgetPublishStats.recordLive(reloadRequested: true, now: t)
        let lines = WidgetPublishStats.summaryLines(now: t)
        // 260905: the summary grew a background split and a requested-vs-served line. Assert the
        // first line's CONTENT rather than the block's length, so adding a diagnostic line does not
        // fail a test about counting publishes.
        XCTAssertTrue(lines.count >= 1)
        XCTAssertTrue(lines.contains { $0.hasPrefix("Widget background:") },
                      "the fg/bg split must be reported — it is the only line that can say whether "
                      + "the reload budget is the problem")
        XCTAssertTrue(lines[0].contains("full=2/2"), lines[0])
        XCTAssertTrue(lines[0].contains("live=1"), lines[0])
        XCTAssertTrue(lines[0].contains("reloads=2"), lines[0])
        XCTAssertTrue(lines[0].contains("dedup=1"), lines[0])
        XCTAssertTrue(lines[0].hasSuffix("steps=200/8000"), lines[0])
    }

    /// A begun with no finished is the starvation / died-inside-the-path signature — it must be
    /// visible as an attempt, never silently dropped.
    func testBegunWithoutFinishedShows() {
        let t = Date(timeIntervalSince1970: 1_788_200_000)
        WidgetPublishStats.recordFullBegun(now: t)
        let lines = WidgetPublishStats.summaryLines(now: t)
        XCTAssertTrue(lines[0].contains("full=0/1"), lines[0])
    }

    /// Day roll: counters reset on the first record of a new local day; the last-publish record
    /// survives, because "last publish was yesterday" is exactly what a frozen morning widget needs.
    func testDayRollResetsCountersButKeepsLastPublish() {
        let day1 = Date(timeIntervalSince1970: 1_788_200_000)
        WidgetPublishStats.recordFullBegun(now: day1)
        WidgetPublishStats.recordFullFinished(glance: "steps=900/8000", reloadRequested: true, now: day1)
        let day2 = day1.addingTimeInterval(86_400 * 2)
        WidgetPublishStats.recordLive(reloadRequested: false, now: day2)
        let lines = WidgetPublishStats.summaryLines(now: day2)
        XCTAssertTrue(lines[0].contains("full=0/0"), lines[0])
        XCTAssertTrue(lines[0].contains("live=1"), lines[0])
        XCTAssertTrue(lines[0].contains("reloads=0"), lines[0])
        XCTAssertTrue(lines[0].hasSuffix("steps=900/8000"), lines[0])
    }
}

/// The 260905 additions: the fg/bg split, the unseen-change probe and the served counter.
///
/// All three exist to answer ONE question the previous instrumentation could not — "the widgets lag
/// behind the app; is that the OS reload budget, or us?" The old line reported a reload TOTAL, and a
/// total cannot distinguish a healthy day of foreground reloads from a starving day of background
/// ones, because only background requests are charged.
final class WidgetPublishBackgroundStatsTests: XCTestCase {

    /// No background activity is itself an answer, so it must be stated rather than omitted: it
    /// would mean the scenePhase gating, not the budget, is what keeps the widget stale.
    func testNoBackgroundPublishesSaysSoExplicitly() {
        let line = WidgetPublishStats.backgroundLine(publishesBg: 0, reloadsBg: 0, dedupBg: 0,
                                                     unseenBg: 0, firstBg: nil, lastBg: nil)
        XCTAssertTrue(line.contains("none today"), line)
        XCTAssertFalse(line.isEmpty, "an absent line cannot report an absence")
    }

    /// The line must carry the numbers a reduction effort would act on, and name the budget so the
    /// count can be read against it without going back to the source.
    func testTheBackgroundLineCarriesTheActionableNumbers() {
        let line = WidgetPublishStats.backgroundLine(publishesBg: 40, reloadsBg: 31, dedupBg: 9,
                                                     unseenBg: 12, firstBg: "06:12", lastBg: "11:48")
        XCTAssertTrue(line.contains("publishes=40"), line)
        XCTAssertTrue(line.contains("reloads=31"), line)
        XCTAssertTrue(line.contains("unseen=12"), line)
        XCTAssertTrue(line.contains("window=06:12-11:48"),
                      "the window is the deferral signature — a cluster that stops early means the "
                      + "budget went by mid-morning")
        XCTAssertTrue(line.contains("40-70"), "state the budget so the count can be read against it")
    }

    /// Requested vs served is the other half of the pipeline: without it a stale widget cannot be
    /// attributed to iOS dropping requests rather than to a stale snapshot.
    func testTheServedLineReportsBothHalves() {
        let line = WidgetPublishStats.servedLine(requested: 53, served: 11, lastServed: "09:40")
        #if os(iOS)
        XCTAssertTrue(line.contains("requested=53"), line)
        XCTAssertTrue(line.contains("served=11"), line)
        XCTAssertTrue(line.contains("last=09:40"), line)
        #else
        XCTAssertTrue(line.isEmpty, "macOS has no widgets; an always-zero line would read as a fault")
        #endif
    }
}
