import XCTest
@testable import Strand
import StrandAnalytics

/// Pins the "How these were set" derivations (260901, final format): FOUR blocks, every line a
/// number in plain language — the readiness verdict unpacked into the "body check" signals, the
/// session ladder living inside the Effort block. Built from the SAME `DailyTargets` calls the
/// pricing used, so the stated arithmetic must reproduce the displayed target.
final class TargetsExplainerTests: XCTestCase {

    private var profile: UserProfile {
        UserProfile(weightKg: 70, heightCm: 175, age: 34, sex: "male", stepTicksPerStep: 0)
    }

    /// A readiness read with concrete HRV/RHR evidence, so the body-check line carries numbers.
    private func readiness(level: ReadinessEngine.Level,
                           hrv: (Double, Double, ReadinessEngine.Flag)? = (62, 60, .neutral),
                           rhr: (Double, Double, ReadinessEngine.Flag)? = (55, 56, .neutral))
        -> ReadinessEngine.Readiness {
        var signals: [ReadinessEngine.Signal] = []
        if let (v, b, f) = hrv {
            signals.append(.init(key: "hrv", label: "HRV",
                                 evidenceData: .metric(value: v, baseline: b, unit: "ms", decimals: 0),
                                 detail: "", flag: f))
        }
        if let (v, b, f) = rhr {
            signals.append(.init(key: "rhr", label: "Resting HR",
                                 evidenceData: .metric(value: v, baseline: b, unit: "bpm", decimals: 0),
                                 detail: "", flag: f))
        }
        return .init(level: level, headline: "", summary: "", signals: signals,
                     acwr: nil, monotony: nil)
    }

    func testWorkoutDayBlocksReadPlainlyAndCarryTheExactNumbers() {
        let charge = 80, rest = 81
        let read = readiness(level: .balanced)
        let session = DailyTargets.sessionPrescription(charge: charge, readiness: .balanced,
                                                       restScore: rest)
        XCTAssertNotNil(session)
        let effortTarget = DailyTargets.effortTargetStored(currentEffortStored: nil, session: session)
        let kcalTarget = DailyTargets.dayKcalTarget(session: session, profile: profile, restingHr: 55)
        let stepsTarget = DailyTargets.stepsTarget(charge: charge, readiness: .balanced)
        let sleepNeed = DailyTargets.sleepNeedTonightMin(age: 34, charge: charge, restScore: rest,
                                                         readiness: .balanced, debtBalanceMin: -40)
        let hr = DailyTargets.sessionHrBpm(session: session!, restingHr: 55, age: 34)

        let blocks = TargetsExplainer.lines(
            charge: charge, readiness: read, restScore: rest,
            session: session, sessionHrBpm: hr,
            effortTarget: effortTarget, kcalTarget: kcalTarget, stepsTarget: stepsTarget,
            sleepNeedMin: sleepNeed, age: 34, restingHr: 55, profile: profile,
            debtBalanceMin: -40)

        XCTAssertEqual(blocks.count, 4, "four blocks — the session ladder lives inside Effort")
        // EFFORT: charge rung with the workout it picked, body-check numbers, Rest rung, the pace
        // spelled from resting HR toward max, the 0–100 scale defined before it's used.
        XCTAssertTrue(blocks[0].hasPrefix("EFFORT TARGET → \(effortTarget)"), blocks[0])
        XCTAssertTrue(blocks[0].contains("Charge 80 is high (≥\(DailyTargets.pushChargeFloor))"
                                         + " → plan a \(DailyTargets.pushSessionMinutes) min workout"),
                      blocks[0])
        XCTAssertTrue(blocks[0].contains("body check: HRV 62ms ≈ your usual 60ms,"
                                         + " resting HR 55bpm ≈ your usual 56bpm → all normal"
                                         + " → keep \(session!.minutes) min"), blocks[0])
        XCTAssertTrue(blocks[0].contains("last night's Rest 81 is mid-range"
                                         + " (\(DailyTargets.poorRestScore)–\(DailyTargets.greatRestScore - 1))"
                                         + " → keep \(session!.minutes) min"), blocks[0])
        XCTAssertTrue(blocks[0].contains("workout pace: ~\(hr) bpm — about "
                                         + "\(Int(session!.hrrFraction * 100))% of the way up from"
                                         + " your resting HR 55"), blocks[0])
        XCTAssertTrue(blocks[0].contains("effort is the app's 0–100 score for a day's exercise:"
                                         + " \(session!.minutes) min at that pace scores \(effortTarget)"),
                      blocks[0])
        XCTAssertTrue(blocks[0].contains("today's effort so far isn't added in"), blocks[0])
        // CAL: resting part stated as target − session, so the printed sum is exact.
        let sessionKcal = DailyTargets.sessionKcal(session: session!, profile: profile, restingHr: 55)
        XCTAssertTrue(blocks[1].hasPrefix("CALORIE TARGET → \(kcalTarget)"), blocks[1])
        XCTAssertTrue(blocks[1].contains("your body at rest burns ≈ \(kcalTarget - sessionKcal) kcal"
                                         + " per 24h (from weight 70kg, height 175cm, age 34)"), blocks[1])
        XCTAssertTrue(blocks[1].contains("the \(session!.minutes) min workout at ~\(hr) bpm burns"
                                         + " ≈ \(sessionKcal) kcal more"), blocks[1])
        XCTAssertTrue(blocks[1].contains("\(kcalTarget - sessionKcal) + \(sessionKcal) = \(kcalTarget)"),
                      blocks[1])
        // STEPS: base rung, compact body check, plain bounds line ending in the target.
        XCTAssertTrue(blocks[2].hasPrefix("STEP TARGET → \(stepsTarget)"), blocks[2])
        XCTAssertTrue(blocks[2].contains("→ base \(DailyTargets.stepsBasePushPerDay) steps"), blocks[2])
        XCTAssertTrue(blocks[2].contains("body check: HRV 62 ≈ your usual 60,"
                                         + " resting HR 55 ≈ your usual 56 → all normal → no reduction"),
                      blocks[2])
        XCTAssertTrue(blocks[2].contains("never set below \(DailyTargets.stepsFloorPerDay) or above"
                                         + " \(DailyTargets.stepsCapPerDay) → \(stepsTarget)"), blocks[2])
        // SLEEP: standard need, +0 rungs still printed, the debt payback in plain words.
        XCTAssertTrue(blocks[3].hasPrefix("SLEEP TARGET → "), blocks[3])
        XCTAssertTrue(blocks[3].contains("standard need for a 34-year-old:"), blocks[3])
        XCTAssertTrue(blocks[3].contains("Charge 80 is high (≥\(DailyTargets.pushChargeFloor)) → +0 min"),
                      blocks[3])
        XCTAssertTrue(blocks[3].contains("you're 40 min short on sleep lately → pay back a quarter"
                                         + " tonight: +10 min (never more than"
                                         + " +\(Int(DailyTargets.sleepDebtCapMin)))"), blocks[3])
        XCTAssertTrue(blocks[3].contains("never set below \(Int(DailyTargets.sleepFloorMin / 60))h"), blocks[3])
        // The jargon is gone.
        for word in ["notch", "zone", "TRIMP", "trimp", "Karvonen", "keytel", "Keytel", "rmr",
                     "clamp", "readiness", "balanced", "rundown"] {
            for block in blocks {
                XCTAssertFalse(block.contains(word), "jargon '\(word)' in: \(block)")
            }
        }
    }

    /// The water block (260903): a body baseline, an effort bump, the rounding, then cups — the
    /// same arithmetic `HydrationGoal` uses, ending in the cup figure the Today row shows.
    func testWaterBlockShowsBaselineEffortBumpAndCups() {
        let read = readiness(level: .balanced)
        let goalML = HydrationGoal.dailyGoalML(sex: "male", effort: 40)
        let blocks = TargetsExplainer.lines(
            charge: 80, readiness: read, restScore: 81,
            session: nil, sessionHrBpm: nil,
            effortTarget: nil, kcalTarget: nil, stepsTarget: nil, sleepNeedMin: nil,
            age: 34, restingHr: 55, profile: profile, debtBalanceMin: 0,
            waterTargetML: goalML, effortForWater: 40)

        XCTAssertEqual(blocks.count, 1, "only the water block when every other target is nil")
        let cups = HydrationGoal.cups(fromML: Double(goalML))
        XCTAssertTrue(blocks[0].hasPrefix("WATER TARGET → \(cups) cups"), blocks[0])
        XCTAssertTrue(blocks[0].contains("baseline for your body: \(HydrationGoal.baselineMaleML) ml"),
                      blocks[0])
        XCTAssertTrue(blocks[0].contains("today's effort 40 adds \(HydrationGoal.effortBump(effort: 40)) ml"),
                      blocks[0])
        XCTAssertTrue(blocks[0].contains("= \(goalML) ml"), blocks[0])
        XCTAssertTrue(blocks[0].contains("\(HydrationGoal.cupML) ml each → \(cups) cups"), blocks[0])
    }

    /// With no effort logged the bump rung still prints, showing what a hard day WOULD add.
    func testWaterBlockPrintsTheZeroBumpRung() {
        let blocks = TargetsExplainer.lines(
            charge: nil, readiness: readiness(level: .balanced), restScore: nil,
            session: nil, sessionHrBpm: nil,
            effortTarget: nil, kcalTarget: nil, stepsTarget: nil, sleepNeedMin: nil,
            age: 34, restingHr: nil, profile: profile, debtBalanceMin: 0,
            waterTargetML: HydrationGoal.dailyGoalML(sex: "male", effort: nil),
            effortForWater: nil)
        XCTAssertTrue(blocks[0].contains("no effort logged yet → +0 ml"), blocks[0])
        XCTAssertTrue(blocks[0].contains("adds up to \(HydrationGoal.maxEffortBumpML) ml"), blocks[0])
    }

    func testRestDayBlocksExplainTheCancelledWorkoutAndTheZeroTarget() {
        let read = readiness(level: .rundown, hrv: (41, 60, .bad), rhr: (63, 56, .watch))
        let kcalTarget = DailyTargets.dayKcalTarget(session: nil, profile: profile, restingHr: 60)
        let blocks = TargetsExplainer.lines(
            charge: 20, readiness: read, restScore: 40,
            session: nil, sessionHrBpm: nil,
            effortTarget: 0,
            kcalTarget: kcalTarget,
            stepsTarget: DailyTargets.stepsTarget(charge: 20, readiness: .rundown),
            sleepNeedMin: DailyTargets.sleepNeedTonightMin(age: 34, charge: 20, restScore: 40,
                                                           readiness: .rundown, debtBalanceMin: 0),
            age: 34, restingHr: 60, profile: profile, debtBalanceMin: 0)

        XCTAssertEqual(blocks.count, 4)
        // EFFORT: the body check names the down signals with their numbers and cancels the workout.
        XCTAssertTrue(blocks[0].hasPrefix("EFFORT TARGET → 0"), blocks[0])
        XCTAssertTrue(blocks[0].contains("Charge 20 is low (≤\(DailyTargets.recoverChargeCeiling))"),
                      blocks[0])
        XCTAssertTrue(blocks[0].contains("body check: HRV 41ms below your usual 60ms,"
                                         + " resting HR 63bpm above your usual 56bpm"
                                         + " → several signals down → no workout today"), blocks[0])
        XCTAssertTrue(blocks[0].contains("target = 0 — anything you do still counts and shows as x/0"),
                      blocks[0])
        // CAL: the resting day alone, the no-workout line explicit, sum still exact.
        XCTAssertTrue(blocks[1].contains("no workout today → nothing added"), blocks[1])
        XCTAssertTrue(blocks[1].contains("target = \(kcalTarget)"), blocks[1])
        // STEPS: recover base and the several-signals reduction.
        XCTAssertTrue(blocks[2].contains("base \(DailyTargets.stepsBaseRecoverPerDay) steps"), blocks[2])
        XCTAssertTrue(blocks[2].contains("→ \(DailyTargets.stepsRundownAdj)"), blocks[2])
        // SLEEP: a balanced ledger still prints its rung.
        XCTAssertTrue(blocks[3].contains("your sleep ledger is even (within"
                                         + " \(Int(DailyTargets.debtDeadbandMin)) min) → +0 min"), blocks[3])
    }

    /// The Rest shift can bring a workout BACK after the body check cancelled it — the rungs must
    /// narrate that honestly ("back on for N min"), not claim a rest day.
    func testGreatRestReinstatesTheWorkoutAfterARundownBodyCheck() {
        let read = readiness(level: .rundown, hrv: (41, 60, .bad), rhr: (63, 56, .watch))
        let session = DailyTargets.sessionPrescription(charge: 80, readiness: .rundown, restScore: 90)
        XCTAssertNotNil(session, "rundown notched back up by Rest 90 prescribes a short session")
        let effortTarget = DailyTargets.effortTargetStored(currentEffortStored: nil, session: session)
        let blocks = TargetsExplainer.lines(
            charge: 80, readiness: read, restScore: 90,
            session: session, sessionHrBpm: 130,
            effortTarget: effortTarget, kcalTarget: nil, stepsTarget: nil,
            sleepNeedMin: nil, age: 34, restingHr: 60, profile: profile, debtBalanceMin: 0)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertTrue(blocks[0].contains("→ no workout today"), blocks[0])
        XCTAssertTrue(blocks[0].contains("last night's Rest 90 is great (\(DailyTargets.greatRestScore)"
                                         + " or above) → back on for \(session!.minutes) min"), blocks[0])
    }
}
