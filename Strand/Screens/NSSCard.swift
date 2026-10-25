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
                    let points = Self.linePoints(snapshot.readings)
                    if showsLine, points.contains(where: { $0.level != nil }) {
                        DaytimeLoadLine(hours: points, referenceLevel: snapshot.typical.map(Self.level))
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
