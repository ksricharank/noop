import SwiftUI
import StrandDesign

/// The daily-target numbers — Effort now/target, TOTAL calories now/target, Steps now/target,
/// tonight's sleep target — big and clear at the head of the Synthesis section, BEFORE the LLM
/// narrative (260830,
/// the maintainer's ask: the numbers the narrative explains should be readable without reading it,
/// the way Charge · Effort · Rest are above). An HR cell (live tilde / burst average) held the first
/// column for one build and was replaced same-day by Effort n/t on maintainer instruction.
///
/// The values are the SAME ones every other surface cites — `Repository.cachedLiveTargets` (memoized;
/// the Live Activity card, the widgets and the coach synthesis read the identical struct) — so the
/// strip, the card, the widgets and the narrative can never disagree. Effort renders on the user's
/// chosen display scale, exactly like the card.
///
/// Shared by BOTH Today screens (classic `TodayView` + `LiquidTodayView` — the codebase treats their
/// divergence as a bug), and compiles on macOS too (Repository is cross-platform).
struct DailyTargetsStrip: View {
    @EnvironmentObject private var repo: Repository
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue

    var body: some View {
        let targets = repo.cachedLiveTargets()
        // 2×2 grid (260830 revision: four cells in one row collided at "1214/2075" widths) — Steps
        // and Cal on top, Effort and Sleep below, per the maintainer's slotting. One distinct data
        // colour per metric, the SAME mapping the widgets use, so the two surfaces read as one.
        // Row pairing balances widths now steps are FULL counts: the two long pairs (Steps, Cal)
        // each share a row with a short value (Effort, Sleep), so the rows come out even.
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                targetCell("Steps", value: stepsText(targets), tint: StrandPalette.chargeColor)
                targetCell("Effort", value: effortText(targets), tint: StrandPalette.effortColor)
            }
            HStack(alignment: .top, spacing: 12) {
                targetCell("Cal", value: calText(targets), tint: StrandPalette.metricAmber)
                targetCell("Sleep", value: sleepText(targets), tint: StrandPalette.metricCyan)
            }
        }
    }

    /// "3205/8000" — full counts, mirrors `WidgetSnapshot.stepsDisplay` / the card's Steps column.
    private func stepsText(_ t: LiveTargets) -> String {
        switch (t.stepsToday.map(String.init), t.stepsTarget.map(String.init)) {
        case let (n?, tt?): return "\(n)/\(tt)"
        case let (n?, nil): return n
        case let (nil, tt?): return "0/\(tt)"
        case (nil, nil): return "–"
        }
    }


    /// "3.2/10.7" on the user's chosen scale — mirrors the card's Effort column: either side degrades
    /// alone, and a fresh day with a live target honestly reads "0/10.7".
    private func effortText(_ t: LiveTargets) -> String {
        let scale = UnitPrefs.resolveEffortScale(effortScaleRaw)
        func fmt(_ stored: Int?) -> String? {
            guard let stored else { return nil }
            if scale == .whoop {
                return String(format: "%.1f", UnitFormatter.effortValue(Double(stored), scale: .whoop))
            }
            return "\(stored)"
        }
        switch (fmt(t.effortTodayStored), fmt(t.effortTarget)) {
        case let (n?, tt?): return "\(n)/\(tt)"
        case let (n?, nil): return n
        case let (nil, tt?): return "0/\(tt)"
        case (nil, nil): return "–"
        }
    }

    /// "1830/2650" — TOTAL calories, mirrors `WidgetSnapshot.calDisplay` / the card's Cal column.
    private func calText(_ t: LiveTargets) -> String {
        switch (t.kcalToday.map(String.init), t.kcalTargetKcal.map(String.init)) {
        case let (c?, tt?): return "\(c)/\(tt)"
        case let (c?, nil): return c
        case let (nil, tt?): return "0/\(tt)"
        case (nil, nil): return "–"
        }
    }

    /// "8h05" — mirrors `WidgetSnapshot.sleepDisplay` / the card's Sleep column.
    private func sleepText(_ t: LiveTargets) -> String {
        guard let need = t.sleepNeedTonightMin, need > 0 else { return "–" }
        return String(format: "%dh%02d", need / 60, need % 60)
    }

    /// One big labelled value, equal-width — the "score" presentation the hero trio established:
    /// caption label over a large rounded number. Back to the full 24pt now the 2×2 grid gives each
    /// pair half a row; `minimumScaleFactor` still carries the widest case. A dash stays tertiary so
    /// missing data never wears a domain colour.
    private func targetCell(_ label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(StrandFont.overline)
                .tracking(1.2)
                .foregroundStyle(StrandPalette.textTertiary)
            Text(value)
                .font(StrandFont.rounded(24, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(value == "–" ? StrandPalette.textTertiary : tint)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(value))
    }
}
