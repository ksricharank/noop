import StrandDesign
import SwiftUI
import WidgetKit

/// Square home-screen widget: today's NSS (Normalized Stress Score), moving through the day (261024c).
///
/// The number is NSS now, out of 100 (261024d: 0 = the wearer's calm state for the pace they were at,
/// 20 points a swing above it), top right; the rest of the box is today's curve (261026b), with a
/// y-axis whose top follows the day (261028, `NSSChartScale`), the time of day under it, and the wearer's TYPICAL as its own dashed line. It reads `WidgetSnapshot`'s NSS fields, which the app
/// publishes after every quick pass from `NormalizedStressStore` — the same snapshot the Stress tab and
/// the Today card show, so the three agree. The curve reuses the stress widget's geometry
/// (`StressTrace`, `StressCurveShape`) with NSS mapped onto its fixed domain, so a gap is a gap and the
/// colours mean what they mean on the Stress screen: blue calm, green usual, amber high.
///
/// Honest-blank: a day with nothing scored yet shows "Learning" (no model yet) or a dash, never a flat
/// line at 50. Fork-only: no Android twin.
struct NSSEntry: TimelineEntry {
    let date: Date
    let snap: WidgetSnapshot?
}

struct NSSProvider: TimelineProvider {
    func placeholder(in context: Context) -> NSSEntry {
        NSSEntry(date: Date(), snap: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (NSSEntry) -> Void) {
        completion(NSSEntry(date: Date(), snap: WidgetSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NSSEntry>) -> Void) {
        // Thirty minutes, like the stress widget: the app requests a reload when NSS moves by a step
        // worth showing, so this is the safety net and the carry across midnight.
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date())
            ?? Date().addingTimeInterval(1_800)
        completion(Timeline(entries: [NSSEntry(date: Date(), snap: WidgetSnapshot.load())],
                            policy: .after(next)))
    }
}

struct NSSWidgetView: View {
    let entry: NSSEntry

    private var points: [NSSPoint] { entry.snap?.nssCurve(now: entry.date) ?? [] }
    /// 261028: the y-axis top follows the day (`NSSChartScale`, the same function as the app's charts).
    private var top: Double {
        NSSChartScale.top(peak: max(points.map(\.nss).max() ?? 0, Double(typical ?? 0)))
    }
    private var series: [StressPoint] { NSSPoint.stressSeries(points, scaleMax: top) }
    /// The figures, only for today: a snapshot from a finished day shows nothing rather than yesterday.
    private var now: Int? { points.isEmpty ? nil : entry.snap?.nssNow }
    private var mean: Int? { points.isEmpty ? nil : entry.snap?.nssMean }
    private var typical: Int? { points.isEmpty ? nil : entry.snap?.nssTypical }

    private var calm: Color { StrandPalette.accent }
    private var steady: Color { StrandPalette.statusPositive }
    private var tense: Color { StrandPalette.statusWarning }

    /// The band colour for an NSS value, on the Stress screen's thresholds (NSS × 3/100 against 1 and 2).
    private func tint(_ nss: Int) -> Color {
        nss >= 67 ? tense : (nss < 33 ? calm : steady)
    }

    var body: some View {
        // 261026b (maintainer: "lot of wasted space. use most of it for the chart"): one compact header
        // row — the label and the typical key left, NSS now top right — and the chart takes the rest of
        // the box, with its y-axis left and the time of day under it.
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 4) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("NSS")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    if let typical {
                        HStack(spacing: 3) {
                            typicalStroke.frame(width: 12, height: 1)
                            Text("typical \(typical)")
                        }
                        .font(.system(size: 9))
                        .foregroundStyle(StrandPalette.textSecondary)
                    } else if mean == nil {
                        Text("No reading yet")
                            .font(.system(size: 9))
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                Spacer(minLength: 0)
                Text(now.map { "\($0)" } ?? "—")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(now.map(tint) ?? StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            if series.contains(where: { $0.level != nil }) {
                HStack(alignment: .top, spacing: 3) {
                    // The y-axis: round ticks from 0 to the day's top (261028; it was a fixed 0–100).
                    GeometryReader { geo in
                        ForEach(NSSChartScale.ticks(top: top), id: \.self) { t in
                            Text("\(Int(t))")
                                .font(.system(size: 7, weight: .medium).monospacedDigit())
                                .lineLimit(1).fixedSize()
                                .foregroundStyle(StrandPalette.textSecondary)
                                .position(x: geo.size.width / 2,
                                          y: geo.size.height * (1 - CGFloat(t / top)))
                        }
                    }
                    .frame(width: 16)
                    ZStack {
                        // Faint grid at the band edges, solid, so the dashed typical stands apart.
                        GeometryReader { geo in
                            Path { p in
                                for t in NSSChartScale.ticks(top: top) {
                                    let y = geo.size.height * (1 - CGFloat(t / top))
                                    p.move(to: CGPoint(x: 0, y: y))
                                    p.addLine(to: CGPoint(x: geo.size.width, y: y))
                                }
                            }
                            .stroke(StrandPalette.textSecondary.opacity(0.18), lineWidth: 0.5)
                        }
                        StressCurveShape(series: series, filled: true)
                            .fill(LinearGradient(colors: [steady.opacity(0.3), steady.opacity(0)],
                                                 startPoint: .top, endPoint: .bottom))
                        StressCurveShape(series: series, filled: false)
                            // Colour by value, not by height: sampled down the visible range, so the
                            // band colours stay true however far the axis is zoomed in.
                            .stroke(LinearGradient(stops: (0...8).map { i in
                                        let f = Double(i) / 8
                                        return .init(color: tint(Int(top * (1 - f))), location: f)
                                    }, startPoint: .top, endPoint: .bottom),
                                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        // My typical: its own dashed line, brighter than the grid and drawn over the curve.
                        if let typical {
                            GeometryReader { geo in
                                let y = geo.size.height * (1 - CGFloat(min(max(Double(typical), 0), top) / top))
                                typicalStroke
                                    .frame(width: geo.size.width, height: 1)
                                    .position(x: geo.size.width / 2, y: y)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(maxHeight: .infinity)
                .padding(.top, 4)   // room for the "100" label, centred on the top edge
                // Time of day under the chart: first, middle and last reading.
                if let first = points.first?.ts, let last = points.last?.ts {
                    HStack {
                        Text(Self.clock(first))
                        Spacer(minLength: 2)
                        Text(Self.clock((first + last) / 2))
                        Spacer(minLength: 2)
                        Text(Self.clock(last))
                    }
                    .font(.system(size: 8, weight: .medium).monospacedDigit())
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
                    .padding(.leading, 19)
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        // 261026: a tap opens the Stress tab (`noop://stress`, handled in `StrandiOSApp.onOpenURL`).
        .widgetURL(URL(string: "noop://stress"))
    }

    /// The typical's dash: brighter than the grid and dashed, so it reads as a different line.
    private var typicalStroke: some View {
        Line()
            .stroke(StrandPalette.textPrimary.opacity(0.75), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
    }

    /// A compact clock for the time axis: "6:45a", "12:10p".
    static func clock(_ ts: Int64) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mma"
        f.amSymbol = "a"
        f.pmSymbol = "p"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    private var accessibilityText: String {
        guard let now else { return String(localized: "NSS, no reading today") }
        if let typical { return String(localized: "NSS \(now) of 100, your typical \(typical)") }
        guard let mean else { return String(localized: "NSS \(now) of 100") }
        return String(localized: "NSS \(now) of 100, today's average \(mean)")
    }
}

struct NSSWidget: Widget {
    static let kind = "NSSWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: NSSProvider()) { entry in
            if #available(iOS 17.0, *) {
                NSSWidgetView(entry: entry)
                    .containerBackground(StrandPalette.surfaceBase, for: .widget)
            } else {
                NSSWidgetView(entry: entry)
                    .padding()
                    .background(StrandPalette.surfaceBase)
            }
        }
        .configurationDisplayName("NSS")
        .description("Today's stress beyond what your activity explains, through the day.")
        .supportedFamilies([.systemSmall])
    }
}

/// A horizontal line across its frame's vertical centre, for the typical's dash.
private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

