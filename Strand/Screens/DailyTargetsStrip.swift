import SwiftUI
import StrandDesign
import StrandAnalytics

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
    /// The "How these were set" disclosure — collapsed by default, session-local state.
    @State private var showDerivations = false

    var body: some View {
        // Reading `repo.hydrationSeq` is what subscribes this view to water writes: hydration
        // deliberately never bumps `refreshSeq` (#989), so without this the row would not re-render
        // on a logged cup even though the targets memo now recomputes. It also joins the memo key,
        // so the read is load-bearing twice over — never delete it as unused.
        let hydrationSeq = repo.hydrationSeq
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
            // Water (260903, maintainer's ask): a THIRD row spanning both columns, because it is
            // the one target that is logged by hand — the −/+ half-cup controls exist so water
            // drunk outside a reminder still lands. Writes through the SAME `logHydration` the
            // hydration screen and the reminder's action use, so the three can never disagree.
            // Hidden entirely when hydration tracking is off (`waterTargetCups` nil).
            if targets.waterTargetCups != nil {
                waterRow(targets).id(hydrationSeq)
            }
            // Optional derivations (260901, maintainer's ask): the precise formula behind each of
            // the four targets, with TODAY's inputs filled in — collapsed by default so the strip
            // stays a glance; sits between the numbers and the LLM narrative that interprets them.
            // The lines are built beside the pricing itself (`TargetsExplainer`, called inside
            // `Repository.liveTargets`), so they can never describe different numbers.
            if !targets.explainLines.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showDerivations.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showDerivations ? "chevron.down" : "chevron.right")
                                .font(StrandFont.caption)
                            Text("How these were set")
                                .font(StrandFont.caption)
                        }
                        .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .buttonStyle(.plain)
                    if showDerivations {
                        // One block per target (260901, third formatting pass): rounded medium-weight
                        // type instead of the mono terminal look — the header wears the metric's own
                        // colour (the same mapping as the cells above), rungs sit slightly bolder for
                        // glanceability, and the untaken-branch legends step back smaller + indented.
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(targets.explainLines, id: \.self) { block in
                                derivationBlock(block)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The water row: label + n/t in the same big rounded type the cells use, with half-cup −/+
    /// controls. Spans the full width (the maintainer's slotting) since it carries two controls.
    @ViewBuilder
    private func waterRow(_ t: LiveTargets) -> some View {
        let drunkHalves = HydrationGoal.halfCups(fromML: t.waterTodayML ?? 0)
        let goalCups = max(1, t.waterTargetCups ?? 0)
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Water")
                    .font(StrandFont.overline)
                    .tracking(1.2)
                    .foregroundStyle(StrandPalette.textTertiary)
                Text("\(HydrationGoal.cupsDisplay(halfCups: drunkHalves))/\(goalCups) cups")
                    .font(StrandFont.rounded(24, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.metricPurple)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
            }
            Spacer(minLength: 0)
            // Half-cup steps. Remove is disabled at zero rather than hidden, so the control pair
            // never reflows as the count changes.
            // Both controls move the number FIRST (optimistic), then persist. The store write is
            // four awaits and can queue behind a strap sync; a counter you cannot watch move is
            // not trackable, which is exactly what was reported.
            waterButton(systemName: "minus", disabled: drunkHalves == 0) {
                repo.bumpHydrationOptimistically(deltaML: -HydrationGoal.halfCupML)
                Task { await removeHalfCup() }
            }
            waterButton(systemName: "plus", disabled: false) {
                repo.bumpHydrationOptimistically(deltaML: HydrationGoal.halfCupML)
                Task { _ = await repo.logHydration(amountMl: HydrationGoal.halfCupML) }
            }
        }
        .padding(.top, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Water"))
        .accessibilityValue(Text("\(HydrationGoal.cupsDisplay(halfCups: drunkHalves)) of \(goalCups) cups"))
    }

    private func waterButton(systemName: String, disabled: Bool, action: @escaping () -> Void)
        -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(StrandFont.rounded(15, weight: .bold))
                .foregroundStyle(disabled ? StrandPalette.textTertiary : StrandPalette.metricPurple)
                .frame(width: 36, height: 32)
                .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(Text(systemName == "plus" ? "Add half a cup" : "Remove half a cup"))
    }

    /// Remove half a cup by deleting the most recent entries worth that much — the tracker stores
    /// per-drink entries, so "subtract" means retiring what was logged, never writing a negative.
    /// A last entry LARGER than a half-cup (a bottle) is shrunk rather than deleted, so undoing a
    /// half-cup tap cannot silently discard a 500 ml log.
    private func removeHalfCup() async {
        let entries = repo.hydrationEntries()
        guard let last = entries.last else { return }
        if last.amountMl > HydrationGoal.halfCupML {
            _ = await repo.updateHydrationEntry(id: last.id,
                                                amountMl: last.amountMl - HydrationGoal.halfCupML)
        } else {
            _ = await repo.deleteHydrationEntry(id: last.id)
        }
    }

    /// One derivation block: header line in the metric's colour, rungs in rounded medium weight,
    /// legend lines (the untaken branches, marked by their leading-space indent) smaller + inset.
    @ViewBuilder
    private func derivationBlock(_ block: String) -> some View {
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                if i == 0 {
                    Text(line)
                        .font(StrandFont.rounded(14, weight: .bold))
                        .foregroundStyle(derivationTint(line))
                } else if line.hasPrefix("   (") {
                    Text(line.trimmingCharacters(in: .whitespaces))
                        .font(StrandFont.rounded(11, weight: .regular))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .padding(.leading, 12)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(line)
                        .font(StrandFont.rounded(12.5, weight: .medium))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The same metric→colour mapping the four cells above use, keyed off the block header.
    private func derivationTint(_ header: String) -> Color {
        if header.hasPrefix("EFFORT") { return StrandPalette.effortColor }
        if header.hasPrefix("CAL") { return StrandPalette.metricAmber }
        if header.hasPrefix("STEP") { return StrandPalette.chargeColor }
        if header.hasPrefix("SLEEP") { return StrandPalette.metricCyan }
        if header.hasPrefix("WATER") { return StrandPalette.metricPurple }
        return StrandPalette.textPrimary
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
    /// caption label over a large rounded number, CENTRED in its half of the row (260830 review:
    /// left-aligned cells read as a ragged column; centring puts the numbers where the eye lands).
    /// A dash stays tertiary so missing data never wears a domain colour.
    private func targetCell(_ label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .center, spacing: 2) {
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
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(value))
    }
}
