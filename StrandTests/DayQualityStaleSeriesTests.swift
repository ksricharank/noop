import XCTest
@testable import Strand
@testable import StrandAnalytics

/// Detecting a stored day-quality series left behind by a retired formula (260909).
///
/// Reported three times: the score card correct, and the trend chart / week summary / calendar below
/// it showing values the current formula cannot produce. Two earlier repairs failed, and both failed
/// the same way — they asked an INDIRECT question:
///
/// 1. `DayQualityPrefs.configChanged` — a latch that records a pass RAN, not that the stored values
///    are current. A pass that latched under one formula leaves the series looking complete.
/// 2. A shape heuristic ("nothing at or below zero across 20+ days"). Tested against a 25-day
///    synthetic fixture and green; the real series was **14 days**, under the threshold, and held one
///    negative day which defeated the other tell. Green on data I invented, silent on the data it
///    existed for.
///
/// The check now compares stored values against what the scorer produces for the same day. These
/// tests use the REPORTED window sizes, not convenient ones — that mismatch is what let the previous
/// version ship twice.
final class DayQualityStaleSeriesTests: XCTestCase {

    // MARK: - The reported case

    /// The 14-day window actually on screen, with stored values from the retired formula (best 77 =
    /// 50 × 1.25 + 15) against live values from the current one. The previous heuristic returned
    /// false here; this must return true.
    func testTheReportedFourteenDayWindowIsDetected() {
        var stored: [String: Double] = [:]
        let old: [Double] = [77, 62, 64, 66, 71, 65, 55, 57, 60, 60, 47, 28, 5, -22]
        for (i, v) in old.enumerated() { stored[String(format: "2026-08-%02d", i + 25)] = v }
        // What the current scorer says about the five most recent of those days.
        let live: [String: Int] = [
            "2026-09-07": 23, "2026-09-06": 20, "2026-09-05": 28,
            "2026-08-31": 19, "2026-08-30": 16,
        ]
        var merged = stored
        for (d, v) in live { merged[d] = Double(v == 23 ? 55 : 60) }  // stored still holds old values
        XCTAssertTrue(DayQualityView.storedDisagreesWithLive(stored: merged, live: live),
                      "a 14-day window with one negative day must still be detected — the previous "
                      + "heuristic needed 20+ days and no negatives, so it was silent on exactly this")
    }

    /// One disagreeing day is enough. The repair is a full forced re-score, so the check is a
    /// detector and does not need to find them all.
    func testASingleDisagreementIsEnough() {
        let stored = ["2026-09-01": 55.0, "2026-09-02": 20.0, "2026-09-03": 21.0]
        let live = ["2026-09-01": 22, "2026-09-02": 20, "2026-09-03": 21]
        XCTAssertTrue(DayQualityView.storedDisagreesWithLive(stored: stored, live: live))
    }

    // MARK: - Must NOT fire

    /// An agreeing series must not trigger a re-score, or every visit to the tab re-derives history.
    func testAnAgreeingSeriesIsLeftAlone() {
        let stored = ["2026-09-01": 23.0, "2026-09-02": -22.0, "2026-09-03": 0.0]
        let live = ["2026-09-01": 23, "2026-09-02": -22, "2026-09-03": 0]
        XCTAssertFalse(DayQualityView.storedDisagreesWithLive(stored: stored, live: live))
    }

    /// Rounding must not read as disagreement: the store holds a Double, the scorer returns an Int.
    func testRoundingIsToleratedButRealDriftIsNot() {
        XCTAssertFalse(DayQualityView.storedDisagreesWithLive(
            stored: ["2026-09-01": 22.6], live: ["2026-09-01": 23]))
        XCTAssertTrue(DayQualityView.storedDisagreesWithLive(
            stored: ["2026-09-01": 20.0], live: ["2026-09-01": 23]),
            "3 points apart is a different formula, not a rounding artifact")
    }

    /// A day the scorer cannot currently score (its inputs are gone) must not be treated as a
    /// disagreement — that would force a re-score on every visit forever.
    func testADayMissingFromTheLiveSetIsIgnored() {
        let stored = ["2026-09-01": 55.0, "2026-09-02": 20.0]
        let live = ["2026-09-02": 20]      // 09-01 could not be re-scored
        XCTAssertFalse(DayQualityView.storedDisagreesWithLive(stored: stored, live: live))
    }

    /// A day the scorer produces but the store has never held is a MISSING day, not a stale one —
    /// the ordinary incremental path writes it, so this must not force a full re-derivation.
    func testADayMissingFromTheStoreIsIgnored() {
        let stored = ["2026-09-02": 20.0]
        let live = ["2026-09-01": 23, "2026-09-02": 20]
        XCTAssertFalse(DayQualityView.storedDisagreesWithLive(stored: stored, live: live))
    }

    func testEmptyInputsAreNotStale() {
        XCTAssertFalse(DayQualityView.storedDisagreesWithLive(stored: [:], live: [:]))
        XCTAssertFalse(DayQualityView.storedDisagreesWithLive(stored: ["2026-09-01": 20], live: [:]))
        XCTAssertFalse(DayQualityView.storedDisagreesWithLive(stored: [:], live: ["2026-09-01": 20]))
    }

    /// The detector is bounded, so it stays cheap on a path that runs whenever the tab opens.
    func testTheRepairCheckIsBounded() {
        XCTAssertLessThanOrEqual(DayQualityView.repairCheckDays, 10,
                                 "one disagreement triggers the full repair, so this only needs to "
                                 + "sample recent days")
        XCTAssertGreaterThan(DayQualityView.repairCheckDays, 1)
    }
}
