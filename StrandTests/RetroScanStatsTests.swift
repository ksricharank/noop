import XCTest
@testable import Strand

/// Pins the retro-scan cost line (260831): the scan runs on every completed sync in the background,
/// and an unmeasured recurring cost cannot be attributed from a log after the fact.
@MainActor
final class RetroScanStatsTests: XCTestCase {

    override func setUp() { super.setUp(); RetroScanStats.reset() }
    override func tearDown() { RetroScanStats.reset(); super.tearDown() }

    func testLineNamesEveryPhaseSoAScanCanBeAttributed() {
        // The reading contract: maxWait >> maxReplay = the scan was QUEUED on the store (the
        // 260903 9.9-minute shape); the reverse would mean the detector itself is the cost.
        XCTAssertEqual(
            RetroScanStats.line(runs: 140, lastMs: 31, maxMs: 592_327,
                                maxWaitMs: 591_800, maxReplayMs: 480, maxBeats: 19_500,
                                blockedRuns: 1),
            "Stress retro-scan today: runs=140 lastMs=31 maxMs=592327 maxWait=591800ms "
            + "maxReplay=480ms maxBeats=19500 blocked=1")
    }

    @MainActor
    func testWorstPhaseValuesSurviveManyFastScans() {
        RetroScanStats.reset()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        // One blocked scan, then a hundred fast ones: the outlier must still be visible (a mean
        // would bury it, which is why these are maxima).
        RetroScanStats.record(millis: 600_000, waitMs: 599_000, replayMs: 400, beats: 19_000, now: now)
        for _ in 0..<100 {
            RetroScanStats.record(millis: 30, waitMs: 12, replayMs: 8, beats: 400, now: now)
        }
        let line = RetroScanStats.summaryLines(now: now).first ?? ""
        XCTAssertTrue(line.contains("runs=101"), line)
        XCTAssertTrue(line.contains("maxWait=599000ms"), line)
        XCTAssertTrue(line.contains("maxBeats=19000"), line)
        XCTAssertTrue(line.contains("blocked=1"), line)
        XCTAssertTrue(line.contains("lastMs=30"), "lastMs stays the most recent scan: \(line)")
    }

    @MainActor
    func testAFastScanIsNotCountedAsBlocked() {
        RetroScanStats.reset()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        RetroScanStats.record(millis: 40, waitMs: RetroScanStats.blockedWaitThresholdMs - 1,
                              replayMs: 10, beats: 500, now: now)
        XCTAssertTrue(RetroScanStats.summaryLines(now: now).first?.contains("blocked=0") ?? false)
    }

    @MainActor
    func testSilentUntilAScanRuns() {
        RetroScanStats.reset()
        XCTAssertTrue(RetroScanStats.summaryLines().isEmpty)
    }
}
