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
        XCTAssertEqual(lines.count, 1)
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
