import XCTest
import StrandAnalytics
@testable import Strand

/// The STRESS line (`AICoachEngine.stressNowSummary`, 261021): stress now against today's average on
/// the Stress screen's 0–3 scale. Pinned because the Today stress bullet quotes these two figures
/// verbatim, so they must be the ones the screen shows — the timeline's newest point and its header
/// average — and, since 261021b, always a level once anything is scored, labelled when I am
/// moving or the reading is old.
final class StressNowLineTests: XCTestCase {

    private let now = 50_000

    private func point(_ startTs: Int, _ level: Double?, masked: Bool = false,
                       hr: Double? = nil) -> DaytimeStress.HourPoint {
        DaytimeStress.HourPoint(hour: 0, startTs: startTs, level: level, meanHR: hr, rmssd: nil,
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
        XCTAssertEqual(line?.components(separatedBy: "\n").first, "STRESS (0–3, the Stress screen's daytime scale: 0 calm, 3 highly activated; "
                       + "higher is more wound-up): now 0.9 · today's average 1.4 over 3 scored hours.")
    }

    /// 261021b: moving never blanks the level — the last settled reading stays, labelled as such.
    func testMovingKeepsTheLastSettledLevelAndSaysSo() {
        let hours = [point(now - 2 * 3600, 1.2), point(now - 3600, nil, masked: true)]
        let timeline = [point(now - 2 * 3600, 1.2), point(now - 5400, 1.04),
                        point(now - 3600, nil, masked: true)]
        let line = AICoachEngine.stressNowSummary(
            result: result(hours: hours, timeline: timeline, dayMean: 1.2), now: now) ?? ""
        XCTAssertTrue(line.contains("now 1.0 · today's average 1.2 over 1 scored hour."), line)
        XCTAssertTrue(line.contains("I am MOVING right now"), line)
        XCTAssertTrue(line.contains("last settled reading, from 30 min ago"), line)
        XCTAssertFalse(line.contains("no reading"), line)
    }

    /// An old level is still given, with its age, rather than withheld.
    func testAnOldLevelIsGivenWithItsAge() {
        let hours = [point(now - 4 * 3600, 2.1)]   // ended three hours ago
        let line = AICoachEngine.stressNowSummary(
            result: result(hours: hours, timeline: hours, dayMean: 2.1), now: now) ?? ""
        XCTAssertTrue(line.contains("now 2.1"), line)
        XCTAssertTrue(line.contains("from 180 min ago; nothing newer has been scored"), line)
        XCTAssertFalse(line.contains("MOVING"), line)
    }

    func testTheLogLineSaysWhatTheCoachWasGiven() {
        let hours = [point(now - 2 * 3600, 1.2), point(now - 3600, nil, masked: true)]
        XCTAssertEqual(AICoachEngine.stressNowDiagnostic(
            result: result(hours: hours, timeline: hours, dayMean: 1.2), now: now),
            "coach: STRESS line — now=1.2 (latest scored, 60 min old) movingNow=true day=1.2/1h"
            + " (timeline points=2 scored=1 moving=1)")
        XCTAssertEqual(AICoachEngine.stressNowDiagnostic(result: .empty, now: now),
                       "coach: STRESS line absent — nothing scored today (timeline points=0 scored=0 moving=0)")
    }

    /// 261022: the block carries the WHY — when it rose (the day's readings, by the end of each
    /// reading's hour, movement shown as "moving") and the heart rate behind the latest reading
    /// against my calmest scored hour.
    func testTheBlockCarriesWhenItRoseAndTheHeartRateBehindIt() {
        let now = 10 * 3600 + 1800   // 10:30 UTC
        let hours = [point(7 * 3600, 0.8, hr: 64), point(8 * 3600, nil, masked: true, hr: 98),
                     point(9 * 3600, 1.9, hr: 81)]
        let timeline = hours + [point(9 * 3600 + 1800, 2.04, hr: 83.4)]
        let block = AICoachEngine.stressNowSummary(
            result: result(hours: hours, timeline: timeline, dayMean: 1.35), now: now,
            timeZone: TimeZone(identifier: "UTC")!) ?? ""
        let lines = block.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3, block)
        XCTAssertTrue(lines[0].contains("now 2.0 · today's average 1.4 over 2 scored hours."), block)
        XCTAssertEqual(lines[1], "  Through the day (each reading is the hour up to that time, oldest first): "
                       + "08:00 0.8 · 09:00 moving · 10:00 1.9 · 10:30 2.0")
        XCTAssertEqual(lines[2], "  Heart rate behind the latest reading: 83 bpm; my calmest scored hour today: 64 bpm.")
    }

    func testNothingScoredTodayEmitsNoLine() {
        XCTAssertNil(AICoachEngine.stressNowSummary(result: .empty, now: now))
    }
}
