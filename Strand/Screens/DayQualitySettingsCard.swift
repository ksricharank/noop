import SwiftUI
import StrandDesign
import StrandAnalytics

/// The day-quality score's three knobs, at the bottom of Trends.
///
/// Placed there on maintainer instruction — the controls belong out of the way of the numbers they
/// tune, and the score itself leads the screen. Collapsed by default for the same reason: someone
/// reading their trend should not have to scroll past a settings panel to reach the charts.
///
/// Changing any of these re-scores HISTORY, not just future days: the nightly latch is keyed on a
/// config fingerprint, so the next pass recomputes every stored day under the new settings. The card
/// says so, because a slider that silently applied only to tomorrow would be a trap.
struct DayQualitySettingsCard: View {

    // `@State` mirrors rather than `@AppStorage`, because every one of these has a non-zero default
    // and plain `@AppStorage` reads an unset key as 0 — the same trap the breathe-sensitivity params
    // documented. Seeded from the prefs (which fall back to the scorer's own defaults) and written
    // back through them on change.
    @State private var loadFactorPct = DayQualityPrefs.loadFactorPct
    @State private var overshootPct = DayQualityPrefs.overshootCapPct
    @State private var expanded = false
    // The absolute normal-day anchor — the day the score calls zero (260909).
    @State private var normalSteps = DayQualityPrefs.normalSteps
    @State private var normalKcal = DayQualityPrefs.normalKcal
    @State private var normalEffort = DayQualityPrefs.normalEffort
    @State private var normalWater = DayQualityPrefs.normalWaterCups
    @State private var normalSleepMin = DayQualityPrefs.normalSleepMin

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Score settings").strandOverline()
                            Text("How day quality is weighted")
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textPrimary)
                            // The zero point, visible WITHOUT expanding (260909). The maintainer
                            // could not find these controls, and a collapsed panel is the right home
                            // for weighting knobs but the wrong one for the definition of zero: it is
                            // what the whole number means, and a reader needs it to interpret every
                            // score on the page above.
                            Text("Zero is \(normalSteps) steps · \(normalKcal) kcal · effort \(normalEffort) · \(normalWater) cups · \(Self.hours(normalSleepMin)) sleep")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 2)
                        }
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .rotationEffect(.degrees(expanded ? 0 : -90))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Collapse score settings" : "Expand score settings")

                if expanded {
                    // ── The zero point ──────────────────────────────────────────────────────────────
                    // The score's origin, stated in absolute units rather than derived from recent
                    // history. Deliberately first: it is the setting that most changes what the
                    // number MEANS, and the one a reader needs in order to interpret everything else.
                    //
                    // `Execution share` used to lead this list and has been removed. The scale no
                    // longer splits a fixed 100 points between two halves for it to divide, so it
                    // moved nothing — and a slider that moves nothing is worse than no slider.
                    VStack(alignment: .leading, spacing: 4) {
                        Text("A normal day").strandOverline()
                        Text("The day the score calls zero: no deliberate exercise, an ordinary night. Beat these and the score climbs; fall short and it goes negative.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    stepperRow(
                        label: "Normal steps",
                        help: "Steps on a day with no deliberate walking or exercise — just moving around.",
                        value: $normalSteps, suffix: "", range: 0...20_000, step: 250
                    ) { DayQualityPrefs.setNormalSteps($0) }

                    rowDivider
                    stepperRow(
                        label: "Normal calories",
                        help: "Active calories burned on such a day.",
                        value: $normalKcal, suffix: " kcal", range: 0...6000, step: 50
                    ) { DayQualityPrefs.setNormalKcal($0) }

                    rowDivider
                    stepperRow(
                        label: "Normal effort",
                        help: "Effort on an ordinary day, on the 0–100 internal scale. Pottering, not training.",
                        value: $normalEffort, suffix: "", range: 0...100, step: 1
                    ) { DayQualityPrefs.setNormalEffort($0) }

                    rowDivider
                    stepperRow(
                        label: "Normal water",
                        help: "Cups you'd drink without thinking about it.",
                        value: $normalWater, suffix: " cups", range: 0...40, step: 1
                    ) { DayQualityPrefs.setNormalWaterCups($0) }

                    rowDivider
                    // Sleep is stored in minutes and shown in hours — a stepper in minutes would take
                    // dozens of taps to cross a useful range.
                    stepperRow(
                        label: "Normal sleep",
                        help: "A normal night, not a good one. Sleeping past this earns points; falling short costs them.",
                        value: $normalSleepMin, suffix: "", range: 0...900, step: 15,
                        format: { Self.hours($0) }
                    ) { DayQualityPrefs.setNormalSleepMin($0) }

                    if DayQualityPrefs.normalDayIsCustomised {
                        Button("Reset the normal day") {
                            DayQualityPrefs.resetNormalDay()
                            normalSteps = DayQualityPrefs.normalSteps
                            normalKcal = DayQualityPrefs.normalKcal
                            normalEffort = DayQualityPrefs.normalEffort
                            normalWater = DayQualityPrefs.normalWaterCups
                            normalSleepMin = DayQualityPrefs.normalSleepMin
                        }
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.accent)
                        .buttonStyle(.plain)
                    }

                    rowDivider
                    stepperRow(
                        label: "Hard-day credit",
                        help: "Your targets shrink on a low-charge day, so hitting them is easier. This scales the execution half by how demanding the day's targets were against your recent average. 0% turns it off.",
                        value: $loadFactorPct, suffix: "%", range: 0...100, step: 10
                    ) { DayQualityPrefs.setLoadFactorPct($0) }

                    rowDivider
                    stepperRow(
                        label: "Overshoot credit",
                        help: "How far past a target a component keeps earning, as a share of the normal-to-target distance. 170% is what makes a fully-beaten day reach 100; 100% stops every component at its target exactly.",
                        value: $overshootPct, suffix: "%", range: 100...300, step: 10
                    ) { DayQualityPrefs.setOvershootCapPct($0) }

                    rowDivider
                    Text("Changing these re-scores your whole history on the next sync, so the trend stays consistent with the settings.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    if DayQualityPrefs.isCustomised {
                        Button("Reset to defaults") {
                            DayQualityPrefs.reset()
                            loadFactorPct = DayQualityPrefs.loadFactorPct
                            overshootPct = DayQualityPrefs.overshootCapPct
                        }
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.accent)
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Same shape as `AutomationsView.stepperRow` — a Stepper, not a Slider, matching every other
    /// numeric knob in the app (and far easier to land on an exact value with a thumb).
    /// `format` overrides the plain "value + suffix" display, for a row whose stored unit is not the
    /// one worth reading (sleep is stored in minutes and shown in hours — a minutes stepper would
    /// otherwise need dozens of taps to cross a useful range).
    private func stepperRow(label: LocalizedStringKey, help: LocalizedStringKey,
                            value: Binding<Int>, suffix: String,
                            range: ClosedRange<Int>, step: Int,
                            format: ((Int) -> String)? = nil,
                            onChange: @escaping (Int) -> Void) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                Text(help)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text(format?(value.wrappedValue) ?? "\(value.wrappedValue)\(suffix)")
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textSecondary)
                .monospacedDigit()
            Stepper("", value: value, in: range, step: step)
                .labelsHidden()
                .accessibilityLabel(label)
        }
        .frame(minHeight: 42)
        .padding(.vertical, 4)
        .onChangeCompat(of: value.wrappedValue) { newValue in onChange(newValue) }
    }

    private var rowDivider: some View {
        Divider().overlay(StrandPalette.hairline)
    }

    /// Minutes as a compact "7h 30m" / "7h".
    static func hours(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}
