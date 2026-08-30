import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

/// `Repository.liveTargets` — the wiring that feeds the three-pillar Live Activity card and the
/// coach's TODAY'S TARGETS block from the same rows. Pinned over fixtures because the wiring is
/// exactly what a refactor would silently bend: which row supplies the resting HR, which supplies
/// today's effort and calories, and that the readiness-dependent values flow through the SAME chain
/// the implementation uses (the readiness level over fixtures is the engine's business, not this
/// test's).
@MainActor
final class RepositoryLiveTargetsTests: XCTestCase {

    private func metric(day: String, sleepMin: Double? = 480, rhr: Int? = 60,
                        recovery: Double? = nil, strain: Double? = nil,
                        kcal: Double? = nil) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: sleepMin, efficiency: nil, deepMin: nil,
                    remMin: nil, lightMin: nil, disturbances: nil, restingHr: rhr,
                    avgHrv: nil, recovery: recovery, strain: strain, exerciseCount: nil,
                    activeKcalEst: kcal)
    }

    /// The full wiring over a steady fortnight plus today's partial row: the ceiling is Karvonen
    /// over the LATEST resting HR, the session/effort/kcal targets flow through the readiness
    /// chain, exercise calories subtract the resting accrual, and the sleep need composes from the
    /// same charge/rest/readiness inputs.
    func testTargetsDeriveFromTheBodyState() {
        var days: [DailyMetric] = []
        for i in 1...14 {
            days.append(metric(day: String(format: "2026-08-%02d", i), rhr: 60,
                               strain: 10, kcal: 900))
        }
        // Today: a partial row — some strain and calories banked, no RHR yet.
        days.append(metric(day: "2026-08-15", sleepMin: nil, rhr: nil, strain: 12, kcal: 700))
        let profile = UserProfile()   // 70 kg / 170 cm / 30 y — the estimator suite's standard
        let halfDay = 43_200

        let t = Repository.liveTargets(days: days, charge: 80, restScore: 81,
                                       profile: profile, secondsSinceMidnight: halfDay,
                                       todayKey: "2026-08-15")

        // Karvonen over the latest measured RHR (day 14's 60 — today has none): 60 + 0.3×127 = 98.
        XCTAssertEqual(t.hrCeilingBpm, DailyTargets.calmCeilingBpm(restingHr: 60, age: 30))

        // The session chain, pinned via the same calls the implementation makes.
        let readiness = ReadinessEngine.evaluate(days: days).level
        let session = DailyTargets.sessionPrescription(charge: 80, readiness: readiness, restScore: 81)
        XCTAssertEqual(t.restDay, session == nil)
        XCTAssertEqual(t.sessionMinutes, session?.minutes)
        XCTAssertEqual(t.effortTarget,
                       DailyTargets.effortTargetStored(currentEffortStored: 12, session: session))
        XCTAssertEqual(t.kcalTargetKcal, session.map {
            DailyTargets.sessionKcal(session: $0, profile: profile, restingHr: 60)
        })

        // Exercise calories: today's 700 minus half a day of resting accrual, floored at 0.
        XCTAssertEqual(t.exerciseKcalToday,
                       DailyTargets.exerciseKcalToday(dayKcalEstimate: 700, profile: profile,
                                                      secondsSinceMidnight: halfDay))

        // Sleep composes through the same chain (8 h nights → no ledger debt beyond the deadband).
        XCTAssertEqual(t.sleepNeedTonightMin,
                       DailyTargets.sleepNeedTonightMin(age: 30, charge: 80, restScore: 81,
                                                        readiness: readiness, debtBalanceMin: 0))
    }

    /// No charge (calibrating install): the session defaults to the maintain base rather than
    /// vanishing, and the ceiling still reads — the two do not share failure modes.
    func testUnknownChargeKeepsANeutralSession() {
        let days = (1...10).map { metric(day: String(format: "2026-08-%02d", $0)) }
        let t = Repository.liveTargets(days: days, charge: nil, restScore: nil,
                                       profile: UserProfile(), secondsSinceMidnight: 3600,
                                       todayKey: "2026-08-15")
        XCTAssertEqual(t.hrCeilingBpm, DailyTargets.calmCeilingBpm(restingHr: 60, age: 30))
        let readiness = ReadinessEngine.evaluate(days: days).level
        XCTAssertEqual(t.sessionMinutes,
                       DailyTargets.sessionPrescription(charge: nil, readiness: readiness,
                                                        restScore: nil)?.minutes)
    }
}
