import XCTest
@testable import Strand

/// The pure math under the daytime-beat calm ceiling (`DaytimeHrHistogram`): the percentile walk
/// over the histogram and the persisted-day merge/prune. Pinned because the ceiling is a number the
/// card prints bare — a drifted percentile silently redefines "elevated" for every future day.
@MainActor
final class DaytimeHrHistogramTests: XCTestCase {

    /// Nearest-rank over sorted bins: 100 beats, p85 lands on the bin holding the 85th beat.
    func testPercentileWalksTheSortedBins() {
        // 60 bpm × 50, 80 bpm × 30, 100 bpm × 20 — cumulative 50 / 80 / 100.
        let counts = [60: 50, 80: 30, 100: 20]
        XCTAssertEqual(DaytimeHrHistogram.percentileBpm(counts: counts, p: 0.5, minSamples: 1), 60)
        XCTAssertEqual(DaytimeHrHistogram.percentileBpm(counts: counts, p: 0.8, minSamples: 1), 80)
        XCTAssertEqual(DaytimeHrHistogram.percentileBpm(counts: counts, p: 0.85, minSamples: 1), 100)
        XCTAssertEqual(DaytimeHrHistogram.percentileBpm(counts: counts, p: 1.0, minSamples: 1), 100)
    }

    /// Below the minimum sample count the histogram stays silent — a percentile of twenty beats is
    /// not a ceiling, and nil is what routes the caller to the RHR fallback.
    func testTooFewSamplesReadAsNil() {
        XCTAssertNil(DaytimeHrHistogram.percentileBpm(counts: [70: 10], p: 0.85, minSamples: 11))
        XCTAssertNil(DaytimeHrHistogram.percentileBpm(counts: [:], p: 0.85, minSamples: 1))
    }

    /// The merge folds new counts into the day's bucket and prunes to the newest keepDays keys — the
    /// week window is what makes the ceiling self-recalibrating rather than a lifetime average.
    func testMergeFoldsAndPrunesToTheWeek() {
        var store: [String: [String: Int]] = [:]
        for d in 1...9 {
            store = DaytimeHrHistogram.merged(persisted: store, adding: [70: d],
                                              day: String(format: "2026-08-%02d", d), keepDays: 7)
        }
        XCTAssertEqual(store.count, 7)
        XCTAssertNil(store["2026-08-01"], "the oldest days must be pruned")
        XCTAssertEqual(store["2026-08-09"]?["70"], 9)
        // Folding into an existing day accumulates rather than replaces.
        store = DaytimeHrHistogram.merged(persisted: store, adding: [70: 1, 90: 2],
                                          day: "2026-08-09", keepDays: 7)
        XCTAssertEqual(store["2026-08-09"]?["70"], 10)
        XCTAssertEqual(store["2026-08-09"]?["90"], 2)
    }
}
