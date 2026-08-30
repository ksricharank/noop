import WidgetKit
import SwiftUI
import ActivityKit
import StrandDesign

/// Live Activity for an active live-HR session — shown on the Lock Screen and in the Dynamic Island.
struct NOOPLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NOOPActivityAttributes.self) { context in
            // Lock Screen / banner presentation: three EQUAL stat columns, one per pillar —
            // HR n/ceiling (breathing & heart rate), Cal n/target (activity & exercise), and Sleep
            // hours needed tonight (rest & sleep) — one shared type size, no oversized hero number.
            // Charge left the banner deliberately: the targets already encode it (they are derived
            // from its band), and it still reads in the expanded Dynamic Island. Effort and Rest
            // live in the coach synthesis now, not on the card.
            HStack(spacing: 14) {
                // The identity icon doubles as the NOT-CONNECTED cue: grey while the strap link is
                // down (charging, out of range — the card now holds its last values through a drop
                // instead of vanishing), red while connected. The numbers stay primary either way;
                // they are real, just frozen — and `live == false` already strips the tilde.
                Image(systemName: "waveform.path.ecg")
                    .font(.title2)
                    .foregroundStyle(context.state.bonded
                                     ? StrandPalette.statusCritical : StrandPalette.textSecondary)
                Spacer()
                // The tilde marks a LIVE beat ("~72", still moving); a window average / frozen value
                // is the plain settled number. The denominator is the calm ceiling — over it the
                // value tints red: the meditate cue.
                bannerStat(label: "HR", value: hrText(context.state, withCeiling: true),
                           tint: elevatedTint(context.state))
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
                    // Same not-connected cue as the banner's icon: grey heart while the link is down.
                    Label(hrText(context.state, withCeiling: true), systemImage: "heart.fill")
                        .foregroundStyle(context.state.bonded
                                         ? StrandPalette.statusCritical : StrandPalette.textSecondary)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    // Charge (its band set today's targets) + the same Cal/Sleep pillars the banner
                    // carries, one size.
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
                // No ceiling in the compact slot — "~72/85" does not fit; the denominator reads in
                // the expanded island and on the banner.
                Text(hrText(context.state, withCeiling: false))
                    .foregroundStyle(elevatedTint(context.state) ?? Color.primary)
            } minimal: {
                // The minimal slot is what iOS demotes us to whenever a SECOND Live Activity is running
                // — it is the only presentation the user sees then, so it has to carry the number. A bare
                // heart icon here (the pre-fix content) told the user nothing they didn't already know:
                // that NOOP was running. The heart rate IS the point of this activity.
                //
                // Only ONE of icon-or-number fits: the slot is a ~24pt circle. Stacking both drops the
                // digits to roughly 7pt, which is unreadable at a glance and so defeats the fix. So the
                // number wins outright and the red tint (the same statusCritical the rest of the widget
                // uses) is what keeps it identifiable as ours next to another app's activity.
                //
                // With no reading, fall back to the heart rather than rendering a dash: an en-dash alone
                // in the slot reads as a broken widget, while the heart honestly says "NOOP is here, no
                // number yet". DEFENSIVE — `LiveActivityController.update` guards `bpm != nil` before it
                // ever starts or pushes a state, so a nil should not reach here; it stays because the
                // ContentState field is optional and a stale activity re-adopted across an app relaunch
                // decodes whatever a previous build wrote.
                if let bpm = context.state.bpm {
                    Text("\(bpm)")
                        .foregroundStyle(StrandPalette.statusCritical)
                        // The slot clips rather than shrinks, so a 3-digit HR (a hard workout) would lose
                        // a digit at the default size. Allow one step of shrink and pin to one line so
                        // "142" stays "142" instead of silently becoming "14".
                        .minimumScaleFactor(0.8)
                        .lineLimit(1)
                } else {
                    Image(systemName: "heart.fill").foregroundStyle(StrandPalette.statusCritical)
                }
            }
        }
    }
}

/// The HR display string: a LIVE beat carries the tilde ("~72" — still moving), a window average /
/// frozen value is the plain settled number. `live` is nil on activities written by older builds —
/// treated as not-live, so an inherited card never claims liveness it can't back. With
/// `withCeiling`, the calm ceiling rides as the denominator ("~72/85") — the tilde belongs to the
/// reading, never the target. File-scope for the same reason as `bannerStat`. The `minimal` slot
/// deliberately uses NEITHER: it clips rather than shrinks, and the extra glyphs would cost the
/// third digit of a workout HR.
private func hrText(_ state: NOOPActivityAttributes.ContentState, withCeiling: Bool) -> String {
    guard let bpm = state.bpm else { return "–" }
    let reading = state.live == true ? "~\(bpm)" : "\(bpm)"
    guard withCeiling, let ceiling = state.hrCeiling else { return reading }
    return "\(reading)/\(ceiling)"
}

/// Red when the reading sits ABOVE the calm ceiling — the meditate/calm-down cue; nil (no tint)
/// otherwise, including when no ceiling is known yet. Honest to a fault during exercise: a workout
/// legitimately exceeds the ceiling and reads red — the ceiling is a rest-state line, and the card
/// has no workout signal to suppress on, so the tint simply says "your heart is above calm" either way.
private func elevatedTint(_ state: NOOPActivityAttributes.ContentState) -> Color? {
    guard let bpm = state.bpm, let ceiling = state.hrCeiling, bpm > ceiling else { return nil }
    return StrandPalette.statusCritical
}

/// The Cal column: active calories so far over today's target ("820/2100"). Either side degrades
/// alone — no target yet (thin history) shows just the count; no count yet (today's row hasn't
/// landed) shows "0/2100", which early morning honestly is.
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

/// Lock-Screen banner stat column (label over value). File-scope because the `ActivityConfiguration`
/// content closure isn't a method of `NOOPLiveActivity`.
///
/// #759 - the label and value are CENTRE-aligned so each value sits directly under its own label. The
/// old `.trailing` alignment right-pinned both to the column's edge: when the value was narrower than
/// the label (e.g. "12" under "Effort") it drifted to the label's right edge instead of under it, which
/// read as "the number doesn't line up with its label". `fixedSize` stops either line truncating so the
/// pairing is never clipped at narrow widths.
@ViewBuilder
private func bannerStat(label: String, value: String, tint: Color? = nil) -> some View {
    VStack(alignment: .center, spacing: 2) {
        Text(label).font(.caption2).foregroundStyle(StrandPalette.textSecondary)
        // .title3 (one step up from .headline): the three values are the banner's whole payload and
        // read from a nightstand distance; the labels stay caption2 so the numbers carry the row.
        // `tint` overrides for a state worth flagging (HR above the calm ceiling).
        Text(value).font(.title3).fontWeight(.semibold)
            .foregroundStyle(tint ?? StrandPalette.textPrimary)
    }
    .multilineTextAlignment(.center)
    .fixedSize()
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
