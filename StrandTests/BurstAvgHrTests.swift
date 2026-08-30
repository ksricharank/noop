import XCTest
import WhoopProtocol
@testable import Strand

/// Pins `Repository.burstAvg` — the pure core of the burst-average HR the NOOP Targets widget and the
/// Today targets strip show in the island-less daytime mode (260830). The instance method feeds it the
/// staleness-horizon query; the window/anchoring truth lives here, testable without a database.
@MainActor
final class BurstAvgHrTests: XCTestCase {

    private func samples(_ pairs: [(ts: Int, bpm: Int)]) -> [HRSample] {
        pairs.map { HRSample(ts: $0.ts, bpm: $0.bpm) }
    }

    func testEmptyAbstains() {
        XCTAssertNil(Repository.burstAvg(samples: []))
    }

    /// The window is anchored at the FRESHEST sample, not at "now": a publish that runs minutes after
    /// the burst landed must still average the burst, never an empty now-anchored window.
    func testAveragesOnlyTheWindowBelowTheFreshestSample() {
        let t = 1_700_000_000
        let rows = samples([
            (ts: t - 2_000, bpm: 200),          // older than the 15-min window — must be ignored
            (ts: t - 800, bpm: 60),
            (ts: t - 400, bpm: 70),
            (ts: t, bpm: 80)
        ])
        XCTAssertEqual(Repository.burstAvg(samples: rows), 70)
    }

    /// A sample exactly at (freshest − window) is OUT — the window is the last `burstAvgWindowSec`
    /// strictly, so two adjacent bursts never share a boundary row.
    func testWindowBoundaryIsExclusive() {
        let t = 1_700_000_000
        let rows = samples([
            (ts: t - Repository.burstAvgWindowSec, bpm: 200),
            (ts: t, bpm: 60)
        ])
        XCTAssertEqual(Repository.burstAvg(samples: rows), 60)
    }

    func testRoundsHalfUp() {
        let t = 1_700_000_000
        let rows = samples([(ts: t - 10, bpm: 60), (ts: t, bpm: 61)])
        XCTAssertEqual(Repository.burstAvg(samples: rows), 61)   // 60.5 rounds to 61
    }

    func testSingleSampleIsItsOwnAverage() {
        XCTAssertEqual(Repository.burstAvg(samples: samples([(ts: 1_700_000_000, bpm: 72)])), 72)
    }
}
