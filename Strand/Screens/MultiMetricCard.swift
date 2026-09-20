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
    /// This card's OWN window, in days — not the page's (260920).
    let windowDays: Int
    /// Changes this card's window.
    var onWindowChange: ((Int) -> Void)?
    /// Opens the metric picker.
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
                    case .rows:    rowStrips
                    case .heatmap: heatmapGrid
                    }
                    // Only the ROW stack needs the legend: each strip already prints its own latest
                    // value, but the window's range is what says whether that value is high FOR
                    // this wearer. The heatmap encodes exactly that in its shading, so repeating it
                    // underneath would be the same fact twice.
                    if style == .rows { legend }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(LocalizedStringKey(style.title),
                              overline: "Last \(windowDays) days")
                if let onConfigure {
                    Button(action: onConfigure) {
                        Label(String(localized: "Edit").uppercased(),
                              systemImage: "slider.horizontal.3")
                            .font(StrandFont.overline)
                            .tracking(StrandFont.overlineTracking)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StrandPalette.accent)
                    .accessibilityLabel("Choose metrics and their order")
                }
            }
            // This card's own window. Deliberately not the page's range bar: a heatmap reads best
            // over weeks and a row stack over days, and one control cannot serve both.
            if let onWindowChange {
                HStack(spacing: 6) {
                    ForEach(MultiMetricPrefs.windowOptions, id: \.self) { d in
                        Button { onWindowChange(d) } label: {
                            Text(d >= 30 ? "\(d / 30)m" : "\(d / 7)w")
                                .font(StrandFont.caption.weight(d == windowDays ? .bold : .regular))
                                .foregroundStyle(d == windowDays
                                                 ? StrandPalette.accent : StrandPalette.textTertiary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule().fill(d == windowDays
                                                   ? StrandPalette.accent.opacity(0.14) : .clear))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("\(d) days"))
                        .accessibilityAddTraits(d == windowDays ? [.isSelected] : [])
                    }
                    Spacer(minLength: 0)
                }
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

    /// The window's days, oldest first — the shared x-axis.
    ///
    /// 260920 FIX: this used to union every metric's own points and sort. Each metric had ALREADY
    /// been clipped to `windowDays` independently, so metrics whose data lands on different days
    /// (steps recorded on a day with no sleep, say) contributed different sets, and the union came
    /// out LONGER than the window — the maintainer selected a week and saw fifteen cells.
    ///
    /// Taking the union first and clipping last gives exactly the window, and a metric missing a
    /// day now renders a gap on the shared axis rather than shifting every later column left.
    private var allDays: [String] {
        Array(Set(resolved.flatMap { $0.points.map(\.day) }).sorted().suffix(windowDays))
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
                    .chartPlotStyle { plot in
                        // 260920 FIX: the maintainer's screenshot showed each row's area wash
                        // bleeding down across the rows beneath it, so seven strips rendered as one
                        // smeared stack.
                        //
                        // `.frame(height:)` bounds the CHART's layout, not its plot's drawing: an
                        // AreaMark fills to the plot's baseline, and SwiftUI Charts lets that fill
                        // paint outside the frame it was given. Clipping the plot is what actually
                        // confines it — without this the marks are drawn unclipped and every row
                        // after the first sits under its predecessors' fills.
                        plot.clipped()
                    }
                    .frame(height: 38)
                    .clipped()
                }
            }
        }
    }

    // MARK: Style 3 — heatmap

    private var heatmapGrid: some View {
        // `allDays` is already the window. The extra cap only bites on a very long one, where past
        // ~60 columns a cell is sub-pixel on a phone and the grid becomes a smear; the most RECENT
        // days are kept, which is the half anyone reading "when did this go wrong" wants.
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
