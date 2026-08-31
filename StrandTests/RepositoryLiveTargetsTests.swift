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

    /// The full wiring over a steady fortnight plus today's partial row: the session/effort/kcal
    /// targets flow through the readiness chain (resting HR from the latest scored row), the Cal
    /// pair is TOTAL calories (raw day estimate vs resting day + session), and the sleep need
    /// composes from the same charge/rest/readiness inputs.
    func testTargetsDeriveFromTheBodyState() {
        var days: [DailyMetric] = []
        for i in 1...14 {
            days.append(metric(day: String(format: "2026-08-%02d", i), rhr: 60,
                               strain: 10, kcal: 900))
        }
        // Today: a partial row — some strain and calories banked, no RHR yet.
        days.append(metric(day: "2026-08-15", sleepMin: nil, rhr: nil, strain: 12, kcal: 700))
        let profile = UserProfile()   // 70 kg / 170 cm / 30 y — the estimator suite's standard

        let t = Repository.liveTargets(days: days, charge: 80, restScore: 81,
                                       profile: profile,
                                       todayKey: "2026-08-15")

        // The session chain, pinned via the same calls the implementation makes.
        let readiness = ReadinessEngine.evaluate(days: days).level
        let session = DailyTargets.sessionPrescription(charge: 80, readiness: readiness, restScore: 81)
        XCTAssertEqual(t.restDay, session == nil)
        XCTAssertEqual(t.sessionMinutes, session?.minutes)
        XCTAssertEqual(t.effortTarget,
                       DailyTargets.effortTargetStored(currentEffortStored: 12, session: session))
        XCTAssertEqual(t.kcalTargetKcal,
                       DailyTargets.dayKcalTarget(session: session, profile: profile,
                                                  restingHr: 60))

        // TOTAL calories: today's raw day estimate, and today's effort carried for the n/t pair.
        XCTAssertEqual(t.kcalToday, 700)
        XCTAssertEqual(t.effortTodayStored, 12)

        // Sleep composes through the same chain (8 h nights → no ledger debt beyond the deadband).
        XCTAssertEqual(t.sleepNeedTonightMin,
                       DailyTargets.sleepNeedTonightMin(age: 30, charge: 80, restScore: 81,
                                                        readiness: readiness, debtBalanceMin: 0))
    }

    /// No charge (calibrating install): the session defaults to the maintain base rather than
    /// vanishing.
    func testUnknownChargeKeepsANeutralSession() {
        let days = (1...10).map { metric(day: String(format: "2026-08-%02d", $0)) }
        let t = Repository.liveTargets(days: days, charge: nil, restScore: nil,
                                       profile: UserProfile(),
                                       todayKey: "2026-08-15")
        let readiness = ReadinessEngine.evaluate(days: days).level
        XCTAssertEqual(t.sessionMinutes,
                       DailyTargets.sessionPrescription(charge: nil, readiness: readiness,
                                                        restScore: nil)?.minutes)
    }
}
