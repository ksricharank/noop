import XCTest
import StrandAnalytics
@testable import Strand

/// The high-NSS notification's gates (`NSSNotifier.decide`, 261026): fresh readings only, once per high
/// stretch (re-armed 7 below the alert level), at most hourly. Pinned at an alert level of 67; 261028
/// made the level configurable, default 50.
final class NSSNotifierTests: XCTestCase {

    private let now = 1_000_000

    func testFiresOnceWhenAFreshReadingReaches67() {
        let first = NSSNotifier.decide(nss: 67, readingTs: now - 60, now: now, armed: true, lastFired: nil, threshold: 67)
        XCTAssertTrue(first.post)
        XCTAssertFalse(first.armed)
        XCTAssertFalse(NSSNotifier.decide(nss: 66.9, readingTs: now, now: now, armed: true, lastFired: nil, threshold: 67).post)
    }

    func testStaysQuietThroughTheSameHighStretch() {
        let again = NSSNotifier.decide(nss: 80, readingTs: now, now: now + 7_200, armed: false, lastFired: now, threshold: 67)
        XCTAssertFalse(again.post, "still in the stretch that fired")
        XCTAssertFalse(again.armed)
        // A wobble to 62 is still the same stretch; only below 60 re-arms.
        XCTAssertFalse(NSSNotifier.decide(nss: 62, readingTs: now, now: now, armed: false, lastFired: now, threshold: 67).armed)
        XCTAssertTrue(NSSNotifier.decide(nss: 59, readingTs: now, now: now, armed: false, lastFired: now, threshold: 67).armed)
    }

    func testANewStretchWithinTheHourWaitsForTheCooldown() {
        let soon = NSSNotifier.decide(nss: 70, readingTs: now + 1_800, now: now + 1_800, armed: true, lastFired: now, threshold: 67)
        XCTAssertFalse(soon.post)
        XCTAssertTrue(soon.armed, "kept armed, so it fires once the hour is up if still high")
        XCTAssertTrue(NSSNotifier.decide(nss: 70, readingTs: now + 3_600, now: now + 3_600, armed: true,
                                         lastFired: now, threshold: 67).post)
    }

    func testTheAlertLevelDefaultsTo50AndMovesTheGates() {
        let d = UserDefaults.standard
        let saved = d.object(forKey: NSSNotifier.thresholdKey)
        defer { d.set(saved, forKey: NSSNotifier.thresholdKey) }
        d.removeObject(forKey: NSSNotifier.thresholdKey)
        XCTAssertEqual(NSSNotifier.threshold, 50)
        NSSNotifier.threshold = 200
        XCTAssertEqual(NSSNotifier.threshold, 95, "clamped")
        XCTAssertTrue(NSSNotifier.decide(nss: 50, readingTs: now, now: now, armed: true, lastFired: nil,
                                         threshold: 50).post)
        XCTAssertFalse(NSSNotifier.decide(nss: 44, readingTs: now, now: now, armed: false, lastFired: nil,
                                          threshold: 50).armed, "44 is within 7 of 50")
        XCTAssertTrue(NSSNotifier.decide(nss: 42, readingTs: now, now: now, armed: false, lastFired: nil,
                                         threshold: 50).armed)
    }

    func testAStaleReadingNeitherFiresNorReArms() {
        let stale = NSSNotifier.decide(nss: 90, readingTs: now - 16 * 60, now: now, armed: true, lastFired: nil, threshold: 67)
        XCTAssertFalse(stale.post)
        XCTAssertTrue(stale.armed)
        XCTAssertFalse(NSSNotifier.decide(nss: 10, readingTs: now - 16 * 60, now: now, armed: false, lastFired: nil, threshold: 67).armed)
        XCTAssertFalse(NSSNotifier.decide(nss: nil, readingTs: nil, now: now, armed: true, lastFired: nil, threshold: 67).post)
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

/// The NSS charts' flexible y-axis (`NSSChartScale`, 261028): the top follows the day's highest value
/// with a little headroom, on a round tick, between 30 and 100.
final class NSSChartScaleTests: XCTestCase {

    func testTheTopFollowsTheDay() {
        XCTAssertEqual(NSSChartScale.top(peak: 12), 30, "never squashed below 30")
        XCTAssertEqual(NSSChartScale.top(peak: 31), 40)
        XCTAssertEqual(NSSChartScale.top(peak: 45), 60)
        XCTAssertEqual(NSSChartScale.top(peak: 72), 80)
        XCTAssertEqual(NSSChartScale.top(peak: 89), 100)
        XCTAssertEqual(NSSChartScale.top(peak: 140), 100)
    }

    func testTicksAreRoundAndEndAtTheTop() {
        XCTAssertEqual(NSSChartScale.ticks(top: 30), [0, 10, 20, 30])
        XCTAssertEqual(NSSChartScale.ticks(top: 60), [0, 20, 40, 60])
        XCTAssertEqual(NSSChartScale.ticks(top: 100), [0, 25, 50, 75, 100])
    }

    func testTheWidgetSeriesMapsTheTopToTheTopOfTheDomain() {
        let s = NSSPoint.stressSeries([NSSPoint(ts: 0, nss: 30)], scaleMax: 60)
        XCTAssertEqual(s.first?.level ?? 0, StressTrace.domainMax / 2, accuracy: 1e-9)
    }
}
