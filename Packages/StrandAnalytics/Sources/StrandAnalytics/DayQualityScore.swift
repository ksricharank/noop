import Foundation

/// Yesterday's day-quality score (0–100): one number for "how did that day go", against both the
/// targets the day set and what the body did with them.
///
/// Built for the long-run motivation the daily synthesis cannot provide. The synthesis is about
/// TODAY — what to do next. This is a closed book: computed once the night's sleep has been scored,
/// shown in Trends as a summary of yesterday, and tracked as a series so the direction of travel is
/// visible over weeks.
///
/// ## Why two halves
///
/// **Execution** is what the wearer controlled: steps, calories, effort, water. **Recovery** is what
/// the body did in response: sleep against need, HRV and resting HR against their own 30-day
/// baselines. A single blended number would let a hard-charging week hide a body that is falling
/// apart, and a rest week look like failure. Splitting them means the score can say "you did the
/// work AND absorbed it", which is the only combination worth trending upward.
///
/// Default 60/40, configurable — the split is a matter of what the wearer wants the number to mean,
/// not a fact about physiology.
///
/// ## Three rules that keep the number honest
///
/// 1. **Overshoot earns credit, but a bounded amount.** An execution component scores above 1.0 when
///    the target is beaten — so a genuinely big day can reach 100 on execution alone, rather than
///    being punished for being hard — but only up to `overshootCap`. The bound is what stops the
///    score rewarding whichever component is easiest to inflate: a 40 000-step day still cannot fully
///    offset a skipped workout, because its extra credit is worth a fraction of the component it
///    would be covering for.
/// 2. **A component with no data is ABSENT, never zero.** Weights renormalise over what is present,
///    so a night the strap did not record scores the day on what it does know. Scoring a missing
///    night as zero would be a claim about the day rather than about the data — the same rule the
///    coach context settled on for absent sleep stages.
/// 3. **Nothing is scored until the night is in.** The recovery half needs the scored night, so the
///    caller waits for it. A score published mid-morning and revised later is worse than one that
///    arrives complete.
///
/// ## The load factor
///
/// Targets shrink on a low-charge day, so hitting them is genuinely easier — which means a score
/// computed purely against the day's own targets can trend UP through a deconditioning stretch. The
/// load factor scales the execution half by how demanding the day's targets were relative to the
/// wearer's own recent average, so matching a hard day beats matching an easy one.
///
/// Deliberately mild and clamped: it corrects the drift without turning a legitimate rest day into a
/// failure. `loadFactorStrength` 0 disables it entirely.
///
/// Pure and database-free, in `StrandAnalytics` so it is covered by `swift test` with no app, no
/// strap and no CoreBluetooth.
public struct DayQualityScore: Equatable, Sendable {

    /// One scored component: what it is called, what it contributed, and the numbers behind it — so
    /// the UI's "how this was computed" panel restates the arithmetic rather than re-deriving it.
    public struct Component: Equatable, Sendable {
        public let label: String
        /// 0…1 achievement against this component's own yardstick, already capped.
        public let achieved: Double
        /// Weight actually applied AFTER renormalisation (so present components sum to the half's total).
        public let weight: Double
        /// Points contributed to the final score.
        public let points: Double
        /// Human-readable evidence, e.g. "7 412 of 8 000 steps" or "HRV 62 ms vs 58 ms baseline".
        public let detail: String

        public init(label: String, achieved: Double, weight: Double, points: Double, detail: String) {
            self.label = label
            self.achieved = achieved
            self.weight = weight
            self.points = points
            self.detail = detail
        }
    }

    /// 0–100, rounded for display. Nil is never published — a day with too little data returns nil
    /// from `score(...)` instead, so the series has a gap rather than a misleading low number.
    public let total: Int
    public let executionPoints: Double
    public let recoveryPoints: Double
    public let components: [Component]
    /// The multiplier applied to the execution half (1.0 when disabled or when the day was average).
    public let loadFactor: Double
    /// Which components had no data, so the UI can say what the score could not see.
    public let missing: [String]

    public init(total: Int, executionPoints: Double, recoveryPoints: Double,
                components: [Component], loadFactor: Double, missing: [String]) {
        self.total = total
        self.executionPoints = executionPoints
        self.recoveryPoints = recoveryPoints
        self.components = components
        self.loadFactor = loadFactor
        self.missing = missing
    }

    // MARK: - Configuration

    /// The wearer-tunable parts. Defaults are the shipped 60/40 with a mild load factor.
    public struct Config: Equatable, Sendable {
        // The three tunables clamp on ASSIGNMENT, not only in `init`. Callers legitimately build a
        // config by mutating `.default` (the app's prefs bridge does exactly that), which would
        // otherwise skip the initializer's clamps entirely and let a corrupt stored preference
        // produce a nonsense score. `didSet` does not fire during `init`, so the initializer keeps
        // its own clamps too — both paths are covered, and both are tested.
        /// RETIRED (260908) — kept only so a stored preference still decodes.
        ///
        /// The old formula split 100 points between an execution and a recovery half, and this chose
        /// the split. The scale no longer works that way: each component contributes its own absolute
        /// points from the normal-day anchor, and the "halves" on the card are now just a grouping of
        /// those components for reading. There is nothing left for a share to divide.
        ///
        /// It does NOT affect the score, and the settings UI must not offer it as though it did — a
        /// slider that moves nothing is worse than no slider. Use the per-component weights instead,
        /// which is the honest way to say "recovery should matter more to me".
        public var executionShare: Double {
            didSet { executionShare = min(max(executionShare, 0), 1) }
        }
        /// 0 disables the load factor; 1 applies it at full strength. Default 0.5 — enough to stop
        /// the deconditioning drift, not enough to punish a genuine rest day.
        public var loadFactorStrength: Double {
            didSet { loadFactorStrength = min(max(loadFactorStrength, 0), 1) }
        }

        /// How far past target a component may be credited, as a MULTIPLE of the normal→target
        /// distance. ≥ 1.0, so a configuration can never make hitting a target score less than full
        /// marks for it; 1.0 restores a hard stop at target.
        ///
        /// The default 1.7 is not taste — it is what makes +100 reachable exactly when everything is
        /// beaten: the five target-bearing components sum to `targetPointsTotal` (50) and the two
        /// baseline signals add 15 at their ceiling, so 50 × 1.7 + 15 = 100. Lowering it lowers the
        /// practical ceiling, which is a legitimate choice ("I want 100 to mean merely hitting my
        /// targets") but no longer lands on 100.
        public var overshootCap: Double {
            didSet { overshootCap = min(max(overshootCap, 1.0), 3.0) }
        }

        /// Relative weights WITHIN each half. They need not sum to anything in particular; each half
        /// normalises its own present components, which is also what makes rule 2 work.
        /// The absolute "normal sedentary day" the score's zero sits on. Tunable, because "no
        /// deliberate activity" is a fact about a person rather than a constant — see `NormalDay`.
        public var normalDay: NormalDay = .default

        public var stepsWeight: Double
        public var calorieWeight: Double
        public var effortWeight: Double
        public var waterWeight: Double
        public var sleepWeight: Double
        public var hrvWeight: Double
        public var restingHrWeight: Double

        public static let `default` = Config(
            executionShare: 0.60,
            loadFactorStrength: 0.5,
            overshootCap: overshootMultiple,
            // The five target-bearing weights are RELATIVE — they are renormalised to
            // `targetPointsTotal` (50) at score time, so only their proportions matter and moving one
            // in settings cannot break the "targets met = +50" anchor.
            //
            // Steps, calories and effort carry equal share; water carries less (it is the easiest to
            // hit and the noisiest to measure); sleep carries most, being the one recovery input the
            // wearer has real agency over.
            stepsWeight: 11, calorieWeight: 11, effortWeight: 11, waterWeight: 5,
            sleepWeight: 12,
            // HRV and resting HR are ABSOLUTE points, outside that total: they score 0 at baseline, so
            // they cannot contribute to "targets met". 9 + 6 = 15 is what makes +100 reachable exactly
            // when every target is beaten to the cap — 50 × 1.7 + 15 = 100.
            hrvWeight: 9, restingHrWeight: 6
        )

        public init(executionShare: Double, loadFactorStrength: Double,
                    overshootCap: Double = overshootMultiple,
                    normalDay: NormalDay = .default,
                    stepsWeight: Double, calorieWeight: Double, effortWeight: Double,
                    waterWeight: Double, sleepWeight: Double, hrvWeight: Double,
                    restingHrWeight: Double) {
            self.normalDay = normalDay
            // The property is deprecated but still stored so an existing preference decodes; assigning
            // it here is deliberate, not an oversight.
            self.executionShare = min(max(executionShare, 0), 1)
            self.loadFactorStrength = min(max(loadFactorStrength, 0), 1)
            // Never below 1.0: a cap under target would mean hitting the target scored less than
            // full marks for it, which no configuration should be able to express.
            self.overshootCap = min(max(overshootCap, 1.0), 3.0)
            self.stepsWeight = max(0, stepsWeight)
            self.calorieWeight = max(0, calorieWeight)
            self.effortWeight = max(0, effortWeight)
            self.waterWeight = max(0, waterWeight)
            self.sleepWeight = max(0, sleepWeight)
            self.hrvWeight = max(0, hrvWeight)
            self.restingHrWeight = max(0, restingHrWeight)
        }
    }

    /// Everything one day needs, all optional so a partial day still scores on what it has.
    public struct DayInput: Equatable, Sendable {
        public var steps: Int?
        public var stepsTarget: Int?
        public var kcal: Int?
        public var kcalTarget: Int?
        public var effort: Int?
        public var effortTarget: Int?
        public var waterCups: Int?
        public var waterTargetCups: Int?
        public var sleepMin: Double?
        public var sleepNeedMin: Int?
        public var hrv: Double?
        public var hrvBaseline: Double?
        public var restingHr: Int?
        public var restingHrBaseline: Double?
        /// Mean of the wearer's own recent daily targets, for the load factor. Nil disables it.
        public var recentAvgEffortTarget: Double?

        public init(steps: Int? = nil, stepsTarget: Int? = nil, kcal: Int? = nil,
                    kcalTarget: Int? = nil, effort: Int? = nil, effortTarget: Int? = nil,
                    waterCups: Int? = nil, waterTargetCups: Int? = nil, sleepMin: Double? = nil,
                    sleepNeedMin: Int? = nil, hrv: Double? = nil, hrvBaseline: Double? = nil,
                    restingHr: Int? = nil, restingHrBaseline: Double? = nil,
                    recentAvgEffortTarget: Double? = nil) {
            self.steps = steps; self.stepsTarget = stepsTarget
            self.kcal = kcal; self.kcalTarget = kcalTarget
            self.effort = effort; self.effortTarget = effortTarget
            self.waterCups = waterCups; self.waterTargetCups = waterTargetCups
            self.sleepMin = sleepMin; self.sleepNeedMin = sleepNeedMin
            self.hrv = hrv; self.hrvBaseline = hrvBaseline
            self.restingHr = restingHr; self.restingHrBaseline = restingHrBaseline
            self.recentAvgEffortTarget = recentAvgEffortTarget
        }
    }

    /// At least this many of the seven components must have data, or the day is not scored at all.
    /// Three is the smallest number that can carry both halves plus one corroborating signal; below
    /// that the "score" is really one measurement wearing a percentage sign.
    public static let minimumComponents = 3

    // MARK: - The scale: 0 is a normal day, +100 is everything beaten (260908, revised)

    /// What an ordinary day with no deliberate activity actually looks like — the ABSOLUTE definition
    /// of the score's zero.
    ///
    /// 260908, second attempt. The first signed scale derived its origin from the scorer and then
    /// spread that origin shift across the components, which turned out to be the mistake the field
    /// cards exposed: every row received about +8.7 points *before any achievement was counted*, so a
    /// 99 %-of-target step count scored +9.7 of 23.4 — nearly half the available credit for MISSING the
    /// target. The offset dominated the performance, and ordinary days published in the high twenties
    /// to fifties. Maintainer: "a steady day with normal activity and normal sleep (not based on
    /// relative data but some absolute definition) should be 0".
    ///
    /// So the origin is now a stated fact about a sedentary day rather than a derived quantity, and
    /// each component is one linear ramp from it: **0 at normal, its full weight at target**. At
    /// normal input every term is literally zero, which makes the anchor STRUCTURAL — it cannot drift
    /// with a weight change, and there is nothing to spread.
    ///
    /// Absolute on purpose. Deriving these from the wearer's own quietest days would reintroduce
    /// exactly the relative drift the maintainer asked to avoid: a declining month would walk the zero
    /// point down with it and a deconditioning stretch would keep reading zero. Tunable instead (see
    /// `DayQualityPrefs`), because "no deliberate activity" is a fact about a person, not a constant.
    public struct NormalDay: Equatable, Sendable {
        /// Incidental walking with no deliberate exercise.
        public var steps: Double
        /// Active burn on a day that did nothing in particular.
        public var kcal: Double
        /// Effort on the stored 0–100 internal scale — pottering, not training.
        public var effort: Double
        public var waterCups: Double
        /// Minutes asleep. 7 h: a normal night, not a good one.
        public var sleepMin: Double

        public init(steps: Double = 4000, kcal: Double = 1600, effort: Double = 8,
                    waterCups: Double = 8, sleepMin: Double = 420) {
            self.steps = steps
            self.kcal = kcal
            self.effort = effort
            self.waterCups = waterCups
            self.sleepMin = sleepMin
        }

        public static let `default` = NormalDay()
    }

    /// How far past target a component may be credited, as a multiple of the normal→target distance.
    ///
    /// 1.7 is not a taste: it is what makes +100 reachable exactly when everything is beaten. The five
    /// target-bearing components sum to 50 (so hitting every target is +50 — see `targetPointsTotal`),
    /// and the two baseline signals contribute 15 at their own ceiling, so 50 × 1.7 + 15 = 100.
    public static let overshootMultiple = 1.7
    /// The mirror below normal, so −100 is reachable on a genuinely bad day.
    public static let shortfallMultiple = -1.7

    /// The points a day earns for hitting every target with both signals at baseline.
    ///
    /// Deliberately 50, at the maintainer's choice: meeting your targets is halfway up the positive
    /// half, leaving real room above it for beating them. HRV and resting HR are NOT part of this sum —
    /// they score 0 at baseline by definition, so they cannot contribute to "targets met" and their
    /// weights sit outside it.
    public static let targetPointsTotal = 50.0

    /// One component's contribution: 0 at the normal day, `weight` at target, clamped both ways.
    ///
    /// `normal` and `target` are in the component's own units. The single interesting case is a target
    /// at or below the normal-day reference, which happens for real: a low-charge day shrinks the steps
    /// target, and one field card showed a 4000-step target against a 4000-step normal. The first
    /// version dropped the component entirely — so a card showed no Steps row at all on a day with 8288
    /// steps, which reads as a data gap rather than as an active day. It now falls back to scoring
    /// against the target itself (0 at target, `weight` at double it), because a target below the
    /// normal-day reference is a statement about the TARGET, not a reason to un-score the day.
    public static func componentPoints(actual: Double, normal: Double, target: Double,
                                       weight: Double, cap: Double = overshootMultiple) -> Double {
        let span = target - normal
        guard span > 0 else {
            guard target > 0 else { return 0 }
            return clampRatio((actual / target) - 1.0, cap: cap) * weight
        }
        return clampRatio((actual - normal) / span, cap: cap) * weight
    }

    /// A signal scored against the wearer's own baseline: 0 AT baseline, `weight` at +10 %, −`weight`
    /// at `tolerance` below. Unchanged in spirit from the previous scale — only the neutral point moved
    /// from 0.75 to 0, which is what the rest of this formula now expresses directly.
    public static func baselinePoints(actual: Double, baseline: Double, weight: Double,
                                      higherIsBetter: Bool, tolerance: Double) -> Double {
        guard baseline > 0, actual > 0 else { return 0 }
        let ratio = actual / baseline
        guard ratio.isFinite else { return 0 }
        let improvement = higherIsBetter ? (ratio - 1) : (1 - ratio)
        let tol = tolerance > 0 ? tolerance : defaultDownsideTolerance
        if improvement >= 0 { return min(1.0, improvement / 0.10) * weight }
        return max(shortfallMultiple, improvement / tol) * weight
    }

    private static func clampRatio(_ x: Double, cap: Double = overshootMultiple) -> Double {
        guard x.isFinite else { return 0 }
        return max(shortfallMultiple, min(max(cap, 1.0), x))
    }

    /// The lowest and highest values `score(...)` can publish.
    public static let publishedMinimum = -100
    public static let publishedMaximum = 100

    // MARK: - Scoring

    /// Score one day, or nil when too little of it was recorded (see `minimumComponents`).
    ///
    /// One pass, no post-scaling. Each component contributes its points directly — 0 at the normal
    /// day, its weight at target — so the rows always sum to the headline by construction rather than
    /// by an apportionment scheme. That property is the whole reason this replaced the first signed
    /// scale: the field cards showed a headline of +56 above rows that summed to 13, because the
    /// headline came from the stored series while the breakdown was recomputed live under a different
    /// formula. There is now one formula and one sum.
    public static func score(_ input: DayInput, config: Config = .default) -> DayQualityScore? {
        let normal = config.normalDay
        var out: [Component] = []
        var missing: [String] = []
        var execPoints = 0.0
        var recPoints = 0.0

        // The five target-bearing components share `targetPointsTotal` in the configured proportions,
        // so "hit every target" lands on that total whatever the weights are set to. Renormalising
        // here (rather than trusting the weights to sum correctly) is what keeps the +50 anchor true
        // when the wearer moves a weight in settings.
        let targetWeights: [(String, Double)] = [
            ("Steps", config.stepsWeight), ("Calories", config.calorieWeight),
            ("Effort", config.effortWeight), ("Water", config.waterWeight),
            ("Sleep", config.sleepWeight),
        ]
        // Only components with DATA share the total, so an unrecorded night does not silently hand its
        // points to nobody — the same absent-is-not-zero rule as before, now expressed as "the day is
        // scored out of what was measured".
        func hasData(_ label: String) -> Bool {
            switch label {
            case "Steps":    return input.steps != nil && input.stepsTarget != nil
            case "Calories": return input.kcal != nil && input.kcalTarget != nil
            case "Effort":   return input.effort != nil && input.effortTarget != nil
            case "Water":    return input.waterCups != nil && input.waterTargetCups != nil
            case "Sleep":    return input.sleepMin != nil && input.sleepNeedMin != nil
            default:         return false
            }
        }
        let presentTargetWeight = targetWeights
            .filter { $0.1 > 0 && hasData($0.0) }
            .reduce(0) { $0 + $1.1 }
        func scaledWeight(_ raw: Double) -> Double {
            guard presentTargetWeight > 0 else { return 0 }
            return targetPointsTotal * (raw / presentTargetWeight)
        }

        /// Add one target-bearing component, or record it as missing.
        func addTarget(_ label: String, actual: Double?, target: Double?, rawWeight: Double,
                       normalValue: Double, isRecovery: Bool,
                       detail: (Double, Double) -> String) {
            guard rawWeight > 0 else { return }
            guard let actual, let target, target > 0 else { missing.append(label); return }
            let weight = scaledWeight(rawWeight)
            let points = componentPoints(actual: actual, normal: normalValue,
                                         target: target, weight: weight,
                                         cap: config.overshootCap)
            if isRecovery { recPoints += points } else { execPoints += points }
            // `achieved` stays a fraction OF TARGET, which is what the evidence line and the
            // attribution card read — it is the plain-language "how much of it did I do", and it is
            // deliberately not the same quantity as the ramp position used for points.
            out.append(Component(label: label, achieved: actual / target, weight: weight,
                                 points: points, detail: detail(actual, target)))
        }

        addTarget("Steps", actual: input.steps.map(Double.init),
                  target: input.stepsTarget.map(Double.init), rawWeight: config.stepsWeight,
                  normalValue: normal.steps, isRecovery: false,
                  detail: { "\(Int($0)) of \(Int($1)) steps" })
        addTarget("Calories", actual: input.kcal.map(Double.init),
                  target: input.kcalTarget.map(Double.init), rawWeight: config.calorieWeight,
                  normalValue: normal.kcal, isRecovery: false,
                  detail: { "\(Int($0)) of \(Int($1)) kcal" })
        addTarget("Effort", actual: input.effort.map(Double.init),
                  target: input.effortTarget.map(Double.init), rawWeight: config.effortWeight,
                  normalValue: normal.effort, isRecovery: false,
                  detail: { "\(Int($0)) of \(Int($1)) effort" })
        addTarget("Water", actual: input.waterCups.map(Double.init),
                  target: input.waterTargetCups.map(Double.init), rawWeight: config.waterWeight,
                  normalValue: normal.waterCups, isRecovery: false,
                  detail: { "\(Int($0)) of \(Int($1)) cups" })
        // Sleep is a target-bearing component that belongs to the RECOVERY half: it is what the body
        // was given, not what it was asked to do.
        addTarget("Sleep", actual: input.sleepMin,
                  target: input.sleepNeedMin.map(Double.init), rawWeight: config.sleepWeight,
                  normalValue: normal.sleepMin, isRecovery: true,
                  detail: { String(format: "%.1fh of %.1fh needed", $0 / 60, $1 / 60) })

        // The two autonomic signals score against the wearer's OWN baseline and sit OUTSIDE
        // `targetPointsTotal` — they are 0 at baseline by definition, so they cannot contribute to
        // "targets met", and their weights are absolute points rather than a share of that total.
        if config.hrvWeight > 0 {
            if let hrv = input.hrv, let base = input.hrvBaseline, base > 0 {
                let points = baselinePoints(actual: hrv, baseline: base, weight: config.hrvWeight,
                                            higherIsBetter: true, tolerance: hrvDownsideTolerance)
                recPoints += points
                out.append(Component(label: "HRV", achieved: hrv / base, weight: config.hrvWeight,
                                     points: points,
                                     detail: String(format: "%.0f ms vs %.0f ms baseline", hrv, base)))
            } else {
                missing.append("HRV")
            }
        }
        if config.restingHrWeight > 0 {
            if let rhr = input.restingHr, let base = input.restingHrBaseline, base > 0 {
                let points = baselinePoints(actual: Double(rhr), baseline: base,
                                            weight: config.restingHrWeight,
                                            higherIsBetter: false,
                                            tolerance: restingHrDownsideTolerance)
                recPoints += points
                out.append(Component(label: "Resting HR", achieved: Double(rhr) / base,
                                     weight: config.restingHrWeight, points: points,
                                     detail: String(format: "%d bpm vs %.0f bpm baseline", rhr, base)))
            } else {
                missing.append("Resting HR")
            }
        }

        guard out.count >= minimumComponents else { return nil }

        // The load factor tilts the EXECUTION half by how demanding the day's targets were relative to
        // the wearer's own recent average. Additive, for the reason the multiplicative form failed on a
        // signed scale: meeting a target scores 0 credit, and zero times anything is zero — the feature
        // went completely inert while still printing a factor in the breakdown. Mild and clamped, so a
        // rest day still reads as a rest day.
        let loadFactor = loadFactor(input: input, strength: config.loadFactorStrength)
        let tilt = (loadFactor - 1.0) * targetPointsTotal
        if tilt != 0, presentTargetWeight > 0 {
            // Applied to the execution components only, spread by weight, and REFLECTED in the rows so
            // the panel still sums to the headline.
            let execTotal = out.filter { $0.label != "Sleep" && $0.label != "HRV"
                                         && $0.label != "Resting HR" }
                               .reduce(0) { $0 + $1.weight }
            if execTotal > 0 {
                out = out.map { c in
                    guard c.label != "Sleep", c.label != "HRV", c.label != "Resting HR" else { return c }
                    let share = c.weight / execTotal
                    return Component(label: c.label, achieved: c.achieved, weight: c.weight,
                                     points: c.points + tilt * share, detail: c.detail)
                }
                execPoints += tilt
            }
        }

        let total = Int(max(Double(publishedMinimum),
                            min(Double(publishedMaximum), execPoints + recPoints)).rounded())
        return DayQualityScore(total: total, executionPoints: execPoints, recoveryPoints: recPoints,
                               components: out, loadFactor: loadFactor, missing: missing)
    }

    /// Achievement for a signal measured against the wearer's own baseline.
    ///
    /// At baseline → 0.75. A 10% improvement → 1.0 (capped). A 20% deterioration → 0.0. Linear
    /// between, clamped both ends. `higherIsBetter` flips the sense for resting HR, where a lower
    /// number is the good news.
    ///
    /// The asymmetry is deliberate: normal is genuinely good (most days should sit near baseline and
    /// score well), but "normal" must not be full marks or the recovery half would be pinned at its
    /// ceiling and the score would move only with execution.
    /// How far below baseline a signal must fall to score ZERO, per signal (260907).
    ///
    /// The reported symptom: a day-quality card showing `HRV 30 ms vs 36 ms baseline → 1.7/15`, which
    /// reads as a broken or missing signal. It was neither — the arithmetic was exactly right. The
    /// CALIBRATION was wrong: a single downside slope of 0.20 was applied to every signal, so 17 %
    /// below baseline scored 11 % of the available points.
    ///
    /// The correction comes from the wearer's own measured spread rather than from taste. Across 23
    /// banked nights the night-to-night HRV deviation from its own median was 7 % (median), 21 %
    /// (p75), 34 % (p90) — so a slope zeroing at 20 % put a ROUTINE night at the bottom of the scale.
    /// HRV is simply that volatile; that is a fact about the signal, not about the day.
    ///
    /// Resting heart rate is a different signal and keeps the tighter slope. It genuinely varies far
    /// less night to night — the same nights that swung HRV 34 % moved RHR by a handful of bpm — so
    /// widening it too would have flattened a signal that carries real information when it does move.
    /// One constant for both was the actual bug; the fix is per-signal, not merely bigger.
    public static let hrvDownsideTolerance = 0.40
    public static let restingHrDownsideTolerance = 0.20
    /// The default for any other baseline-scored signal, unchanged from the original.
    public static let defaultDownsideTolerance = 0.20

    /// Score a signal against the wearer's own baseline.
    ///
    /// `downsideTolerance` is the fractional shortfall that scores zero — see the constants above for
    /// why it is per-signal. The UPSIDE stays at +10 % for full marks: beating your own baseline by a
    /// tenth is a genuinely good day for any of these signals, and the asymmetry is deliberate rather
    /// than an oversight (a bad night should be recoverable; a great one should be reachable).
    public static func baselineAchievement(ratio: Double, higherIsBetter: Bool,
                                           downsideTolerance: Double = defaultDownsideTolerance) -> Double {
        // Non-finite is BAD DATA, not a perfect day: an infinite ratio would otherwise sail through
        // the improvement branch below and score full marks off a divide-by-almost-zero baseline.
        guard ratio.isFinite, ratio > 0 else { return 0 }
        // A zero or negative tolerance would divide by zero (or invert the slope). Fall back rather
        // than produce a score nobody could explain.
        let tolerance = downsideTolerance > 0 ? downsideTolerance : defaultDownsideTolerance
        // Express every signal as "fractional improvement", so one formula serves both directions.
        let improvement = higherIsBetter ? (ratio - 1) : (1 - ratio)
        // 0.0 → 0.75, +0.10 → 1.0, −tolerance → 0.0
        if improvement >= 0 {
            return min(1.0, 0.75 + (improvement / 0.10) * 0.25)
        }
        return max(0.0, 0.75 + (improvement / tolerance) * 0.75)
    }

    /// How demanding the day's targets were, relative to the wearer's own recent average.
    ///
    /// Uses the EFFORT target as the proxy for the whole day's ask: it is the target that actually
    /// swings with charge (steps and calories move far less), so it is the one that makes an easy
    /// day easy. Clamped to ±15% at full strength, then scaled by `strength`, so this can nudge a
    /// score but never dominate it — a rest day should read as a rest day, not a failure.
    public static func loadFactor(input: DayInput, strength: Double) -> Double {
        guard strength > 0,
              let target = input.effortTarget.map(Double.init), target > 0,
              let recent = input.recentAvgEffortTarget, recent > 0 else { return 1.0 }
        let ratio = min(1.15, max(0.85, target / recent))
        return 1.0 + (ratio - 1.0) * min(max(strength, 0), 1)
    }

    /// A short, plain-language band for the number — the headline the Trends card leads with.
    /// Deliberately not judgemental at the low end: a bad day is information, not a verdict.
    /// Re-banded for the signed scale (260908). Zero is a sedentary day with a normal night, so the
    /// bands have to place it as exactly that — unremarkable, neither good nor bad — rather than at the
    /// bottom of a 0–100 ramp where it used to sit around 58.
    ///
    /// Deliberately not judgemental at the low end, and now with the room to be accurate at it: a
    /// negative day is one the body or the day genuinely went backwards on, which the old scale could
    /// not say at all.
    public static func band(_ total: Int) -> String {
        switch total {
        case 80...: return "Excellent"
        case 55..<80: return "Strong"
        case 30..<55: return "Solid"
        case 10..<30: return "Steady"
        case -10..<10: return "Flat"
        case -40..<(-10): return "Mixed"
        default: return "Depleted"
        }
    }
}
