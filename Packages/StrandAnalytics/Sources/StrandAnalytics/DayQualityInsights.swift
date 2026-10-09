import Foundation

/// Three reads on a day-quality series the score itself cannot give (260908).
///
/// The Day tab showed the score, the arithmetic behind it and the coach's narrative — and then stopped.
/// What it could not answer is the set of questions a wearer actually asks of a number they see daily:
/// which of the seven components is dragging me, what would move it next, and am I being consistent.
///
/// All three are computed from data already stored — the scored series and the per-day component
/// breakdowns — so none of this adds a measurement or a background cost. Pure and database-free, in
/// `StrandAnalytics` so `swift test` covers it with no app, no strap and no CoreBluetooth.
///
/// Deliberately NOT a prediction. Nothing here forecasts tomorrow's score: the correlation between a
/// day's score and the next day's recovery is unvalidated for any individual, and a downstream gate on
/// thin evidence is exactly what the PPG→HR withdrawal (#194) was about. These three restate what
/// happened and price what is already within reach; both are arithmetic on observed values.
public enum DayQualityInsights {

    // MARK: - Attribution: what actually moved the score

    /// One component's contribution across a window, in published points.
    public struct Attribution: Equatable, Sendable {
        public let label: String
        /// Mean points this component contributed per scored day — signed, so a drag reads negative.
        public let meanPoints: Double
        /// How many days contributed (a component absent on some days is averaged over the days it
        /// appeared, never scored as zero on the others — the absent-is-not-zero rule).
        public let days: Int
        /// Mean achievement 0…cap, for the evidence line.
        public let meanAchieved: Double

        public init(label: String, meanPoints: Double, days: Int, meanAchieved: Double) {
            self.label = label
            self.meanPoints = meanPoints
            self.days = days
            self.meanAchieved = meanAchieved
        }
    }

    /// Rank each component by its mean signed contribution over the window, best first.
    ///
    /// The point of ranking by POINTS rather than by achievement is that points already carry the
    /// component's weight: a 60 %-achieved sleep matters more than a 60 %-achieved water, and a ranking
    /// on achievement alone would hide that. The caller supplies the per-day breakdowns it already has.
    ///
    /// Components are averaged over the days they were PRESENT. Averaging over the whole window instead
    /// would quietly punish a component the strap could not measure, which is the same mistake as
    /// scoring an unrecorded night as zero.
    public static func attribution(breakdowns: [DayQualityScore]) -> [Attribution] {
        guard !breakdowns.isEmpty else { return [] }
        var pointsByLabel: [String: (points: Double, achieved: Double, days: Int)] = [:]
        // Insertion order of first appearance, so ties rank stably rather than by dictionary order.
        var order: [String] = []
        for day in breakdowns {
            for c in day.components {
                if pointsByLabel[c.label] == nil { order.append(c.label) }
                var acc = pointsByLabel[c.label] ?? (0, 0, 0)
                acc.points += c.points
                acc.achieved += c.achieved
                acc.days += 1
                pointsByLabel[c.label] = acc
            }
        }
        return order.compactMap { label -> Attribution? in
            guard let acc = pointsByLabel[label], acc.days > 0 else { return nil }
            return Attribution(label: label,
                               meanPoints: acc.points / Double(acc.days),
                               days: acc.days,
                               meanAchieved: acc.achieved / Double(acc.days))
        }
        // Descending by contribution: the strongest first, the biggest drag last, which is where the
        // reader's attention should land.
        .sorted { $0.meanPoints > $1.meanPoints }
    }

    /// The single biggest drag, when there is one worth naming — the most negative contributor.
    /// Nil when every component is contributing positively (a genuinely good stretch has no drag, and
    /// inventing one would be noise).
    public static func biggestDrag(breakdowns: [DayQualityScore]) -> Attribution? {
        attribution(breakdowns: breakdowns).last.flatMap { $0.meanPoints < 0 ? $0 : nil }
    }

    // MARK: - Counterfactual: what is closest to hand

    /// "N more of this would be worth M points."
    public struct Counterfactual: Equatable, Sendable {
        public let label: String
        /// Points the day would gain by reaching this component's next meaningful step.
        public let pointsGained: Double
        /// How much more of the component's own unit is needed (steps, kcal, cups, minutes).
        public let shortfall: Double
        /// The component's target, for the evidence line.
        public let target: Double

        public init(label: String, pointsGained: Double, shortfall: Double, target: Double) {
            self.label = label
            self.pointsGained = pointsGained
            self.shortfall = shortfall
            self.target = target
        }
    }

    /// What closing each unmet component's gap to TARGET would be worth, richest first.
    ///
    /// Exact arithmetic, not a model: the scorer's own weight and the signed-credit slope give the
    /// marginal value of a component directly. Only components genuinely short of target appear —
    /// something already met has no gap to close, and inventing an overshoot suggestion would turn the
    /// card into a nag rather than information.
    ///
    /// `publishedFactor` is applied so the numbers are in the SAME points the headline shows. Quoting
    /// raw credit here would be the "reconciles against a number the screen never shows" mistake in a
    /// second place.
    public static func counterfactuals(for score: DayQualityScore,
                                       actuals: [String: Double],
                                       targets: [String: Double],
                                       normals: [String: Double],
                                       config: DayQualityScore.Config = .default) -> [Counterfactual] {
        score.components.compactMap { c -> Counterfactual? in
            guard let actual = actuals[c.label], let target = targets[c.label], target > 0 else { return nil }
            guard actual < target else { return nil }
            guard let normal = normals[c.label] else { return nil }
            // The gain is simply the difference between this component's points AT TARGET (which is its
            // full weight, by the definition of the scale) and its points now. Exact arithmetic on the
            // scorer's own ramp — no factor, no re-derivation, and directly comparable with the headline
            // because every component's points are already published points.
            let atTarget = DayQualityScore.componentPoints(actual: target, normal: normal,
                                                           target: target, weight: c.weight)
            let gain = atTarget - c.points
            guard gain > 0 else { return nil }
            return Counterfactual(label: c.label, pointsGained: gain,
                                  shortfall: target - actual, target: target)
        }
        .sorted { $0.pointsGained > $1.pointsGained }
    }

    // MARK: - Consistency

    /// Days above zero, and the run in progress.
    public struct Consistency: Equatable, Sendable {
        /// Scored days at or above zero.
        public let positiveDays: Int
        /// Scored days in the window.
        public let totalDays: Int
        /// The current unbroken run of non-negative days, counting back from the most recent.
        public let currentStreak: Int
        /// The longest such run anywhere in the window.
        public let longestStreak: Int

        public init(positiveDays: Int, totalDays: Int, currentStreak: Int, longestStreak: Int) {
            self.positiveDays = positiveDays
            self.totalDays = totalDays
            self.currentStreak = currentStreak
            self.longestStreak = longestStreak
        }

        /// Share of scored days that were not negative, 0…1. Nil when nothing is scored.
        public var positiveShare: Double? {
            totalDays > 0 ? Double(positiveDays) / Double(totalDays) : nil
        }
    }

    /// Consistency over a day-keyed series.
    ///
    /// "Days above zero" only became a meaningful statistic when zero became the sedentary anchor: on
    /// the old 0–100 scale every day was above zero, so the count was the day count. That is why this
    /// ships with the rescale rather than before it.
    ///
    /// Streaks run over SCORED days in date order, not calendar days — an unscored day (the strap was
    /// off) neither extends nor breaks a run, because it is an absence of evidence rather than a bad
    /// day. Treating a gap as a break would let a missing night silently destroy a real streak.
    public static func consistency(valuesByDay: [String: Double]) -> Consistency {
        let ordered = valuesByDay.keys.sorted().compactMap { valuesByDay[$0] }
        guard !ordered.isEmpty else { return Consistency(positiveDays: 0, totalDays: 0, currentStreak: 0, longestStreak: 0) }
        let positive = ordered.filter { $0 >= 0 }.count
        var longest = 0
        var run = 0
        for v in ordered {
            if v >= 0 { run += 1; longest = max(longest, run) } else { run = 0 }
        }
        // The current streak is the trailing run, which `run` already holds after the walk.
        return Consistency(positiveDays: positive, totalDays: ordered.count,
                           currentStreak: run, longestStreak: longest)
    }
}
