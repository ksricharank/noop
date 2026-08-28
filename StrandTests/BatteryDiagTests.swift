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

    // 3. An unusable window (zero, negative, non-finite) yields no line rather than a division blowup
    // or a nonsense rate.
    func testUnusableWindowsYieldNoLine() {
        XCTAssertNil(BatteryDiag.formatNotifyLine(counts: ["hr2A37": 5], seconds: 0))
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

    // 5. The CPU line exists and reads sane on the host running this test — getrusage is POSIX and the
    // test process has certainly consumed some CPU by now.
    func testCpuLineReadsTheProcess() throws {
        let line = try XCTUnwrap(BatteryDiag.cpuLine())
        XCTAssertTrue(line.hasPrefix("CPU this app session: user="), line)
    }
}
