#if !os(watchOS)
// Sparkline uses .onContinuousHover + ChartHover helpers (unavailable on watchOS); the watch
// doesn't draw sparklines, so the whole view is excluded there. iOS/macOS unchanged.
import SwiftUI

// MARK: - Sparkline (§9.4 Today / Live HR tile)
//
// A tiny inline line for live HR (or any short numeric series). Gradient-stroked,
// with an optional crisp leading dot at the latest sample and a faint area
// wash (WHOOP-flat: no bloom). Designed to sit in a card/tile or the menu-bar popover.

/// Preferences for how the inline sparklines draw (260920).
///
/// The KEY STRING is the contract — a `.noobak` round-trip carries the setting by key, not by
/// symbol name — so it is fixed here the same way `QuietMotionPrefs.enabledKey` is.
public enum SparklinePrefs {
    /// "Simple sparklines": draw through a fixed-size `Canvas` instead of a `GeometryReader`.
    ///
    /// The maintainer isolated the Sleep tab's Night-detail grid (7 sparkline tiles) and the Trends
    /// tab's Daily-signals block as the only two cards whose presence made their page scroll badly,
    /// and the lag followed the CARDS rather than their position — the signature of per-instance
    /// work on every layout pass, not of drawing.
    ///
    /// `GeometryReader` is that work: it participates in layout on every pass and propagates size
    /// upward, and there are seven of them in one grid inside a scrolling `LazyVGrid`. The reader is
    /// not needed — the only thing read from it is `geo.size`, and every call site already pins the
    /// frame (`StatTile` uses `.frame(height: 22)`), so a `Canvas` at that same fixed size draws the
    /// identical line with no layout participation at all.
    ///
    /// Shipped as a TOGGLE rather than a silent default because the cause of this lag was wrong six
    /// times before the maintainer bisected it on-device; a switch lets the next report compare the
    /// two directly instead of trusting a claim. Default ON, since the Canvas path is strictly less
    /// work and visually identical.
    /// Stored INVERTED — the key means "use the rich GeometryReader path" — so an untouched
    /// install reads `false` and gets the cheap one. A default-ON preference over a `Bool` that
    /// is `false` when unset has to be phrased this way or it defaults off by accident.
    public static let richKey = "noop.richSparklines"

    public static var simple: Bool { !UserDefaults.standard.bool(forKey: richKey) }
}

public struct Sparkline: View {

    public var values: [Double]
    /// Line gradient (defaults to recovery scale; pass strain/zone gradients as needed).
    public var gradient: Gradient
    /// Optional explicit value range; otherwise auto-fit with padding.
    public var range: ClosedRange<Double>?
    public var lineWidth: CGFloat
    public var showsArea: Bool
    public var showsHead: Bool
    /// Whether hovering highlights the nearest sample + shows a compact tooltip.
    public var showsHover: Bool
    /// Formats a sample value for the tooltip's bold line.
    public var valueFormat: (Double) -> String
    /// Optional secondary label for a sample by index (e.g. a timestamp). When
    /// nil the tooltip falls back to "sample N".
    public var indexLabel: ((Int) -> String)?

    public init(
        values: [Double],
        gradient: Gradient = StrandPalette.recoveryGradient,
        range: ClosedRange<Double>? = nil,
        lineWidth: CGFloat = 2,
        showsArea: Bool = true,
        showsHead: Bool = true,
        showsHover: Bool = Sparkline.hoverIsReachable,
        valueFormat: @escaping (Double) -> String = { Sparkline.defaultValueString($0) },
        indexLabel: ((Int) -> String)? = nil
    ) {
        self.values = values
        self.gradient = gradient
        self.range = range
        self.lineWidth = lineWidth
        self.showsArea = showsArea
        self.showsHead = showsHead
        self.showsHover = showsHover
        self.valueFormat = valueFormat
        self.indexLabel = indexLabel
    }

    /// Whether a pointer hover can reach this view AT ALL on the current platform.
    ///
    /// On iPhone it cannot. The hover affordance is pointer-only — the comment on the
    /// `.accessibilityLabel` below has said so since it was written ("dead on touch") — but it was
    /// still built on every sparkline: an `.onContinuousHover`, a `.contentShape(Rectangle())` and
    /// an `.animation(_:value:)` inside a `GeometryReader`, per tile.
    ///
    /// That is free when a page has one sparkline and expensive when it has seven. The maintainer
    /// isolated exactly this (260920): the Sleep tab's Night-detail grid (7 tiles) and the Trends
    /// tab's Daily-signals block were the ONLY two cards whose presence made their whole page
    /// scroll badly — and the lag followed the cards rather than their position, which is the
    /// signature of a per-tile cost paid on every body evaluation, not of the drawing itself.
    ///
    /// iPadOS and visionOS DO have pointers, so this is `os(iOS) && !targetEnvironment(macCatalyst)`
    /// gated on `UIDevice.current.userInterfaceIdiom` rather than a blanket iOS exclusion — an iPad
    /// with a trackpad keeps the affordance it can actually use.
    ///
    /// A call site may still pass `showsHover:` explicitly to override this default either way.
    public static var hoverIsReachable: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad
        #else
        return true
        #endif
    }

    /// The hovered x-position in local coordinates.
    @State private var hoverX: CGFloat? = nil

    /// Default value formatting: integer when whole, else one decimal.
    public static func defaultValueString(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    private var bounds: (min: Double, max: Double) {
        if let range { return (range.lowerBound, range.upperBound) }
        guard let lo = values.min(), let hi = values.max() else { return (0, 1) }
        if lo == hi { return (lo - 1, hi + 1) }
        let pad = (hi - lo) * 0.12
        return (lo - pad, hi + pad)
    }

    /// The area-wash top colour (gradient sampled at 0.7, dimmed). Computed once per body eval instead of
    /// re-sampling the gradient inside the ZStack on every draw.
    private var areaWashColor: Color {
        StrandPalette.sample(stops: gradient.stops, at: 0.7).opacity(0.22)
    }
    /// The head-dot ring colour (gradient sampled at its bright end). Computed once per body eval.
    private var headColor: Color {
        StrandPalette.sample(stops: gradient.stops, at: 1.0)
    }

    /// Read through `@AppStorage` rather than `SparklinePrefs.simple` directly, so flipping the
    /// Settings toggle re-renders every sparkline immediately instead of at the next relaunch. The
    /// static accessor stays for non-SwiftUI readers and for the default-OFF semantics.
    @AppStorage(SparklinePrefs.richKey) private var richSparklines = false

    public var body: some View {
        // The cheap path (default): a Canvas that draws into whatever size the parent already gave
        // it, with NO GeometryReader and no layout participation. Visually identical — same
        // polyline, same area wash, same head dot, same gradient sampling.
        //
        // The hover affordance is absent here by construction, which costs nothing on a phone: it
        // is pointer-only and unreachable on touch (see `hoverIsReachable`). A pointer device that
        // wants it turns the rich path back on.
        if richSparklines {
            richBody
        } else {
            simpleBody
        }
    }

    /// Fixed-size Canvas rendering. Everything is computed from the `size` the Canvas is handed,
    /// exactly as `points(in:)` computed it from `geo.size`.
    private var simpleBody: some View {
        Canvas { ctx, size in
            let pts = points(in: size)
            guard pts.count > 1 else { return }
            if showsArea {
                ctx.fill(Path(areaPathCG(pts, in: size)),
                         with: .linearGradient(Gradient(colors: [areaWashColor, .clear]),
                                               startPoint: .zero,
                                               endPoint: CGPoint(x: 0, y: size.height)))
            }
            ctx.stroke(Path(linePathCG(pts)),
                       with: .linearGradient(gradient,
                                             startPoint: .zero,
                                             endPoint: CGPoint(x: size.width, y: 0)),
                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            if showsHead, let head = pts.last {
                let r = lineWidth * 1.1
                ctx.fill(Path(ellipseIn: CGRect(x: head.x - r, y: head.y - r,
                                                width: r * 2, height: r * 2)),
                         with: .color(headColor))
                let ri = lineWidth * 0.5
                ctx.fill(Path(ellipseIn: CGRect(x: head.x - ri, y: head.y - ri,
                                                width: ri * 2, height: ri * 2)),
                         with: .color(StrandPalette.tipCore))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(axSummary))
    }

    /// Path builders shared with the Canvas path. `Path` here rather than the SwiftUI `Shape`
    /// wrappers so one definition serves both renderers and they cannot drift.
    private func linePathCG(_ pts: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        for p in pts.dropFirst() { path.addLine(to: p) }
        return path
    }

    private func areaPathCG(_ pts: [CGPoint], in size: CGSize) -> CGPath {
        let path = CGMutablePath()
        guard let first = pts.first, let last = pts.last else { return path }
        path.move(to: first)
        for p in pts.dropFirst() { path.addLine(to: p) }
        path.addLine(to: CGPoint(x: last.x, y: size.height))
        path.addLine(to: CGPoint(x: first.x, y: size.height))
        path.closeSubpath()
        return path
    }

    /// The original GeometryReader rendering, kept behind the preference so the two can be
    /// compared directly on-device and so pointer platforms keep the hover affordance.
    private var richBody: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            ZStack {
                // STATIC LAYER: area wash + gradient line + head dot. Drawn INLINE — NO .drawingGroup().
                // A ~14-point polyline + fill + 2 dots is trivially cheap, and a per-sparkline offscreen
                // flatten costs FAR more (a dedicated MTLTexture + an extra composite pass) than it saves.
                // Today shows ~10-16 tiles at once, so per-tile .drawingGroup() piled up ~16 offscreen
                // passes that re-rasterised on every scroll / body re-eval — the v7.0.2 lag regression.
                // CoreAnimation already caches this flat layer natively.
                ZStack {
                    if showsArea, pts.count > 1 {
                        areaPath(pts, in: geo.size)
                            .fill(
                                LinearGradient(
                                    colors: [areaWashColor, Color.clear],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                    }
                    if pts.count > 1 {
                        linePath(pts)
                            .stroke(
                                LinearGradient(gradient: gradient, startPoint: .leading, endPoint: .trailing),
                                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                            )
                    }
                    if showsHead, let head = pts.last {
                        // Design Reset (WHOOP): a crisp solid leading dot, no blurred bloom halo.
                        // The line colour reads as the head ring; a small core sits inside it.
                        Circle().fill(headColor).frame(width: lineWidth * 2.2, height: lineWidth * 2.2)
                            .position(head)
                        Circle().fill(StrandPalette.tipCore).frame(width: lineWidth * 1.0, height: lineWidth * 1.0)
                            .position(head)
                    }
                }

                // Hover affordance: crosshair + highlighted sample + tooltip.
                if showsHover, !values.isEmpty, let hx = hoverX,
                   let idx = ChartHoverMath.nearestIndex(toX: hx, count: values.count, width: geo.size.width),
                   idx < pts.count {
                    let p = pts[idx]
                    let color = sampleColor(forIndex: idx)
                    CrosshairRule(x: p.x, height: geo.size.height)
                    HighlightDot(color: color, diameter: max(7, lineWidth * 3))
                        .position(p)
                    PositionedTooltip(
                        anchor: p,
                        container: geo.size,
                        tooltip: ChartTooltip(
                            value: valueFormat(values[idx]),
                            label: indexLabel?(idx) ?? "sample \(idx + 1)",
                            accent: color
                        )
                    )
                }
            }
            // Attached ONLY when a pointer can reach this view. Gating the CALLBACK (the previous
            // `guard showsHover else { return }` inside it) still built the tracker, the hit-test
            // shape and an animation observer for every tile — the work is in attaching them, not
            // in running them, and on a touch device none of it can ever fire. `hoverModifiers`
            // keeps one view TYPE in both branches, so this never changes view identity.
            .animation(showsHover ? StrandMotion.fade : nil, value: hoverX)
            .hoverModifiers(enabled: showsHover) { hoverX = $0 }
            // The line is pointer-hover only (dead on touch); give VoiceOver a
            // spoken summary of the series so the trend isn't silent on iPhone.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(axSummary))
        }
    }

    /// A spoken summary of the series for VoiceOver: count + latest/low/high,
    /// formatted via the same `valueFormat` closure so units match the call site.
    private var axSummary: String {
        guard let last = values.last, let lo = values.min(), let hi = values.max() else {
            return String(localized: "No data", bundle: .module)
        }
        return String(localized: "Trend, \(values.count) points, latest \(valueFormat(last)), low \(valueFormat(lo)), high \(valueFormat(hi))", bundle: .module)
    }

    /// The gradient colour at a sample's normalized position along the line.
    private func sampleColor(forIndex idx: Int) -> Color {
        let pos = values.count > 1 ? Double(idx) / Double(values.count - 1) : 1.0
        return StrandPalette.sample(stops: gradient.stops, at: pos)
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard !values.isEmpty else { return [] }
        let (lo, hi) = bounds
        let span = max(hi - lo, 0.0001)
        let n = values.count
        return values.enumerated().map { i, v in
            let x = n > 1 ? CGFloat(i) / CGFloat(n - 1) * size.width : size.width / 2
            let norm = (v - lo) / span
            let y = size.height - CGFloat(norm) * size.height
            return CGPoint(x: x, y: y)
        }
    }

    private func linePath(_ pts: [CGPoint]) -> Path {
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: first)
        for p in pts.dropFirst() { path.addLine(to: p) }
        return path
    }

    private func areaPath(_ pts: [CGPoint], in size: CGSize) -> Path {
        var path = linePath(pts)
        if let last = pts.last, let first = pts.first {
            path.addLine(to: CGPoint(x: last.x, y: size.height))
            path.addLine(to: CGPoint(x: first.x, y: size.height))
            path.closeSubpath()
        }
        return path
    }
}

#if DEBUG
private func sampleHR() -> [Double] {
    (0..<48).map { i -> Double in
        let wave: Double = 10 * sin(Double(i) / 4.0)
        let jitter: Double = Double((i * 13) % 7)
        return 58 + wave + jitter
    }
}

#Preview("Sparkline") {
    VStack(alignment: .leading, spacing: 20) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("64").font(StrandFont.number(34)).foregroundStyle(StrandPalette.textPrimary)
            Text("bpm").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            Spacer()
            Sparkline(
                values: sampleHR(),
                valueFormat: { "\(Int($0.rounded())) bpm" },
                indexLabel: { "\($0)s ago" }
            )
            .frame(width: 160, height: 44)
        }
        Sparkline(values: sampleHR(), gradient: StrandPalette.strainGradient)
            .frame(height: 60)
        Text("Hover any sparkline to read the exact sample under the cursor.")
            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
    }
    .padding(24)
    .frame(width: 380, height: 240)
    .background(NoopChromeSurface())
    .preferredColorScheme(.dark)
}
#endif
// MARK: - Conditional hover attachment

private extension View {
    /// Attaches the pointer-hover tracker, its hit-test shape and its crossfade — or none of them.
    ///
    /// Written as ONE modifier returning a single concrete type rather than an `if` in the caller's
    /// body: a conditional modifier puts the two states in different `_ConditionalContent` branches,
    /// which changes view identity and would tear down and rebuild the sparkline (and lose any
    /// `@State` under it) if the condition ever moved. It cannot move here — it is a per-platform
    /// constant — but the cheap habit is the one worth keeping, and #519 in `RootTabView` is this
    /// exact bug in the gesture layer.
    @ViewBuilder
    func hoverModifiers(enabled: Bool, onX: @escaping (CGFloat?) -> Void) -> some View {
        if enabled {
            self
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let location): onX(location.x)
                    case .ended: onX(nil)
                    }
                }
        } else {
            self
        }
    }
}

#endif
