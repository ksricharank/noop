import Foundation
import WhoopStore
import StrandAnalytics

/// The Recap tab's shareable text (260919, maintainer request: "a download tab to the recap page
/// similar to how the trends page has a download — I can download this summary and send it to other
/// LLM apps if I want to, each day morning").
///
/// TEXT, deliberately, where Trends exports a PDF. The stated destination is another LLM, and a PDF
/// of a rendered card is the worst possible container for that — it has to be OCR'd or re-uploaded,
/// and the numbers arrive as pixels. Markdown pastes into any chat box and every figure survives.
///
/// Pure and store-free so it is testable without a strap, a provider or a screen: the caller hands
/// over what it already loaded for the page.
enum DayRecapExport {

    /// Build the day's recap as Markdown.
    ///
    /// - Parameters:
    ///   - day: the "yyyy-MM-dd" key being browsed.
    ///   - score: that day's quality breakdown, when it scored.
    ///   - metric: the stored daily row behind it.
    ///   - recentScores: "yyyy-MM-dd" → score for context, newest handled here rather than by the
    ///     caller. A single day's number says little without the days around it, and the whole point
    ///     is to hand a reader enough to say something useful.
    static func markdown(day: String,
                         score: DayQualityScore?,
                         metric: DailyMetric?,
                         recentScores: [String: Double] = [:],
                         generatedAt: Date = Date()) -> String {
        var out: [String] = []
        out.append("# NOOP day recap — \(day)")
        out.append("")

        if let score {
            out.append("**Day quality: \(score.total)/100**  (execution \(oneDp(score.executionPoints)), recovery \(oneDp(score.recoveryPoints)))")
            if score.loadFactor != 1.0 {
                out.append("Load factor applied: ×\(twoDp(score.loadFactor))")
            }
        } else {
            // An unscored day is a real state — too little data — and saying so is more useful than
            // omitting the line and leaving the reader to wonder.
            out.append("**Day quality: not scored** (insufficient data for this day)")
        }
        out.append("")

        if let score, !score.components.isEmpty {
            out.append("## What drove the score")
            out.append("")
            out.append("| Component | Achieved | Points | Detail |")
            out.append("|---|---|---|---|")
            for c in score.components {
                out.append("| \(c.label) | \(pct(c.achieved)) | \(oneDp(c.points)) | \(c.detail) |")
            }
            out.append("")
        }

        if let score, !score.missing.isEmpty {
            // Named rather than silently dropped: a reader comparing two days needs to know one of
            // them was scored on fewer components.
            out.append("Not scored (no data): \(score.missing.joined(separator: ", "))")
            out.append("")
        }

        if let m = metric {
            out.append("## Measurements")
            out.append("")
            var rows: [String] = []
            func row(_ label: String, _ value: String?) {
                if let value { rows.append("- \(label): \(value)") }
            }
            row("Sleep", m.totalSleepMin.map { "\(Int($0 / 60))h \(Int($0.truncatingRemainder(dividingBy: 60)))m" })
            row("Sleep efficiency", m.efficiency.map { "\(Int($0))%" })
            row("Deep / REM / light", zip3(m.deepMin, m.remMin, m.lightMin).map {
                "\(Int($0))m / \(Int($1))m / \(Int($2))m" })
            row("Disturbances", m.disturbances.map(String.init))
            row("Recovery", m.recovery.map { "\(Int($0))%" })
            row("Strain", m.strain.map { oneDp($0) })
            row("Resting HR", m.restingHr.map { "\($0) bpm" })
            row("HRV", m.avgHrv.map { "\(Int($0)) ms" })
            row("Respiratory rate", m.respRateBpm.map { "\(oneDp($0)) br/min" })
            row("SpO₂", m.spo2Pct.map { "\(Int($0))%" })
            row("Skin temp deviation", m.skinTempDevC.map { "\(signedOneDp($0))°C" })
            row("Steps", m.steps.map(String.init))
            row("Active calories", m.activeKcalEst.map { "\(Int($0)) kcal" })
            out.append(contentsOf: rows.isEmpty ? ["- No stored measurements for this day."] : rows)
            out.append("")
        }

        let context = recentScores.keys.sorted().reversed().prefix(14)
            .compactMap { k -> String? in recentScores[k].map { "\(k): \(Int($0.rounded()))" } }
        if context.count > 1 {
            out.append("## Recent day scores (newest first)")
            out.append("")
            out.append(context.joined(separator: " · "))
            out.append("")
        }

        // States the provenance plainly. A file handed to another model should say what produced it
        // and when, so a stale paste is recognisable as stale.
        out.append("---")
        out.append("Generated by NOOP on \(stamp(generatedAt)). All figures computed on-device.")
        return out.joined(separator: "\n")
    }

    /// `noop-recap-2026-09-19.md` — the day it describes, not the day it was exported, so two
    /// exports of the same day overwrite rather than accumulate.
    static func filename(day: String) -> String { "noop-recap-\(day).md" }

    // MARK: - Formatting

    private static func oneDp(_ v: Double) -> String { String(format: "%.1f", v) }
    private static func twoDp(_ v: Double) -> String { String(format: "%.2f", v) }
    private static func signedOneDp(_ v: Double) -> String { String(format: "%+.1f", v) }
    private static func pct(_ achieved: Double) -> String { "\(Int((achieved * 100).rounded()))%" }

    private static func zip3(_ a: Double?, _ b: Double?, _ c: Double?) -> (Double, Double, Double)? {
        guard let a, let b, let c else { return nil }
        return (a, b, c)
    }

    private static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }
}
