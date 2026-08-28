import XCTest
@testable import Strand

/// `BatteryDiag` — the per-channel BLE wake counters and CPU line in the strap-log header. The
/// counters are what a drain report reads to say WHAT resumes the process, so the formatting rules
/// (silent-when-unused, busiest-first, a rate not just a total) are pinned here.
@MainActor
final class BatteryDiagTests: XCTestCase {

    override func setUp() async throws {
        BatteryDiag.reset()
    }

    // 1. Silent when nothing was counted — a log exported before the strap ever connected must be
    // byte-identical to today's, same contract as the Health line.
    func testNoNotificationsMeansNoLine() {
        XCTAssertNil(BatteryDiag.formatNotifyLine(counts: [:], seconds: 3600))
        XCTAssertFalse(BatteryDiag.summaryLines().contains { $0.hasPrefix("BLE wakes:") })
    }

    // 2. Busiest channel first, and the line carries total + per-hour rate + window, so numbers stay
    // comparable across logs of different lengths.
    func testFormatOrdersBusiestFirstAndCarriesTheRate() {
        let line = BatteryDiag.formatNotifyLine(counts: ["battery": 2, "hr2A37": 7200],
                                                seconds: 2 * 3600)
        XCTAssertEqual(line, "BLE wakes: hr2A37=7200 battery=2 — 7202 total, 3601/h over 2.0h")
    }

    // 3. A genuinely unusable window (negative, non-finite) yields no line rather than a division
    // blowup — but ZERO is valid (an export moments after the first notification) and floors the
    // rate span to one second instead of dropping the line. Dropping short windows is the exact
    // shape of the first-export bug pinned in test 5.
    func testUnusableWindowsYieldNoLineButZeroIsValid() {
        XCTAssertNotNil(BatteryDiag.formatNotifyLine(counts: ["hr2A37": 5], seconds: 0))
        XCTAssertNil(BatteryDiag.formatNotifyLine(counts: ["hr2A37": 5], seconds: -60))
        XCTAssertNil(BatteryDiag.formatNotifyLine(counts: ["hr2A37": 5], seconds: .nan))
    }

    // 4. Recording feeds the summary: counts accumulate per label and reset() zeroes them.
    func testRecordAccumulatesAndResets() {
        BatteryDiag.recordNotify("hr2A37")
        BatteryDiag.recordNotify("hr2A37")
        BatteryDiag.recordNotify("data")
        XCTAssertEqual(BatteryDiag.notifyCounts, ["hr2A37": 2, "data": 1])
        BatteryDiag.reset()
        XCTAssertEqual(BatteryDiag.notifyCounts, [:])
    }

    // 5. THE FIRST-EXPORT REGRESSION (260827-2142 log): a process that has recorded notifications
    // must produce the line on its very first export, even when that export lands the same instant.
    // The original code anchored the window on a lazy `Date()` static first touched INSIDE the
    // export — microseconds after `now` — so the window read negative and the line silently vanished
    // while its CPU sibling printed. The window is now anchored on the first recorded notification.
    func testFirstExportAfterRecordingAlwaysCarriesTheLine() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        BatteryDiag.recordNotify("hr2A37", now: t0)
        let lines = BatteryDiag.summaryLines(now: t0)   // same instant — the worst case
        XCTAssertTrue(lines.contains { $0.hasPrefix("BLE wakes: hr2A37=1") },
                      "first export must carry the wake line: \(lines)")
    }

    // 5. The CPU line exists and reads sane on the host running this test — getrusage is POSIX and the
    // test process has certainly consumed some CPU by now.
    func testCpuLineReadsTheProcess() throws {
        let line = try XCTUnwrap(BatteryDiag.cpuLine())
        XCTAssertTrue(line.hasPrefix("CPU this app session: user="), line)
    }
}
