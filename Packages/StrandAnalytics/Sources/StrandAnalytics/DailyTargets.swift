import Foundation

// DailyTargets.swift — the deterministic daily targets behind the three-pillar Live Activity card
// and the coach synthesis: a calm heart-rate ceiling, a prescribed session with its effort and
// calorie targets, and tonight's sleep need.
//
// DESIGN DOCTRINE (the maintainer's, stated across 260829–30 and binding): every target describes
// what is right for the body AT THIS INSTANT — physiology and today's measured state — never what
// the user's recent history happens to look like. Three earlier formulas died to this doctrine,
// each kept below as a HISTORY note: a history-percentile calorie target (reachable by simply
// existing), a history-fitted kcal-per-effort regression (extrapolated into a "crazy" 2,000 kcal
// ask), and a last-week daytime-HR-percentile calm ceiling (still "what it has been the last few
// days"). What replaced them is published exercise physiology over the user's profile and TODAY's
// measurements: Karvonen heart-rate reserve (1957), Tanaka HRmax (2001), Edwards TRIMP zones
// (1993) through the app's own StrainScorer curve, and the Keytel (2005) energy model the app's
// own calorie estimates already use.
public enum DailyTargets {

    // MARK: - Shared physiology

    /// Tanaka 2001: HRmax = 208 − 0.7 × age — the same estimate StrainScorer's references use.
    /// Unknown/zero age falls back to the estimator suite's standard 30.
    public static func hrMax(age: Double?) -> Double {
        let a = (age ?? 0) > 0 ? age! : 30
        return 208.0 - 0.7 * a
    }

    // MARK: - Calm heart-rate ceiling (the "go breathe" line)

    // HISTORY: v1 (260829) was "recent nightly RHR median + 25" — the +25 was an invented constant,
    // rejected. v2 (260830, hours old) was the 85th percentile of the last week's daytime beats —
    // self-calibrating but still "what it has been the last few days", rejected under the doctrine.
    // v3 is instant physiology: the top of the REST zone on today's own heart-rate reserve.

    /// The ceiling sits at this fraction of heart-rate reserve above today's resting HR — the
    /// established Karvonen boundary under which activity reads as rest/very-light. At rest ABOVE
    /// it, the heart is working like light exercise with no exercise present: the meditate cue.
    public static let calmCeilingHrrFraction = 0.30
    /// Sanity clamp — a corrupted RHR or age must not produce a 40 or a 180.
    public static let calmCeilingRange = 70...115

    /// The calm ceiling (bpm): last night's resting HR + 30% of today's heart-rate reserve
    /// (Karvonen, Tanaka HRmax). Both inputs are the body's current state — the overnight RHR is
    /// the freshest resting measurement there is — and neither is a trailing-window habit. Nil only
    /// when no resting HR has ever been measured.
    public static func calmCeilingBpm(restingHr: Int?, age: Double?) -> Int? {
        guard let rhr = restingHr, rhr > 0 else { return nil }
        let ceiling = Double(rhr) + calmCeilingHrrFraction * (hrMax(age: age) - Double(rhr))
        return min(max(Int(ceiling.rounded()), calmCeilingRange.lowerBound),
                   calmCeilingRange.upperBound)
    }

    // MARK: - The charge bands (the #43 recovery bands, shared by the session and sleep asks)

    /// Charge at or above this = green light to build/push. Identical to the coach prompt's band.
    public static let pushChargeFloor = 67
    /// Charge at or below this = active recovery only. Identical to the coach prompt's band.
    public static let recoverChargeCeiling = 33

    // MARK: - The prescribed session (what the effort and calorie targets are PRICED FROM)

    // HISTORY: the effort target was first a percentile of recent effort history (self-referential,
    // rejected), then a position inside the #43 optimal-strain band (14–18 of 21 on a green day) —
    // readiness-driven, but the TRIMP arithmetic exposes those bands as multi-hour training asks
    // (16 of 21 ≈ 4.7 h of zone-2), which priced a "crazy" calorie target. The target is now a
    // concrete SESSION — minutes at an intensity — chosen from the body's state; the effort target
    // is today's effort plus exactly that session through the app's own strain curve, and the
    // calorie target is that session through the app's own Keytel model. For an effort-0 day on a
    // balanced green read this lands the day at ≈ 10–11 of 21 — precisely the "optimal effort is
    // around 10" the maintainer named from feel.

    /// One prescribed bout: duration, intensity (as Karvonen %HRR), and the Edwards zone weight
    /// that intensity carries in the strain curve.
    public struct SessionPrescription: Equatable, Sendable {
        public let minutes: Int
        public let hrrFraction: Double
        public let edwardsZoneWeight: Double
        public init(minutes: Int, hrrFraction: Double, edwardsZoneWeight: Double) {
            self.minutes = minutes
            self.hrrFraction = hrrFraction
            self.edwardsZoneWeight = edwardsZoneWeight
        }
    }

    /// Base session minutes by charge band: a green body is asked for a solid session, a mid one
    /// for maintenance, a red one for gentle movement. Unknown charge reads as maintain.
    public static let pushSessionMinutes = 45
    public static let maintainSessionMinutes = 30
    public static let recoverSessionMinutes = 15
    /// Zone-2 (the notch-1/2 intensity): the 60–70 %HRR Edwards zone, taken at its middle.
    public static let moderateHrrFraction = 0.65
    public static let moderateZoneWeight = 2.0
    /// Zone-3 (the primed notch's intensity): 70–80 %HRR, at its middle.
    public static let brisksHrrFraction = 0.75
    public static let briskZoneWeight = 3.0
    /// A Rest score below this drags the prescription one notch down; at or above the upper bound
    /// it lifts one notch — last night is a body-state input the morning charge can understate.
    public static let poorRestScore = 50
    public static let greatRestScore = 85

    /// Today's prescribed session from the body's state — or nil for a REST day (rundown readiness,
    /// or strained/poor-rest combinations that notch to the floor): rest is the prescription, and
    /// the effort target is then simply "stay where you are".
    ///
    /// The four-notch ladder: 0 = rest day (nil), 1 = half the band's minutes at zone-2,
    /// 2 = the band's minutes at zone-2, 3 = a third more at zone-3. Readiness picks the notch
    /// (rundown 0, strained 1, balanced/insufficient 2, primed 3); Rest shifts it one either way.
    public static func sessionPrescription(charge: Int?,
                                           readiness: ReadinessEngine.Level,
                                           restScore: Int?) -> SessionPrescription? {
        let base: Int
        if let charge {
            base = charge >= pushChargeFloor ? pushSessionMinutes
                 : (charge <= recoverChargeCeiling ? recoverSessionMinutes : maintainSessionMinutes)
        } else { base = maintainSessionMinutes }
        var notch: Int
        switch readiness {
        case .rundown: notch = 0
        case .strained: notch = 1
        case .balanced, .insufficient: notch = 2
        case .primed: notch = 3
        }
        if let rest = restScore {
            if rest < poorRestScore { notch = max(notch - 1, 0) }
            else if rest >= greatRestScore { notch = min(notch + 1, 3) }
        }
        // Rounded to 5 min — a 23-minute prescription claims precision the ladder does not have.
        func rounded5(_ m: Double) -> Int { Int((m / 5).rounded() * 5) }
        switch notch {
        case 0: return nil
        case 1: return SessionPrescription(minutes: rounded5(Double(base) * 0.5),
                                           hrrFraction: moderateHrrFraction,
                                           edwardsZoneWeight: moderateZoneWeight)
        case 2: return SessionPrescription(minutes: base,
                                           hrrFraction: moderateHrrFraction,
                                           edwardsZoneWeight: moderateZoneWeight)
        default: return SessionPrescription(minutes: rounded5(Double(base) * 4.0 / 3.0),
                                            hrrFraction: brisksHrrFraction,
                                            edwardsZoneWeight: briskZoneWeight)
        }
    }

    /// The session's target heart rate (bpm): resting HR + the prescription's %HRR (Karvonen).
    public static func sessionHrBpm(session: SessionPrescription, restingHr: Int?,
                                    age: Double?) -> Int {
        let rhr = Double(restingHr ?? 60)
        return Int((rhr + session.hrrFraction * (hrMax(age: age) - rhr)).rounded())
    }

    /// Today's effort target on the STORED 0–100 axis: today's effort so far, plus exactly the
    /// prescribed session, through the app's own strain curve (Edwards TRIMP → the StrainScorer
    /// log map — analytically inverted, so the card's target and the engine's scoring can never
    /// disagree about what the session is worth).
    public static func effortTargetStored(currentEffortStored: Double?,
                                          session: SessionPrescription?) -> Int {
        let current = min(max(currentEffortStored ?? 0, 0), StrainScorer.maxStrain)
        guard let session else { return Int(current.rounded()) }   // rest day: hold, don't add
        let trimpNow = exp(current / StrainScorer.maxStrain * log(StrainScorer.strainDenominator)) - 1
        let trimpAfter = trimpNow + session.edwardsZoneWeight * Double(session.minutes)
        return Int(StrainScorer.trimpToStrain(trimpAfter).rounded())
    }

    /// The session priced in calories via the SAME Keytel model the app's own calorie estimates
    /// use, at the session's Karvonen HR, fitness-adjusted when a resting HR is known (Uth VO2max)
    /// — profile physiology and today's RHR, no history anywhere. Rounded to 25 kcal, floored at a
    /// token 50 so a five-minute prescription never prints as 0.
    public static let calorieRoundKcal = 25.0
    public static func sessionKcal(session: SessionPrescription, profile: UserProfile,
                                   restingHr: Int?) -> Int {
        let weightKg = profile.weightKg > 0 ? profile.weightKg : 70.0
        let age = profile.age > 0 ? profile.age : 30.0
        let hrmax = hrMax(age: age)
        let hr = Double(sessionHrBpm(session: session, restingHr: restingHr, age: age))
        let coeffs = Calories.resolveCoeffs(profile.sex)
        let vo2 = Calories.vo2maxFor(hrmax: hrmax, restingHR: restingHr.map(Double.init))
        let perSecond = Calories.activeKcalPerS(coeffs, hr: hr, hrmax: hrmax,
                                                weightKg: weightKg, age: age, vo2max: vo2)
        let raw = perSecond * Double(session.minutes) * 60.0
        return max(50, Int((raw / calorieRoundKcal).rounded() * calorieRoundKcal))
    }

    /// Today's EXERCISE calories so far: the whole-day HR estimate minus the resting metabolism the
    /// day has accrued (the day estimator credits resting burn for every worn second — see
    /// `Calories.estimateDayCalories` — which is why the raw figure reads ~1,400 by evening having
    /// done nothing; that inflation is exactly what made the v2 target look "crazy"). Assumes
    /// near-continuous wear (this strap's reality); a large wear gap undercounts the subtraction
    /// and so OVERSTATES exercise slightly — the conservative direction for a gap is stated, not
    /// hidden. Floored at 0.
    public static func exerciseKcalToday(dayKcalEstimate: Double?, profile: UserProfile,
                                         secondsSinceMidnight: Int) -> Int? {
        guard let dayKcalEstimate else { return nil }
        let weightKg = profile.weightKg > 0 ? profile.weightKg : 70.0
        let heightCm = profile.heightCm > 0 ? profile.heightCm : 170.0
        let age = profile.age > 0 ? profile.age : 30.0
        let restingRate = Calories.restingKcalPerS(Calories.resolveCoeffs(profile.sex),
                                                   weightKg: weightKg, heightCm: heightCm, age: age)
        let restingAccrued = restingRate * Double(max(secondsSinceMidnight, 0))
        return Int(max(0, dayKcalEstimate - restingAccrued).rounded())
    }

    // MARK: - Tonight's sleep need

    // HISTORY: v1 was "personalized need + half the debt capped at 90 min" — the cap bound every
    // night, one constant for weeks. v2 based the number on the user's own p75 typical night —
    // rejected under the doctrine ("I don't care what my typical night looks like"). v3 starts
    // from the age-appropriate POPULATION need (physiology, not this user's habits) and lets the
    // body's measured day set tonight's ask: charge, last night's Rest, the readiness read, and
    // the debt as the junior term. Charge/Rest/readiness change daily, so the number finally does.

    /// The final target's bounds (the maintainer's stated contract): never below 7 h, never above 10 h.
    public static let sleepFloorMin = 420.0
    public static let sleepCapMin = 600.0
    /// Charge ask: a mid-recovery body is asked for a little more, a poor one more still. A green
    /// day adds nothing — recovery is not a reason to sleep less than the base.
    public static let sleepChargeAdjMaintainMin = 20.0
    public static let sleepChargeAdjRecoverMin = 40.0
    /// Rest ask: a poor LAST night asks tonight to make some back; an excellent one relaxes tonight.
    public static let sleepRestAdjPoorMin = 30.0
    public static let sleepRestAdjGreatMin = -15.0
    /// Readiness ask: several recovery signals down = the body is asking for sleep regardless of
    /// what charge says; primed relaxes slightly.
    public static let sleepReadinessAdjRundownMin = 30.0
    public static let sleepReadinessAdjStrainedMin = 15.0
    public static let sleepReadinessAdjPrimedMin = -15.0
    /// The debt term, the junior partner: a quarter of the outstanding ledger, capped, silent
    /// inside the ledger's own on-target deadband. A surplus never discounts the night — sleep is
    /// not bankable ahead.
    public static let sleepDebtShare = 0.25
    public static let sleepDebtCapMin = 45.0
    public static let debtDeadbandMin = SleepDebt.onTargetBandMin

    /// Minutes of sleep to target TONIGHT: the age-appropriate population need
    /// (`Rest.populationNeedFloorHours` — 8 h adult, 9 h under-18) adjusted by today's charge band,
    /// last night's Rest, the multi-signal readiness read, and the capped junior debt term —
    /// clamped to the stated 7–10 h bounds.
    public static func sleepNeedTonightMin(age: Int?,
                                           charge: Int?,
                                           restScore: Int?,
                                           readiness: ReadinessEngine.Level,
                                           debtBalanceMin: Double) -> Int {
        var need = AnalyticsEngine.Rest.populationNeedFloorHours(age: age) * 60.0
        if let charge {
            if charge <= recoverChargeCeiling { need += sleepChargeAdjRecoverMin }
            else if charge < pushChargeFloor { need += sleepChargeAdjMaintainMin }
        }
        if let rest = restScore {
            if rest < poorRestScore { need += sleepRestAdjPoorMin }
            else if rest >= greatRestScore { need += sleepRestAdjGreatMin }
        }
        switch readiness {
        case .rundown: need += sleepReadinessAdjRundownMin
        case .strained: need += sleepReadinessAdjStrainedMin
        case .primed: need += sleepReadinessAdjPrimedMin
        case .balanced, .insufficient: break
        }
        let debt = max(0, -debtBalanceMin)
        if debt > debtDeadbandMin { need += min(sleepDebtCapMin, debt * sleepDebtShare) }
        return Int(min(max(need, sleepFloorMin), sleepCapMin).rounded())
    }
}
