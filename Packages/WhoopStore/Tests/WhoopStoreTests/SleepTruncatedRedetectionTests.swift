import XCTest
@testable import WhoopStore

/// 261018: a night that began before an earlier day's analysis window closed is re-detected in that
/// window as its opening stretch only — the same start, ending hours early at the window's edge.
/// Written over the whole night it pulled the stored night back onto the previous day, and the Sleep
/// tab showed yesterday. A same-start re-detection may not SHORTEN a stored night by hours; a re-stage
/// that moves the wake by minutes, and one that lengthens it, still land.
final class SleepTruncatedRedetectionTests: XCTestCase {

    private let computed = "my-whoop-noop"

    /// Stages that tile `[start, end)` exactly, so both sides have the same richness (fully covered)
    /// and only the new end-time guard can decide.
    private func night(start: Int, end: Int, edited: Bool = false) -> CachedSleepSession {
        let stages = "[{\"start\":\(start),\"end\":\(end),\"stage\":\"light\"}]"
        return CachedSleepSession(startTs: start, endTs: end, efficiency: 0.9, restingHr: 55,
                                  avgHrv: 45, stagesJSON: stages, userEdited: edited)
    }

    private func stored(_ store: WhoopStore, start: Int) async throws -> CachedSleepSession? {
        try await store.sleepSessions(deviceId: computed, from: start, to: start, limit: 1).first
    }

    func testAWindowClippedOpeningStretchDoesNotShortenTheStoredNight() async throws {
        let store = try await WhoopStore.inMemory()
        let start = 1_000_000
        let fullEnd = start + 9 * 3600            // 22:15 → 07:15
        try await store.upsertSleepSessions([night(start: start, end: fullEnd)], deviceId: computed)
        // The earlier day's window closes at midnight: the same start, ending 1h45 in.
        try await store.upsertSleepSessions([night(start: start, end: start + 6300)], deviceId: computed)
        let row = try await stored(store, start: start)
        XCTAssertEqual(row?.endTs, fullEnd, "the clipped copy must not pull the night back")
    }

    func testTheWholeNightStillReplacesAnEarlierClippedRow() async throws {
        let store = try await WhoopStore.inMemory()
        let start = 1_000_000
        // 22:43 the evening before: only the first 22 minutes existed yet.
        try await store.upsertSleepSessions([night(start: start, end: start + 1320)], deviceId: computed)
        try await store.upsertSleepSessions([night(start: start, end: start + 9 * 3600)], deviceId: computed)
        let row = try await stored(store, start: start)
        XCTAssertEqual(row?.endTs, start + 9 * 3600)
    }

    func testARestageThatMovesTheWakeByMinutesStillLands() async throws {
        let store = try await WhoopStore.inMemory()
        let start = 1_000_000
        try await store.upsertSleepSessions([night(start: start, end: start + 9 * 3600)], deviceId: computed)
        let restaged = start + 9 * 3600 - 20 * 60
        try await store.upsertSleepSessions([night(start: start, end: restaged)], deviceId: computed)
        let row = try await stored(store, start: start)
        XCTAssertEqual(row?.endTs, restaged)
    }
}
