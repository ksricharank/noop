import WidgetKit
import SwiftUI
import StrandDesign

/// The daily-targets glance (260830) — built for the maintainer's battery-first default mode: Live
/// Activity OFF, continuous HRV overnight-only, daytime data arriving as ~15-minute offload bursts.
/// With no island and no banner, these widgets ARE the daytime surface, carrying the same three
/// numbers the Live Activity card shows: burst-average HR, exercise calories now/target, and
/// tonight's sleep target.
///
/// Families and their intended slots:
///   - `accessoryInline` (the Lock-Screen line ABOVE the clock): just "Cal 820/2100".
///   - `accessoryRectangular` (below the clock): all three — HR · Cal · Sleep.
///   - `systemSmall` / `systemMedium` (Home Screen): the trio plus the strap battery in the top-right
///     corner — the targets analogue of `NOOPWidget`'s Charge · Effort · Rest rings.
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
        .description("Average heart rate, calories vs target and tonight's sleep target — updated with each strap sync, no Live Activity needed.")
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

    /// Plain settled number, deliberately WITHOUT the Live Activity's tilde: the tilde marks a LIVE
    /// beat, and this value is a burst average by construction — claiming liveness would be the exact
    /// dishonesty the tilde vocabulary exists to prevent.
    private var hrText: String { snap.avgHr.map(String.init) ?? "–" }
    private var calText: String { snap.calDisplay ?? "–" }
    private var sleepText: String { snap.sleepDisplay ?? "–" }

    var body: some View {
        switch family {
        case .accessoryInline:
            // The slot above the Lock-Screen clock: one short line, Cal only (the user's pick for
            // the day's most actionable number).
            Text("Cal \(calText)")
        case .accessoryRectangular:
            rectangular
        case .systemMedium:
            medium
        default:
            small
        }
    }

    // MARK: - Lock Screen rectangular (below the clock): all three, one row

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("NOOP")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(StrandPalette.textSecondary)
            HStack(alignment: .top, spacing: 0) {
                targetCell("HR", text: snap.avgHr.map(String.init), size: 16)
                targetCell("Cal", text: snap.calDisplay, size: 16)
                targetCell("Sleep", text: snap.sleepDisplay, size: 16)
            }
        }
    }

    // MARK: - Home Screen

    /// systemSmall: header + the trio as label/value ROWS — "820/2100" is too wide for three columns
    /// at the narrowest small-widget content width, and rows keep every value full-size.
    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Spacer(minLength: 0)
            targetRow("HR", value: hrText, tint: StrandPalette.statusCritical)
            targetRow("Cal", value: calText, tint: StrandPalette.effortColor)
            targetRow("Sleep", value: sleepText, tint: StrandPalette.restColor)
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
                targetCell("HR", text: snap.avgHr.map(String.init), size: 26,
                           tint: StrandPalette.statusCritical)
                targetCell("Cal", text: snap.calDisplay, size: 26,
                           tint: StrandPalette.effortColor)
                targetCell("Sleep", text: snap.sleepDisplay, size: 26,
                           tint: StrandPalette.restColor)
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
