import SwiftUI
import StrandDesign
import StrandAnalytics

/// The Stress tab's NSS card (261024): the Normalized Stress Score now, today's line, the last unusual
/// stretch, and an honest caption. Reads `NormalizedStressStore`'s snapshot — the same one the Today
/// card and the coach read — so the three always show one number for one moment.
///
/// 261024d: NSS is measured UP from my calm state at each pace (0 = calm, 20 points a swing), and what
/// is normal for me is shown beside it — my TYPICAL and the level that is UNUSUAL for me — rather than
/// pinned to 50. The pill says where now sits against those; the line's dashed reference is my typical.
/// Colour still reuses the Stress screen's ramp at NSS × 3/100 (near calm blue, above calm green, far
/// above calm amber).
struct NSSCard: View {
    let snapshot: NormalizedStressStore.Snapshot
    /// The Stress tab's hero leaves the line to its own timeline section below (261024b), so the
    /// screen draws today's NSS once.
    var showsLine = true

    var body: some View {
        NoopCard(tint: StressRamp.calm) {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                HStack {
                    Text("Normalized stress · NSS").strandOverline()
                    Spacer()
                    if let c = snapshot.current {
                        let status = Self.status(c.nss, typical: snapshot.typical, unusual: snapshot.unusualLevel)
                        StatePill("\(status.title)", tone: status.tone, showsDot: true)
                    }
                }
                if let c = snapshot.current {
                    HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                        Text("\(Int(c.nss.rounded()))")
                            .font(StrandFont.number(44, weight: .bold))
                            .foregroundStyle(StressRamp.color(Self.level(c.nss)))
                        Text("of 100")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            if let typical = snapshot.typical {
                                Text("your typical \(Int(typical.rounded()))")
                                    .font(StrandFont.captionNumber)
                                    .foregroundStyle(StrandPalette.textSecondary)
                            }
                            if let mean = snapshot.dayMean {
                                Text("today avg \(Int(mean.rounded()))")
                                    .font(StrandFont.captionNumber)
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                        }
                    }
                    Text(Self.explanation(c, unscoredNow: snapshot.unscoredNow, exercise: snapshot.unscoredExercise))
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if showsLine, !snapshot.readings.isEmpty {
                        NSSDayChart(readings: snapshot.readings, typical: snapshot.typical)
                    }
                    if let e = snapshot.lastUnusual {
                        Text("Unusual for you \(Self.clock(e.startTs))–\(Self.clock(e.endTs)) · peak \(Int(e.peak.nss.rounded())) while \(e.peak.pace.phrase)")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                } else {
                    Text(snapshot.modelledPaces.isEmpty
                         ? "Learning your calm state at each pace — \(snapshot.modelDays) of \(snapshot.baselineDays) days so far."
                         : "No reading yet today.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("0 is your calm state for the pace you're moving at, from your calmest moments over the last \(snapshot.baselineDays) days. Each 20 points is one typical swing above it. Your typical is the middle of your days; unusual is your top 5%. Heat, caffeine, a meal, illness or talking raise it too. Experimental.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// NSS on the Stress screen's 0–3 band and colour scale.
    static func level(_ nss: Double) -> Double { nss * 3 / 100 }

    /// Where a reading sits against MY normal (the coach's `nssBandWord`, as a pill): unusual for me
    /// (my top 5%), above my typical, typical (within ±3 — 261024g, it was ±10, which labelled 18
    /// against a typical of 27 "typical"), or below typical; before there is a typical, the fixed
    /// scale's own steps.
    static func status(_ nss: Double, typical: Double?, unusual: Double?) -> (title: String, tone: StrandTone) {
        if let typical, let unusual {
            let gap = nss - typical
            if nss >= unusual { return (String(localized: "UNUSUAL FOR YOU"), .critical) }
            if gap >= 10 { return (String(localized: "WELL ABOVE TYPICAL"), .warning) }
            if gap > 3 { return (String(localized: "ABOVE TYPICAL"), .warning) }
            if gap >= -3 { return (String(localized: "TYPICAL"), .positive) }
            return (String(localized: "BELOW TYPICAL"), .positive)
        }
        if nss < 20 { return (String(localized: "NEAR CALM"), .positive) }
        return nss < 60 ? (String(localized: "ABOVE CALM"), .warning) : (String(localized: "FAR ABOVE CALM"), .critical)
    }

    /// One plain line: the pace and what moved the score, against calm at that pace.
    static func explanation(_ r: NormalizedStress.Reading, unscoredNow: NormalizedStress.Window?,
                            exercise: NormalizedStress.ExerciseMark? = nil) -> String {
        let diff = Int((r.hr - r.hrCalm).rounded())
        let heart = diff <= 0
            ? String(localized: "heart rate at your calm level for this pace")
            : String(localized: "heart rate \(diff) bpm above your calm for this pace")
        var line = String(localized: "While \(r.pace.phrase): \(heart)")
        if let z = r.zRMSSD, z >= 1 {
            line += String(localized: ", HRV below your calm level")
        }
        line += "."
        if let exercise {
            line += " " + (exercise == .exercise
                ? String(localized: "Exercise isn't scored — this is your last reading.")
                : String(localized: "Recovering from exercise isn't scored for \(NormalizedStress.recoveryMinutes) minutes — this is your last reading."))
        } else if let u = unscoredNow {
            line += " " + (u.pace == .run
                ? String(localized: "Running now isn't scored — this is your last reading.")
                : String(localized: "Not enough history at your current pace yet — this is your last reading."))
        }
        return line
    }

    /// Today's readings on a 5-minute grid (the latest reading in each slot), as the screen line's points;
    /// slots with no reading stay empty so the line breaks there.
    static func linePoints(_ readings: [NormalizedStress.Reading]) -> [DaytimeStress.HourPoint] {
        guard let first = readings.first, let last = readings.last else { return [] }
        var bySlot: [Int: NormalizedStress.Reading] = [:]
        for r in readings { bySlot[r.ts / 300] = r }
        let cal = Calendar.current
        return (first.ts / 300...last.ts / 300).map { slot in
            let ts = slot * 300
            let hour = cal.component(.hour, from: Date(timeIntervalSince1970: TimeInterval(ts)))
            return DaytimeStress.HourPoint(hour: hour, startTs: ts, level: bySlot[slot].map { level($0.nss) },
                                           meanHR: bySlot[slot]?.hr, rmssd: nil)
        }
    }

    static func clock(_ ts: Int) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
}

/// Today's NSS through the day WITH ITS AXES (261026: the maintainer "can't see what values the chart is
/// referring to" — the line had only the dashed typical). The Stress tab's own `DaytimeLoadLine`, so there
/// is one drawing of the day, framed by a y-axis at the band edges (0 · 33 · 67 · 100, the screen's calm /
/// moderate / high cut points and the notification line at 67), the first, middle and last times under
/// it, and a key for the dashed typical. Used by the Stress tab's timeline, the NSS card, Today's NSS
/// section and the Today-hosted stress card.
struct NSSDayChart: View {
    let readings: [NormalizedStress.Reading]
    let typical: Double?
    var height: CGFloat = 92

    /// The y-axis ticks, on the NSS scale.
    static let ticks: [Double] = [0, 33, 67, 100]
    private let gutter: CGFloat = 26

    var body: some View {
        let points = NSSCard.linePoints(readings)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 4) {
                // y-axis labels, placed on the same 0–100 mapping the line uses (level = NSS × 3/100).
                GeometryReader { geo in
                    ForEach(Self.ticks, id: \.self) { t in
                        Text("\(Int(t))")
                            .font(StrandFont.footnote)
                            .monospacedDigit()
                            .foregroundStyle(StrandPalette.textTertiary)
                            .frame(width: gutter, alignment: .trailing)
                            .position(x: gutter / 2, y: geo.size.height * (1 - CGFloat(t / 100)))
                    }
                }
                .frame(width: gutter, height: height)
                DaytimeLoadLine(hours: points, referenceLevel: typical.map(NSSCard.level),
                                gridLevels: Self.ticks.map(NSSCard.level), chartHeight: height)
            }
            .padding(.vertical, 6)   // room for the 0 and 100 labels, which centre on the chart's edges
            HStack {
                if let first = points.first, let last = points.last {
                    Text(NSSCard.clock(first.startTs))
                    Spacer()
                    Text(NSSCard.clock((first.startTs + last.startTs) / 2))
                    Spacer()
                    Text(NSSCard.clock(last.startTs))
                }
            }
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .padding(.leading, gutter + 4)
            if let typical {
                Text("Dashed line: your typical \(Int(typical.rounded())). 67 and above is high.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .padding(.leading, gutter + 4)
            }
        }
    }
}

/// The Today page's NSS card body (261026): NSS now beside its label, like the heart-rate card's bpm,
/// today's chart with its axes, and the day's low, average and high. The same snapshot as every other
/// NSS surface. The caller supplies the card chrome and the tap.
struct NSSTodayChart: View {
    let snapshot: NormalizedStressStore.Snapshot

    var body: some View {
        let scores = snapshot.readings.map(\.nss)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: NoopMetrics.space2) {
                HStack(spacing: NoopMetrics.space1) {
                    Text("NORMALIZED STRESS")
                        .font(StrandFont.overline)
                        .tracking(1.6)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(StrandPalette.stressColor)
                        .accessibilityHidden(true)
                }
                .layoutPriority(1)
                Spacer(minLength: NoopMetrics.space2)
                if let c = snapshot.current {
                    (Text("\(Int(c.nss.rounded()))").font(StrandFont.rounded(22)).monospacedDigit()
                        + Text(" of 100").font(StrandFont.caption))
                        .foregroundStyle(StressRamp.color(NSSCard.level(c.nss)))
                }
            }
            Text(subtitle)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
            if !scores.isEmpty {
                NSSDayChart(readings: snapshot.readings, typical: snapshot.typical)
                HStack {
                    stat(String(localized: "Min"), scores.min())
                    Spacer()
                    stat(String(localized: "Avg"), snapshot.dayMean)
                    Spacer()
                    stat(String(localized: "Max"), scores.max())
                }
            }
        }
    }

    private var subtitle: String {
        guard let c = snapshot.current else {
            return snapshot.modelledPaces.isEmpty
                ? String(localized: "Learning your calm state — \(snapshot.modelDays) of \(snapshot.baselineDays) days")
                : String(localized: "No reading yet today")
        }
        let status = NSSCard.status(c.nss, typical: snapshot.typical, unusual: snapshot.unusualLevel).title
        if let mark = snapshot.unscoredExercise {
            return mark == .exercise
                ? String(localized: "Exercising — not scored · last reading \(NSSCard.clock(c.ts))")
                : String(localized: "Recovering from exercise — not scored · last reading \(NSSCard.clock(c.ts))")
        }
        return String(localized: "\(status.capitalized) · 5-minute readings since \(NSSCard.clock(snapshot.readings.first?.ts ?? c.ts))")
    }

    private func stat(_ label: String, _ v: Double?) -> some View {
        HStack(spacing: 5) {
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            Text(v.map { String(Int($0.rounded())) } ?? "–")
                .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
        }
    }
}

