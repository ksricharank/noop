import WidgetKit
import SwiftUI
import ActivityKit
import StrandDesign

/// Live Activity for an active live-HR session — shown on the Lock Screen and in the Dynamic Island.
struct NOOPLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NOOPActivityAttributes.self) { context in
            // Lock Screen / banner presentation: four EQUAL stat columns — Effort now/target,
            // Cal now/target (TOTAL calories), Steps now/target (thousands), and Sleep hours needed
            // tonight — one shared type size.
            // HISTORY: an HR column (live tilde + the red breathe-cue digits) led this row through
            // 10.6.0.14.9 and was removed 260830 by maintainer instruction — the card carries the
            // three TARGETS now; the HRV-dip "go breathe" read moved to the stress check-in's strap
            // buzz + screen notification. Charge left the banner earlier the same day (the targets
            // already encode it); it still reads in the expanded Dynamic Island.
            // Spacing dropped 14 → 10 when Steps became the fourth column; the stats' own
            // minimumScaleFactor absorbs the rest at narrow widths.
            HStack(spacing: 10) {
                // The identity icon doubles as the NOT-CONNECTED cue: grey while the strap link is
                // down (charging, out of range — the card holds its last values through a drop
                // instead of vanishing), red while connected. The numbers stay primary either way;
                // they are real, just frozen.
                Image(systemName: "waveform.path.ecg")
                    .font(.title2)
                    .foregroundStyle(context.state.bonded
                                     ? StrandPalette.statusCritical : StrandPalette.textSecondary)
                Spacer()
                bannerStat(label: "Steps", value: stepsText(context.state))
                Spacer()
                bannerStat(label: "Effort", value: effortNTText(context.state))
                Spacer()
                bannerStat(label: "Cal", value: calText(context.state))
                Spacer()
                bannerStat(label: "Sleep", value: sleepText(context.state))
            }
            .padding()
            .activityBackgroundTint(StrandPalette.surfaceBase)
            .activitySystemActionForegroundColor(StrandPalette.textPrimary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    // The heart carries the identity + the not-connected cue (red = linked, grey =
                    // dropped); the value beside it is the Effort pair, primary.
                    HStack(spacing: 4) {
                        Image(systemName: "heart.fill")
                            .foregroundStyle(context.state.bonded
                                             ? StrandPalette.statusCritical : StrandPalette.textSecondary)
                        Text(effortNTText(context.state))
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    // Charge (its band set today's targets) + the same Cal/Sleep pillars, one size.
                    // Steps is deliberately BANNER-ONLY (260830, maintainer: "I don't need steps in
                    // the island") — the island keeps its original three columns.
                    HStack(spacing: 10) {
                        if let r = context.state.recovery {
                            statColumn(label: "Charge", value: "\(r)")
                        }
                        statColumn(label: "Cal", value: calText(context.state))
                        statColumn(label: "Sleep", value: sleepText(context.state))
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.attributes.title).font(.caption).foregroundStyle(.secondary)
                }
            } compactLeading: {
                // Grey heart = link down (the compact face of the same cue). Deliberately NOT applied
                // to the minimal slot below: demoted next to another app's activity, the red tint is
                // the only thing identifying the number as ours.
                Image(systemName: "heart.fill")
                    .foregroundStyle(context.state.bonded
                                     ? StrandPalette.statusCritical : StrandPalette.textSecondary)
            } compactTrailing: {
                // The compact slot carries today's effort ALONE — the full "3.2/10.7" pair does not
                // fit a compact trailing without clipping, and the number the user checks in passing
                // is where the day stands, not the ask.
                Text(effortNowText(context.state))
            } minimal: {
                // The minimal slot is what iOS demotes us to whenever a SECOND Live Activity is running
                // — it is the only presentation the user sees then, so it has to carry a number. Only
                // ONE of icon-or-number fits (the slot is a ~24pt circle), so today's effort wins and
                // the red tint (the same statusCritical the rest of the widget uses) is what keeps it
                // identifiable as ours next to another app's activity. With no reading yet, fall back
                // to the heart rather than a dash: an en-dash alone reads as a broken widget, while
                // the heart honestly says "NOOP is here, no number yet".
                if let now = context.state.effortDisplay {
                    Text(now)
                        .foregroundStyle(StrandPalette.statusCritical)
                        // The slot clips rather than shrinks; allow one step of shrink and pin to one
                        // line so a wide value stays whole instead of silently losing a digit.
                        .minimumScaleFactor(0.8)
                        .lineLimit(1)
                } else {
                    Image(systemName: "heart.fill").foregroundStyle(StrandPalette.statusCritical)
                }
            }
        }
    }
}

/// The Effort display pair: today's effort over its target, both PRE-FORMATTED on the user's chosen
/// scale by the controller (the extension can't read the scale preference). Either side degrades
/// alone; a missing numerator with a live target reads "0/10.7", which a fresh day honestly is.
/// File-scope for the same reason as `bannerStat`.
private func effortNTText(_ state: NOOPActivityAttributes.ContentState) -> String {
    switch (state.effortDisplay, state.effortTargetDisplay) {
    case let (n?, t?): return "\(n)/\(t)"
    case let (n?, nil): return n
    case let (nil, t?): return "0/\(t)"
    case (nil, nil): return "–"
    }
}

/// Today's effort alone, for the compact/minimal slots where the pair cannot fit.
private func effortNowText(_ state: NOOPActivityAttributes.ContentState) -> String {
    state.effortDisplay ?? "–"
}

/// The Cal column: TOTAL calories so far over today's total target ("1830/2650"). Either side
/// degrades alone — no target yet shows just the count; no count yet shows "0/2650", which right
/// after midnight honestly is.
private func calText(_ state: NOOPActivityAttributes.ContentState) -> String {
    let count = state.kcal.map(String.init)
    let target = state.kcalTarget.map(String.init)
    switch (count, target) {
    case let (c?, t?): return "\(c)/\(t)"
    case let (c?, nil): return c
    case let (nil, t?): return "0/\(t)"
    case (nil, nil): return "–"
    }
}

/// The Sleep column: hours of sleep to target tonight, as "8h05" (minutes zero-padded so the glyph
/// count is stable across pushes).
private func sleepText(_ state: NOOPActivityAttributes.ContentState) -> String {
    guard let need = state.sleepNeedMin, need > 0 else { return "–" }
    return String(format: "%dh%02d", need / 60, need % 60)
}

/// The Steps column: today over target as FULL counts ("3205/8000") — the same vocabulary as
/// `WidgetSnapshot.stepsDisplay`, so the card and the widgets never spell the pair two ways.
private func stepsText(_ state: NOOPActivityAttributes.ContentState) -> String {
    switch (state.steps.map(String.init), state.stepsTarget.map(String.init)) {
    case let (n?, t?): return "\(n)/\(t)"
    case let (n?, nil): return n
    case let (nil, t?): return "0/\(t)"
    case (nil, nil): return "–"
    }
}

/// Lock-Screen banner stat column (label over value). File-scope because the `ActivityConfiguration`
/// content closure isn't a method of `NOOPLiveActivity`.
///
/// #759 - the label and value are CENTRE-aligned so each value sits directly under its own label. The
/// old `.trailing` alignment right-pinned both to the column's edge: when the value was narrower than
/// the label it drifted to the label's right edge instead of under it, which read as "the number
/// doesn't line up with its label". `fixedSize` stops either line truncating so the pairing is never
/// clipped at narrow widths.
@ViewBuilder
private func bannerStat(label: String, value: String) -> some View {
    VStack(alignment: .center, spacing: 2) {
        Text(label).font(.caption2).foregroundStyle(StrandPalette.textSecondary)
        // .headline (was .title3 in the HR era): the values are now n/t pairs ("1830/2650"), and
        // three of those at .title3 overflow the banner's width — one step down keeps all three
        // whole at a nightstand-readable size.
        Text(value).font(.headline).fontWeight(.semibold)
            .foregroundStyle(StrandPalette.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
    .multilineTextAlignment(.center)
}

/// Dynamic Island expanded-region stat column (label over value). File-scope for the same reason as
/// `bannerStat`. #759 - centre-aligned + `fixedSize` for the same value-under-its-label fix as the banner.
@ViewBuilder
private func statColumn(label: String, value: String) -> some View {
    VStack(alignment: .center, spacing: 1) {
        Text(label).font(.caption2).foregroundStyle(.secondary)
        Text(value).font(.headline)
    }
    .multilineTextAlignment(.center)
    .fixedSize()
}
