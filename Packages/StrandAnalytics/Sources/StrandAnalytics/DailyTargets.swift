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

    /// Today's ACTIVE-calorie target (kcal) from the charge band over the user's recent daily
    /// estimates (typically the last 14 days of `activeKcalEst`). Nil until `calorieMinDays` usable
    /// days exist. Deterministic on purpose: the Live Activity cannot ask a model, and the synthesis
    /// cites the same number the card shows.
    public static func calorieTargetKcal(charge: Int?, recentActiveKcal: [Double]) -> Int? {
        let usable = recentActiveKcal.filter { $0 > 0 }
        guard usable.count >= calorieMinDays else { return nil }
        guard let raw = percentile(usable, targetPercentile(charge: charge)) else { return nil }
        return Int((raw / calorieRoundKcal).rounded() * calorieRoundKcal)
    }

    // MARK: - Effort target (the synthesis' number; the card carries calories instead)

    /// Today's effort target (the app's 0–100 axis) from the same charge band over recent daily
    /// effort scores. Same minimum-history rule as calories; rounded to a whole point.
    public static func effortTarget(charge: Int?, recentEffort: [Double]) -> Int? {
        let usable = recentEffort.filter { $0 > 0 }
        guard usable.count >= calorieMinDays else { return nil }
        return percentile(usable, targetPercentile(charge: charge)).map { Int($0.rounded()) }
    }

    // MARK: - Tonight's sleep need

    /// At most this much of the rolling debt is scheduled for repayment in one night. Sleeping 11 h
    /// to clear a fortnight's ledger in one go is neither realistic nor healthy advice; ~1.5 h extra
    /// is the accepted ceiling for useful same-night catch-up.
    public static let debtRepayCapMin = 90.0
    /// Share of the outstanding debt asked of tonight (the rest amortizes over coming nights).
    public static let debtRepayShare = 0.5
    /// Debts inside the ledger's own on-target deadband are noise, not a prescription.
    public static let debtDeadbandMin = SleepDebt.onTargetBandMin

    /// Minutes of sleep to target TONIGHT (the night that spans into tomorrow morning): the personal
    /// need plus a capped share of the outstanding rolling debt. A surplus never reduces the need
    /// below baseline — banking sleep ahead is not physiologically bankable, so the credit side of
    /// the ledger only ever zeroes the repayment, never discounts the night.
    ///
    /// - Parameters:
    ///   - needMin: personal nightly need in minutes (`Rest.personalizedNeedHours` × 60).
    ///   - debtBalanceMin: the rolling ledger's signed balance (`SleepDebtLedger.balanceMin`,
    ///     negative = net debt).
    public static func sleepNeedTonightMin(needMin: Double, debtBalanceMin: Double) -> Int {
        let debt = max(0, -debtBalanceMin)
        let repay = debt <= debtDeadbandMin ? 0 : min(debtRepayCapMin, debt * debtRepayShare)
        return Int((needMin + repay).rounded())
    }
}
