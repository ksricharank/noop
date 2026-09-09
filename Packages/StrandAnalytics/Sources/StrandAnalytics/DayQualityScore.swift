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

    // MARK: - The signed scale (−100…+100)

    /// Where a component sits when the day was UNREMARKABLE for it — the point that earns zero credit.
    ///
    /// 260908, maintainer's ask: "a sedentary day with no exercise and normal sleep should be a 0, a good
    /// day should start rising and go up to a 100, a poor day should go down to −100". The old 0–100 scale
    /// could not express that: it had no negative half at all, and its own arithmetic overflowed the top
    /// (a merely good day already summed to 103 and was clamped, so real range was being thrown away —
    /// the ceiling problem the HRV recalibration note warned about, applied to the total).
    ///
    /// The fix is to score each component as SIGNED CREDIT against a neutral point rather than as a
    /// fraction of a maximum. Hitting a target is neutral, not full marks; beating it earns credit up to
    /// the overshoot cap; missing it costs credit down to zero output. Nothing about the per-component
    /// achievement math changes — `overshootCap`, the per-signal downside tolerances and the absent-is-not-
    /// zero rule all behave exactly as before. Only the mapping from achievement to POINTS is new.
    ///
    /// The ratio components (steps, calories, effort, water, sleep) are neutral AT TARGET: 1.0.
    /// The baseline-scored signals (HRV, resting HR) are neutral AT BASELINE, which
    /// `baselineAchievement` already places at 0.75 — so they need no new constant, and the "normal is
    /// genuinely good but must not be full marks" reasoning behind that 0.75 is what makes it the right
    /// neutral point rather than a coincidence.
    public static let ratioNeutral = 1.0
    public static let baselineNeutral = 0.75

    /// One component's contribution as signed credit: −1 at zero output, 0 at neutral, and at most
    /// `(cap − neutral) / neutral` above it.
    ///
    /// **The upside is deliberately NOT normalised to +1.** Both directions are measured in the same
    /// units — fractions of the neutral value — so beating a target by the full overshoot allowance
    /// (25 % at the default cap) is worth 0.25 while skipping a component entirely costs 1.0. That 4:1
    /// asymmetry IS the anti-gaming property: one runaway metric cannot cover a component that scored
    /// zero, because its extra credit is worth a quarter of what the miss costs.
    ///
    /// Normalising the upside to +1 (the first version of this) silently destroyed that: a 40 000-step
    /// day with no workout scored identically to a day that hit every target, because +1 and −1
    /// cancelled exactly. The old scale's own bound came from the same 0.25-vs-1.0 spread, so keeping
    /// the units shared is what preserves it rather than a separate rule —
    /// `testOvershootIsBoundedSoItCannotCoverASkippedComponent` is the test that caught it.
    public static func signedCredit(achieved: Double, neutral: Double, cap: Double) -> Double {
        guard neutral > 0 else { return 0 }
        let capped = min(achieved, cap)
        return max(-1.0, (capped - neutral) / neutral)
    }

    /// The raw signed sum for the three reference days, used to place the published scale.
    ///
    /// These are the anchors the maintainer named, and they are computed from the SCORER rather than
    /// written down as literals — so a change to a weight or a tolerance moves them automatically and the
    /// published scale keeps meaning what it says. Deriving them beats hardcoding for exactly the reason
    /// the steps explainer had to be rewritten: a named constant that silently stops matching the code it
    /// describes is worse than no constant at all.
    ///
    /// `neutralDay` is the sedentary anchor: no exercise, incidental movement only, water target met, a
    /// normal night (7 h against an 8 h need) and both autonomic signals at baseline. It maps to 0.
    /// `bestDay` (everything past the cap) maps to +100 and `worstDay` (nothing done, both signals deep
    /// below baseline) to −100.
    /// The raw signed sum for one input — `executionPoints + recoveryPoints`, before the published
    /// scale is applied. This is the quantity the anchors are expressed in.
    ///
    /// Computed by running the ordinary scorer and reading its two unscaled halves, so there is exactly
    /// ONE assembly of the components and the anchors cannot drift from the day they are anchoring.
    /// `score` returning nil (an input below `minimumComponents`) yields 0, which only the reference
    /// inputs could trigger and all three are complete by construction.
    public static func rawSigned(_ input: DayInput, config: Config = .default) -> Double {
        // applyNeutralOffset: false — an anchor is an offset-FREE sum by definition, and asking for the
        // offset here would require the anchors that are being defined.
        guard let s = scoreUnscaled(input, config: config, applyNeutralOffset: false) else { return 0 }
        return s.executionPoints + s.recoveryPoints
    }

    /// The three anchors, derived from the scorer rather than written down. `static let` would capture
    /// them at first use; computed properties keep them honest if a weight or tolerance ever changes.
    static var neutralDayRaw: Double { rawSigned(referenceNeutralDay) }
    static var bestDayRaw: Double { rawSigned(referenceBestDay) }
    static var worstDayRaw: Double { rawSigned(referenceWorstDay) }

    /// The sedentary day the maintainer defined as zero (260908). Steps/calories/effort at the level a
    /// day with no deliberate activity actually reaches, water target met, 7 h of an 8 h need, both
    /// autonomic signals exactly at baseline.
    ///
    /// The anchor is deliberately not knife-edged on these numbers: across sleep needs from 7 h to 9 h it
    /// moves ±2 points, and across a plausible span of "no activity" (steps 15–40 % of target) ±6. That
    /// robustness is why a single fixed anchor is honest here rather than a fitted constant.
    public static let referenceNeutralDay = DayInput(
        steps: 1600, stepsTarget: 6400, kcal: 700, kcalTarget: 2000, effort: 2, effortTarget: 40,
        waterCups: 8, waterTargetCups: 8, sleepMin: 420, sleepNeedMin: 480,
        hrv: 40, hrvBaseline: 40, restingHr: 60, restingHrBaseline: 60)
    /// Every component past its cap and both signals clearly above baseline — the +100 end.
    public static let referenceBestDay = DayInput(
        steps: 16000, stepsTarget: 6400, kcal: 4000, kcalTarget: 2000, effort: 80, effortTarget: 40,
        waterCups: 16, waterTargetCups: 8, sleepMin: 960, sleepNeedMin: 480,
        hrv: 60, hrvBaseline: 40, restingHr: 30, restingHrBaseline: 60)
    /// Nothing done and both signals deep below baseline — the −100 end.
    public static let referenceWorstDay = DayInput(
        steps: 0, stepsTarget: 6400, kcal: 0, kcalTarget: 2000, effort: 0, effortTarget: 40,
        waterCups: 0, waterTargetCups: 8, sleepMin: 0, sleepNeedMin: 480,
        hrv: 12, hrvBaseline: 40, restingHr: 96, restingHrBaseline: 60)

    /// Per-component share of the origin shift, in raw signed-credit points.
    ///
    /// The sedentary anchor is not at zero raw credit — a day with no deliberate activity misses its
    /// execution targets, so its raw sum is about −37. Moving the published origin there means adding a
    /// constant. That constant is folded into EACH component (spread by its weight, so a component that
    /// can move the score more carries more of the shift) rather than added to the total, which is what
    /// lets the published scale be a pure multiplier and keeps the breakdown panel reconciling with the
    /// headline. Adding it to the sum instead would leave the rows summing to a number the screen never
    /// shows — and would zero every row on a target-met day, whose raw sum is exactly 0.
    static func neutralOffset(weight: Double) -> Double {
        // `weight` is already the component's share of 100, so dividing by 100 turns the whole-day shift
        // into this component's part of it.
        -neutralDayRaw * (weight / 100)
    }

    /// The multiplier that maps offset raw credit onto −100…+100.
    ///
    /// Two slopes, one per side of the origin, because the raw distances to the best and worst days are
    /// not equal — that asymmetry is what lets both ends land exactly at ±100 without distorting the
    /// middle, and it is the reason a single bias term cannot do this job (a bias that puts the sedentary
    /// day at 0 leaves the worst possible day at −63, so −100 becomes unreachable). Same
    /// piecewise-linear-through-anchors technique as `stepsBaseForCharge`.
    ///
    /// The clamp lives here too: past either anchor the factor shrinks so the product stops at ±100,
    /// which keeps `total`, the halves and every row clamped consistently instead of only the headline.
    static func publishedFactor(rawSigned raw: Double) -> Double {
        guard raw != 0 else { return 0 }
        let span = raw > 0 ? (bestDayRaw - neutralDayRaw) : (neutralDayRaw - worstDayRaw)
        guard span > 0 else { return 0 }
        let unclamped = 100 / span
        // Stop at the anchor rather than running past it.
        let magnitude = abs(raw * unclamped)
        return magnitude > 100 ? (100 / abs(raw)) : unclamped
    }

    /// The lowest and highest values `score(...)` can publish. UI that draws a scale reads these rather
    /// than assuming 0…100 (which is what `ScoreTrendSection`/`band` used to do).
    public static let publishedMinimum = -100
    public static let publishedMaximum = 100

    // MARK: - Scoring

    /// Score one day, or nil when too little of it was recorded (see `minimumComponents`).
    /// Score one day and publish it on the −100…+100 scale, or nil when too little of it was recorded.
    ///
    /// Thin wrapper over `scoreUnscaled`: the component assembly, the renormalisation and the signed
    /// credit all happen there, and this applies `publishedScale` to the result. The split is what keeps
    /// the anchors from recursing — `rawSigned` calls `scoreUnscaled`, which never consults the scale.
    public static func score(_ input: DayInput, config: Config = .default) -> DayQualityScore? {
        guard let s = scoreUnscaled(input, config: config) else { return nil }
        // Publish by scaling the parts, not the sum — the breakdown panel restates the arithmetic, so
        // the components and the two halves must add up to the HEADLINE rather than to the raw signed sum
        // the headline was derived from.
        //
        // This works because the origin shift is folded into each component BEFORE summing (see
        // `neutralOffset`): every part already carries its own share of the sedentary anchor, so the
        // published scale is a single MULTIPLIER on the parts and the sum of scaled parts is exactly the
        // scaled sum. One factor, applied uniformly, sign and reconciliation both preserved — no
        // apportionment scheme, and nothing for the panel and the headline to disagree about.
        let raw = s.executionPoints + s.recoveryPoints
        let factor = Self.publishedFactor(rawSigned: raw)
        let scaled = s.components.map {
            Component(label: $0.label, achieved: $0.achieved, weight: $0.weight * factor,
                      points: $0.points * factor, detail: $0.detail)
        }
        return DayQualityScore(
            total: Int((raw * factor).rounded()),
            executionPoints: s.executionPoints * factor, recoveryPoints: s.recoveryPoints * factor,
            components: scaled, loadFactor: s.loadFactor, missing: s.missing)
    }

    /// The scorer proper: components, renormalisation and signed credit, with `total` left as the raw
    /// signed sum rounded. Internal because the published number is what callers want; exposed to tests
    /// so the arithmetic can be pinned without the scale on top.
    /// `applyNeutralOffset` is what breaks the recursion the anchors would otherwise cause: the anchors
    /// are DEFINED as offset-free raw sums, and folding the offset in requires knowing them. Callers
    /// scoring a real day pass true; `rawSigned` (which the anchors use) passes false.
    static func scoreUnscaled(_ input: DayInput, config: Config = .default,
                              applyNeutralOffset: Bool = true) -> DayQualityScore? {
        var execution: [(Component, Double)] = []   // (component, raw weight)
        // (component, raw weight, neutral, cap) — the yardstick travels WITH the component rather than
        // being re-derived from its label downstream. A label compare would be exactly the scattered
        // string match the device-family rule warns about: it silently misses when a label is
        // localised or reworded, and the failure mode is a wrong score rather than a crash.
        var recovery: [(Component, Double, Double, Double)] = []
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
                ), config.sleepWeight, ratioNeutral, config.overshootCap))
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
                ), config.hrvWeight, baselineNeutral, 1.0))
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
                ), config.restingHrWeight, baselineNeutral, 1.0))
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

        // Points are SIGNED CREDIT against each component's neutral point (260908) — hitting a target
        // contributes 0, not full marks. `weight` stays the component's full share of its half, so it
        // still reads as "this component can move the score by up to ±N", which is what the breakdown
        // panel needs to explain the arithmetic.
        let execWeightTotal = execution.reduce(0) { $0 + $1.1 }
        for (c, w) in execution {
            let weight = execShare * 100 * (w / execWeightTotal)
            // The load factor lands on the execution half only: recovery is not something the day's
            // targets made easier or harder. It scales the CREDIT, so a hard day's overshoot is worth
            // more and a hard day's shortfall costs more — both directions, which is the honest
            // reading of "these targets were more demanding".
            let credit = signedCredit(achieved: c.achieved, neutral: ratioNeutral, cap: config.overshootCap)
            // The load factor is applied as an ADDITIVE tilt, not a multiplier on the credit (260908).
            //
            // Multiplying was correct on the old 0–100 scale, where meeting a target scored 1.0 and there
            // was always something to scale. On the signed scale meeting a target scores exactly ZERO
            // credit — so a multiplier left the feature completely inert: two days that both hit 100 % of
            // very different targets published the SAME number while correctly reporting load factors of
            // 1.075 and 0.925. The feature was silently dead, which is worse than absent, because the
            // load factor still appeared in the breakdown as though it had done something.
            //
            // A tilt proportional to how demanding the day was fixes it in the right direction: matching a
            // hard day earns credit, matching an easy one gives some back, and a day at its own recent
            // average is untouched (loadFactor 1.0 ⇒ zero tilt). It stays mild for the same reason the
            // multiplier did — the factor is clamped to ±15 % and halved at default strength — so a rest
            // day still reads as a rest day.
            let tilt = loadFactor - 1.0
            let points = weight * (credit + tilt)
                + (applyNeutralOffset ? neutralOffset(weight: weight) : 0)
            execPoints += points
            out.append(Component(label: c.label, achieved: c.achieved, weight: weight,
                                 points: points, detail: c.detail))
        }
        let recWeightTotal = recovery.reduce(0) { $0 + $1.1 }
        for (c, w, neutral, cap) in recovery {
            let weight = recShare * 100 * (w / recWeightTotal)
            // Sleep is a ratio component living in the recovery half (neutral at target, overshoot
            // allowed); HRV and resting HR are baseline-scored (neutral at 0.75, ceiling 1.0). Both
            // yardsticks arrived with the component, so re-partitioning the halves cannot silently
            // swap them.
            let credit = signedCredit(achieved: c.achieved, neutral: neutral, cap: cap)
            let points = weight * credit + (applyNeutralOffset ? neutralOffset(weight: weight) : 0)
            recPoints += points
            out.append(Component(label: c.label, achieved: c.achieved, weight: weight,
                                 points: points, detail: c.detail))
        }

        let total = Int((execPoints + recPoints).rounded())
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
