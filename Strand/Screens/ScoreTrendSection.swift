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
            heatStrip
        }
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
