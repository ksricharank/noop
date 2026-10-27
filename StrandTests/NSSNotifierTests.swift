import XCTest
import StrandAnalytics
@testable import Strand

/// The high-NSS notification's gates (`NSSNotifier.decide`, 261026): fresh readings only, once per high
/// stretch (re-armed below 60), at most hourly.
final class NSSNotifierTests: XCTestCase {

    private let now = 1_000_000

    func testFiresOnceWhenAFreshReadingReaches67() {
        let first = NSSNotifier.decide(nss: 67, readingTs: now - 60, now: now, armed: true, lastFired: nil)
        XCTAssertTrue(first.post)
        XCTAssertFalse(first.armed)
        XCTAssertFalse(NSSNotifier.decide(nss: 66.9, readingTs: now, now: now, armed: true, lastFired: nil).post)
    }

    func testStaysQuietThroughTheSameHighStretch() {
        let again = NSSNotifier.decide(nss: 80, readingTs: now, now: now + 7_200, armed: false, lastFired: now)
        XCTAssertFalse(again.post, "still in the stretch that fired")
        XCTAssertFalse(again.armed)
        // A wobble to 62 is still the same stretch; only below 60 re-arms.
        XCTAssertFalse(NSSNotifier.decide(nss: 62, readingTs: now, now: now, armed: false, lastFired: now).armed)
        XCTAssertTrue(NSSNotifier.decide(nss: 59, readingTs: now, now: now, armed: false, lastFired: now).armed)
    }

    func testANewStretchWithinTheHourWaitsForTheCooldown() {
        let soon = NSSNotifier.decide(nss: 70, readingTs: now + 1_800, now: now + 1_800, armed: true, lastFired: now)
        XCTAssertFalse(soon.post)
        XCTAssertTrue(soon.armed, "kept armed, so it fires once the hour is up if still high")
        XCTAssertTrue(NSSNotifier.decide(nss: 70, readingTs: now + 3_600, now: now + 3_600, armed: true,
                                         lastFired: now).post)
    }

    func testAStaleReadingNeitherFiresNorReArms() {
        let stale = NSSNotifier.decide(nss: 90, readingTs: now - 16 * 60, now: now, armed: true, lastFired: nil)
        XCTAssertFalse(stale.post)
        XCTAssertTrue(stale.armed)
        XCTAssertFalse(NSSNotifier.decide(nss: 10, readingTs: now - 16 * 60, now: now, armed: false, lastFired: nil).armed)
        XCTAssertFalse(NSSNotifier.decide(nss: nil, readingTs: nil, now: now, armed: true, lastFired: nil).post)
    }
}

/// The Stress tab's summary (261026): a ninth editable prompt, in the catalogue the "My default" layer,
/// the log export and the Coach screen all read, and a data key that moves with the situation, not the
/// sync.
@MainActor
final class StressSummaryPromptTests: XCTestCase {

    func testTheStressPromptIsInTheCatalogue() {
        XCTAssertTrue(AICoachEngine.promptCatalog.contains { $0.key == AICoachEngine.stressPromptKey })
        XCTAssertTrue(AICoachEngine.defaultStressPrompt.contains("MY STRESS TODAY"))
        XCTAssertTrue(AICoachEngine.defaultStressPrompt.contains("never call exercise stress"))
    }

    func testTheSummaryKeyIgnoresSmallMovesAndFollowsBigOnes() {
        func snap(_ nss: Double, exercise: NormalizedStress.ExerciseMark? = nil) -> NormalizedStressStore.Snapshot {
            var s = NormalizedStressStore.Snapshot.empty
            s.current = .init(ts: 0, nss: nss, raw: nss, pace: .still, hr: 70, hrCalm: 67,
                              zHR: 0.5, zSI: nil, zRMSSD: nil)
            s.typical = 27
            s.unscoredExercise = exercise
            return s
        }
        XCTAssertEqual(StressView.stressSummaryKey(snap(22)), StressView.stressSummaryKey(snap(27)))
        XCTAssertNotEqual(StressView.stressSummaryKey(snap(27)), StressView.stressSummaryKey(snap(72)))
        XCTAssertNotEqual(StressView.stressSummaryKey(snap(27)), StressView.stressSummaryKey(snap(27, exercise: .exercise)))
        XCTAssertNil(StressView.stressSummaryKey(.empty))
    }
}
