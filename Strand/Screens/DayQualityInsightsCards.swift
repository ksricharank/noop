import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Insights (260908)

/// The three Insights cards below the coach narrative on the Day tab.
///
/// All three read `DayQualityInsights`, which is pure and lives in `StrandAnalytics` — these views hold
/// no arithmetic of their own beyond formatting, so the numbers are covered by `swift test` rather than
/// only by looking at the screen.
///
/// Presented as cards rather than notifications at the maintainer's request: the counterfactuals in
/// particular are information to consult, not a nag to be interrupted by.

/// **What moved the score** — every component ranked by its mean signed contribution over the window.
///
/// The card the tab was missing most. With seven components there was no way to see WHICH one was
/// dragging; the breakdown panel shows one day at a time, which cannot answer a question about a habit.
struct DayQualityAttributionCard: View {
    let breakdowns: [DayQualityScore]
    let windowLabel: String

    private var ranked: [DayQualityInsights.Attribution] {
        DayQualityInsights.attribution(breakdowns: breakdowns)
    }

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                SectionHeader("What moved the score", overline: "Insights",
                              trailing: breakdowns.isEmpty ? nil : windowLabel)
                if ranked.isEmpty {
                    Text("No scored days in this window yet.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(ranked, id: \.label) { row(for: $0) }
                    // Name the drag explicitly. The ranking already puts it last, but the reader should
                    // not have to infer the headline from a sort order.
                    if let drag = DayQualityInsights.biggestDrag(breakdowns: breakdowns) {
                        Divider().overlay(StrandPalette.hairline)
                        Text("\(drag.label) is costing you the most — about \(Self.points(abs(drag.meanPoints))) points a day.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// One component: its name, its mean contribution, and a bar showing the direction.
    private func row(for a: DayQualityInsights.Attribution) -> some View {
        let positive = a.meanPoints >= 0
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(alignment: .firstTextBaseline) {
                Text(a.label)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Text(Self.signedPoints(a.meanPoints))
                    .font(StrandFont.number(17, weight: .semibold))
                    .foregroundStyle(positive ? StrandPalette.chargeColor : StrandPalette.metricAmber)
                    .monospacedDigit()
            }
            // A signed bar: the magnitude of the contribution against the largest one present, so the
            // rows are comparable with each other rather than against an arbitrary ceiling.
            PipBar(value: abs(a.meanPoints), range: 0...max(1, maxMagnitude),
                   tint: positive ? StrandPalette.chargeColor : StrandPalette.metricAmber)
            // The evidence line, so the card never asks to be taken on trust.
            Text("\(Self.percent(a.meanAchieved)) of target on average · \(a.days) day\(a.days == 1 ? "" : "s")")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(a.label))
        .accessibilityValue(Text("\(Self.signedPoints(a.meanPoints)) points a day, "
                                 + "\(Self.percent(a.meanAchieved)) of target"))
    }

    private var maxMagnitude: Double {
        ranked.map { abs($0.meanPoints) }.max() ?? 1
    }

    private static func signedPoints(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r > 0 ? "+\(points(r))" : (r < 0 ? "−\(points(abs(r)))" : "0")
    }
    private static func points(_ v: Double) -> String {
        String(format: v < 10 ? "%.1f" : "%.0f", v)
    }
    private static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
}

/// **Closest gains** — what closing each unmet component's gap to target would be worth, today.
///
/// Exact arithmetic from the scorer's own weights, not a model. Only components genuinely short of
/// target appear: something already met has no gap, and suggesting an overshoot would turn the card
/// into a nag rather than information.
struct DayQualityCounterfactualCard: View {
    let score: DayQualityScore
    let actuals: [String: Double]
    let targets: [String: Double]
    let config: DayQualityScore.Config

    private var suggestions: [DayQualityInsights.Counterfactual] {
        DayQualityInsights.counterfactuals(for: score, actuals: actuals, targets: targets, config: config)
    }

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                SectionHeader("Closest gains", overline: "Insights")
                if suggestions.isEmpty {
                    // The honest empty state: everything measured was met. Not a failure to compute.
                    Text("Every measured target was met on this day — there was nothing left within reach.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(suggestions.prefix(3), id: \.label) { row(for: $0) }
                    Text("Worth what the scoring weights say, not an estimate — closing a gap to target earns exactly the points that component was short by.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func row(for c: DayQualityInsights.Counterfactual) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(c.label)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(Self.shortfallPhrase(label: c.label, shortfall: c.shortfall))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer()
            Text("+\(Int(c.pointsGained.rounded()))")
                .font(StrandFont.number(22, weight: .bold))
                .foregroundStyle(StrandPalette.chargeColor)
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(c.label))
        .accessibilityValue(Text("\(Self.shortfallPhrase(label: c.label, shortfall: c.shortfall)), "
                                 + "worth \(Int(c.pointsGained.rounded())) points"))
    }

    /// The gap in the component's OWN units. A bare number ("4000 more") is ambiguous across seven
    /// components measured in steps, calories, cups and minutes.
    static func shortfallPhrase(label: String, shortfall: Double) -> String {
        let n = Int(shortfall.rounded())
        switch label {
        case "Steps":    return String(localized: "\(n) more steps")
        case "Calories": return String(localized: "\(n) more kcal")
        case "Water":    return String(localized: "\(n) more cup\(n == 1 ? "" : "s")")
        case "Effort":   return String(localized: "\(n) more effort")
        case "Sleep":    return String(localized: "\(n) more minutes asleep")
        default:         return String(localized: "\(n) more")
        }
    }
}

/// **Consistency** — days above zero, and the run in progress.
///
/// Only meaningful since the rescale: on the old 0–100 scale every day was above zero, so the count was
/// just the day count. Zero being the sedentary anchor is what turns "above zero" into a real statement
/// about behaviour.
struct DayQualityStreakCard: View {
    let valuesByDay: [String: Double]
    let windowLabel: String

    private var c: DayQualityInsights.Consistency {
        DayQualityInsights.consistency(valuesByDay: valuesByDay)
    }

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                SectionHeader("Consistency", overline: "Insights",
                              trailing: c.totalDays == 0 ? nil : windowLabel)
                if c.totalDays == 0 {
                    Text("No scored days yet.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                } else {
                    HStack(alignment: .top, spacing: NoopMetrics.space4) {
                        stat(String(localized: "Current run"), c.currentStreak,
                             unit: String(localized: "day\(c.currentStreak == 1 ? "" : "s")"),
                             tint: c.currentStreak > 0 ? StrandPalette.effortColor : StrandPalette.textSecondary)
                        stat(String(localized: "Longest"), c.longestStreak,
                             unit: String(localized: "day\(c.longestStreak == 1 ? "" : "s")"),
                             tint: StrandPalette.chargeColor)
                        stat(String(localized: "Above zero"), c.positiveDays,
                             unit: String(localized: "of \(c.totalDays)"),
                             tint: StrandPalette.chargeBright)
                    }
                    if let share = c.positiveShare {
                        PipBar(value: share * 100, range: 0...100, tint: StrandPalette.chargeColor)
                        Text("\(Int((share * 100).rounded()))% of scored days landed at or above a normal day.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Say what a gap does, because the alternative reading is that a streak was lost.
                    Text("A day the strap did not score neither extends nor breaks a run.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func stat(_ label: String, _ value: Int, unit: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).strandOverline()
            Text("\(value)")
                .font(StrandFont.number(28, weight: .bold))
                .foregroundStyle(tint)
                .monospacedDigit()
            Text(unit)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text("\(value) \(unit)"))
    }
}
