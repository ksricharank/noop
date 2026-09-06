import XCTest
@testable import StrandAnalytics

/// The body-state daily targets behind the three-pillar Live Activity card. Pinned because the card
/// prints these numbers with no surrounding prose, the synthesis cites the same figures, and the
/// doctrine they encode — instant physiology, never habit — died three formula revisions to get
/// here (see the HISTORY notes in `DailyTargets`).
final class DailyTargetsTests: XCTestCase {

    // MARK: - The prescribed session

    /// Charge picks the base minutes, readiness the notch: a balanced green day is the full 45 min
    /// at zone-2; primed lifts to 60 min at zone-3; strained halves; rundown prescribes REST (nil).
    func testSessionLadder() {
        XCTAssertEqual(DailyTargets.sessionPrescription(charge: 81, readiness: .balanced, restScore: nil),
                       .init(minutes: 45, hrrFraction: 0.65, edwardsZoneWeight: 2))
        XCTAssertEqual(DailyTargets.sessionPrescription(charge: 81, readiness: .primed, restScore: nil),
                       .init(minutes: 60, hrrFraction: 0.75, edwardsZoneWeight: 3))
        XCTAssertEqual(DailyTargets.sessionPrescription(charge: 50, readiness: .strained, restScore: nil),
                       .init(minutes: 15, hrrFraction: 0.65, edwardsZoneWeight: 2))
        XCTAssertNil(DailyTargets.sessionPrescription(charge: 81, readiness: .rundown, restScore: nil))
        // Unknown charge reads as maintain; insufficient readiness as balanced — neutral, never bold.
        XCTAssertEqual(DailyTargets.sessionPrescription(charge: nil, readiness: .insufficient, restScore: nil),
                       .init(minutes: 30, hrrFraction: 0.65, edwardsZoneWeight: 2))
    }

    /// Last night's Rest shifts the ladder one notch either way — a poor night can turn a strained
    /// read into a rest day, and the shifts clamp at the ladder's ends.
    func testRestShiftsTheSessionNotch() {
        XCTAssertEqual(DailyTargets.sessionPrescription(charge: 50, readiness: .balanced, restScore: 40),
                       .init(minutes: 15, hrrFraction: 0.65, edwardsZoneWeight: 2))
        XCTAssertNil(DailyTargets.sessionPrescription(charge: 50, readiness: .strained, restScore: 40))
        XCTAssertEqual(DailyTargets.sessionPrescription(charge: 50, readiness: .balanced, restScore: 90),
                       .init(minutes: 40, hrrFraction: 0.75, edwardsZoneWeight: 3))
        XCTAssertEqual(DailyTargets.sessionPrescription(charge: 81, readiness: .primed, restScore: 90),
                       .init(minutes: 60, hrrFraction: 0.75, edwardsZoneWeight: 3))
    }

    /// The session HR is plain Karvonen at the prescription's %HRR: rhr 60, age 30, zone-2 mid →
    /// 60 + 0.65 × 127 ≈ 143.
    func testSessionHrIsKarvonen() {
        let z2 = DailyTargets.SessionPrescription(minutes: 30, hrrFraction: 0.65, edwardsZoneWeight: 2)
        XCTAssertEqual(DailyTargets.sessionHrBpm(session: z2, restingHr: 60, age: 30), 143)
    }

    // MARK: - Effort target (the session through the app's own strain curve)

    /// A 45-minute zone-2 session from effort 0 is 90 Edwards TRIMP → 100·ln(91)/ln(7201) ≈ 51
    /// stored ≈ 10.7 of 21 — the arithmetic that lands exactly on the maintainer's "optimal effort
    /// is around 10", where the abandoned #43 band (14–18) implied multi-hour asks.
    func testEffortTargetIsTodayPlusTheSession() {
        let z2 = DailyTargets.SessionPrescription(minutes: 45, hrrFraction: 0.65, edwardsZoneWeight: 2)
        XCTAssertEqual(DailyTargets.effortTargetStored(currentEffortStored: 0, session: z2), 51)
        XCTAssertEqual(DailyTargets.effortTargetStored(currentEffortStored: nil, session: z2), 51)
        // The log curve compounds honestly: the same session on top of an already-scored day adds
        // less than its from-zero worth, and never less than the day already holds.
        let onTop = DailyTargets.effortTargetStored(currentEffortStored: 51, session: z2)
        XCTAssertGreaterThan(onTop, 51)
        XCTAssertLessThan(onTop, 102)
    }

    /// A rest day holds: the target IS today's effort, never an ask to add more.
    func testRestDayHoldsTheCurrentEffort() {
        XCTAssertEqual(DailyTargets.effortTargetStored(currentEffortStored: 37.4, session: nil), 37)
        XCTAssertEqual(DailyTargets.effortTargetStored(currentEffortStored: nil, session: nil), 0)
    }

    // MARK: - Calories (the session through the app's own Keytel model)

    /// The session kcal is sane for a standard profile (a 45-min zone-2 bout lands in the hundreds,
    /// not the thousands the abandoned regression produced), rounds to 25, and scales with duration.
    func testSessionKcalIsSaneRoundedAndMonotonic() {
        let z2 = DailyTargets.SessionPrescription(minutes: 45, hrrFraction: 0.65, edwardsZoneWeight: 2)
        let kcal = DailyTargets.sessionKcal(session: z2, profile: UserProfile(), restingHr: 60)
        XCTAssertGreaterThan(kcal, 100, "a 45-min moderate bout burns real calories")
        XCTAssertLessThan(kcal, 900, "…but never a four-digit ask")
        XCTAssertEqual(kcal % 25, 0)
        let z2short = DailyTargets.SessionPrescription(minutes: 15, hrrFraction: 0.65, edwardsZoneWeight: 2)
        XCTAssertLessThan(DailyTargets.sessionKcal(session: z2short, profile: UserProfile(), restingHr: 60),
                          kcal)
    }

    /// The TOTAL-day calorie target (260830: the Cal glance moved from exercise-only to total) =
    /// a full day of the SAME resting rate the day estimator credits, plus the priced session —
    /// pinned against that shared rate so the target can never drift from what the numerator's
    /// estimator accrues. A rest day's target is the resting day alone.
    func testDayKcalTargetIsRestingDayPlusSession() {
        let profile = UserProfile()
        let rate = Calories.restingKcalPerS(Calories.resolveCoeffs(profile.sex),
                                            weightKg: profile.weightKg,
                                            heightCm: profile.heightCm, age: profile.age)
        let restingDay = rate * 86_400.0
        let restTarget = DailyTargets.dayKcalTarget(session: nil, profile: profile, restingHr: 60)
        XCTAssertEqual(restTarget % 25, 0)
        XCTAssertEqual(Double(restTarget), restingDay, accuracy: 12.5,
                       "a REST day's total target is the resting day, to rounding")
        let z2 = DailyTargets.SessionPrescription(minutes: 45, hrrFraction: 0.65, edwardsZoneWeight: 2)
        let sessionTarget = DailyTargets.dayKcalTarget(session: z2, profile: profile, restingHr: 60)
        XCTAssertEqual(sessionTarget % 25, 0)
        let sessionKcal = DailyTargets.sessionKcal(session: z2, profile: profile, restingHr: 60)
        XCTAssertEqual(Double(sessionTarget), restingDay + Double(sessionKcal), accuracy: 25,
                       "a session day adds exactly the priced session")
        // Sanity: a real human's total-day target is four digits, not the session's hundreds.
        XCTAssertGreaterThan(restTarget, 1_000)
        XCTAssertLessThan(sessionTarget, 4_000)
    }

    /// The step target is charge + notches, never history. 260906: the charge term is now CONTINUOUS
    /// (was three bands), but the three published anchors are unchanged — recover ceiling → 6k, the
    /// midpoint → 8k, push floor → 10k — so this ladder still pins the same numbers it always did.
    /// Rundown −2k / strained −1k, clamped 4k–12k.
    func testStepsTargetLadder() {
        XCTAssertEqual(DailyTargets.stepsTarget(charge: 80, readiness: .balanced), 10_000)
        XCTAssertEqual(DailyTargets.stepsTarget(charge: 50, readiness: .balanced), 8_000)
        XCTAssertEqual(DailyTargets.stepsTarget(charge: 20, readiness: .balanced), 6_000)
        XCTAssertEqual(DailyTargets.stepsTarget(charge: nil, readiness: .insufficient), 8_000)
        XCTAssertEqual(DailyTargets.stepsTarget(charge: 80, readiness: .strained), 9_000)
        XCTAssertEqual(DailyTargets.stepsTarget(charge: 20, readiness: .rundown), 4_000,
                       "recover base minus the rundown notch pins to the floor")
        XCTAssertEqual(DailyTargets.stepsTarget(charge: 80, readiness: .primed), 10_000,
                       "primed adds nothing — the session is where primed headroom goes")
    }

    /// The anchors the continuous curve must reproduce EXACTLY, stated separately from the ladder
    /// above so the intent is explicit: this change refines the curve BETWEEN the published points,
    /// it does not move the points. A day that previously sat on a band edge keeps its number.
    func testTheContinuousCurveKeepsThePublishedAnchors() {
        XCTAssertEqual(DailyTargets.stepsTarget(charge: DailyTargets.recoverChargeCeiling,
                                                readiness: .balanced), 6_000)
        XCTAssertEqual(DailyTargets.stepsTarget(charge: DailyTargets.pushChargeFloor,
                                                readiness: .balanced), 10_000)
        let mid = (DailyTargets.recoverChargeCeiling + DailyTargets.pushChargeFloor) / 2
        XCTAssertEqual(DailyTargets.stepsTarget(charge: mid, readiness: .balanced), 8_000)
    }

    /// The point of the change: the target must actually vary inside the old bands. Charge 34 and 66
    /// both asked for exactly 8,000 before, and 66→67 jumped 2,000 steps in a single point.
    func testTheTargetVariesInsideTheOldBands() {
        let a = DailyTargets.stepsTarget(charge: 40, readiness: .balanced)
        let b = DailyTargets.stepsTarget(charge: 60, readiness: .balanced)
        XCTAssertNotEqual(a, b, "two mid-charge days must no longer share one target")
        XCTAssertGreaterThan(b, a, "more charge asks for more walking")
        // No single point of charge may move the ask by a band-sized jump any more.
        for c in 1...100 {
            let step = abs(DailyTargets.stepsTarget(charge: c, readiness: .balanced)
                           - DailyTargets.stepsTarget(charge: c - 1, readiness: .balanced))
            XCTAssertLessThanOrEqual(step, 200,
                                     "charge \(c-1)→\(c) moved the target by \(step); the cliff is back")
        }
    }

    /// Monotonic across the whole charge range: more charge never asks for LESS walking. A curve that
    /// dipped anywhere would be incoherent as an ask regardless of how smooth it looked.
    func testTheCurveIsMonotonicInCharge() {
        var previous = 0
        for c in 0...100 {
            let t = DailyTargets.stepsTarget(charge: c, readiness: .balanced)
            XCTAssertGreaterThanOrEqual(t, previous, "target dipped at charge \(c)")
            previous = t
        }
    }

    /// Outside the anchors the value is HELD, not extrapolated — charge 5 and charge 33 are both
    /// "recover", and the readiness notch is what handles a genuinely rundown body. Extrapolating
    /// would drive the ask below the recover figure purely because a score approached zero.
    func testTheCurveIsHeldOutsideTheAnchors() {
        XCTAssertEqual(DailyTargets.stepsTarget(charge: 0, readiness: .balanced), 6_000)
        XCTAssertEqual(DailyTargets.stepsTarget(charge: 5, readiness: .balanced), 6_000)
        XCTAssertEqual(DailyTargets.stepsTarget(charge: 100, readiness: .balanced), 10_000)
    }

    // MARK: - Tonight's sleep need (population base + the body's day)

    /// The composition: the 8 h adult population base, plus the charge band's ask, last night's
    /// Rest, the readiness read, and the capped junior debt term.
    func testSleepNeedComposesTheBodysDay() {
        XCTAssertEqual(DailyTargets.sleepNeedTonightMin(age: 35, charge: 81, restScore: 81,
                                                        readiness: .balanced, debtBalanceMin: -400),
                       480 + 45)
        // 480 base + 20 (maintain band) + 15 (strained) + 5 (the debt term: a 20-minute deficit is
        // OUTSIDE the 10-minute deadband, so a quarter of it is asked back tonight). The debt term
        // was originally omitted from this expectation, which made the case assert 515 against a
        // correct 520 — the code was right and the arithmetic here was short by one term.
        XCTAssertEqual(DailyTargets.sleepNeedTonightMin(age: 35, charge: 50, restScore: 60,
                                                        readiness: .strained, debtBalanceMin: -20),
                       480 + 20 + 15 + 5)
        XCTAssertEqual(DailyTargets.sleepNeedTonightMin(age: 35, charge: 81, restScore: 90,
                                                        readiness: .primed, debtBalanceMin: 0),
                       480 - 15 - 15)
        XCTAssertEqual(DailyTargets.sleepNeedTonightMin(age: nil, charge: nil, restScore: nil,
                                                        readiness: .insufficient, debtBalanceMin: 0),
                       480)
    }

    /// The stated 7–10 h bounds hold when everything stacks one way.
    func testSleepNeedClampsToTheStatedBounds() {
        XCTAssertEqual(DailyTargets.sleepNeedTonightMin(age: 35, charge: 20, restScore: 40,
                                                        readiness: .rundown, debtBalanceMin: -400),
                       600)
        XCTAssertGreaterThanOrEqual(DailyTargets.sleepNeedTonightMin(
            age: 35, charge: 81, restScore: 90, readiness: .primed, debtBalanceMin: 300), 420)
    }
}
