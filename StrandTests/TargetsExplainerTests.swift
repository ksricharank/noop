import XCTest
@testable import Strand
import StrandAnalytics

/// Pins the optional "How these were set" derivations (260901): one line per target with that
/// day's actual inputs, built from the SAME `DailyTargets` calls the pricing used — so the stated
/// arithmetic must reproduce the displayed target, which is exactly what these tests assert.
final class TargetsExplainerTests: XCTestCase {

    private var profile: UserProfile {
        UserProfile(weightKg: 70, heightCm: 175, age: 34, sex: "male", stepTicksPerStep: 0)
    }

    func testSessionDayLinesCarryTheRealArithmetic() {
        let charge = 80, rest = 81
        let readiness = ReadinessEngine.Level.balanced
        let session = DailyTargets.sessionPrescription(charge: charge, readiness: readiness,
                                                       restScore: rest)
        XCTAssertNotNil(session, "charge 80 / balanced / rest 81 prescribes a session")
        let effortTarget = DailyTargets.effortTargetStored(currentEffortStored: nil, session: session)
        let kcalTarget = DailyTargets.dayKcalTarget(session: session, profile: profile, restingHr: 55)
        let stepsTarget = DailyTargets.stepsTarget(charge: charge, readiness: readiness)
        let sleepNeed = DailyTargets.sleepNeedTonightMin(age: 34, charge: charge, restScore: rest,
                                                         readiness: readiness, debtBalanceMin: -40)
        let hr = DailyTargets.sessionHrBpm(session: session!, restingHr: 55, age: 34)

        let lines = TargetsExplainer.lines(
            charge: charge, readiness: readiness, restScore: rest,
            session: session, sessionHrBpm: hr,
            effortTarget: effortTarget, kcalTarget: kcalTarget, stepsTarget: stepsTarget,
            sleepNeedMin: sleepNeed, age: 34, restingHr: 55, profile: profile,
            debtBalanceMin: -40)

        XCTAssertEqual(lines.count, 5, "session line + one per target")
        // Session line: band, readiness, rest shift, minutes and HR — the shared input.
        XCTAssertTrue(lines[0].contains("charge 80 → push band"), lines[0])
        XCTAssertTrue(lines[0].contains("\(session!.minutes) min"), lines[0])
        XCTAssertTrue(lines[0].contains("~\(hr) bpm"), lines[0])
        // Effort: the stated TRIMP must be the exact product the curve was fed.
        let trimp = Int(session!.edwardsZoneWeight * Double(session!.minutes))
        XCTAssertTrue(lines[1].contains("Effort \(effortTarget)/100"), lines[1])
        XCTAssertTrue(lines[1].contains("\(trimp) TRIMP"), lines[1])
        // Cal: resting part stated as target − session, so the sum is exact by construction.
        let sessionKcal = DailyTargets.sessionKcal(session: session!, profile: profile, restingHr: 55)
        XCTAssertTrue(lines[2].contains("Cal \(kcalTarget):"), lines[2])
        XCTAssertTrue(lines[2].contains("~\(kcalTarget - sessionKcal) kcal"), lines[2])
        XCTAssertTrue(lines[2].contains("session \(sessionKcal) kcal"), lines[2])
        // Steps: band base + no trim on balanced.
        XCTAssertTrue(lines[3].contains("Steps \(stepsTarget):"), lines[3])
        XCTAssertTrue(lines[3].contains("no trim"), lines[3])
        // Sleep: the debt term appears with its share (40 m owed is past the deadband).
        XCTAssertTrue(lines[4].contains("Sleep \(sleepNeed / 60)h\(String(format: "%02d", sleepNeed % 60))"),
                      lines[4])
        XCTAssertTrue(lines[4].contains("debt"), lines[4])
    }

    func testRestDayLinesSayRestAndKeepTheZeroTargetStory() {
        let lines = TargetsExplainer.lines(
            charge: 20, readiness: .rundown, restScore: 40,
            session: nil, sessionHrBpm: nil,
            effortTarget: 0,
            kcalTarget: DailyTargets.dayKcalTarget(session: nil, profile: profile, restingHr: 60),
            stepsTarget: DailyTargets.stepsTarget(charge: 20, readiness: .rundown),
            sleepNeedMin: DailyTargets.sleepNeedTonightMin(age: 34, charge: 20, restScore: 40,
                                                           readiness: .rundown, debtBalanceMin: 0),
            age: 34, restingHr: 60, profile: profile, debtBalanceMin: 0)

        XCTAssertEqual(lines.count, 5)
        XCTAssertTrue(lines[0].contains("rest day, no session"), lines[0])
        // The zero target's meaning is spelled out — the "x/0" story from the pair-form fix.
        XCTAssertTrue(lines[1].contains("x/0"), lines[1])
        XCTAssertTrue(lines[2].contains("resting day alone"), lines[2])
        // Rundown trims steps by the published adjustment.
        XCTAssertTrue(lines[3].contains("\(DailyTargets.stepsRundownAdj)"), lines[3])
        // No debt term when the ledger is balanced.
        XCTAssertFalse(lines[4].contains("debt"), lines[4])
    }
}
