import SwiftUI
import StrandDesign

/// The three daily-target numbers — Effort now/target, TOTAL calories now/target, tonight's sleep
/// target — big and clear at the head of the Synthesis section, BEFORE the LLM narrative (260830,
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
        HStack(alignment: .top, spacing: 0) {
            targetCell("Effort", value: effortText(targets), tint: StrandPalette.effortColor)
            targetCell("Cal", value: calText(targets), tint: StrandPalette.effortColor)
            targetCell("Sleep", value: sleepText(targets), tint: StrandPalette.restColor)
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
    /// caption label over a large rounded number. Sized one step below the HR-era 24pt because the
    /// n/t pairs are wide ("1830/2650"); `minimumScaleFactor` keeps the worst case whole. A dash
    /// stays tertiary so missing data never wears a domain colour.
    private func targetCell(_ label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(StrandFont.overline)
                .tracking(1.2)
                .foregroundStyle(StrandPalette.textTertiary)
            Text(value)
                .font(StrandFont.rounded(20, weight: .bold))
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
