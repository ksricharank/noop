import XCTest
@testable import Strand
import StrandAnalytics

/// Pins the optional "How these were set" derivations (260901, iterated same-day to the
/// code-shaped format: `input comparison → consequence` lines, real thresholds, taken branch).
/// Built from the SAME `DailyTargets` calls the pricing used — so the stated arithmetic must
/// reproduce the displayed target, which is exactly what these tests assert.
final class TargetsExplainerTests: XCTestCase {

    private var profile: UserProfile {
        UserProfile(weightKg: 70, heightCm: 175, age: 34, sex: "male", stepTicksPerStep: 0)
    }

    func testSessionDayBlocksCarryTheTakenBranchesAndExactArithmetic() {
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

        let blocks = TargetsExplainer.lines(
            charge: charge, readiness: readiness, restScore: rest,
            session: session, sessionHrBpm: hr,
            effortTarget: effortTarget, kcalTarget: kcalTarget, stepsTarget: stepsTarget,
            sleepNeedMin: sleepNeed, age: 34, restingHr: 55, profile: profile,
            debtBalanceMin: -40)

        XCTAssertEqual(blocks.count, 5, "session block + one per target")
        // SESSION: each ladder rung states its comparison against the real threshold, and the
        // conclusion line derives the notch from the inputs (balanced=2, rest 81 in-band → 2).
        XCTAssertTrue(blocks[0].hasPrefix("SESSION"), blocks[0])
        XCTAssertTrue(blocks[0].contains("charge 80 ≥ \(DailyTargets.pushChargeFloor) → base "
                                         + "\(DailyTargets.pushSessionMinutes)m (push)"), blocks[0])
        XCTAssertTrue(blocks[0].contains("readiness balanced → notch 2"), blocks[0])
        XCTAssertTrue(blocks[0].contains("rest 81 in \(DailyTargets.poorRestScore)–"
                                         + "\(DailyTargets.greatRestScore - 1) → notch +0"), blocks[0])
        XCTAssertTrue(blocks[0].contains("⇒ notch 2 → \(session!.minutes)m"), blocks[0])
        // Karvonen spelled with the actual numbers, ending in the exact bpm.
        XCTAssertTrue(blocks[0].contains("= \(hr)bpm"), blocks[0])
        XCTAssertTrue(blocks[0].contains("hr = 55 + "), blocks[0])
        // EFFORT: trimp product and the curve call both end in the displayed numbers.
        let trimp = Int(session!.edwardsZoneWeight * Double(session!.minutes))
        XCTAssertTrue(blocks[1].hasPrefix("EFFORT → \(effortTarget)"), blocks[1])
        XCTAssertTrue(blocks[1].contains("× \(session!.minutes)m = \(trimp)"), blocks[1])
        XCTAssertTrue(blocks[1].contains("strain(\(trimp)) = \(effortTarget)"), blocks[1])
        // CAL: resting part stated as target − session, so the printed sum is exact.
        let sessionKcal = DailyTargets.sessionKcal(session: session!, profile: profile, restingHr: 55)
        XCTAssertTrue(blocks[2].hasPrefix("CAL → \(kcalTarget)"), blocks[2])
        XCTAssertTrue(blocks[2].contains("keytel(\(hr)bpm × \(session!.minutes)m) = \(sessionKcal)"),
                      blocks[2])
        XCTAssertTrue(blocks[2].contains("round\(Int(DailyTargets.calorieRoundKcal))"
                                         + "(\(kcalTarget - sessionKcal) + \(sessionKcal)) = \(kcalTarget)"),
                      blocks[2])
        // STEPS: band base, explicit −0 on balanced, clamp ends in the target.
        XCTAssertTrue(blocks[3].hasPrefix("STEPS → \(stepsTarget)"), blocks[3])
        XCTAssertTrue(blocks[3].contains("base \(DailyTargets.stepsBasePushPerDay) (push)"), blocks[3])
        XCTAssertTrue(blocks[3].contains("readiness balanced → −0"), blocks[3])
        XCTAssertTrue(blocks[3].contains("clamp(\(DailyTargets.stepsFloorPerDay)…"
                                         + "\(DailyTargets.stepsCapPerDay)) → \(stepsTarget)"), blocks[3])
        // SLEEP: 40 m owed is past the deadband, so the debt rung shows the min() with its share.
        XCTAssertTrue(blocks[4].hasPrefix("SLEEP → "), blocks[4])
        XCTAssertTrue(blocks[4].contains("charge 80 ≥ \(DailyTargets.pushChargeFloor) → +0m"), blocks[4])
        XCTAssertTrue(blocks[4].contains("debt 40m > \(Int(DailyTargets.debtDeadbandMin))m → +min("),
                      blocks[4])
        XCTAssertTrue(blocks[4].contains("clamp(\(Int(DailyTargets.sleepFloorMin / 60))h…"
                                         + "\(Int(DailyTargets.sleepCapMin / 60))h)"), blocks[4])
    }

    func testRestDayBlocksSayRestDayAndEvaluateEveryBranch() {
        let kcalTarget = DailyTargets.dayKcalTarget(session: nil, profile: profile, restingHr: 60)
        let stepsTarget = DailyTargets.stepsTarget(charge: 20, readiness: .rundown)
        let blocks = TargetsExplainer.lines(
            charge: 20, readiness: .rundown, restScore: 40,
            session: nil, sessionHrBpm: nil,
            effortTarget: 0,
            kcalTarget: kcalTarget,
            stepsTarget: stepsTarget,
            sleepNeedMin: DailyTargets.sleepNeedTonightMin(age: 34, charge: 20, restScore: 40,
                                                           readiness: .rundown, debtBalanceMin: 0),
            age: 34, restingHr: 60, profile: profile, debtBalanceMin: 0)

        XCTAssertEqual(blocks.count, 5)
        XCTAssertTrue(blocks[0].contains("REST DAY"), blocks[0])
        XCTAssertTrue(blocks[0].contains("rest 40 < \(DailyTargets.poorRestScore) → notch −1"),
                      blocks[0])
        // The zero target's meaning is spelled out — the "x/0" story from the pair-form fix.
        XCTAssertTrue(blocks[1].hasPrefix("EFFORT → 0"), blocks[1])
        XCTAssertTrue(blocks[1].contains("x/0"), blocks[1])
        XCTAssertTrue(blocks[2].contains("rest day → session = 0"), blocks[2])
        XCTAssertTrue(blocks[2].contains("= \(kcalTarget)"), blocks[2])
        // Recover base and the rundown trim, both against real constants.
        XCTAssertTrue(blocks[3].contains("charge 20 ≤ \(DailyTargets.recoverChargeCeiling) → base "
                                         + "\(DailyTargets.stepsBaseRecoverPerDay) (recover)"), blocks[3])
        XCTAssertTrue(blocks[3].contains("readiness rundown → \(DailyTargets.stepsRundownAdj)"),
                      blocks[3])
        // A balanced ledger still shows its rung — evaluated, not omitted.
        XCTAssertTrue(blocks[4].contains("debt 0m ≤ \(Int(DailyTargets.debtDeadbandMin))m → +0m"),
                      blocks[4])
    }
}
