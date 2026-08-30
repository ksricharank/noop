import XCTest
@testable import StrandAnalytics

/// The body-state daily targets behind the three-pillar Live Activity card. Pinned because the card
/// prints these numbers with no surrounding prose, the synthesis cites the same figures, and the
/// doctrine they encode — instant physiology, never habit — died three formula revisions to get
/// here (see the HISTORY notes in `DailyTargets`).
final class DailyTargetsTests: XCTestCase {

    // MARK: - Calm ceiling (Karvonen)

    /// Last night's RHR + 30% of the Tanaka heart-rate reserve: rhr 60 at age 30 → HRmax 187 →
    /// 60 + 0.3 × 127 = 98. No invented margin — both numbers are published physiology over
    /// today's measurement.
    func testCeilingIsThirtyPercentOfReserveAboveRest() {
        XCTAssertEqual(DailyTargets.calmCeilingBpm(restingHr: 60, age: 30), 98)
        XCTAssertEqual(DailyTargets.calmCeilingBpm(restingHr: 60, age: nil), 98)   // unknown age → 30
        XCTAssertEqual(DailyTargets.calmCeilingBpm(restingHr: 50, age: 50), 87)    // HRmax 173
    }

    /// No resting HR has ever been measured → no ceiling (never guessed); corrupted inputs clamp.
    func testCeilingRefusesAndClamps() {
        XCTAssertNil(DailyTargets.calmCeilingBpm(restingHr: nil, age: 30))
        XCTAssertNil(DailyTargets.calmCeilingBpm(restingHr: 0, age: 30))
        XCTAssertEqual(DailyTargets.calmCeilingBpm(restingHr: 110, age: 20), 115)  // cap
        XCTAssertEqual(DailyTargets.calmCeilingBpm(restingHr: 5, age: 90), 70)     // floor
    }

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

    /// Exercise calories = the whole-day estimate minus the resting metabolism the day has accrued —
    /// pinned against the SAME resting rate the estimator uses, so the subtraction can never drift
    /// from what `estimateDayCalories` credited in the first place. A sedentary half-day nets ~0.
    func testExerciseKcalSubtractsRestingAccrual() {
        let profile = UserProfile()
        let rate = Calories.restingKcalPerS(Calories.resolveCoeffs(profile.sex),
                                            weightKg: profile.weightKg,
                                            heightCm: profile.heightCm, age: profile.age)
        let halfDay = 43_200
        let sedentary = rate * Double(halfDay)   // what merely existing accrued by noon
        XCTAssertEqual(DailyTargets.exerciseKcalToday(dayKcalEstimate: sedentary, profile: profile,
                                                      secondsSinceMidnight: halfDay), 0)
        XCTAssertEqual(DailyTargets.exerciseKcalToday(dayKcalEstimate: sedentary + 312,
                                                      profile: profile,
                                                      secondsSinceMidnight: halfDay), 312)
        XCTAssertNil(DailyTargets.exerciseKcalToday(dayKcalEstimate: nil, profile: profile,
                                                    secondsSinceMidnight: halfDay))
        XCTAssertEqual(DailyTargets.exerciseKcalToday(dayKcalEstimate: 100, profile: profile,
                                                      secondsSinceMidnight: 86_400), 0,
                       "the subtraction floors at zero, never a negative burn")
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
