import XCTest
@testable import Strand
@testable import StrandAnalytics

/// Detecting a stored series computed under a retired formula (260909).
///
/// Reported twice: the score card showed a correct value while the trend chart, week summary and
/// calendar below it showed numbers from an older formula. The first repair gated on
/// `DayQualityPrefs.configChanged`, which was the wrong signal — a latch records that a pass RAN, not
/// that the stored values match the current formula, so a pass that latched under one formula leaves
/// the series looking complete to the next one.
///
/// The check is now on the VALUES, which cannot go stale the way a flag can.
@MainActor
final class DayQualityStaleSeriesTests: XCTestCase {

    /// The reported series: 25 days, all positive, best 77 — which is exactly 50 × 1.25 + 15, the
    /// ceiling of a retired overshoot cap. No current setting can produce a series like this.
    func testTheReportedStaleSeriesIsDetected() {
        var series: [String: Double] = [:]
        let values: [Double] = [77, 62, 64, 66, 71, 65, 55, 57, 60, 60, 47, 28, 5,
                                55, 58, 61, 63, 59, 52, 54, 56, 58, 44, 30, 12]
        for (i, v) in values.enumerated() {
            series[String(format: "2026-08-%02d", i + 15)] = v
        }
        XCTAssertTrue(DayQualityView.seriesLooksStale(series),
                      "25 dense days with nothing at or below zero cannot come from a scale whose "
                      + "zero is an ordinary sedentary day")
    }

    /// A value outside the published range is proof on its own, at any sample size.
    func testAnOutOfRangeValueIsDetectedImmediately() {
        XCTAssertTrue(DayQualityView.seriesLooksStale(["2026-09-01": 140]))
        XCTAssertTrue(DayQualityView.seriesLooksStale(["2026-09-01": -140]))
    }

    /// A REAL series crosses zero, so it must not be flagged — otherwise every visit re-scores.
    func testARealSignedSeriesIsNotFlagged() {
        var series: [String: Double] = [:]
        for i in 0..<25 {
            series[String(format: "2026-08-%02d", i + 5)] = i % 4 == 0 ? -18 : Double(20 + i)
        }
        XCTAssertFalse(DayQualityView.seriesLooksStale(series))
    }

    /// A genuinely excellent SHORT stretch must not be mistaken for stale data. The all-positive tell
    /// is gated on a generous sample for exactly this reason: a false positive costs one idempotent
    /// re-score, but flagging a real good fortnight would re-score on every visit.
    func testAShortAllPositiveStretchIsNotFlagged() {
        var series: [String: Double] = [:]
        for i in 0..<12 { series[String(format: "2026-09-%02d", i + 1)] = Double(30 + i) }
        XCTAssertFalse(DayQualityView.seriesLooksStale(series),
                       "twelve good days is a good fortnight, not a stale scale")
    }

    /// A day sitting exactly AT zero counts as crossing it — zero is a real, reachable score (the
    /// sedentary anchor), not a sentinel.
    func testAZeroValueCountsAsCrossing() {
        var series: [String: Double] = [:]
        for i in 0..<25 { series[String(format: "2026-08-%02d", i + 5)] = i == 3 ? 0 : Double(40) }
        XCTAssertFalse(DayQualityView.seriesLooksStale(series))
    }

    func testAnEmptySeriesIsNotFlagged() {
        XCTAssertFalse(DayQualityView.seriesLooksStale([:]),
                       "no data is not stale data — a first run must not force a re-score")
    }
}
