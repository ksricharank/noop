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
        /// Share of the score carried by the execution half, 0…1. Recovery takes the remainder.
        public var executionShare: Double {
            didSet { executionShare = min(max(executionShare, 0), 1) }
        }
        /// 0 disables the load factor; 1 applies it at full strength. Default 0.5 — enough to stop
        /// the deconditioning drift, not enough to punish a genuine rest day.
        public var loadFactorStrength: Double {
            didSet { loadFactorStrength = min(max(loadFactorStrength, 0), 1) }
        }

        /// Ceiling on a single execution component's achievement, ≥ 1.0. Default 1.25: beating a
        /// target by 25% or more earns the full bonus and nothing beyond.
        ///
        /// This is what lets a big day reach 100 without the score becoming gameable. The bound
        /// matters more than the bonus: with four equal execution components, one metric run to the
        /// cap adds at most 0.25/4 of the execution half — enough to reward a hard day, far too
        /// little to cover a component that scored zero. Set to 1.0 to restore a hard cap at target.
        public var overshootCap: Double {
            didSet { overshootCap = min(max(overshootCap, 1.0), 2.0) }
        }

        /// Relative weights WITHIN each half. They need not sum to anything in particular; each half
        /// normalises its own present components, which is also what makes rule 2 work.
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
            overshootCap: 1.25,
            stepsWeight: 1, calorieWeight: 1, effortWeight: 1, waterWeight: 1,
            // Sleep carries more than each autonomic signal: it is the one recovery input the wearer
            // has real agency over, and the two autonomic signals are correlated with each other.
            sleepWeight: 1.5, hrvWeight: 1.5, restingHrWeight: 1
        )

        public init(executionShare: Double, loadFactorStrength: Double,
                    overshootCap: Double = 1.25,
                    stepsWeight: Double, calorieWeight: Double, effortWeight: Double,
                    waterWeight: Double, sleepWeight: Double, hrvWeight: Double,
                    restingHrWeight: Double) {
            self.executionShare = min(max(executionShare, 0), 1)
            self.loadFactorStrength = min(max(loadFactorStrength, 0), 1)
            // Never below 1.0: a cap under target would mean hitting the target scored less than
            // full marks for it, which no configuration should be able to express.
            self.overshootCap = min(max(overshootCap, 1.0), 2.0)
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

    // MARK: - Scoring

    /// Score one day, or nil when too little of it was recorded (see `minimumComponents`).
    public static func score(_ input: DayInput, config: Config = .default) -> DayQualityScore? {
        var execution: [(Component, Double)] = []   // (component, raw weight)
        var recovery: [(Component, Double)] = []
        var missing: [String] = []

        // ---- Execution: ratio against the day's own target, capped at 1.0 ----

        func ratioComponent(_ label: String, actual: Double?, target: Double?, weight: Double,
                            detail: (Double, Double) -> String) -> (Component, Double)? {
            guard weight > 0 else { return nil }
            guard let actual, let target, target > 0 else { missing.append(label); return nil }
            let achieved = min(config.overshootCap, max(0, actual / target))
            return (Component(label: label, achieved: achieved, weight: 0, points: 0,
                              detail: detail(actual, target)), weight)
        }

        if let c = ratioComponent("Steps", actual: input.steps.map(Double.init),
                                  target: input.stepsTarget.map(Double.init),
                                  weight: config.stepsWeight,
                                  detail: { "\(Int($0)) of \(Int($1)) steps" }) { execution.append(c) }
        if let c = ratioComponent("Calories", actual: input.kcal.map(Double.init),
                                  target: input.kcalTarget.map(Double.init),
                                  weight: config.calorieWeight,
                                  detail: { "\(Int($0)) of \(Int($1)) kcal" }) { execution.append(c) }
        if let c = ratioComponent("Effort", actual: input.effort.map(Double.init),
                                  target: input.effortTarget.map(Double.init),
                                  weight: config.effortWeight,
                                  detail: { "\(Int($0)) of \(Int($1)) effort" }) { execution.append(c) }
        if let c = ratioComponent("Water", actual: input.waterCups.map(Double.init),
                                  target: input.waterTargetCups.map(Double.init),
                                  weight: config.waterWeight,
                                  detail: { "\(Int($0)) of \(Int($1)) cups" }) { execution.append(c) }

        // ---- Recovery ----

        // Sleep is a ratio like the execution items — it has an explicit target — but it belongs to
        // the recovery half because it is what the body was given, not what it was asked to do.
        if config.sleepWeight > 0 {
            if let slept = input.sleepMin, let need = input.sleepNeedMin, need > 0 {
                // Sleeping PAST the need earns the same bounded credit as beating an execution
                // target: an extra hour banked is a genuine recovery win, not a rounding error.
                let achieved = min(config.overshootCap, max(0, slept / Double(need)))
                recovery.append((Component(
                    label: "Sleep", achieved: achieved, weight: 0, points: 0,
                    detail: String(format: "%.1fh of %.1fh needed", slept / 60, Double(need) / 60)
                ), config.sleepWeight))
            } else {
                missing.append("Sleep")
            }
        }

        // HRV and resting HR score against the wearer's OWN baseline, not a population range: the
        // question is "was this a good day for me", and an absolute HRV number cannot answer that.
        //
        // A signal AT baseline scores 0.75 rather than 1.0, so there is headroom to reward a genuinely
        // strong day and room to fall. Full marks need a clear improvement on baseline.
        if config.hrvWeight > 0 {
            if let hrv = input.hrv, let base = input.hrvBaseline, base > 0 {
                let achieved = baselineAchievement(ratio: hrv / base, higherIsBetter: true,
                                                   downsideTolerance: hrvDownsideTolerance)
                recovery.append((Component(
                    label: "HRV", achieved: achieved, weight: 0, points: 0,
                    detail: String(format: "%.0f ms vs %.0f ms baseline", hrv, base)
                ), config.hrvWeight))
            } else {
                missing.append("HRV")
            }
        }
        if config.restingHrWeight > 0 {
            if let rhr = input.restingHr, let base = input.restingHrBaseline, base > 0 {
                let achieved = baselineAchievement(ratio: Double(rhr) / base, higherIsBetter: false,
                                                   downsideTolerance: restingHrDownsideTolerance)
                recovery.append((Component(
                    label: "Resting HR", achieved: achieved, weight: 0, points: 0,
                    detail: String(format: "%d bpm vs %.0f bpm baseline", rhr, base)
                ), config.restingHrWeight))
            } else {
                missing.append("Resting HR")
            }
        }

        guard execution.count + recovery.count >= minimumComponents else { return nil }

        // ---- Renormalise each half over what is PRESENT (rule 2) ----
        //
        // When a whole half is missing, its share goes to the other rather than being lost: a day
        // with no strap-scored night is still a real day of execution, and scoring it out of 60
        // would make it look like a failure. The `missing` list is what tells the reader.
        let execShare = recovery.isEmpty ? 1.0 : (execution.isEmpty ? 0.0 : config.executionShare)
        let recShare = execution.isEmpty ? 1.0 : (recovery.isEmpty ? 0.0 : 1 - config.executionShare)

        let loadFactor = loadFactor(input: input, strength: config.loadFactorStrength)

        var out: [Component] = []
        var execPoints = 0.0
        var recPoints = 0.0

        let execWeightTotal = execution.reduce(0) { $0 + $1.1 }
        for (c, w) in execution {
            let weight = execShare * 100 * (w / execWeightTotal)
            // The load factor lands on the execution half only: recovery is not something the day's
            // targets made easier or harder.
            let points = weight * c.achieved * loadFactor
            execPoints += points
            out.append(Component(label: c.label, achieved: c.achieved, weight: weight,
                                 points: points, detail: c.detail))
        }
        let recWeightTotal = recovery.reduce(0) { $0 + $1.1 }
        for (c, w) in recovery {
            let weight = recShare * 100 * (w / recWeightTotal)
            let points = weight * c.achieved
            recPoints += points
            out.append(Component(label: c.label, achieved: c.achieved, weight: weight,
                                 points: points, detail: c.detail))
        }

        let total = Int(min(100, max(0, execPoints + recPoints)).rounded())
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
    public static func band(_ total: Int) -> String {
        switch total {
        case 90...: return "Excellent"
        case 75..<90: return "Strong"
        case 60..<75: return "Solid"
        case 45..<60: return "Mixed"
        default: return "Light"
        }
    }
}
