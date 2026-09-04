import XCTest
@testable import Strand
import StrandAnalytics

/// Concurrent hydration logging must not lose taps (260904).
///
/// Reported from the device: a water reminder reading "5 of 21 cups" on a day the wearer had logged
/// 8. Not a notification bug — a LOST WRITE.
///
/// `logHydration` is a read-modify-write (read the day's running total, upsert total + amount) and
/// the +/- buttons call it from fire-and-forget `Task`s. Tapping quickly therefore ran several
/// concurrently, each reading the same "current" and writing back only its own increment. The
/// on-screen counter still looked right, because the optimistic cache is synchronous and cannot miss
/// a tap; only the stored series fell behind, and the reminder read the series.
@MainActor
final class HydrationConcurrentLogTests: XCTestCase {

    /// A day unique to each RUN — and the DAY is the only thing that isolates these tests.
    ///
    /// Two persistent stores are involved: the entry list (UserDefaults, keyed by day) and the metric
    /// series (SQLite). Hydration always writes the series under the fixed `HydrationStore.sourceId`,
    /// NOT the Repository's device id, so a per-test device id isolates nothing — the rows collide
    /// whatever it is. Only the day key separates them.
    ///
    /// An earlier attempt derived the day from `hashValue`, which is randomised per process but not
    /// unique per run, so runs still collided: the series total came back HIGHER than the entry total
    /// (944 against 708) and the test failed intermittently while looking exactly like the drift
    /// under test. The direction is the tell — a lost write makes the series lower, never higher.
    ///
    /// A monotonic counter plus the process id gives a distinct, well-formed date per test per run,
    /// so every test starts against empty storage without deleting anything.
    ///
    /// CORRECTION (260904): that was still not enough, and the failure looked exactly like the bug
    /// under test. `pid % 100` recycles — macOS hands out pids well above 100 and wraps — so two
    /// runs eventually share a year, and the day then collides. The UserDefaults entry list is
    /// cleared in `setUp`, but the SQLite metricSeries row for that day is NOT, so the second run
    /// added its six half-cups to the first run's banked total: 1416 against an expected 708,
    /// EXACTLY double. The direction is the tell (a lost write makes the series lower, never
    /// higher) and doubling is the signature of a surviving row, not of a race.
    ///
    /// Fixed by clearing BOTH stores for the chosen day in `setUp` rather than relying on the day
    /// being unique. That removes the guesswork entirely: whatever day is picked, both records of
    /// it start empty, so the invariant under test ("the two records agree") is measured against a
    /// known-zero baseline.
    private var day = ""

    private static var counter = 0

    private func repository() -> Repository {
        Repository(deviceId: "test-hydration")
    }

    override func setUp() {
        super.setUp()
        Self.counter += 1
        // A real "yyyy-MM-dd" — the code parses it — pushed into the far past where no other test
        // or fixture writes. Year varies per run, day-of-month per test within the run.
        let year = 1800 + (Int(ProcessInfo.processInfo.processIdentifier) % 100)
        day = String(format: "%04d-01-%02d", year, (Self.counter % 28) + 1)
        UserDefaults.standard.removeObject(forKey: HydrationStore.entriesKey(forDay: day))
        // And the SQLite side of the same day — see the note on `day`. Without this the series row
        // survives a re-run that reuses the year, and the test fails looking like a lost write.
        // Zeroed through the ORDINARY upsert (`ON CONFLICT … DO UPDATE`), not a test-only hook: the
        // production write path is the thing that must leave the row at 0, and using it here means
        // this reset cannot drift from how the app actually writes.
        let repo = repository()
        let dayKey = day
        let done = expectation(description: "clear the day's series row")
        Task { @MainActor in
            await repo.resetHydrationSeries(day: dayKey)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: HydrationStore.entriesKey(forDay: day))
        UserDefaults.standard.removeObject(forKey: HydrationStore.enabledKey)
        super.tearDown()
    }

    /// Eight concurrent half-cup logs must bank EIGHT half-cups.
    ///
    /// This is the reported scenario reduced to its mechanism. Before the serialisation each task
    /// read the same total and the day ended short; the count lost depended on timing, which is why
    /// the figure looked arbitrary ("5" against a real 8).
    func testConcurrentLogsDoNotLoseTaps() async {
        let repo = repository()
        let half = HydrationGoal.halfCupML

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { @MainActor in
                    _ = await repo.logHydration(amountMl: half, day: self.day)
                }
            }
        }

        let entries = repo.hydrationEntries(day: day)
        XCTAssertEqual(entries.count, 8,
                       "every tap must produce an entry — the entry list is the display's truth")
        XCTAssertEqual(repo.hydrationManualTotalFromEntries(day: day), Double(half * 8),
                       accuracy: 0.001,
                       "eight half-cups logged must total eight half-cups, not fewer")
    }

    /// The two records of the same water must AGREE after concurrent logging.
    ///
    /// The entry list (append-per-tap) and the metricSeries row (running total) are both maintained
    /// by `logHydration`. Their divergence is precisely what made the reminder disagree with the
    /// Today row, so the invariant worth pinning is that they end up equal.
    func testTheEntryListAndTheRunningTotalAgree() async {
        let repo = repository()
        let half = HydrationGoal.halfCupML

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask { @MainActor in
                    _ = await repo.logHydration(amountMl: half, day: self.day)
                }
            }
        }

        let fromEntries = repo.hydrationManualTotalFromEntries(day: day)
        let fromSeries = await repo.hydrationManualTotal(day: day)
        XCTAssertEqual(fromEntries, Double(half * 6), accuracy: 0.001)
        XCTAssertEqual(fromSeries, fromEntries, accuracy: 0.001,
                       "the running total drifted from the entry list — the exact divergence that "
                       + "made a reminder state a different cup count from the Today row")
    }

    /// Ordering, not just exclusion: a log followed by a removal must not be reordered, or the
    /// removal looks for an entry that has not been written yet.
    func testALogAndARemovalStayOrdered() async {
        let repo = repository()
        let half = HydrationGoal.halfCupML

        _ = await repo.logHydration(amountMl: half, day: day)
        _ = await repo.logHydration(amountMl: half, day: day)
        let toDelete = repo.hydrationEntries(day: day).last
        XCTAssertNotNil(toDelete)

        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                _ = await repo.logHydration(amountMl: half, day: self.day)
            }
            group.addTask { @MainActor in
                if let id = toDelete?.id {
                    _ = await repo.deleteHydrationEntry(id: id, day: self.day)
                }
            }
        }

        // Two of the three logs plus the third, minus one deletion = 2 half-cups.
        let entries = repo.hydrationEntries(day: day)
        XCTAssertEqual(entries.count, 2, "one deletion out of three logs must leave two entries")
        let fromSeries = await repo.hydrationManualTotal(day: day)
        XCTAssertEqual(fromSeries, repo.hydrationManualTotalFromEntries(day: day), accuracy: 0.001,
                       "a delete racing a log must still leave the two records agreeing")
    }
}
