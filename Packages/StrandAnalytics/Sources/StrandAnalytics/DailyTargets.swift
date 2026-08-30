import Foundation

// DailyTargets.swift — the deterministic daily targets behind the three-pillar Live Activity card
// and the coach synthesis: a calm heart-rate ceiling, a calorie target for the day, an effort
// target, and tonight's sleep need.
//
// Pure, DB-free, constant-explicit — every number is a stated rule over the user's own recent
// history, never a model output, so the card can print `72/85` and the synthesis can cite the same
// figure and both are explainable in one sentence. The bands mirror the coach's own autoregulation
// prescription (charge 67–100 = build/push, 34–66 = maintain, 0–33 = recover), so the numbers the
// card shows and the plan the coach writes can never disagree about what kind of day this is.
public enum DailyTargets {

    // MARK: - Calm heart-rate ceiling (the "go breathe" line)

    /// Margin (bpm) added onto the recent nightly resting-HR median. Nightly RHR is the floor the
    /// body idles at; daytime seated rest runs ~10–15 bpm above it, so RHR + 25 marks "elevated while
    /// at rest" without flagging every walk to the kitchen. A ceiling, not a zone: exceeding it AT
    /// REST is the meditate/calm-down cue — during exercise exceeding it is the point, which is why
    /// the card's live surface may suppress the comparison during a detected workout.
    public static let calmMarginBpm = 25
    /// Sanity clamp on the ceiling. Below 70 the cue would fire on normal desk life even for genuine
    /// low-RHR athletes; above 110 "calm" has lost its meaning.
    public static let calmCeilingRange = 70...110
    /// Minimum recent nights of resting HR before a personal ceiling is trusted (cold-start honesty,
    /// same shape as `Rest.minNeedNights`). Below it the ceiling is absent, never guessed.
    public static let calmMinNights = 3

    /// The calm ceiling (bpm) from recent nightly resting HRs (newest window the caller chooses,
    /// typically the last 7 nights): median + `calmMarginBpm`, clamped. Nil until `calmMinNights`
    /// usable values exist — the card then shows the plain HR with no denominator.
    public static func calmCeilingBpm(recentRestingHr: [Int]) -> Int? {
        let xs = recentRestingHr.filter { $0 > 0 }.sorted()
        guard xs.count >= calmMinNights else { return nil }
        let median = xs[xs.count / 2]
        return min(max(median + calmMarginBpm, calmCeilingRange.lowerBound),
                   calmCeilingRange.upperBound)
    }

    // MARK: - The charge bands (shared by the calorie and effort targets)

    /// Charge at or above this = green light to build/push. Identical to the coach prompt's band.
    public static let pushChargeFloor = 67
    /// Charge at or below this = active recovery only. Identical to the coach prompt's band.
    public static let recoverChargeCeiling = 33

    /// The percentile of the user's own recent history a day's target sits at, by charge band:
    /// a push day targets the 75th percentile (their bigger recent days), a maintain day the median,
    /// a recovery day the 25th. An unknown charge (not yet scored this morning) reads as maintain —
    /// the neutral prescription, never the aggressive one.
    public static func targetPercentile(charge: Int?) -> Double {
        guard let charge else { return 0.5 }
        if charge >= pushChargeFloor { return 0.75 }
        if charge <= recoverChargeCeiling { return 0.25 }
        return 0.5
    }

    /// Linear-interpolated percentile over a sorted copy of `values` — the same estimator
    /// `Rest.personalizedNeedHours` uses for its upper quartile, so the two never disagree about
    /// what "p75" means. Nil for an empty input.
    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        let xs = values.sorted()
        guard !xs.isEmpty else { return nil }
        let pos = min(max(p, 0), 1) * Double(xs.count - 1)
        let lo = Int(pos), hi = min(lo + 1, xs.count - 1)
        return xs[lo] + (pos - Double(lo)) * (xs[hi] - xs[lo])
    }

    // MARK: - Calorie target

    /// Minimum recent days with a calorie estimate before a target is offered.
    public static let calorieMinDays = 3
    /// Targets are rounded to this granularity — a 1,187 kcal target would claim a precision the
    /// underlying HR-only estimate does not have.
    public static let calorieRoundKcal = 25.0

    /// FALLBACK calorie target: the charge band's percentile over the user's recent daily estimates
    /// (typically the last 14 days of `activeKcalEst`). Nil until `calorieMinDays` usable days exist.
    ///
    /// Fallback rather than primary since 260829: a percentile of a mostly-sedentary history is
    /// reachable by simply existing — the whole-day HR estimate is dominated by baseline daily
    /// living, so "close to target on an effort-0 day" was the norm, which is useless as a
    /// weight-loss stretch goal. The primary target is `calorieTargetKcal(effortTarget:fit:)`,
    /// which prices the EFFORT target in calories; this percentile stands in only while the
    /// history is too thin or too flat to fit.
    public static func calorieTargetKcal(charge: Int?, recentActiveKcal: [Double]) -> Int? {
        let usable = recentActiveKcal.filter { $0 > 0 }
        guard usable.count >= calorieMinDays else { return nil }
        guard let raw = percentile(usable, targetPercentile(charge: charge)) else { return nil }
        return Int((raw / calorieRoundKcal).rounded() * calorieRoundKcal)
    }

    /// The user's own calories-per-effort-point line: a least-squares fit of daily active kcal
    /// against daily effort over recent history, `kcal ≈ intercept + slope × effort`. The intercept
    /// is their typical zero-effort day (the baseline burn of existing); the slope is what one
    /// effort point costs THEM in calories — both personal, both explainable in one sentence.
    public struct EffortCalorieFit: Equatable {
        /// Typical whole-day active kcal at zero effort — the baseline burn.
        public let interceptKcal: Double
        /// Additional kcal per effort point.
        public let kcalPerEffortPoint: Double
        public init(interceptKcal: Double, kcalPerEffortPoint: Double) {
            self.interceptKcal = interceptKcal
            self.kcalPerEffortPoint = kcalPerEffortPoint
        }
    }

    /// Minimum (effort, kcal) days before the fit is trusted — same cold-start honesty as the rest.
    public static let effortFitMinDays = 5

    /// Fit the calories-per-effort line, or nil when the history cannot support one: too few paired
    /// days, no variance in effort (a flat week fits nothing), or a non-positive slope (noise saying
    /// "more effort burns fewer calories" is not a line worth pricing a target on).
    public static func effortCalorieFit(history: [(effort: Double, kcal: Double)]) -> EffortCalorieFit? {
        let pts = history.filter { $0.kcal > 0 && $0.effort >= 0 }
        guard pts.count >= effortFitMinDays else { return nil }
        let n = Double(pts.count)
        let meanX = pts.reduce(0) { $0 + $1.effort } / n
        let meanY = pts.reduce(0) { $0 + $1.kcal } / n
        let sxx = pts.reduce(0) { $0 + ($1.effort - meanX) * ($1.effort - meanX) }
        guard sxx > 0 else { return nil }
        let sxy = pts.reduce(0) { $0 + ($1.effort - meanX) * ($1.kcal - meanY) }
        let slope = sxy / sxx
        guard slope > 0 else { return nil }
        let intercept = meanY - slope * meanX
        guard intercept >= 0 else { return nil }
        return EffortCalorieFit(interceptKcal: intercept, kcalPerEffortPoint: slope)
    }

    /// PRIMARY calorie target: the effort target priced in the user's own calories — baseline burn
    /// plus what the target's effort points cost them. This is the "rely on strain, converted to
    /// calories" contract: on an effort-0 day the count sits near the baseline and the visible gap
    /// IS the exercise still owed, instead of a percentile a sedentary day drifts into anyway.
    public static func calorieTargetKcal(effortTarget: Int, fit: EffortCalorieFit) -> Int {
        let raw = fit.interceptKcal + fit.kcalPerEffortPoint * Double(effortTarget)
        return Int((raw / calorieRoundKcal).rounded() * calorieRoundKcal)
    }

    // MARK: - Effort target (readiness-driven; the synthesis' number, and what prices the calories)

    // HISTORY (260829, same night it shipped): the first effort target was a percentile of the
    // user's own recent effort history — which made the whole activity pillar self-referential: a
    // sedentary fortnight could never ask for more than a sedentary fortnight. The target is now
    // READINESS-driven, by explicit request ("determined by the readiness of my body ... not my
    // history"): today's charge picks the approved #43 optimal-strain band, and the body's other
    // signals position the target inside (or below) it. History plays no part.

    /// A rundown body is prescribed BELOW the charge band by this many 21-axis points — several
    /// recovery signals down outranks a charge score that hasn't caught up yet.
    public static let rundownBelowBand21 = 3.0
    /// The absolute floor for a prescribed target (21-axis): below this, "target" stops meaning
    /// anything — rest is the prescription and the synthesis says so.
    public static let effortFloor21 = 2.0
    /// Primed stops one point short of the band's top: the top is the band's own ceiling for a
    /// perfect day, not a standing prescription.
    public static let primedHeadroom21 = 1.0
    /// A Rest score below this drags the target one notch down (poor sleep is a readiness fact the
    /// morning charge can understate); at or above `greatRestScore` it lifts one notch.
    public static let poorRestScore = 50
    public static let greatRestScore = 85

    /// Today's effort target on the 0–21 coupled axis, from the body's state alone.
    ///
    /// - `band`: the approved #43 recovery→optimal-strain band (14–18 / 10–14 / 4–10 of 21) for
    ///   today's charge — the caller resolves it (`CoupledView.optimalStrainRange`) so this stays
    ///   one source of truth away from drift. Nil charge ⇒ no band ⇒ the caller passes nothing and
    ///   there is no target (never guess).
    /// - `readiness`: the multi-signal `ReadinessEngine` level (HRV / resting HR / respiration vs
    ///   personal baselines, plus acute:chronic load and monotony) — it positions the target on a
    ///   four-notch ladder: rundown = below the band, strained = the band's low, balanced (and
    ///   insufficient, where the signals can't speak) = the midpoint, primed = just under the top.
    /// - `restScore`: last night's Rest (0–100) shifts the ladder one notch down when poor, one up
    ///   when excellent — sleep is the readiness input the other signals see only indirectly.
    public static func effortTarget21(band: ClosedRange<Int>,
                                      readiness: ReadinessEngine.Level,
                                      restScore: Int?) -> Double {
        let low = Double(band.lowerBound), high = Double(band.upperBound)
        let ladder: [Double] = [
            max(low - rundownBelowBand21, effortFloor21),   // 0: rundown — below the band
            low,                                            // 1: strained — the band's floor
            (low + high) / 2,                               // 2: balanced / insufficient — midpoint
            high - primedHeadroom21,                        // 3: primed — just under the top
        ]
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
        return ladder[notch]
    }

    // MARK: - Tonight's sleep need

    // HISTORY (260830): v1 was "personalized need + half the debt capped at 90 min". On this user's
    // deep ledger the cap bound every single night, so the card read the same maxed number for weeks
    // — a constant is not a prescription. Rebuilt by explicit request ("based on my rest and charge
    // score, not just my sleep debt — personalize the number for each night; floor at 7, cap at 10"):
    // charge and rest change daily, so they now carry the night-to-night variation and the debt term
    // is deliberately the smallest.

    /// The final target's bounds (the user's stated contract): never below 7 h, never above 10 h.
    public static let sleepFloorMin = 420.0
    public static let sleepCapMin = 600.0
    /// The BASE (typical need before tonight's adjustments): the 75th percentile of the user's own
    /// recent nights — their less-restricted nights, the same upper-quartile idea as
    /// `Rest.personalizedNeedHours` — clamped so adjustments keep headroom under the cap. Fewer than
    /// `calorieMinDays` usable nights → the 8 h default.
    public static let sleepBaseCapMin = 570.0
    /// Charge adjustment: a body that scored mid-recovery asks a little more of tonight, a poor one
    /// more still. A green day adds nothing — recovery is not a reason to sleep less.
    public static let sleepChargeAdjMaintainMin = 20.0
    public static let sleepChargeAdjRecoverMin = 40.0
    /// Rest adjustment: a poor LAST night (Rest < `poorRestScore`) asks tonight to make some back;
    /// an excellent one (≥ `greatRestScore`) relaxes tonight slightly.
    public static let sleepRestAdjPoorMin = 30.0
    public static let sleepRestAdjGreatMin = -15.0
    /// The debt term, now the junior partner: a quarter of the outstanding ledger, capped, and
    /// silent inside the ledger's own on-target deadband. A surplus never discounts the night —
    /// sleep is not bankable ahead.
    public static let sleepDebtShare = 0.25
    public static let sleepDebtCapMin = 45.0
    public static let debtDeadbandMin = SleepDebt.onTargetBandMin

    /// Minutes of sleep to target TONIGHT (the night that spans into tomorrow morning), from the
    /// body's day: the typical-need base, adjusted by today's charge band and last night's Rest
    /// score, plus the capped junior debt term — clamped to the user's stated 7–10 h bounds.
    public static func sleepNeedTonightMin(nightlyMinutes: [Double],
                                           charge: Int?,
                                           restScore: Int?,
                                           debtBalanceMin: Double) -> Int {
        let nights = nightlyMinutes.filter { $0 > 0 }
        let base = min(max(
            (nights.count >= calorieMinDays ? percentile(nights, 0.75) : nil) ?? 480,
            sleepFloorMin), sleepBaseCapMin)
        var need = base
        if let charge {
            if charge <= recoverChargeCeiling { need += sleepChargeAdjRecoverMin }
            else if charge < pushChargeFloor { need += sleepChargeAdjMaintainMin }
        }
        if let rest = restScore {
            if rest < poorRestScore { need += sleepRestAdjPoorMin }
            else if rest >= greatRestScore { need += sleepRestAdjGreatMin }
        }
        let debt = max(0, -debtBalanceMin)
        if debt > debtDeadbandMin { need += min(sleepDebtCapMin, debt * sleepDebtShare) }
        return Int(min(max(need, sleepFloorMin), sleepCapMin).rounded())
    }
}
