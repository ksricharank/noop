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

    // 7. A sub-ten-minute window reports the honest span and NO hourly rate: the 260828-0731 header
    // extrapolated a 30 s launch-time offload burst into "224148/h", which reads as a day verdict
    // and is nothing of the kind. The line itself must still appear (test 5's first-export rule).
    func testShortWindowsCarryNoRate() {
        let line = BatteryDiag.formatNotifyLine(counts: ["puffin": 1360], seconds: 30)
        XCTAssertEqual(line, "BLE wakes: puffin=1360 — 1360 total over 30s (window too short for a rate)")
        XCTAssertNil(line?.range(of: "/h"))
    }

    // 8. The per-day bank: counts merge additively into the day's bucket, and pruning keeps only the
    // newest `keepDays` day keys — the header prints today + yesterday, so anything older is dead
    // weight in the plist (and the store must never grow without bound).
    func testPersistedDayMergeAddsAndPrunes() {
        var persisted: [String: [String: Int]] = [
            "2026-08-26": ["puffin": 10],
            "2026-08-27": ["puffin": 100, "hr2A37": 5],
        ]
        persisted = BatteryDiag.merged(persisted: persisted, adding: ["puffin": 7, "battery": 1],
                                       day: "2026-08-28")
        XCTAssertEqual(persisted.keys.sorted(), ["2026-08-27", "2026-08-28"])
        XCTAssertEqual(persisted["2026-08-28"], ["puffin": 7, "battery": 1])
        persisted = BatteryDiag.merged(persisted: persisted, adding: ["puffin": 3],
                                       day: "2026-08-28")
        XCTAssertEqual(persisted["2026-08-28"]?["puffin"], 10)
        XCTAssertEqual(persisted["2026-08-27"]?["hr2A37"], 5)
    }

    // 9. The day line: same busiest-first ordering as the session line, silent for an empty bucket.
    func testDayLineFormatsAndStaysSilentWhenEmpty() {
        XCTAssertEqual(
            BatteryDiag.formatDayLine(label: "today", counts: ["battery": 2, "puffin": 900]),
            "BLE wakes today: puffin=900 battery=2 — 902 total")
        XCTAssertNil(BatteryDiag.formatDayLine(label: "today", counts: [:]))
    }
}
