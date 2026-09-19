import WidgetKit
import SwiftUI
import StrandDesign

/// The daily-targets glance (260830) — built for the maintainer's battery-first default mode: Live
/// Activity OFF, continuous HRV overnight-only, daytime data arriving as ~15-minute offload bursts.
/// With no island and no banner, these widgets ARE the daytime surface, carrying the same three
/// numbers the Live Activity card shows: Effort now/target, TOTAL calories now/target, Steps
/// now/target, and today's water now/target. (260903: Water replaced tonight's sleep target in the
/// fourth slot on maintainer instruction — sleep need is a fixed figure that does not move through
/// the day, so it spent a daytime cell saying the same thing every refresh, whereas water is both
/// actionable and the one number the notification's buttons change. Sleep keeps its Live Activity
/// column and its in-app row.) (A burst-average HR held the first column for one build — replaced same-day by
/// Effort n/t on maintainer instruction; the HRV-dip "go breathe" read moved to the stress
/// check-in's buzz + notification.)
///
/// Families and their intended slots:
///   - `accessoryInline` (the Lock-Screen line ABOVE the clock): "Cal 1830/2650 · Steps 3k/8k" —
///     the maintainer's two most actionable daytime pairs; Effort and Water are skipped by spec.
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
        .configurationDisplayName("NOOP Targets (Bars)")
        .description("Effort, calories, steps and water against today's targets — updated with each strap sync, no Live Activity needed.")
        .supportedFamilies([
            .systemSmall, .systemMedium,
            .accessoryInline, .accessoryRectangular
        ])
    }
}

/// Which shape the four targets take on the Home-Screen faces. Two widgets, one view: the numbers,
/// colours, accessibility and every other family are identical, so a style flag is the whole
/// difference rather than a second copy to keep in sync (260919, maintainer wanted both offered so
/// the choice can be made on the phone).
enum TargetsStyle {
    /// Four rows, label left and pair right, with a progress track under each.
    case bars
    /// A 2x2 of progress rings, the metric named inside the arc and the pair beneath it.
    case rings
}

/// The rings variant of `NOOPTargetsWidget` — same data, same provider, same snapshot, drawn as a
/// 2x2 of progress rings instead of four bars. A separate `kind` so BOTH appear in the widget
/// gallery and the choice is made on the phone rather than in a build.
struct NOOPTargetsRingsWidget: Widget {
    let kind = "NOOPTargetsRingsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NOOPProvider()) { entry in
            if #available(iOS 17.0, *) {
                NOOPTargetsView(entry: entry, style: .rings)
                    .containerBackground(StrandPalette.surfaceBase, for: .widget)
            } else {
                NOOPTargetsView(entry: entry, style: .rings)
                    .padding()
                    .background(StrandPalette.surfaceBase)
            }
        }
        .configurationDisplayName("NOOP Targets (Rings)")
        .description("The same four targets as NOOP Targets, drawn as progress rings.")
        .supportedFamilies([
            .systemSmall, .systemMedium,
            .accessoryInline, .accessoryRectangular
        ])
    }
}

struct NOOPTargetsView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NOOPEntry
    var style: TargetsStyle = .bars

    private var snap: WidgetSnapshot { entry.snapshot }

    // Widget faces use the ABBREVIATED Cal/Steps pairs ("1.2k/2.1k", "3.2k/8k") — a widget cell has
    // no room for two four-digit pairs; the in-app strip and the banner keep the full counts.
    private var effortText: String { snap.effortNT ?? "–" }
    private var calText: String { snap.calAbbrev ?? "–" }
    private var stepsText: String { snap.stepsAbbrev ?? "–" }
    private var waterText: String { snap.waterDisplay ?? "–" }

    var body: some View {
        switch family {
        case .accessoryInline:
            // The slot above the Lock-Screen clock: one line, Cal + Steps (260830 revision — was
            // Cal-only), abbreviated and BOLD — the full counts were "hard to read across" one line.
            // Effort and Water are deliberately skipped: the maintainer's pick for the two most
            // actionable daytime numbers, and the line has no room for four pairs anyway.
            Text("Cal \(calText) · Steps \(stepsText)").bold()
        case .accessoryRectangular:
            rectangular
        case .systemMedium:
            medium
        default:
            // Only the Home-Screen small face differs between the two widgets; every other family
            // (medium, and both Lock-Screen accessories) is shape-agnostic and shared verbatim.
            switch style {
            case .bars:  small
            case .rings: smallRings
            }
        }
    }

    // MARK: - Lock Screen rectangular (below the clock): all three, one row

    /// 2×2 grid, no "NOOP" wordmark (260830 revision: four cells in one row crushed the Cal pair,
    /// and the label spent a whole line saying what the widget's placement already says). Rows match
    /// the in-app strip — each LONG pair (Steps, Cal — full counts) shares its row with a short one
    /// (Effort, Water) so the rows balance. Values are pushed to the slot's ceiling ("as large as
    /// possible without spoiling the formatting", third screenshot review): 21pt BOLD with the
    /// labels dropped to 8pt and every spacing at minimum — the ~72pt rectangular slot fits exactly
    /// two 8+21 cells plus 2pt between rows; `minimumScaleFactor` absorbs the widest pairs.
    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 6) {
                targetCell("Steps", text: snap.stepsAbbrev, size: 21, labelSize: 8,
                           tint: StrandPalette.chargeColor)
                targetCell("Effort", text: snap.effortNT, size: 21, labelSize: 8,
                           tint: StrandPalette.effortColor)
            }
            HStack(alignment: .top, spacing: 6) {
                targetCell("Cal", text: snap.calAbbrev, size: 21, labelSize: 8,
                           tint: StrandPalette.metricAmber)
                targetCell("Water", text: snap.waterDisplay, size: 21, labelSize: 8,
                           tint: StrandPalette.metricCyan)
            }
        }
    }

    // MARK: - Home Screen

    /// systemSmall: header + the trio as label/value ROWS — "1830/2650" is far too wide for three
    /// columns at the narrowest small-widget content width, and rows keep every value full-size.
    private var small: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            Spacer(minLength: 0)
            // One distinct data colour per metric (260830: a shared activity tint made the fourth
            // cell's muted restColor read as "off" beside three identical blues).
            targetArcRow("Steps", value: stepsText, fraction: snap.stepsFraction,
                         tint: StrandPalette.chargeColor)
            targetArcRow("Effort", value: effortText, fraction: snap.effortFraction,
                         tint: StrandPalette.effortColor)
            targetArcRow("Cal", value: calText, fraction: snap.calFraction,
                         tint: StrandPalette.metricAmber)
            targetArcRow("Water", value: waterText, fraction: snap.waterFraction,
                         tint: StrandPalette.metricCyan)
            Spacer(minLength: 0)
        }
        .padding(11)
    }

    /// The RINGS variant's small face: the same four metrics as a 2x2 of progress rings (260919).
    /// Shares this view's header, colours, text and accessibility — only the shape differs.
    var smallRings: some View {
        VStack(spacing: 8) {
            header
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                targetRing("Steps", value: stepsText, fraction: snap.stepsFraction,
                           tint: StrandPalette.chargeColor)
                targetRing("Effort", value: effortText, fraction: snap.effortFraction,
                           tint: StrandPalette.effortColor)
            }
            HStack(spacing: 8) {
                targetRing("Cal", value: calText, fraction: snap.calFraction,
                           tint: StrandPalette.metricAmber)
                targetRing("Water", value: waterText, fraction: snap.waterFraction,
                           tint: StrandPalette.metricCyan)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
    }

    /// One metric row: label, value, and a progress track underneath (260919).
    ///
    /// The four pairs were four bare "now/target" strings, which is the whole number but not the
    /// whole answer — "1.4k/8.9k" takes a beat of arithmetic to place, and the widget is a glance
    /// surface. The track answers "how far through am I" without reading either number.
    ///
    /// A nil fraction (target off, or a pair that did not parse) draws the empty track rather than a
    /// zero-length fill, so "not tracked" never looks like "none done".
    private func targetArcRow(_ label: String, value: String, fraction: Double?,
                              tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(value)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(value == "–" ? StrandPalette.textTertiary : tint)
                    // Single line with room to shrink: "11.2k/8.9k" is the widest realistic pair and
                    // this face has truncated before.
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            ProgressTrack(fraction: fraction, tint: tint)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(progressSpoken(value: value, fraction: fraction)))
    }

    /// One metric as a progress ring with its pair inside it (260919).
    ///
    /// The pair stays the text — "1.4k/8.9k" is the number the maintainer reads — and the ring
    /// answers "how far through am I" without the division. A nil fraction draws the EMPTY ring
    /// rather than a zero-length arc, so "not tracked" never looks like "none done yet".
    ///
    /// OVERFLOW: the pair sits INSIDE the ring, which is the tightest space on this face, so it is
    /// single-line at a small size with a generous scale floor. "18.4k/8.9k" is the widest realistic
    /// case and is checked by rendering.
    private func targetRing(_ label: String, value: String, fraction: Double?,
                            tint: Color) -> some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .stroke(StrandPalette.textTertiary.opacity(0.22), lineWidth: 4)
                if let fraction, fraction > 0 {
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Text(value)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(value == "–" ? StrandPalette.textTertiary : tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 5)
            }
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(progressSpoken(value: value, fraction: fraction)))
    }

    /// VoiceOver gets the pair AND the progress — the arc is the part a sighted reader gets for free.
    private func progressSpoken(value: String, fraction: Double?) -> String {
        guard value != "–" else { return "unavailable" }
        guard let fraction else { return value }
        return "\(value), \(Int((fraction * 100).rounded())) percent of target"
    }

    /// systemMedium: header + the trio as three big columns (the banner-card layout).
    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Spacer(minLength: 0)
            HStack(alignment: .top, spacing: 0) {
                // Both activity-pillar values wear the Effort domain colour; size dropped one step
                // from the HR era ("72" → "1830/2650") so the wide pairs fit without scale-crushing.
                targetCell("Steps", text: snap.stepsAbbrev, size: 20,
                           tint: StrandPalette.chargeColor)
                targetCell("Effort", text: snap.effortNT, size: 20,
                           tint: StrandPalette.effortColor)
                targetCell("Cal", text: snap.calAbbrev, size: 20,
                           tint: StrandPalette.metricAmber)
                targetCell("Water", text: snap.waterDisplay, size: 20,
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
        HStack(spacing: 6) {
            NoopPulseMark()
                .frame(width: 22, height: 22)
            Spacer(minLength: 4)
            // Deliberately small (260919): the strap charge is an operational vital worth a corner,
            // not a headline — the four targets are what this widget is for.
            BatteryPips(percent: snap.batteryPct)
            Text(snap.batteryPct.map { "\($0)%" } ?? "–")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Strap battery"))
        .accessibilityValue(Text(snap.batteryPct.map { "\($0) percent" } ?? "unavailable"))
    }

    /// One labelled value column (value over caption), equal-width. Tint applies to the value only
    /// when it exists — a dash stays tertiary so missing data never wears a domain colour.
    /// `labelSize` lets the space-starved rectangular slot trade caption points for value points.
    private func targetCell(_ label: String, text: String?, size: CGFloat, labelSize: CGFloat = 9,
                            tint: Color = StrandPalette.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(text ?? "–")
                .font(.system(size: size, weight: .bold, design: .rounded))
                .foregroundStyle(text == nil ? StrandPalette.textTertiary : tint)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(label)
                .font(.system(size: labelSize))
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

/// A slim progress track. Used by the Targets small face so each pair shows how far through its
/// target the day is without the reader doing the division.
///
/// A nil fraction draws the EMPTY track, never a zero-length fill: "not tracked" and "none done yet"
/// are different states and must not look identical.
private struct ProgressTrack: View {
    let fraction: Double?
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(StrandPalette.textTertiary.opacity(0.22))
                if let fraction, fraction > 0 {
                    Capsule()
                        .fill(tint)
                        // At least a visible nub, so a genuine 1% does not render as nothing and read
                        // the same as no data at all.
                        .frame(width: max(3, geo.size.width * fraction))
                }
            }
        }
        .frame(height: 3)
    }
}

/// The strap battery as SIX discrete pips (maintainer's request, 260919: steps at 0/20/40/60/80/100).
///
/// Drawn rather than an SF Symbol because SF Symbols ships only five battery fills — `battery.0`
/// through `battery.100` — so a sixth step is not expressible as a glyph. Pips also read better at
/// this size than a shrunken battery outline, and the lit count is the whole message.
///
/// Colour carries the warning, not the count: below two pips the fill goes critical, because a strap
/// about to die during a night's sleep is the one battery state worth interrupting a glance for.
private struct BatteryPips: View {
    let percent: Int?

    private var lit: Int { BatteryGlyph.bars(forPercent: percent) }

    private var fill: Color {
        guard percent != nil else { return StrandPalette.textTertiary }
        switch lit {
        case ..<2: return StrandPalette.statusCritical
        case 2:    return StrandPalette.metricAmber
        default:   return StrandPalette.statusPositive
        }
    }

    var body: some View {
        HStack(spacing: 1.2) {
            ForEach(0..<BatteryGlyph.barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 0.8, style: .continuous)
                    .fill(i < lit ? fill : StrandPalette.textTertiary.opacity(0.25))
                    .frame(width: 2, height: 7)
            }
        }
        // The pips ARE the battery; the percentage beside them carries the exact figure, and the
        // header as a whole speaks one accessibility value.
        .accessibilityHidden(true)
    }
}

/// The NOOP mark — the app icon's broken ring and centre dot, drawn as a path rather than shipped
/// as a bitmap: the widget extension has no asset catalogue of its own, and a stroked arc stays
/// crisp at any size.
///
/// Geometry MEASURED from `StrandiOS/Resources/Assets.xcassets/AppIcon.appiconset/icon_1024.png`
/// rather than eyeballed — an earlier attempt drew the `docs/assets/logo.svg` pulse trace, which is
/// a different, older mark and is not what the app wears. In that 1024pt artwork: centre 512,512;
/// ring mid-radius 300 with a 72pt stroke; a 58° gap running 205°→262° measured clockwise from
/// east; white centre dot radius 87.5. Expressed here as fractions of the view so it scales.
private struct NoopPulseMark: View {
    /// The arc SWEEPS from the gap's end back round to its start — 302° of ring.
    private let gapStart: Double = 205
    private let gapEnd: Double = 262

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let c = CGPoint(x: side / 2, y: side / 2)
            // Fractions of the 1024pt source: 300/512 mid-radius, 72/1024 stroke, 87.5/512 dot.
            let radius = side * (300.0 / 1024.0)
            let stroke = side * (72.0 / 1024.0)
            let dot = side * (87.5 / 1024.0)
            ZStack {
                Path { p in
                    p.addArc(center: c, radius: radius,
                             startAngle: .degrees(gapEnd), endAngle: .degrees(gapStart + 360),
                             clockwise: false)
                }
                .stroke(StrandPalette.chargeColor,
                        style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                Circle()
                    .fill(Color.white)
                    .frame(width: dot * 2, height: dot * 2)
                    .position(c)
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

