import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

/// The integration digest (260920). The digest builder and the cadence rule are pure, so both are
/// tested here without a store, a folder or a provider.
final class MuseIntegrationTests: XCTestCase {

    // MARK: Filename safety

    func testBasenameStripsPathSeparatorsAndDots() {
        XCTAssertEqual(MuseIntegration.sanitizeBasename("../../etc/passwd"), "etcpasswd")
        XCTAssertEqual(MuseIntegration.sanitizeBasename("noop_to_muse"), "noop_to_muse")
        // A wearer typing the extension must not get it twice.
        XCTAssertEqual(MuseIntegration.sanitizeBasename("noop_to_muse.txt"), "noop_to_muse")
        // Empty / separator-only input falls back rather than writing a dotfile.
        XCTAssertEqual(MuseIntegration.sanitizeBasename("   "), MuseIntegration.defaultFilename)
        XCTAssertEqual(MuseIntegration.sanitizeBasename("..."), MuseIntegration.defaultFilename)
        XCTAssertFalse(MuseIntegration.sanitizeBasename("/tmp/x").contains("/"))
    }

    // MARK: Cadence

    func testIsDueOnlyAfterTheHourAndOncePerDay() {
        let cal = Calendar.current
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 9))!
        let beforeHour = cal.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 5))!

        // Never written: due once the hour has passed, not before.
        XCTAssertTrue(MuseIntegration.isDue(now: now, lastWrittenMs: 0, hourOfDay: 7))
        XCTAssertFalse(MuseIntegration.isDue(now: beforeHour, lastWrittenMs: 0, hourOfDay: 7))

        // Already written after today's trigger: not due again.
        let writtenAt8 = cal.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 8))!
        XCTAssertFalse(MuseIntegration.isDue(now: now,
                                             lastWrittenMs: Int(writtenAt8.timeIntervalSince1970 * 1000),
                                             hourOfDay: 7))

        // Written YESTERDAY: due again today — a missed day catches up rather than being skipped.
        let yesterday = cal.date(from: DateComponents(year: 2026, month: 9, day: 19, hour: 8))!
        XCTAssertTrue(MuseIntegration.isDue(now: now,
                                            lastWrittenMs: Int(yesterday.timeIntervalSince1970 * 1000),
                                            hourOfDay: 7))
    }

    // MARK: Day arithmetic

    @MainActor
    func testPreviousDayKeyIsTheInverseOfNext() {
        XCTAssertEqual(DayQualityComputer.previousDayKey("2026-09-20"), "2026-09-19")
        XCTAssertEqual(DayQualityComputer.previousDayKey("2026-01-01"), "2025-12-31")
        XCTAssertEqual(DayQualityComputer.previousDayKey("2026-03-01"), "2026-02-28")
        for day in ["2026-09-20", "2026-01-01", "2024-02-29"] {
            XCTAssertEqual(DayQualityComputer.nextDayKey(DayQualityComputer.previousDayKey(day)!), day)
        }
    }

    // MARK: The digest

    private func metric(day: String,
                        sleep: Double? = nil, deep: Double? = nil, rem: Double? = nil,
                        light: Double? = nil, eff: Double? = nil, dist: Int? = nil,
                        rhr: Int? = nil, hrv: Double? = nil, rec: Double? = nil,
                        strain: Double? = nil, steps: Int? = nil,
                        kcal: Double? = nil, resp: Double? = nil) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: sleep, efficiency: eff, deepMin: deep, remMin: rem,
                    lightMin: light, disturbances: dist, restingHr: rhr, avgHrv: hrv,
                    recovery: rec, strain: strain, exerciseCount: nil,
                    spo2Pct: nil, skinTempDevC: nil, respRateBpm: resp,
                    steps: steps, activeKcalEst: kcal)
    }

    /// The whole point of the file: a reader must be able to tell "no data" from "zero".
    func testAbsentFieldsSayNotRecordedRatherThanVanishing() {
        let input = MuseIntegration.Input(recapDay: "2026-09-19",
                                          recapScore: nil,
                                          recapMetric: nil,
                                          nightMetric: nil,
                                          todayMetric: metric(day: "2026-09-20"),
                                          todayDay: "2026-09-20")
        let out = MuseIntegration.digest(input)
        XCTAssertTrue(out.contains("not recorded"), out)
        XCTAssertTrue(out.contains("not scored"), out)
        XCTAssertTrue(out.contains("No sleep recorded"), out)
    }

    /// The night section must describe the night by the morning it ENDED on — the 1.9h-vs-7.9h
    /// attribution fault the coach prompts hit on 260920.
    func testNightIsLabelledByTheMorningItEndedOn() {
        let night = metric(day: "2026-09-20", sleep: 474, deep: 90, rem: 110, light: 274,
                           eff: 0.88, dist: 6, rhr: 64, hrv: 36, resp: 16.0)
        let input = MuseIntegration.Input(recapDay: "2026-09-19",
                                          recapScore: nil, recapMetric: nil,
                                          nightMetric: night,
                                          todayMetric: nil, todayDay: "2026-09-20")
        let out = MuseIntegration.digest(input)
        XCTAssertTrue(out.contains("ended on the morning of 2026-09-20"), out)
        XCTAssertTrue(out.contains("7h 54m"), out)
    }

    /// Efficiency is stored as a fraction OR a percentage depending on import path; both must
    /// render as the same percentage the app shows.
    func testEfficiencyNormalisesBothStorageForms() {
        for raw in [0.88, 88.0] {
            let night = metric(day: "2026-09-20", sleep: 474, eff: raw)
            let input = MuseIntegration.Input(recapDay: "2026-09-19", recapScore: nil,
                                              recapMetric: nil, nightMetric: night,
                                              todayMetric: nil, todayDay: "2026-09-20")
            XCTAssertTrue(MuseIntegration.digest(input).contains("Efficiency: 88%"))
        }
    }

    /// The baseline block is what a single day's file cannot carry, and it must not appear at all
    /// on too little history rather than averaging two points into a "normal".
    func testBaselinesNeedThreeDays() {
        let days = (1...5).map { metric(day: "2026-09-0\($0)", rhr: 60 + $0, hrv: 30) }
        var input = MuseIntegration.Input(recapDay: "2026-09-19", recapScore: nil,
                                          recapMetric: nil, nightMetric: nil,
                                          todayMetric: nil, todayDay: "2026-09-20")
        input.recentDays = Array(days.prefix(2))
        XCTAssertFalse(MuseIntegration.digest(input).contains("My normal range"))
        input.recentDays = days
        XCTAssertTrue(MuseIntegration.digest(input).contains("My normal range"))
    }
}

// MARK: - Sample render (260920)
//
// Not an assertion — a readable dump of a fully-populated digest, so the maintainer can review the
// file's CONTENT rather than infer it from the builder. Kept because it is also the fastest way to
// see the effect of adding or removing a field.
extension MuseIntegrationTests {
    @MainActor
    func testPrintFullSampleDigest() throws {
        var input = MuseIntegration.Input(
            recapDay: "2026-09-19",
            recapScore: nil,
            recapMetric: metric(day: "2026-09-19", rhr: 64, hrv: 36, rec: 71, strain: 39,
                                steps: 8512, kcal: 1828),
            nightMetric: metric(day: "2026-09-20", sleep: 474, deep: 96, rem: 114, light: 264,
                                eff: 0.88, dist: 6, rhr: 64, hrv: 36, resp: 16.0),
            todayMetric: metric(day: "2026-09-20", rhr: 63, hrv: 34, rec: 74, strain: 12,
                                steps: 2140, kcal: 620),
            todayDay: "2026-09-20")
        input.recapWaterCups = 10
        input.recapWaterTargetCups = 21
        var recent: [DailyMetric] = []
        for i in 1...14 {
            let day: String = String(format: "2026-09-%02d", i)
            let sleepMin: Double = 430 + Double(i * 3)
            let rhrV: Int = 62 + (i % 3)
            let hrvV: Double = 31 + Double(i % 5)
            let recV: Double = 65 + Double(i % 10)
            let strainV: Double = 30 + Double(i % 12)
            let stepsV: Int = 7000 + i * 120
            let respV: Double = 15.5 + Double(i % 3) * 0.2
            recent.append(metric(day: day, sleep: sleepMin, rhr: rhrV, hrv: hrvV,
                                 rec: recV, strain: strainV, steps: stepsV, resp: respV))
        }
        input.recentDays = recent

        var scores: [String: Double] = [:]
        for i in 6...19 {
            let day: String = String(format: "2026-09-%02d", i)
            scores[day] = Double(((i * 7) % 60) - 20)
        }
        input.recentQualityScores = scores
        input.derivedTrends = AICoachEngine.derivedTrendsBlock(days: recent)

        let out = MuseIntegration.digest(
            input, generatedAt: Date(timeIntervalSince1970: 1_789_000_000))
        print("\n===== BEGIN noop_to_muse.txt =====\n" + out + "===== END =====\n")
    }
}
