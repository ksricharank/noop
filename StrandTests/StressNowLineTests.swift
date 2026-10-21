import XCTest
import StrandAnalytics
@testable import Strand

/// The STRESS line (`AICoachEngine.stressNowSummary`, 261021): stress now against today's average on
/// the Stress screen's 0–3 scale. Pinned because the Today stress bullet quotes these two figures
/// verbatim, so they must be the ones the screen shows — the timeline's newest point and its header
/// average — and a gap must say why instead of passing off an old number as "now".
final class StressNowLineTests: XCTestCase {

    private let now = 50_000

    private func point(_ startTs: Int, _ level: Double?, masked: Bool = false) -> DaytimeStress.HourPoint {
        DaytimeStress.HourPoint(hour: 0, startTs: startTs, level: level, meanHR: nil, rmssd: nil,
                                maskedForActivity: masked)
    }

    private func result(hours: [DaytimeStress.HourPoint], timeline: [DaytimeStress.HourPoint],
                        dayMean: Double?) -> DaytimeStress.Result {
        DaytimeStress.Result(hours: hours, sustainedHigh: false, sustainedRun: 0, dayMean: dayMean,
                             peak: nil, timeline: timeline)
    }

    func testNowIsTheNewestTimelinePointAgainstTheDayAverage() {
        let hours = [point(now - 3 * 3600, 1.8), point(now - 2 * 3600, 1.5), point(now - 3600, 0.9)]
        let timeline = hours + [point(now - 1800, 0.94)]
        let line = AICoachEngine.stressNowSummary(
            result: result(hours: hours, timeline: timeline, dayMean: 1.4), now: now)
        XCTAssertEqual(line, "STRESS (0–3, the Stress screen's daytime scale: 0 calm, 3 highly activated; "
                       + "higher is more wound-up): now 0.9 · today's average 1.4 over 3 scored hours.")
    }

    func testAMovingNewestPointSaysSoInsteadOfAnOlderLevel() {
        let hours = [point(now - 2 * 3600, 1.2), point(now - 3600, nil, masked: true)]
        let line = AICoachEngine.stressNowSummary(
            result: result(hours: hours, timeline: hours, dayMean: 1.2), now: now) ?? ""
        XCTAssertTrue(line.contains("now: no reading — I was moving"), line)
        XCTAssertTrue(line.contains("today's average 1.2 over 1 scored hour."), line)
    }

    func testAStaleNewestPointIsNotNow() {
        let hours = [point(now - 4 * 3600, 2.1)]   // ended three hours ago
        let line = AICoachEngine.stressNowSummary(
            result: result(hours: hours, timeline: hours, dayMean: 2.1), now: now) ?? ""
        XCTAssertTrue(line.contains("now: no recent reading"), line)
        XCTAssertFalse(line.contains("now 2.1"), line)
    }

    func testNothingScoredTodayEmitsNoLine() {
        XCTAssertNil(AICoachEngine.stressNowSummary(result: .empty, now: now))
    }
}
