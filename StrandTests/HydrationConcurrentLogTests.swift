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

    /// A UNIQUE day per test. The entry list lives in UserDefaults keyed by day, and the metric
    /// series in a store keyed by device — both process-wide. Sharing one day across tests let one
    /// test's entries leak into the next and made the totals accumulate, which looked like a
    /// concurrency failure and was really test bleed.
    private var day = ""

    private func repository() -> Repository {
        Repository(deviceId: "test-hydration-concurrency-" + day)
    }

    override func setUp() {
        super.setUp()
        day = "2026-09-" + String(format: "%02d", abs(name.hashValue % 28) + 1)
        UserDefaults.standard.removeObject(forKey: HydrationStore.entriesKey(forDay: day))
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
