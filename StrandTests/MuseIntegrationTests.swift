import XCTest
import StrandDesign
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

    func testIsDueOncePerSlotFromTheSleepWindowEnd() {
        let cal = Calendar.current
        let anchor = 7 * 60   // the sleep window ends 07:00
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
        }
        func ms(_ d: Date) -> Int { Int(d.timeIntervalSince1970 * 1000) }
        let now = at(20, 9), beforeAnchor = at(20, 5)

        // Never written: due, before or after the anchor (before it, the slot walks back to yesterday's).
        XCTAssertTrue(MuseIntegration.isDue(now: now, lastWrittenMs: 0, updatesPerDay: 1, anchorMinuteOfDay: anchor))
        XCTAssertTrue(MuseIntegration.isDue(now: beforeAnchor, lastWrittenMs: 0, updatesPerDay: 1, anchorMinuteOfDay: anchor))

        // Written yesterday evening: yesterday's slot is served, so 05:00 today is NOT due …
        XCTAssertFalse(MuseIntegration.isDue(now: beforeAnchor, lastWrittenMs: ms(at(19, 20)),
                                             updatesPerDay: 1, anchorMinuteOfDay: anchor))
        // … and 09:00 today IS: a new slot began at 07:00.
        XCTAssertTrue(MuseIntegration.isDue(now: now, lastWrittenMs: ms(at(19, 20)),
                                            updatesPerDay: 1, anchorMinuteOfDay: anchor))
        // Written at 08:00 today: same slot, not again.
        XCTAssertFalse(MuseIntegration.isDue(now: now, lastWrittenMs: ms(at(20, 8)),
                                             updatesPerDay: 1, anchorMinuteOfDay: anchor))
        // A missed day catches up rather than being skipped.
        XCTAssertTrue(MuseIntegration.isDue(now: now, lastWrittenMs: ms(at(19, 8)),
                                            updatesPerDay: 1, anchorMinuteOfDay: anchor))

        // Twice a day: slots at 07:00 and 19:00. Written at 08:00 → not due at 15:00, due at 19:30.
        XCTAssertFalse(MuseIntegration.isDue(now: at(20, 15), lastWrittenMs: ms(at(20, 8)),
                                             updatesPerDay: 2, anchorMinuteOfDay: anchor))
        XCTAssertTrue(MuseIntegration.isDue(now: at(20, 19, 30), lastWrittenMs: ms(at(20, 8)),
                                            updatesPerDay: 2, anchorMinuteOfDay: anchor))
        // Four a day from 07:00: 07, 13, 19, 01. Written at 19:10 → not due at 23:00, due at 01:30.
        XCTAssertFalse(MuseIntegration.isDue(now: at(20, 23), lastWrittenMs: ms(at(20, 19, 10)),
                                             updatesPerDay: 4, anchorMinuteOfDay: anchor))
        XCTAssertTrue(MuseIntegration.isDue(now: at(21, 1, 30), lastWrittenMs: ms(at(20, 19, 10)),
                                            updatesPerDay: 4, anchorMinuteOfDay: anchor))
    }

    /// 260922: a digest with no night in it is not ready. The 260921-0737 file was exactly that.
    func testReadinessRequiresLastNight() {
        var input = MuseIntegration.Input(recapDay: "2026-09-20", recapScore: nil, recapMetric: nil,
                                          nightMetric: nil, todayMetric: nil, todayDay: "2026-09-21")
        XCTAssertFalse(input.isReady)
        input.nightMetric = DailyMetric(day: "2026-09-21", totalSleepMin: 507, efficiency: 0.93, deepMin: 104,
                                        remMin: 133, lightMin: 271, disturbances: nil, restingHr: 64, avgHrv: 33,
                                        recovery: 62, strain: nil, exerciseCount: nil, spo2Pct: nil,
                                        skinTempDevC: nil, respRateBpm: nil, steps: nil, activeKcalEst: nil,
                                        spo2Red: nil, spo2Ir: nil, avgSdnn: nil, skinTempC: nil)
        XCTAssertTrue(input.isReady)
    }

    /// The slot start the readiness grace is measured from: the most recent boundary at or before now.
    func testCurrentSlotStartWalksBackBeforeTheAnchor() {
        let cal = Calendar.current
        let anchor = 7 * 60
        let at9 = cal.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 9))!
        let at5 = cal.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 5))!
        XCTAssertEqual(MuseIntegration.currentSlotStart(now: at9, updatesPerDay: 1, anchorMinuteOfDay: anchor),
                       cal.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 7)))
        XCTAssertEqual(MuseIntegration.currentSlotStart(now: at5, updatesPerDay: 1, anchorMinuteOfDay: anchor),
                       cal.date(from: DateComponents(year: 2026, month: 9, day: 19, hour: 7)))
        XCTAssertEqual(MuseIntegration.currentSlotStart(now: at5, updatesPerDay: 4, anchorMinuteOfDay: anchor),
                       cal.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 1)))
    }

    /// The retired hour + interval pair maps onto the new setting once: 24 h → 1, 6 h → 4.
    func testUpdatesPerDayMigratesFromTheRetiredInterval() {
        let d = UserDefaults.standard
        d.removeObject(forKey: MuseIntegration.updatesPerDayKey)
        d.set(6, forKey: MuseIntegration.intervalKey)
        XCTAssertEqual(MuseIntegration.updatesPerDay, 4)
        d.set(24, forKey: MuseIntegration.intervalKey)
        XCTAssertEqual(MuseIntegration.updatesPerDay, 1)
        MuseIntegration.updatesPerDay = 3
        XCTAssertEqual(MuseIntegration.updatesPerDay, 3, "an explicit setting wins over the migration")
        d.removeObject(forKey: MuseIntegration.updatesPerDayKey)
        d.removeObject(forKey: MuseIntegration.intervalKey)
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

// MARK: - Sparkline preference (260920)

final class SparklinePrefsTests: XCTestCase {
    /// Default-OFF over an inverted key: an untouched install must get the CHEAP renderer. Phrasing
    /// this as a plain `simpleKey` would have defaulted to the expensive path by accident, because
    /// an unset `Bool` reads `false`.
    func testAnUntouchedInstallGetsTheCheapPath() {
        UserDefaults.standard.removeObject(forKey: SparklinePrefs.richKey)
        XCTAssertTrue(SparklinePrefs.simple)
    }

    func testTheToggleSelectsTheRichPath() {
        defer { UserDefaults.standard.removeObject(forKey: SparklinePrefs.richKey) }
        UserDefaults.standard.set(true, forKey: SparklinePrefs.richKey)
        XCTAssertFalse(SparklinePrefs.simple)
        UserDefaults.standard.set(false, forKey: SparklinePrefs.richKey)
        XCTAssertTrue(SparklinePrefs.simple)
    }

    /// The key string is the cross-platform/backup contract, pinned so a rename cannot silently
    /// orphan a wearer's setting across a `.noopbak` round-trip.
    func testKeyStringIsPinned() {
        XCTAssertEqual(SparklinePrefs.richKey, "noop.richSparklines")
    }
}
