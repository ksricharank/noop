import WidgetKit
import SwiftUI
import StrandDesign

/// The daily-targets glance (260830) — built for the maintainer's battery-first default mode: Live
/// Activity OFF, continuous HRV overnight-only, daytime data arriving as ~15-minute offload bursts.
/// With no island and no banner, these widgets ARE the daytime surface, carrying the same three
/// numbers the Live Activity card shows: Effort now/target, TOTAL calories now/target, Steps
/// now/target, and tonight's sleep target. (A burst-average HR held the first column for one build — replaced same-day by
/// Effort n/t on maintainer instruction; the HRV-dip "go breathe" read moved to the stress
/// check-in's buzz + notification.)
///
/// Families and their intended slots:
///   - `accessoryInline` (the Lock-Screen line ABOVE the clock): "Cal 1830/2650 · Steps 3k/8k" —
///     the maintainer's two most actionable daytime pairs; Effort and Sleep are skipped by spec.
///   - `accessoryRectangular` (below the clock): all four as a 2×2 grid, no wordmark.
///   - `systemSmall` / `systemMedium` (Home Screen): the four targets plus the strap battery in the
///     top-right corner — the targets analogue of `NOOPWidget`'s Charge · Effort · Rest rings.
///
/// Values move at the burst cadence, not per beat: the app republishes the shared snapshot after each
/// completed offload (#980, background included), and WidgetKit re-reads it on the 15-minute timeline
/// policy — subject to iOS's daily widget refresh budget, so an individual repaint can land late.
/// Shares `NOOPProvider` (and therefore the exact snapshot) with `NOOPWidget`, so the two widgets can
/// never disagree about the numbers.
struct NOOPTargetsWidget: Widget {
    let kind = "NOOPTargetsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NOOPProvider()) { entry in
            if #available(iOS 17.0, *) {
                NOOPTargetsView(entry: entry)
                    .containerBackground(StrandPalette.surfaceBase, for: .widget)
            } else {
                NOOPTargetsView(entry: entry)
                    .padding()
                    .background(StrandPalette.surfaceBase)
            }
        }
        .configurationDisplayName("NOOP Targets")
        .description("Effort, calories and steps against today's targets, plus tonight's sleep target — updated with each strap sync, no Live Activity needed.")
        .supportedFamilies([
            .systemSmall, .systemMedium,
            .accessoryInline, .accessoryRectangular
        ])
    }
}

struct NOOPTargetsView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NOOPEntry

    private var snap: WidgetSnapshot { entry.snapshot }

    private var effortText: String { snap.effortNT ?? "–" }
    private var calText: String { snap.calDisplay ?? "–" }
    private var stepsText: String { snap.stepsDisplay ?? "–" }
    private var sleepText: String { snap.sleepDisplay ?? "–" }

    var body: some View {
        switch family {
        case .accessoryInline:
            // The slot above the Lock-Screen clock: one line, Cal + Steps (260830 revision — was
            // Cal-only). Effort and Sleep are deliberately skipped: the maintainer's pick for the
            // two most actionable daytime numbers, and the line has no room for four pairs anyway.
            Text("Cal \(calText) · Steps \(stepsText)")
        case .accessoryRectangular:
            rectangular
        case .systemMedium:
            medium
        default:
            small
        }
    }

    // MARK: - Lock Screen rectangular (below the clock): all three, one row

    /// 2×2 grid, no "NOOP" wordmark (260830 revision: four cells in one row crushed the Cal pair,
    /// and the label spent a whole line saying what the widget's placement already says). Rows match
    /// the in-app strip: Steps · Cal on top, Effort · Sleep below.
    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 6) {
                targetCell("Steps", text: snap.stepsDisplay, size: 15, tint: StrandPalette.chargeColor)
                targetCell("Cal", text: snap.calDisplay, size: 15, tint: StrandPalette.metricAmber)
            }
            HStack(alignment: .top, spacing: 6) {
                targetCell("Effort", text: snap.effortNT, size: 15, tint: StrandPalette.effortColor)
                targetCell("Sleep", text: snap.sleepDisplay, size: 15, tint: StrandPalette.metricCyan)
            }
        }
    }

    // MARK: - Home Screen

    /// systemSmall: header + the trio as label/value ROWS — "1830/2650" is far too wide for three
    /// columns at the narrowest small-widget content width, and rows keep every value full-size.
    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Spacer(minLength: 0)
            // One distinct data colour per metric (260830: a shared activity tint made Sleep's muted
            // restColor read as "off" beside three identical blues).
            targetRow("Effort", value: effortText, tint: StrandPalette.effortColor)
            targetRow("Cal", value: calText, tint: StrandPalette.metricAmber)
            targetRow("Steps", value: stepsText, tint: StrandPalette.chargeColor)
            targetRow("Sleep", value: sleepText, tint: StrandPalette.metricCyan)
            Spacer(minLength: 0)
        }
        .padding(10)
    }

    /// systemMedium: header + the trio as three big columns (the banner-card layout).
    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Spacer(minLength: 0)
            HStack(alignment: .top, spacing: 0) {
                // Both activity-pillar values wear the Effort domain colour; size dropped one step
                // from the HR era ("72" → "1830/2650") so the wide pairs fit without scale-crushing.
                targetCell("Effort", text: snap.effortNT, size: 20,
                           tint: StrandPalette.effortColor)
                targetCell("Cal", text: snap.calDisplay, size: 20,
                           tint: StrandPalette.metricAmber)
                targetCell("Steps", text: snap.stepsDisplay, size: 20,
                           tint: StrandPalette.chargeColor)
                targetCell("Sleep", text: snap.sleepDisplay, size: 20,
                           tint: StrandPalette.metricCyan)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    /// "NOOP" left, strap battery in the top-RIGHT corner (the user's explicit placement — this
    /// widget's whole point is running island-less, so the strap's remaining charge is the one
    /// operational vital worth a corner).
    private var header: some View {
        HStack {
            Text("NOOP")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            HStack(spacing: 3) {
                Image(systemName: "battery.50")
                Text(snap.batteryPct.map { "\($0)%" } ?? "–")
            }
            .font(.caption2)
            .foregroundStyle(StrandPalette.textSecondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Strap battery"))
            .accessibilityValue(Text(snap.batteryPct.map { "\($0) percent" } ?? "unavailable"))
        }
    }

    /// One labelled value column (value over caption), equal-width. Tint applies to the value only
    /// when it exists — a dash stays tertiary so missing data never wears a domain colour.
    private func targetCell(_ label: String, text: String?, size: CGFloat,
                            tint: Color = StrandPalette.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(text ?? "–")
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .foregroundStyle(text == nil ? StrandPalette.textTertiary : tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(text ?? "unavailable"))
    }

    /// One label-left / value-right row for the systemSmall stack.
    private func targetRow(_ label: String, value: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(StrandPalette.textTertiary)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(value == "–" ? StrandPalette.textTertiary : tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(value))
    }
}
