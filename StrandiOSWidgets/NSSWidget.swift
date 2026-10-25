import StrandDesign
import SwiftUI
import WidgetKit

/// Square home-screen widget: today's NSS (Normalized Stress Score), moving through the day (261024c).
///
/// The number is NSS now, out of 100 (261024d: 0 = the wearer's calm state for the pace they were at,
/// 20 points a swing above it), with their TYPICAL beside it and today's curve beneath over a dashed
/// line at that typical. It reads `WidgetSnapshot`'s NSS fields, which the app
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
    private var series: [StressPoint] { NSSPoint.stressSeries(points) }
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
        VStack(alignment: .leading, spacing: 4) {
            Text("NSS")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(StrandPalette.textPrimary)
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(now.map { "\($0)" } ?? "—")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(now.map(tint) ?? StrandPalette.textPrimary)
                if now != nil {
                    Text("of 100")
                        .font(.system(size: 11))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            if let typical {
                Text("typical \(typical)")
                    .font(.system(size: 11))
                    .foregroundStyle(StrandPalette.textSecondary)
            } else if let mean {
                Text("avg \(mean)")
                    .font(.system(size: 11))
                    .foregroundStyle(StrandPalette.textSecondary)
            } else {
                Text("No reading yet today")
                    .font(.system(size: 11))
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer(minLength: 2)
            if series.contains(where: { $0.level != nil }) {
                ZStack {
                    // The wearer's typical, dashed, when there is one.
                    if let typical {
                        GeometryReader { geo in
                            Path { p in
                                let y = geo.size.height * (1 - CGFloat(min(max(typical, 0), 100)) / 100)
                                p.move(to: CGPoint(x: 0, y: y))
                                p.addLine(to: CGPoint(x: geo.size.width, y: y))
                            }
                            .stroke(StrandPalette.textSecondary.opacity(0.35),
                                    style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        }
                    }
                    StressCurveShape(series: series, filled: true)
                        .fill(LinearGradient(colors: [steady.opacity(0.3), steady.opacity(0)],
                                             startPoint: .top, endPoint: .bottom))
                    StressCurveShape(series: series, filled: false)
                        .stroke(LinearGradient(colors: [tense, steady, calm],
                                               startPoint: .top, endPoint: .bottom),
                                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 46)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
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
