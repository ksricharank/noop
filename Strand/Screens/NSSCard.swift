import SwiftUI
import StrandDesign
import StrandAnalytics

/// The Stress tab's NSS card (261024): the Normalized Stress Score now, today's line, the last high,
/// and an honest caption. Reads `NormalizedStressStore`'s snapshot — the same one the Today card and
/// the coach read — so the three always show one number for one moment.
///
/// Colour and band reuse the Stress screen's ramp at NSS × 3/100, so a HIGH NSS and a HIGH 0–3 score
/// look the same, and the line is the screen's own `DaytimeLoadLine` fed 5-minute points on that scale.
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
                        let band = StressBand(score: Self.level(c.nss))
                        StatePill("\(band.title)", tone: band.tone, showsDot: true)
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
                        if let mean = snapshot.dayMean {
                            Text("today avg \(Int(mean.rounded()))")
                                .font(StrandFont.captionNumber)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                    Text(Self.explanation(c, unscoredNow: snapshot.unscoredNow))
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    let points = Self.linePoints(snapshot.readings)
                    if showsLine, points.contains(where: { $0.level != nil }) {
                        DaytimeLoadLine(hours: points)
                    }
                    if let e = snapshot.lastHigh {
                        Text("Last high \(Self.clock(e.startTs))–\(Self.clock(e.endTs)) · peak \(Int(e.peak.nss.rounded())) while \(e.peak.pace.phrase)")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                } else {
                    Text(snapshot.modelledPaces.isEmpty
                         ? "Learning your usual heart rate and HRV at each pace — \(snapshot.modelDays) of 14 days so far."
                         : "No reading yet today.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("50 is your usual for the pace you're moving at. Higher means your heart is working harder and your HRV is lower than that activity explains, against your own last 14 days. Heat, caffeine, a meal, illness or talking raise it too. Experimental.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// NSS on the Stress screen's 0–3 band and colour scale.
    static func level(_ nss: Double) -> Double { nss * 3 / 100 }

    /// One plain line: the pace and what moved the score.
    static func explanation(_ r: NormalizedStress.Reading, unscoredNow: NormalizedStress.Window?) -> String {
        let diff = Int((r.hr - r.hrPred).rounded())
        let heart = diff == 0
            ? String(localized: "heart rate right at your usual for this pace")
            : String(localized: "heart rate \(abs(diff)) bpm \(diff > 0 ? String(localized: "above") : String(localized: "below")) your usual for this pace")
        var line = String(localized: "While \(r.pace.phrase): \(heart)")
        if let z = r.zRMSSD, abs(z) >= 1 {
            line += z > 0 ? String(localized: ", HRV lower than usual") : String(localized: ", HRV higher than usual")
        }
        line += "."
        if let u = unscoredNow {
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
