import XCTest
@testable import Strand

/// Pins the retro-scan cost line (260831): the scan runs on every completed sync in the background,
/// and an unmeasured recurring cost cannot be attributed from a log after the fact.
@MainActor
final class RetroScanStatsTests: XCTestCase {

    override func setUp() { super.setUp(); RetroScanStats.reset() }
    override func tearDown() { RetroScanStats.reset(); super.tearDown() }

    func testLineFormat() {
        XCTAssertEqual(RetroScanStats.line(runs: 41, lastMs: 180, maxMs: 2100),
                       "Stress retro-scan today: runs=41 lastMs=180 maxMs=2100")
    }

    /// Silent until the scan ever runs — a macOS or fresh-install log must not carry a zeros line.
    func testSilentWhenNeverRan() {
        XCTAssertEqual(RetroScanStats.summaryLines(), [])
    }

    /// lastMs tracks the most recent run; maxMs latches the day's worst.
    func testLastAndMaxTracking() {
        let t = Date(timeIntervalSince1970: 1_788_200_000)
        RetroScanStats.record(millis: 500, now: t)
        RetroScanStats.record(millis: 90, now: t)
        let lines = RetroScanStats.summaryLines(now: t)
        XCTAssertEqual(lines, ["Stress retro-scan today: runs=2 lastMs=90 maxMs=500"])
    }

    /// Day roll: the first record of a new local day starts fresh counters.
    func testDayRollResets() {
        let day1 = Date(timeIntervalSince1970: 1_788_200_000)
        RetroScanStats.record(millis: 900, now: day1)
        let day2 = day1.addingTimeInterval(86_400 * 2)
        RetroScanStats.record(millis: 40, now: day2)
        XCTAssertEqual(RetroScanStats.summaryLines(now: day2),
                       ["Stress retro-scan today: runs=1 lastMs=40 maxMs=40"])
    }
}
