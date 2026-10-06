import XCTest
@testable import WhoopStore

/// Pins the read/write timing accumulator behind the `analyzeRecent store sql` diagnostic line
/// (#1538 follow-up). The line exists to split a slow re-score prep into actor-wait vs SQL, so the
/// accumulator's two contracts matter: every read through `syncRead` is counted (or the SQL figure
/// under-reports and actor-wait over-reports by the same amount), and a reset genuinely zeroes it
/// (or one pass's tally bleeds into the next and the per-pass line stops meaning anything).
final class PerfInstrumentationTests: XCTestCase {

    func testReadsAccrueTimeAndCount() async throws {
        let store = try await WhoopStore.inMemory()
        let before = await store.perfSnapshot()
        XCTAssertEqual(before.sqlReadCount, 0)

        _ = try await store.cursor("strap_trim")      // one syncRead
        _ = try await store.cursor("strap_trim")      // another

        let after = await store.perfSnapshot()
        XCTAssertEqual(after.sqlReadCount, 2, "every syncRead must be counted")
        XCTAssertGreaterThanOrEqual(after.sqlReadSeconds, 0, "time must accrue, never go negative")
    }

    func testWritesAccrueSeparatelyFromReads() async throws {
        let store = try await WhoopStore.inMemory()
        await store.perfReset()

        try await store.setCursor("strap_trim", 1)    // one syncWrite

        let snap = await store.perfSnapshot()
        XCTAssertEqual(snap.sqlReadCount, 0, "a write must not count as a read")
        XCTAssertGreaterThanOrEqual(snap.sqlWriteSeconds, 0)
    }

    func testResetZeroesTheTally() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.cursor("strap_trim")
        try await store.setCursor("strap_trim", 1)

        await store.perfReset()
        let snap = await store.perfSnapshot()
        XCTAssertEqual(snap.sqlReadCount, 0)
        XCTAssertEqual(snap.sqlReadSeconds, 0)
        XCTAssertEqual(snap.sqlWriteSeconds, 0)
    }
}
