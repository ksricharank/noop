import XCTest
import WhoopStore
@testable import Strand

/// 261009: the coach summaries rewrite only when what they DESCRIBE moves. The report: "the LLM output
/// updates twice within 1-5 seconds" — every summary re-asked on any data refresh, and the numerators
/// (steps, effort, calories) change on every strap sync while last night's figures do not.
final class SummaryRewriteKeyTests: XCTestCase {

    private func night(day: String, sleep: Double = 474, deep: Double = 96, hrv: Double = 36,
                       recovery: Double? = 62, steps: Int? = 2_140, strain: Double? = 12) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: sleep, efficiency: 0.9, deepMin: deep, remMin: 114,
                    lightMin: 264, disturbances: 6, restingHr: 61, avgHrv: hrv, recovery: recovery,
                    strain: strain, exerciseCount: nil, spo2Pct: nil, skinTempDevC: nil,
                    respRateBpm: 15.5, steps: steps, activeKcalEst: 620)
    }

    // MARK: Sleep tab ("What last night says")

    func testSleepKeyIgnoresTheDaysNumerators() {
        let before = night(day: "2026-10-09")
        let later = night(day: "2026-10-09", steps: 9_870, strain: 41)
        XCTAssertEqual(SleepView.sleepSummaryKey(before), SleepView.sleepSummaryKey(later),
                       "a strap sync moving steps/effort must not rewrite a summary of last night")
    }

    func testSleepKeyMovesWithTheNight() {
        let partial = night(day: "2026-10-09", sleep: 256, deep: 56)
        let full = night(day: "2026-10-09", sleep: 474, deep: 96)
        XCTAssertNotEqual(SleepView.sleepSummaryKey(partial), SleepView.sleepSummaryKey(full),
                          "a partial night becoming the full one (the 261006 case) must rewrite it")
    }

    // MARK: Today synthesis

    @MainActor
    func testTodayKeyIgnoresNumeratorsAndMovesWithTheNight() async throws {
        let repo = Repository(deviceId: "test-summary-rewrite-key")
        let engine = AICoachEngine(repo: repo)
        let today = Repository.localDayKey(Date())

        repo.days = [night(day: today)]
        let base = engine.synthesisMaterialKey()

        repo.days = [night(day: today, steps: 9_870, strain: 41)]
        XCTAssertEqual(engine.synthesisMaterialKey(), base,
                       "steps and effort ticking over must not rewrite the Today read")

        repo.days = [night(day: today, sleep: 256)]
        XCTAssertNotEqual(engine.synthesisMaterialKey(), base, "a different night must")

        repo.days = [night(day: today, recovery: 50)]
        XCTAssertNotEqual(engine.synthesisMaterialKey(), base, "a re-judged Charge must")
    }
}
