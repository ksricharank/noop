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
    @State private var executionPct = DayQualityPrefs.executionSharePct
    @State private var loadFactorPct = DayQualityPrefs.loadFactorPct
    @State private var overshootPct = DayQualityPrefs.overshootCapPct
    @State private var expanded = false

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
                    stepperRow(
                        label: "Execution share",
                        help: "How much of the score comes from hitting your targets — steps, calories, effort and water. The rest comes from how your body responded: sleep, HRV and resting heart rate.",
                        value: $executionPct, suffix: "%", range: 0...100, step: 5
                    ) { DayQualityPrefs.setExecutionSharePct($0) }

                    rowDivider
                    stepperRow(
                        label: "Hard-day credit",
                        help: "Your targets shrink on a low-charge day, so hitting them is easier. This scales the execution half by how demanding the day's targets were against your recent average. 0% turns it off.",
                        value: $loadFactorPct, suffix: "%", range: 0...100, step: 10
                    ) { DayQualityPrefs.setLoadFactorPct($0) }

                    rowDivider
                    stepperRow(
                        label: "Overshoot credit",
                        help: "The most a single component can score by beating its target. 125% means beating a target by a quarter earns the full bonus; 100% caps every component at its target exactly.",
                        value: $overshootPct, suffix: "%", range: 100...200, step: 5
                    ) { DayQualityPrefs.setOvershootCapPct($0) }

                    rowDivider
                    Text("Changing these re-scores your whole history on the next sync, so the trend stays consistent with the settings.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    if DayQualityPrefs.isCustomised {
                        Button("Reset to defaults") {
                            DayQualityPrefs.reset()
                            executionPct = DayQualityPrefs.executionSharePct
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
    private func stepperRow(label: LocalizedStringKey, help: LocalizedStringKey,
                            value: Binding<Int>, suffix: String,
                            range: ClosedRange<Int>, step: Int,
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
            Text("\(value.wrappedValue)\(suffix)")
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
}
