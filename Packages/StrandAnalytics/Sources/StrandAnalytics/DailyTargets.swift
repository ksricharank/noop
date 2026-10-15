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

    // HISTORY — the calm heart-rate ceiling (260829–30, retired the same night): three attempts at
    // a "go breathe" THRESHOLD lived here — nightly-RHR median + 25 (invented constant), the 85th
    // percentile of a week's daytime beats (still trailing history), and Karvonen 30%-of-reserve
    // (honest physiology, but a near-constant the maintainer rightly called too crude: "always 96?
    // come on"). All three answered the wrong question. The breathe verdict is not a number to
    // cross — it is the live autonomic STATE (fast RMSSD vs the rolling baseline, exercise-gated).
    // A level-form read of it drove the card's red HR digits (and briefly a # marker) for one build;
    // since 260830 it reaches the user as `StressOnsetDetector.evaluate`'s event — the stress
    // check-in's strap buzz + screen notification — and the card carries no HR at all.

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
    /// The session's bounds (261004): the floor is the notch-1 half of the recover ask, the cap the
    /// notch-3 lift of the push ask — both figures the ladder could already produce, now stated as
    /// the ends of the continuous curve rather than reachable only at exact band values.
    public static let sessionMinutesFloor = 8
    public static let sessionMinutesCap = 60

    /// The continuous charge→session-minutes base (261004, maintainer: "more granular and
    /// continuous targets"). Same shape and the same three anchors as `stepsBaseForCharge`
    /// (recover ceiling → 15, midpoint → 30, push floor → 45), with the held ends now extended
    /// linearly to the curve's own bounds: charge 0 → the floor's pre-round 7.5 (half the recover
    /// ask, the notch-1 figure) and charge 100 → 60 (4/3 of the push ask, the notch-3 figure). A
    /// charge of 75 and a charge of 95 used to ask the identical 45 minutes; the ask now moves
    /// with every point of charge, which is the whole point. Anchors are preserved EXACTLY, so any
    /// charge that previously sat on a band edge still gets that band's number.
    public static func sessionBaseMinutesForCharge(_ charge: Int?) -> Double {
        guard let c = charge.map(Double.init) else { return Double(maintainSessionMinutes) }
        let lo = Double(recoverChargeCeiling), hi = Double(pushChargeFloor)
        let mid = (lo + hi) / 2.0
        func lerp(_ x: Double, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Double {
            y0 + (min(max(x, x0), x1) - x0) / (x1 - x0) * (y1 - y0)
        }
        switch c {
        case ..<lo:  return lerp(c, 0, Double(recoverSessionMinutes) * 0.5, lo, Double(recoverSessionMinutes))
        case ..<mid: return lerp(c, lo, Double(recoverSessionMinutes), mid, Double(maintainSessionMinutes))
        case ..<hi:  return lerp(c, mid, Double(maintainSessionMinutes), hi, Double(pushSessionMinutes))
        default:     return lerp(c, hi, Double(pushSessionMinutes), 100, Double(pushSessionMinutes) * 4.0 / 3.0)
        }
    }

    public static func sessionPrescription(charge: Int?,
                                           readiness: ReadinessEngine.Level,
                                           restScore: Int?) -> SessionPrescription? {
        let base = sessionBaseMinutesForCharge(charge)
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
        // Rounded to the MINUTE (261004; was 5): with the base continuous in charge, a 5-minute
        // grain re-quantized the very movement the curve exists to show. Clamped to the stated
        // floor/cap so the notch multipliers cannot ask less than the gentlest half-session or
        // more than the ladder's previous maximum.
        func minutes(_ m: Double) -> Int {
            min(max(Int(m.rounded()), sessionMinutesFloor), sessionMinutesCap)
        }
        switch notch {
        case 0: return nil
        case 1: return SessionPrescription(minutes: minutes(base * 0.5),
                                           hrrFraction: moderateHrrFraction,
                                           edwardsZoneWeight: moderateZoneWeight)
        case 2: return SessionPrescription(minutes: minutes(base),
                                           hrrFraction: moderateHrrFraction,
                                           edwardsZoneWeight: moderateZoneWeight)
        default: return SessionPrescription(minutes: minutes(base * 4.0 / 3.0),
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
    /// 261004: 25 → 10 kcal on the "more granular and continuous" ask — fine enough that the
    /// continuous session minutes show through, coarse enough not to imply single-kcal precision.
    public static let calorieRoundKcal = 10.0
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

    // HISTORY: `exerciseKcalToday` (the day estimate minus the resting accrual so far) lived here
    // for one build (10.6.0.14.8–.14.9) — the Cal glance then showed EXERCISE-only calories. Retired
    // 260830 by maintainer instruction: the glance now shows TOTAL calories against a total-day
    // target (`dayKcalTarget` below), which matches how every mainstream tracker frames the number
    // and removes the mid-day subtraction entirely — the raw day estimate IS the numerator.

    /// Today's TOTAL-calorie target: a full day of resting metabolism plus the prescribed session
    /// priced through the app's own Keytel model. On a REST day (nil session) the target is honestly
    /// the resting day alone — reaching it means "you existed", which is exactly what rest asks.
    /// Rounded to `calorieRoundKcal` like `sessionKcal`, so the glance never implies false precision.
    ///
    /// The numerator this is compared against is the raw whole-day HR estimate
    /// (`Calories.estimateDayCalories`), which credits resting burn only for WORN seconds — so a
    /// long unworn gap undercounts the numerator against this target. Stated, not hidden: the strap
    /// is worn near-continuously on this install.
    public static func dayKcalTarget(session: SessionPrescription?, profile: UserProfile,
                                     restingHr: Int?) -> Int {
        let weightKg = profile.weightKg > 0 ? profile.weightKg : 70.0
        let heightCm = profile.heightCm > 0 ? profile.heightCm : 170.0
        let age = profile.age > 0 ? profile.age : 30.0
        let restingRate = Calories.restingKcalPerS(Calories.resolveCoeffs(profile.sex),
                                                   weightKg: weightKg, heightCm: heightCm, age: age)
        let restingDay = restingRate * 86_400.0
        let sessionPart = session.map { Double(sessionKcal(session: $0, profile: profile,
                                                           restingHr: restingHr)) } ?? 0
        return Int(((restingDay + sessionPart) / calorieRoundKcal).rounded() * calorieRoundKcal)
    }

    // MARK: - Today's step target (all-day movement, priced by the same body-state bands)

    /// Step bases by charge band (260830) — all-day gentle movement (NEAT), a separate ask from the
    /// prescribed SESSION above: a recovery day still wants walking, just less of it. The bases are
    /// deliberately round guideline-scale numbers (the 7–10k range population evidence actually
    /// supports), banded by TODAY's charge — never by the user's own step history (the doctrine).
    public static let stepsBaseRecoverPerDay = 6_000
    public static let stepsBaseMaintainPerDay = 8_000
    public static let stepsBasePushPerDay = 10_000
    /// Readiness notches: a rundown read halves the walking ask toward the floor; strained trims it.
    public static let stepsRundownAdj = -2_000
    public static let stepsStrainedAdj = -1_000
    /// The target's bounds: below 4k the ask stops being a target, above 12k it stops being NEAT.
    public static let stepsFloorPerDay = 4_000
    public static let stepsCapPerDay = 12_000

    /// Rounding granularity for the step target (260906 "almost continuous"; 261004 tightened 50 → 10
    /// on the maintainer's "more granular and continuous" ask — still whole numbers, and 10 keeps the
    /// last digit from implying the curve resolves single steps).
    public static let stepsRoundPerDay = 10

    /// Today's step target: CONTINUOUS in charge (260906), the readiness read notches it down when the
    /// body says ease off, clamped 4k–12k. Primed adds nothing — a green day already asks the push
    /// figure, and steps are not where a primed body's headroom should go (the session is).
    ///
    /// ## Why interpolated rather than banded
    ///
    /// This used to pick one of three bases by charge band, so charge 34 and charge 66 both asked for
    /// exactly 8,000 while charge 66→67 jumped the ask by 2,000 steps in a single point. The bands
    /// were never a physiological claim — the population evidence supports the 7–10k RANGE, not three
    /// points inside it — so the cliff was an artefact of the encoding, not of the science.
    ///
    /// The three published anchors are preserved EXACTLY (recover ceiling → 6k, push floor → 10k, and
    /// the midpoint between them → 8k), so this is a refinement of the same curve rather than a new
    /// target scale: any charge that previously sat on a band edge still gets that band's number.
    /// Between the anchors the ask moves linearly, rounded to `stepsRoundPerDay`.
    ///
    /// Unknown charge still asks the maintain figure: no reading is not evidence of a low day.
    public static func stepsTarget(charge: Int?, readiness: ReadinessEngine.Level) -> Int {
        let base = stepsBaseForCharge(charge)
        let notch: Int
        switch readiness {
        case .rundown: notch = stepsRundownAdj
        case .strained: notch = stepsStrainedAdj
        default: notch = 0
        }
        let rounded = ((Double(base + notch) / Double(stepsRoundPerDay)).rounded()
                       * Double(stepsRoundPerDay))
        return min(max(Int(rounded), stepsFloorPerDay), stepsCapPerDay)
    }

    /// The continuous charge→steps curve, before the readiness notch and the clamp.
    ///
    /// Piecewise-linear through the three anchors rather than one straight line end to end: the
    /// recover→maintain and maintain→push halves have different slopes (2k over 17 points vs 2k over
    /// 34), and flattening them into a single line would move the maintain figure off 8k for the
    /// mid-charge days that are the most common case. Outside the anchors the value is held, not
    /// extrapolated — charge 5 and charge 33 are both "recover", and there is no evidence for asking
    /// less than the recover figure as charge approaches zero (the readiness notch is what handles a
    /// body that is genuinely rundown).
    /// 261004: the held ends are gone. Charge 67 and charge 95 used to ask the identical 10,000;
    /// the ends now extend linearly to the curve's own stated bounds — charge 100 → the 12k cap,
    /// charge 0 → the 4k floor — so every point of charge moves the ask. The three published
    /// anchors are still hit EXACTLY (33 → 6k, midpoint → 8k, 67 → 10k); the floor and cap are
    /// the same constants that always clamped the target, now reached as curve endpoints instead
    /// of being unreachable beyond held flats.
    public static func stepsBaseForCharge(_ charge: Int?) -> Int {
        guard let c = charge.map(Double.init) else { return stepsBaseMaintainPerDay }
        let lo = Double(recoverChargeCeiling), hi = Double(pushChargeFloor)
        let mid = (lo + hi) / 2.0
        func lerp(_ x: Double, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Double {
            y0 + (min(max(x, x0), x1) - x0) / (x1 - x0) * (y1 - y0)
        }
        let v: Double
        switch c {
        case ..<lo:  v = lerp(c, 0, Double(stepsFloorPerDay), lo, Double(stepsBaseRecoverPerDay))
        case ..<mid: v = lerp(c, lo, Double(stepsBaseRecoverPerDay), mid, Double(stepsBaseMaintainPerDay))
        case ..<hi:  v = lerp(c, mid, Double(stepsBaseMaintainPerDay), hi, Double(stepsBasePushPerDay))
        default:     v = lerp(c, hi, Double(stepsBasePushPerDay), 100, Double(stepsCapPerDay))
        }
        return Int(v.rounded())
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

    /// Tonight's sleep target (minutes): the personal need plus a share of any carried debt.
    ///
    /// 260922: ONE need everywhere. Three figures used to coexist — the ledger's per-night need,
    /// this target (a population floor with charge / rest / readiness notches), and the Day-quality
    /// "needed" (yesterday's copy of this target) — and read 8h27, 8h05 and 7.6h across one screen
    /// set for one body. `needMin` is now the caller's canonical personal need
    /// (`SleepModel.personalNeedMin`, the estimator Rest is scored against), and the ONLY adjustment
    /// is the debt term: a quarter of a carried deficit beyond the deadband, capped at 45 minutes.
    /// The charge / rest / readiness notches are retired: they were the unexplained gap between the
    /// need and the target, and a target that cannot be derived from the two numbers beside it is
    /// noise. Bounds unchanged (7-10 h).
    public static func sleepNeedTonightMin(needMin: Double, debtBalanceMin: Double) -> Int {
        var need = needMin
        let debt = max(0, -debtBalanceMin)
        if debt > debtDeadbandMin { need += min(sleepDebtCapMin, debt * sleepDebtShare) }
        return Int(min(max(need, sleepFloorMin), sleepCapMin).rounded())
    }
}
