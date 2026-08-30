import SwiftUI
import StrandDesign

/// The three daily-target numbers — HR, exercise calories now/target, tonight's sleep target — big
/// and clear at the head of the Synthesis section, BEFORE the LLM narrative (260830, the maintainer's
/// ask: the numbers the narrative explains should be readable without reading it, the way Charge ·
/// Effort · Rest are above).
///
/// The values are the SAME ones every other surface cites — `Repository.cachedLiveTargets` for Cal
/// and Sleep (memoized; the Live Activity card and the coach synthesis read the identical struct) and
/// the burst-average HR the NOOP Targets widget shows — so the strip, the card, the widget and the
/// narrative can never disagree. HR upgrades to the LIVE beat (tilde) whenever one is flowing, which
/// in the island-less default mode it typically is not: daytime data arrives as ~15-minute offload
/// bursts, and the plain settled number is the honest form for an average.
///
/// Shared by BOTH Today screens (classic `TodayView` + `LiquidTodayView` — the codebase treats their
/// divergence as a bug), and compiles on macOS too (LiveState/Repository are cross-platform).
struct DailyTargetsStrip: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var live: LiveState

    /// Mean HR over the freshest offload burst (`Repository.burstAvgHr`), loaded off the render path
    /// and re-resolved when the dashboard caches actually change (a completed offload bumps
    /// `refreshSeq`). Nil while loading and when the freshest sample is stale — the cell then abstains.
    @State private var burstAvg: Int?

    var body: some View {
        let targets = repo.cachedLiveTargets()
        HStack(alignment: .top, spacing: 0) {
            targetCell("HR", value: hrText, tint: StrandPalette.statusCritical)
            targetCell("Cal", value: calText(targets), tint: StrandPalette.effortColor)
            targetCell("Sleep", value: sleepText(targets), tint: StrandPalette.restColor)
        }
        .task(id: repo.refreshSeq) { burstAvg = await repo.burstAvgHr() }
    }

    /// A LIVE beat wears the tilde ("~72", still moving — same vocabulary as the Live Activity card);
    /// otherwise the burst average as the plain settled number; "–" when neither exists.
    private var hrText: String {
        if let hr = live.heartRate, hr > 0, live.connected { return "~\(hr)" }
        if let avg = burstAvg { return "\(avg)" }
        return "–"
    }

    /// "820/2100" — mirrors `WidgetSnapshot.calDisplay` / the Live Activity's Cal column: either side
    /// degrades alone, and a missing count early in the day honestly reads "0/2100".
    private func calText(_ t: LiveTargets) -> String {
        switch (t.exerciseKcalToday.map(String.init), t.kcalTargetKcal.map(String.init)) {
        case let (c?, t?): return "\(c)/\(t)"
        case let (c?, nil): return c
        case let (nil, t?): return "0/\(t)"
        case (nil, nil): return "–"
        }
    }

    /// "8h05" — mirrors `WidgetSnapshot.sleepDisplay` / the Live Activity's Sleep column.
    private func sleepText(_ t: LiveTargets) -> String {
        guard let need = t.sleepNeedTonightMin, need > 0 else { return "–" }
        return String(format: "%dh%02d", need / 60, need % 60)
    }

    /// One big labelled value, equal-width — the "score" presentation the hero trio established:
    /// caption label over a large rounded number. A dash stays tertiary so missing data never wears
    /// a domain colour.
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
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(value))
    }
}
