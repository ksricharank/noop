import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

/// feature/store-concurrent-reads (261007): reads run on the `DatabasePool`'s reader connections and
/// SUSPEND the store actor instead of blocking its executor. The field evidence this exists for: a
/// 21-night pass read held the actor 104 s while two ~130 s Today loads queued behind it (261005);
/// a Today screen took 30.3 s to show numbers already on disk because its reads queued behind a
/// relaunch's pass (261007); Health syncs averaged 139 s mostly waiting in the same line (261006).
///
/// Both pins are OVERLAP-shaped, never timing ratios: a fast operation must COMPLETE while a slow
/// read is provably still in flight. Under the old blocking `syncRead` both fail deterministically —
/// the fast operation cannot even start until the slow read returns. File-backed stores, because the
/// in-memory test store is a serial `DatabaseQueue` and has no reader pool to exercise.
final class ConcurrentReadTests: XCTestCase {

    /// Enough CTE steps that the slow read reliably outlives the 200 ms head start plus the probe,
    /// on any machine fast enough to run the suite at all (~1-5 s in practice).
    private static let slowIterations = 30_000_000

    private func tempPath() -> String {
        NSTemporaryDirectory() + "whoopstore-concurrent-\(UUID().uuidString).sqlite"
    }

    private func removeDB(_ path: String) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    /// THE feature pin: the ACTOR answers another call while a slow read is still running.
    /// `stepDataRevisionSignature` is actor-isolated but touches no database, so its completion is
    /// pure proof the executor is free — exactly what a screen's quick store call needs during a
    /// heavy pass. The slow task returns its completion instant AND its row count, so one task pins
    /// both liberation and correctness of the async path.
    func testActorAnswersWhileASlowReadRuns() async throws {
        let path = tempPath()
        defer { removeDB(path) }
        let store = try await WhoopStore(path: path)

        let slow = Task { () -> (done: ContinuousClock.Instant, count: Int) in
            let count = try await store.slowReadForTest(iterations: Self.slowIterations)
            return (ContinuousClock.now, count)
        }
        // Give the slow read time to reach the reader connection before probing.
        try await Task.sleep(nanoseconds: 200_000_000)

        _ = await store.stepDataRevisionSignature(deviceId: "probe", from: 0, to: 1)
        let probeDone = ContinuousClock.now

        let slowResult = try await slow.value
        XCTAssertLessThan(probeDone, slowResult.done,
                          "the actor must answer while the slow read is still in flight — "
                          + "a probe that had to wait for it is the blocked-door regression")
        XCTAssertEqual(slowResult.count, Self.slowIterations,
                       "the async read path must return the same result the blocking one did")
    }

    /// The user-visible shape: a QUICK database read completes while a slow one is still running —
    /// the Today screen's read no longer queues behind the pass. Needs the pool's second reader
    /// connection, which is the half `testActorAnswersWhileASlowReadRuns` does not cover (its probe
    /// never touches SQLite).
    func testAQuickReadCompletesWhileASlowReadRuns() async throws {
        let path = tempPath()
        defer { removeDB(path) }
        let store = try await WhoopStore(path: path)

        let slow = Task { () -> ContinuousClock.Instant in
            _ = try await store.slowReadForTest(iterations: Self.slowIterations)
            return ContinuousClock.now
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        _ = try await store.cursor("concurrent-read-probe")   // a real read, through the same funnel
        let quickDone = ContinuousClock.now

        let slowDone = try await slow.value
        XCTAssertLessThan(quickDone, slowDone,
                          "a quick read must be served by another reader connection while the slow "
                          + "read runs — queueing behind it is the 30-second-Today-screen regression")
    }

    /// The perf ledger keeps counting under the async path: the `reads=`/`maxRead=` strap-log line
    /// is how every slow-store episode has been diagnosed, and the conversion must not silence it.
    func testConcurrentReadsStillAccrueThePerfLedger() async throws {
        let path = tempPath()
        defer { removeDB(path) }
        let store = try await WhoopStore(path: path)
        await store.perfReset()

        _ = try await store.cursor("perf-probe")
        _ = try await store.cursor("perf-probe")

        let snap = await store.perfSnapshot()
        XCTAssertEqual(snap.sqlReadCount, 2, "every concurrentRead must be counted")
        XCTAssertGreaterThanOrEqual(snap.sqlReadSeconds, 0)
    }
}
