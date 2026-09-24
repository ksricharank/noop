import XCTest
@testable import Strand
@testable import StrandAnalytics

/// Day quality and sleep score on the Trends page (260908).
final class TrendsScoreSeriesTests: XCTestCase {

    /// The week-row window must match the digest's own inclusive "yyyy-MM-dd" range, using string
    /// comparison — the property `WeeklyDigest.valuesInRange` relies on. A locale-sensitive calendar
    /// walk here would drift out of step with the metrics printed directly above these rows.
    func testWeekWindowIsInclusiveAndStringOrdered() {
        let series = ["2026-08-30": 1.0,   // the Sunday before
                      "2026-08-31": 2.0,   // Monday, week start
                      "2026-09-02": 3.0,
                      "2026-09-06": 4.0,   // Sunday, week end
                      "2026-09-07": 5.0]   // the Monday after
        let inWeek = TrendsView.valuesInWeek(series, start: "2026-08-31", end: "2026-09-06")
        XCTAssertEqual(inWeek, [2.0, 3.0, 4.0], "both ends inclusive, nothing outside")
    }

    func testWeekWindowIsEmptyWhenNothingFallsInside() {
        XCTAssertTrue(TrendsView.valuesInWeek(["2026-01-01": 9.0],
                                              start: "2026-08-31", end: "2026-09-06").isEmpty)
    }

    /// Values come back in DATE order, not dictionary order — a mean is order-independent but the
    /// count and any future ordered use are not.
    func testWeekValuesAreReturnedInDateOrder() {
        let series = ["2026-09-03": 30.0, "2026-09-01": 10.0, "2026-09-02": 20.0]
        XCTAssertEqual(TrendsView.valuesInWeek(series, start: "2026-09-01", end: "2026-09-07"),
                       [10.0, 20.0, 30.0])
    }

    /// The calendar strip colours cells with `recoveryColor`, which expects 0–100 — so the signed
    /// score is normalised at the call site and the tooltip un-normalises to print the real number.
    /// A sign or scale error here would mislabel every cell in the strip, silently.
    func testSignedScoreNormalisationRoundTrips() {
        let lo = Double(DayQualityScore.publishedMinimum)
        let hi = Double(DayQualityScore.publishedMaximum)
        func normalise(_ v: Double) -> Double { (v - lo) / (hi - lo) * 100 }
        func unnormalise(_ shown: Double) -> Double { shown / 100 * (hi - lo) + lo }

        for signed in [-100.0, -50.0, -23.0, 0.0, 26.0, 58.0, 100.0] {
            XCTAssertEqual(unnormalise(normalise(signed)), signed, accuracy: 1e-9,
                           "normalisation must round-trip exactly for \(signed)")
        }
        // And the endpoints land where the palette expects them.
        XCTAssertEqual(normalise(lo), 0, accuracy: 1e-9)
        XCTAssertEqual(normalise(hi), 100, accuracy: 1e-9)
        XCTAssertEqual(normalise(0), 50, accuracy: 1e-9,
                       "a neutral day sits mid-palette, not at the bottom — which is the whole "
                       + "reason for normalising rather than passing signed values through")
    }

    /// The digest's shared `WeeklyMetric` enum must stay untouched: it has a byte-identical Kotlin
    /// twin, and the parity contract requires a change there to land on both platforms together. Day
    /// quality is computed in the view precisely to avoid that, so this pins the enum's shape.
    func testWeeklyMetricEnumIsUnchangedForAndroidParity() {
        XCTAssertEqual(Set(WeeklyMetric.allCases.map(\.rawValue)),
                       ["charge", "effort", "rest", "rhr", "hrv"],
                       "adding a case here requires the Kotlin twin in the same PR — day quality is "
                       + "summarised in the view instead, which is why this must not grow")
    }
}
