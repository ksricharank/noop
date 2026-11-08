import XCTest
@testable import Strand
import WhoopStore

/// 261004: the PER-METRIC TREND CALCS block behind the Trends tab's seven-line summary. Pinned
/// because the prompt promises the model one calc line per surfaced metric, in a fixed vocabulary
/// (mean / halves / slope / extremes / anomalies) — a drifted label or a dropped metric silently
/// starves the corresponding output line of its numbers.
final class PerMetricTrendBlockTests: XCTestCase {

    private func day(_ d: String, charge: Double? = nil, hrv: Double? = nil, rhr: Int? = nil,
                     sleepMin: Double? = nil, strain: Double? = nil, steps: Int? = nil) -> DailyMetric {
        DailyMetric(day: d, totalSleepMin: sleepMin, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: charge,
                    strain: strain, exerciseCount: nil, steps: steps)
    }

    /// All seven metrics appear, in the surfaced order, exactly once.
    func testAllSevenMetricsAppearInOrder() {
        let days = (1...10).map { i in
            day(String(format: "2026-09-%02d", i), charge: Double(50 + i), hrv: Double(30 + i),
                rhr: 60, sleepMin: 420, strain: 5, steps: 8_000)
        }
        let block = AICoachEngine.perMetricTrendBlock(days: days, restByDay: [:], dayQualityByDay: [:])
        let labels = ["Charge:", "HRV:", "Resting HR:", "Sleep:", "Effort:", "Steps:", "Day quality:"]
        var last = -1
        for label in labels {
            let r = block.range(of: "  " + label)
            XCTAssertNotNil(r, "missing \(label)")
            let pos = block.distance(from: block.startIndex, to: r!.lowerBound)
            XCTAssertGreaterThan(pos, last, "\(label) out of order")
            last = pos
        }
    }

    /// A rising series carries a positive slope and the halves show the move; extremes name days.
    func testARisingSeriesReadsAsRising() {
        let days = (1...14).map { i in
            day(String(format: "2026-09-%02d", i), charge: Double(40 + 2 * i))
        }
        let block = AICoachEngine.perMetricTrendBlock(days: days, restByDay: [:], dayQualityByDay: [:])
        let chargeLine = block.split(separator: "\n").first { $0.contains("Charge:") }.map(String.init) ?? ""
        XCTAssertTrue(chargeLine.contains("slope=+14"), chargeLine)   // +2/day = +14/wk
        XCTAssertTrue(chargeLine.contains("min=42@09-01"), chargeLine)
        XCTAssertTrue(chargeLine.contains("max=68@09-14"), chargeLine)
    }

    /// Fewer than three readings is said out loud, not padded; a clean constant series lists no anomalies.
    func testSparseAndFlatAreHonest() {
        let days = (1...8).map { i in
            day(String(format: "2026-09-%02d", i), charge: 60, hrv: i <= 2 ? 40 : nil)
        }
        let block = AICoachEngine.perMetricTrendBlock(days: days, restByDay: [:], dayQualityByDay: [:])
        XCTAssertTrue(block.contains("HRV: too few readings (2)"), block)
        let chargeLine = block.split(separator: "\n").first { $0.contains("Charge:") }.map(String.init) ?? ""
        XCTAssertFalse(chargeLine.contains("anomalies"), chargeLine)
        XCTAssertTrue(chargeLine.contains("slope=+0"), chargeLine)
    }

    /// A single wild day is flagged as an anomaly with its value.
    func testAnAnomalousDayIsNamed() {
        var days = (1...12).map { i in day(String(format: "2026-09-%02d", i), charge: 60) }
        days[5] = day("2026-09-06", charge: 10)
        let block = AICoachEngine.perMetricTrendBlock(days: days, restByDay: [:], dayQualityByDay: [:])
        XCTAssertTrue(block.contains("anomalies=09-06(10)"), block)
    }

    /// 261024c: NSS rides as an eighth calc line only when there is NSS to read — absent otherwise,
    /// so a window without it reads exactly as before.
    func testNSSLineOnlyWhenThereIsNSS() {
        let days = (1...6).map { day(String(format: "2026-10-%02d", $0)) }
        let without = AICoachEngine.perMetricTrendBlock(days: days, restByDay: [:], dayQualityByDay: [:])
        XCTAssertFalse(without.contains("Stress (NSS)"), without)
        let nss = Dictionary(uniqueKeysWithValues: days.enumerated().map { ($1.day, 45.0 + Double($0) * 2) })
        let with = AICoachEngine.perMetricTrendBlock(days: days, restByDay: [:], dayQualityByDay: [:],
                                                     nssByDay: nss)
        XCTAssertTrue(with.contains("Stress (NSS): n=6 mean=50"), with)
        XCTAssertTrue(AICoachEngine.nssWindowBlock(days: Array(days.prefix(2)), nssByDay: nss)
            .hasSuffix("oldest first: 10-01 45 · 10-02 47"))
        XCTAssertEqual(AICoachEngine.nssWindowBlock(days: days, nssByDay: [:]), "")
    }
}
