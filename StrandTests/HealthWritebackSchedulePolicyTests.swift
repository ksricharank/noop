import XCTest
@testable import Strand

final class HealthWritebackSchedulePolicyTests: XCTestCase {
    func testSchedulesOnlyAfterAppleHealthAuthorization() {
        XCTAssertTrue(HealthWritebackSchedulePolicy.shouldSchedule(isAuthorized: true))
        XCTAssertFalse(HealthWritebackSchedulePolicy.shouldSchedule(isAuthorized: false))
    }

    func testRequestsNextRefreshOneHourAfterScheduling() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            HealthWritebackSchedulePolicy.earliestBeginDate(after: now),
            now.addingTimeInterval(3_600)
        )
    }
}

/// 260928: the spacing floor on the routine post-backfill write-back — 168 full 14-day rewrites by
/// 11:20 (vs 4 two days earlier), one per strap offload, was the Health app's battery-share story.
extension HealthWritebackSchedulePolicyTests {
    func testSpacingFloorStandsDownRapidRewrites() {
        let now = Date()
        XCTAssertTrue(HealthWritebackSchedulePolicy.shouldWriteBackNow(now: now, lastWriteBack: nil),
                      "first of the process always runs")
        XCTAssertFalse(HealthWritebackSchedulePolicy.shouldWriteBackNow(
            now: now, lastWriteBack: now.addingTimeInterval(-10 * 60)),
            "a strap offload ten minutes after the last write stands down")
        XCTAssertTrue(HealthWritebackSchedulePolicy.shouldWriteBackNow(
            now: now, lastWriteBack: now.addingTimeInterval(-31 * 60)))
        XCTAssertTrue(HealthWritebackSchedulePolicy.shouldWriteBackNow(
            now: now, lastWriteBack: now.addingTimeInterval(60)),
            "a backwards clock must never wedge the export")
    }

    /// The stamped gate the call sites share: the first admit stamps, the second inside the floor
    /// stands down (and is counted), one past the floor runs again.
    @MainActor
    func testAdmissionGateStampsAndStandsDown() {
        HealthWritebackThrottle.reset()
        HealthSyncStats.reset()
        XCTAssertTrue(HealthWritebackThrottle.admit(now: Date(timeIntervalSince1970: 1_000)))
        XCTAssertFalse(HealthWritebackThrottle.admit(now: Date(timeIntervalSince1970: 1_000 + 10 * 60)),
                       "ten minutes after an admitted run, the offload cadence, stands down")
        XCTAssertEqual(HealthSyncStats.writeBacksSkipped, 1, "a stood-down run is evidence, not silence")
        XCTAssertTrue(HealthWritebackThrottle.admit(now: Date(timeIntervalSince1970: 1_000 + 31 * 60)))
        HealthWritebackThrottle.reset()
        HealthSyncStats.reset()
    }
}
