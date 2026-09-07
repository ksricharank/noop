import SwiftUI
import StrandDesign

/// The trend block a per-metric tab shows beneath its detail: window selector, chart, comparison
/// footer, a calendar heat strip, and a period digest.
///
/// 260906, maintainer: "thoroughly review the trends tab and copy the best of the trends type
/// features into day quality tab… Do the same thing wrt trends on sleep in the dedicated sleep tab".
/// Written once here rather than twice, so the two tabs cannot drift in how they compute or label a
/// comparison — the exact class of divergence that produced the "vs prev 7" defect below.
///
/// ## The comparison the footer makes
///
/// The old footer hard-coded "Last 7 / vs prev 7" regardless of the selected window. That was wrong
/// twice over: with 13 stored days the "prev 7" bucket actually held SIX days while still claiming
/// seven, and because both halves were fixed at 7 the figure was identical at 14d, 30d and 90d — the
/// window selector visibly did nothing to it.
///
/// Here the comparison scales with the window (half the window per half, so 30d compares 15 vs 15),
/// the label states the REAL bucket size, and the delta is suppressed entirely unless both halves
/// are full. A comparison between a 7-day mean and a 6-day mean is not a like-for-like figure, and
/// printing it as one is how a trend gets misread.
struct ScoreTrendSection: View {

    /// One selectable window.
    struct Window: Identifiable, Hashable {
        let days: Int
        let label: String
        var id: Int { days }
    }

    let title: LocalizedStringKey
    /// Day key ("yyyy-MM-dd") → value. The stored series, so the chart and the detail agree.
    let valuesByDay: [String: Double]
    let windows: [Window]
    @Binding var window: Window
    /// The value scale the gradient is anchored to, and the axis ceiling.
    var valueRange: ClosedRange<Double> = 0...106
    /// Formats a value for the footer and the heat-strip tooltip.
    var format: (Double) -> String = { "\(Int($0.rounded()))" }
    /// Shown under the heat strip's gradient, naming the two ends of the scale.
    var lowLabel: LocalizedStringKey = "Low"
    var highLabel: LocalizedStringKey = "High"

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
            SegmentedPillControl(windows, selection: $window,
                                 adaptsToAvailableWidth: true) { $0.label }
            chart
            weekInReview
            heatStrip
        }
    }

    // MARK: - Week in review

    /// The Trends page's "Week in review", for one metric.
    ///
    /// 260906, maintainer: "can you add a week in review for day quality and sleep like how the
    /// trends page has?" Same visual language as `TrendsView.pipScoreRow` — the liquid vessel, the
    /// count-up number and the pip bar — so the three surfaces read as one idea rather than three
    /// dialects of it.
    ///
    /// Three rows instead of Trends' Charge/Effort/Rest trio, because there is only one metric here:
    /// this week, the week before, and the change. That is the comparison the card is for, and it is
    /// the same like-for-like arithmetic the chart footer uses (`comparison`), so the two cannot
    /// disagree about a delta on the same screen.
    ///
    /// Self-hides unless BOTH weeks are complete. A "this week vs last week" card that quietly
    /// compared seven days against three would be the defect this file was written to fix, in a new
    /// place.
    @ViewBuilder
    private var weekInReview: some View {
        if let week = weekComparison {
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                    SectionHeader("Week in review", overline: "This week vs last")
                    pipRow(label: "This week", value: week.recent)
                    pipRow(label: "Last week", value: week.prior)
                    deltaRow(week.recent - week.prior)
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    /// Always seven days a side, whatever the chart's window is showing.
    ///
    /// Deliberately NOT `comparison`, which scales with the selected window (15 vs 15 at 30d). A card
    /// titled "Week in review" must mean a week — reading 15 days under that heading because the
    /// picker moved would be the same class of mislabelling as the "prev 7" bug.
    private var weekComparison: (recent: Double, prior: Double)? {
        // Ask over a 14-day window so exactly two weeks are in scope regardless of the selection.
        guard let c = Self.comparison(valuesByDay: valuesByDay, windowDays: 14) else { return nil }
        return (c.recent, c.prior)
    }

    /// One pip row, matching `TrendsView.pipScoreRow`'s layout.
    private func pipRow(label: LocalizedStringKey, value: Double) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text(label)
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .textCase(.uppercase)
                .foregroundStyle(StrandPalette.textSecondary)
            HStack(spacing: NoopMetrics.space3) {
                // Static (posed) vessel, as on Trends: a cached frame each, not a live canvas.
                LiquidVessel(value: fill(value), tint: StrandPalette.chargeColor, animated: false)
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)
                CountUpText(value: value, format: format,
                            font: StrandFont.number(30, weight: .bold),
                            color: StrandPalette.textPrimary)
            }
            PipBar(value: value, range: valueRange.lowerBound...min(valueRange.upperBound, 100),
                   tint: StrandPalette.chargeColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(format(value)))
    }

    /// The change, signed and coloured by direction — the thing the card exists to show.
    private func deltaRow(_ delta: Double) -> some View {
        let up = delta.rounded() > 0
        let flat = delta.rounded() == 0
        return HStack(spacing: NoopMetrics.space2) {
            Image(systemName: flat ? "equal" : (up ? "arrow.up.right" : "arrow.down.right"))
                .font(StrandFont.footnote)
            Text(flat ? String(localized: "No change")
                      : String(localized: "\(signed(delta)) vs last week"))
                .font(StrandFont.footnote)
        }
        // Neutral for flat, and the domain colours otherwise. Not red-for-down: a quieter week is
        // not a failure, and the palette should not scold.
        .foregroundStyle(flat ? StrandPalette.textTertiary
                              : (up ? StrandPalette.chargeColor : StrandPalette.textSecondary))
        .accessibilityElement(children: .combine)
    }

    /// The vessel fill, 0…1 on the metric's own scale.
    private func fill(_ value: Double) -> Double {
        let span = min(valueRange.upperBound, 100) - valueRange.lowerBound
        guard span > 0 else { return 0 }
        return max(0, min(1, (value - valueRange.lowerBound) / span))
    }

    // MARK: - Points

    /// The series inside the window, oldest first.
    private var points: [TrendPoint] { Self.points(valuesByDay: valuesByDay, windowDays: window.days) }

    /// Pure, so the windowing is testable without standing up a view.
    static func points(valuesByDay: [String: Double], windowDays: Int) -> [TrendPoint] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -windowDays, to: Date())
        return valuesByDay.keys.sorted().compactMap { key in
            guard let date = parser.date(from: key), let v = valuesByDay[key] else { return nil }
            if let cutoff, date < cutoff { return nil }
            return TrendPoint(date: date, value: v, segment: "score")
        }
    }

    /// (recent mean, prior mean, bucket size) — nil unless BOTH halves are full.
    ///
    /// Each half is HALF THE WINDOW, so the comparison scales with what is on screen: 14d compares 7
    /// vs 7, 30d compares 15 vs 15. Capped at 30 so a 90-day view compares months rather than
    /// half-quarters, which no longer reads as "recently".
    ///
    /// Nil unless both buckets are full. That is the fix for the reported defect: with 13 stored days
    /// the old code compared a 7-day mean against a 6-day one and labelled the result "vs prev 7". A
    /// partial bucket is not a like-for-like comparison, and the honest move is to withhold the
    /// figure rather than dress it up.
    static func comparison(valuesByDay: [String: Double],
                           windowDays: Int) -> (recent: Double, prior: Double, n: Int)? {
        let n = min(windowDays / 2, 30)
        guard n >= 2 else { return nil }
        let values = points(valuesByDay: valuesByDay, windowDays: windowDays).map(\.value)
        guard values.count >= n * 2 else { return nil }
        let recent = values.suffix(n)
        let prior = values.dropLast(n).suffix(n)
        guard prior.count == n else { return nil }
        return (recent.reduce(0, +) / Double(n), prior.reduce(0, +) / Double(n), n)
    }

    private var comparison: (recent: Double, prior: Double, n: Int)? {
        Self.comparison(valuesByDay: valuesByDay, windowDays: window.days)
    }

    // MARK: - Chart

    @ViewBuilder
    private var chart: some View {
        let pts = points
        if pts.count >= 2 {
            let mean = pts.map(\.value).reduce(0, +) / Double(pts.count)
            ChartCard(
                title: title,
                subtitle: String(localized: "Last \(window.days) days"),
                trailing: format(mean),
                height: NoopMetrics.chartHeight,
                chart: {
                    TrendChart(points: pts,
                               gradient: StrandPalette.recoveryGradient,
                               valueRange: valueRange,
                               valueFormat: format,
                               accessibilityLabel: String(localized: "Trend"),
                               nowCapColor: StrandPalette.chargeBright)
                },
                footer: { footer(pts) })
            .accessibilityElement(children: .contain)
        } else {
            NoopCard {
                Text("Not enough scored days in this window to draw a trend yet.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Mean, the like-for-like delta, best, and the day count.
    ///
    /// The delta's label names the bucket size it actually used ("vs prev 7", "vs prev 15"), and the
    /// pair is omitted rather than shown as "—" when the window cannot support it — a dash invites
    /// the reader to wonder what went wrong, where absence of the row says the window is simply too
    /// short for the comparison.
    @ViewBuilder
    private func footer(_ pts: [TrendPoint]) -> some View {
        let values = pts.map(\.value)
        if let c = comparison {
            ChartFooter([
                (LocalizedStringKey("Last \(c.n)"), format(c.recent)),
                (LocalizedStringKey("vs prev \(c.n)"), signed(c.recent - c.prior)),
                ("Best", values.max().map(format) ?? "—"),
                ("Days", "\(pts.count)"),
            ])
        } else {
            ChartFooter([
                ("Mean", format(values.reduce(0, +) / Double(max(values.count, 1)))),
                ("Best", values.max().map(format) ?? "—"),
                ("Days", "\(pts.count)"),
            ])
        }
    }

    /// A signed delta, so the direction is unmissable — the thing the trend exists to show.
    ///
    /// Formats the MAGNITUDE through the caller's formatter and prefixes the sign, so a metric
    /// rendered as "7h30" reads "+0h15" rather than being run through a number formatter that knows
    /// nothing about its units.
    private func signed(_ delta: Double) -> String {
        let rounded = delta.rounded()
        guard rounded != 0 else { return format(0) }
        return (rounded > 0 ? "+" : "−") + format(abs(rounded))
    }

    // MARK: - Calendar heat strip

    /// The Trends page's year strip, pointed at this metric. A calendar view answers a question the
    /// line chart cannot — "how consistent has this been" — and reads streaks and gaps at a glance.
    @ViewBuilder
    private var heatStrip: some View {
        let days: [RecoveryDay] = valuesByDay.keys.sorted().compactMap { key in
            guard let d = Self.parser.date(from: key) else { return nil }
            return RecoveryDay(date: d, score: valuesByDay[key])
        }
        if !days.isEmpty {
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                    SectionHeader("Calendar", overline: "Every scored day",
                                  trailing: String(localized: "\(days.count) days"))
                    ScrollView(.horizontal, showsIndicators: false) {
                        YearHeatStrip(days: days, valueFormat: format)
                            .padding(.vertical, NoopMetrics.space1 / 2)
                    }
                    Divider().overlay(StrandPalette.hairline)
                    HStack(spacing: NoopMetrics.space2) {
                        Text(lowLabel).font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary).fixedSize()
                        LinearGradient(gradient: StrandPalette.recoveryGradient,
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(maxWidth: .infinity)
                            .frame(height: NoopMetrics.indicatorTrackHeight)
                            .clipShape(Capsule())
                            .accessibilityHidden(true)
                        Text(highLabel).font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary).fixedSize()
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private static let parser: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
}
