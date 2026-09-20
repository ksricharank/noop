import SwiftUI
import Charts
import StrandDesign

// MARK: - The unified Trends card (260920)
//
// One card, the page's window, a configurable metric set, three ways to draw it. Replaces the whole
// Trends widget stack for a wearer who wants a single view — see `MultiMetricPrefs`.
//
// NON-INTERACTIVE by construction: no hover, no drag, no selection. The same scroll-capture that
// made the maintainer "get stuck on the widget" would be worse here, since this card is taller than
// any of the ones it replaces.
struct MultiMetricCard: View {
    /// Day-keyed series per metric. Assembled by the caller from the data the page already holds.
    let seriesByMetric: [MultiMetric: [String: Double]]
    /// Which metrics to draw, in order.
    let metrics: [MultiMetric]
    let style: MultiMetricStyle
    /// The window the page's selector is on, in days.
    let windowDays: Int
    /// Opens the metric/style picker.
    var onConfigure: (() -> Void)?

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                header
                if resolved.isEmpty {
                    Text("No data in this window yet.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                } else {
                    switch style {
                    case .overlay: overlayChart
                    case .rows:    rowStrips
                    case .heatmap: heatmapGrid
                    }
                    legend
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            SectionHeader("Metrics", overline: "Last \(windowDays) days",
                          trailing: style.title)
            if let onConfigure {
                Button(action: onConfigure) {
                    Label(String(localized: "Edit").uppercased(), systemImage: "slider.horizontal.3")
                        .font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking)
                }
                .buttonStyle(.plain)
                .foregroundStyle(StrandPalette.accent)
                .accessibilityLabel("Choose metrics and style")
            }
        }
    }

    // MARK: Resolved series

    /// One metric's windowed points, with the scaling facts every style needs computed once.
    struct Resolved: Identifiable {
        let metric: MultiMetric
        /// (day, value) oldest first.
        let points: [(day: String, value: Double)]
        let min: Double
        let max: Double
        let mean: Double
        var id: String { metric.rawValue }

        /// 0…1 within this metric's own observed range. A flat series sits at 0.5 rather than
        /// dividing by zero, which reads as "no movement" instead of pinning it to an edge.
        func normalized(_ v: Double) -> Double {
            let span = max - min
            return span > 0 ? (v - min) / span : 0.5
        }
    }

    /// Windowed, sorted and measured once per body — every style reads this rather than re-walking
    /// the dictionaries, which is the cost that made the old five-chart card slow.
    var resolved: [Resolved] {
        metrics.compactMap { metric in
            guard let series = seriesByMetric[metric], !series.isEmpty else { return nil }
            let sorted = series.keys.sorted().suffix(windowDays)
            let pts = sorted.compactMap { key -> (day: String, value: Double)? in
                series[key].map { (day: key, value: $0) }
            }
            guard pts.count >= 2 else { return nil }
            let vals = pts.map(\.value)
            return Resolved(metric: metric,
                            points: pts,
                            min: vals.min() ?? 0,
                            max: vals.max() ?? 1,
                            mean: vals.reduce(0, +) / Double(vals.count))
        }
    }

    /// Every day present in any selected metric, oldest first — the shared x-axis.
    private var allDays: [String] {
        Array(Set(resolved.flatMap { $0.points.map(\.day) })).sorted()
    }

    // MARK: Style 1 — normalized overlay

    private var overlayChart: some View {
        Chart {
            ForEach(resolved) { r in
                ForEach(r.points, id: \.day) { p in
                    LineMark(
                        x: .value("Day", p.day),
                        y: .value("Level", r.normalized(p.value))
                    )
                    .foregroundStyle(r.metric.color)
                    .interpolationMethod(.monotone)
                }
                .foregroundStyle(by: .value("Metric", r.metric.title))
            }
        }
        .chartForegroundStyleScale(domain: resolved.map(\.metric.title),
                                   range: resolved.map(\.metric.color))
        .chartLegend(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...1)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(StrandPalette.hairline)
            }
        }
        .frame(height: NoopMetrics.chartHeight)
        .accessibilityLabel(Text("Overlaid trend of \(resolved.count) metrics"))
    }

    // MARK: Style 2 — stacked rows

    private var rowStrips: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            ForEach(resolved) { r in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(r.metric.title.uppercased())
                            .font(StrandFont.overlineScaled(10))
                            .tracking(0.8)
                            .foregroundStyle(StrandPalette.textTertiary)
                        Spacer(minLength: 4)
                        Text(valueText(r, r.points.last?.value))
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .monospacedDigit()
                    }
                    Chart(r.points, id: \.day) { p in
                        AreaMark(x: .value("Day", p.day),
                                 y: .value(r.metric.title, p.value))
                            .foregroundStyle(r.metric.color.opacity(0.18))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Day", p.day),
                                 y: .value(r.metric.title, p.value))
                            .foregroundStyle(r.metric.color)
                            .interpolationMethod(.monotone)
                    }
                    .chartYScale(domain: r.min...(r.max > r.min ? r.max : r.min + 1))
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .frame(height: 38)
                }
            }
        }
    }

    // MARK: Style 3 — heatmap

    private var heatmapGrid: some View {
        // Capped so a long window stays legible: past ~60 columns a cell is sub-pixel on a phone
        // and the grid becomes a smear. The most RECENT days are kept, which is the half anyone
        // reading "when did this go wrong" actually wants.
        let days = Array(allDays.suffix(60))
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(resolved) { r in
                let lookup = Dictionary(r.points.map { ($0.day, $0.value) },
                                        uniquingKeysWith: { _, last in last })
                HStack(spacing: 2) {
                    Text(r.metric.title.uppercased())
                        .font(StrandFont.overlineScaled(9))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(width: 74, alignment: .leading)
                        .lineLimit(1)
                    GeometryReader { geo in
                        let w = max(1.0, (geo.size.width - CGFloat(days.count - 1) * 1.0)
                                    / CGFloat(max(days.count, 1)))
                        HStack(spacing: 1) {
                            ForEach(days, id: \.self) { day in
                                Rectangle()
                                    .fill(cellColor(r, lookup[day]))
                                    .frame(width: w)
                            }
                        }
                    }
                    .frame(height: 16)
                }
            }
            Text("Shaded by distance from your own average over this window.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .padding(.top, 2)
        }
    }

    /// A cell's shade: greener the better the day was FOR THAT METRIC, amber the worse, and a faint
    /// neutral when the day has no reading. `higherIsBetter` is what stops a high resting HR being
    /// painted as a good day.
    private func cellColor(_ r: Resolved, _ value: Double?) -> Color {
        guard let value else { return StrandPalette.hairline.opacity(0.35) }
        let span = r.max - r.min
        guard span > 0 else { return r.metric.color.opacity(0.4) }
        let t = (value - r.mean) / span                 // -1…1-ish, 0 = average
        let signed = r.metric.higherIsBetter ? t : -t
        if signed >= 0 {
            return StrandPalette.statusPositive.opacity(0.25 + min(0.65, signed * 1.3))
        }
        return StrandPalette.metricAmber.opacity(0.25 + min(0.65, -signed * 1.3))
    }

    // MARK: Legend

    private var legend: some View {
        // Carries the current value and the window's range per metric, which is what the overlay
        // gives up by normalising. Without it that style shows shape and nothing else.
        VStack(alignment: .leading, spacing: 3) {
            ForEach(resolved) { r in
                HStack(spacing: 6) {
                    Circle().fill(r.metric.color).frame(width: 7, height: 7)
                    Text(r.metric.title)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer(minLength: 4)
                    Text(valueText(r, r.points.last?.value))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .monospacedDigit()
                    Text("(\(compact(r.min))–\(compact(r.max)))")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.top, 2)
    }

    private func valueText(_ r: Resolved, _ v: Double?) -> String {
        guard let v else { return "—" }
        let unit = r.metric.unit
        return unit.isEmpty ? compact(v) : "\(compact(v)) \(unit)"
    }

    /// Step counts reach five digits and would dominate every row; everything else is small enough
    /// to print whole.
    private func compact(_ v: Double) -> String {
        if v >= 10_000 { return String(format: "%.0fk", v / 1000) }
        if v == v.rounded() { return String(Int(v)) }
        return String(format: "%.1f", v)
    }
}
