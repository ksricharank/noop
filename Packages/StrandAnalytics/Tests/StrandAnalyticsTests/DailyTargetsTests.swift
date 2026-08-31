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

    /// The step target is bands + notches, never history: charge band sets 6/8/10k (unknown = 8k),
    /// rundown −2k / strained −1k, clamped 4k–12k. Pinned across the ladder.
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

    // MARK: - Tonight's sleep need (population base + the body's day)

    /// The composition: the 8 h adult population base, plus the charge band's ask, last night's
    /// Rest, the readiness read, and the capped junior debt term.
    func testSleepNeedComposesTheBodysDay() {
        XCTAssertEqual(DailyTargets.sleepNeedTonightMin(age: 35, charge: 81, restScore: 81,
                                                        readiness: .balanced, debtBalanceMin: -400),
                       480 + 45)
        XCTAssertEqual(DailyTargets.sleepNeedTonightMin(age: 35, charge: 50, restScore: 60,
                                                        readiness: .strained, debtBalanceMin: -20),
                       480 + 20 + 15)
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
