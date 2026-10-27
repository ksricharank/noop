import XCTest
@testable import Strand

/// The square NSS widget's data half (261024c): the published points, their mapping onto the stress
/// trace's domain, the stale-day rule, and the reload-request rule that keeps NSS from spending the
/// background widget budget on every sync. `WidgetSnapshot` and `StressTrace` are compiled into this
/// bundle (project.yml), so these run on macOS exactly as the widget reads them.
final class NSSWidgetSnapshotTests: XCTestCase {

    func testPointsMapOntoTheTraceDomainAndBreakAtGaps() {
        let pts = [NSSPoint(ts: 1_000, nss: 50), NSSPoint(ts: 1_300, nss: 100), NSSPoint(ts: 3_000, nss: 0)]
        let series = NSSPoint.stressSeries(pts)
        XCTAssertEqual(series.map(\.level), [1.5, 3.0, nil, 0.0], "NSS × 3/100, with a hole at the 28-minute gap")
    }

    func testAFinishedDaysCurveIsNotDrawn() {
        let cal = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = WidgetSnapshot.localDayNumber(now, calendar: cal)
        var snap = WidgetSnapshot(recovery: nil, bpm: nil, batteryPct: nil, bonded: false, updated: now,
                                  nssSeries: [NSSPoint(ts: 1, nss: 60)], nssDay: today, nssNow: 60, nssMean: 55)
        XCTAssertEqual(snap.nssCurve(now: now, calendar: cal).count, 1)
        snap.nssDay = today - 1
        XCTAssertTrue(snap.nssCurve(now: now, calendar: cal).isEmpty)
    }

    func testReloadsOnlyForAVisibleStepInNSS() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func snap(_ nssNow: Int?, day: Int = 7) -> WidgetSnapshot {
            WidgetSnapshot(recovery: 80, bpm: nil, batteryPct: nil, bonded: false, updated: now,
                           nssSeries: [NSSPoint(ts: Int64(nssNow ?? 0), nss: Double(nssNow ?? 0))],
                           nssDay: day, nssNow: nssNow)
        }
        XCTAssertFalse(WidgetSnapshot.renderedContentChanged(from: snap(51), to: snap(53)),
                       "a series that moved within the same 5-point step is not worth a reload")
        XCTAssertTrue(WidgetSnapshot.renderedContentChanged(from: snap(53), to: snap(56)))
        XCTAssertTrue(WidgetSnapshot.renderedContentChanged(from: snap(53, day: 7), to: snap(53, day: 8)))
        XCTAssertTrue(WidgetSnapshot.renderedContentChanged(from: snap(nil), to: snap(50)))
    }
}
