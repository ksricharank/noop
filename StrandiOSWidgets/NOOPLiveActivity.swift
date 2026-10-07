import WidgetKit
import SwiftUI
import ActivityKit
import StrandDesign

/// Live Activity for an active live-HR session — shown on the Lock Screen and in the Dynamic Island.
struct NOOPLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NOOPActivityAttributes.self) { context in
            // Lock Screen / banner presentation: four EQUAL stat columns — HR, Steps now/target,
            // Cal now/target (TOTAL calories) and Effort now/target — one shared type size.
            //
            // HISTORY, since this row has now changed hands twice and the reasons matter: an HR
            // column (live tilde + the red breathe-cue digits) led it through 10.6.0.14.9 and was
            // removed 260830 by maintainer instruction in favour of the three targets. HR RETURNS
            // 260905 — "for the lock screen live notification, I realized I want HR, plus steps n/t
            // cal n/t, effort n/t" — taking Sleep's column rather than adding a fifth, because four
            // is what fits at this type size. Sleep still reads in the expanded Dynamic Island,
            // which this change deliberately leaves untouched ("for the dynamic island, we have the
            // right behavior"). The HRV-dip "go breathe" cue is NOT coming back with it; that moved
            // to the stress check-in's strap buzz + screen notification and stays there.
            //
            // WHY HR BELONGS HERE AND NOT ON THE WIDGET: a Live Activity is pushed directly by the
            // app — ~2 s unlocked, the wearer's locked spacing otherwise — and is NOT charged
            // against the WidgetKit reload budget. It is the only lock-screen surface that can carry
            // a genuinely live number.
            HStack(spacing: 10) {
                // The identity icon doubles as the NOT-CONNECTED cue: grey while the strap link is
                // down (charging, out of range — the card holds its last values through a drop
                // instead of vanishing), red while connected. The numbers stay primary either way;
                // they are real, just frozen.
                Image(systemName: "waveform.path.ecg")
                    .font(.body)
                    .foregroundStyle(context.state.bonded
                                     ? StrandPalette.statusCritical : StrandPalette.textSecondary)
                Spacer()
                bannerStat(label: "HR", value: hrText(context.state))
                Spacer()
                bannerStat(label: "Steps", value: stepsText(context.state))
                Spacer()
                bannerStat(label: "Cal", value: calText(context.state))
                Spacer()
                bannerStat(label: "Effort", value: effortNTText(context.state))
            }
            .padding()
            .activityBackgroundTint(StrandPalette.surfaceBase)
            .activitySystemActionForegroundColor(StrandPalette.textPrimary)
        } dynamicIsland: { context in
            DynamicIsland {
                // TOP ROW: Sleep, Water. BOTTOM ROW: Effort, Steps, Cal. Five values, no HR
                // (260905, maintainer: "in the expanded view remove the hr and just keep the other
                // five in their exact locations").
                //
                // HR is NOT gone from the island — it is the whole of the COLLAPSED presentation
                // (compact trailing + minimal), which is the one seen in passing. Expanding is the
                // deliberate act of asking for the day, and the day is these five. The heart glyph
                // goes with it: it was the not-connected cue for the HR value beside it, and with no
                // HR here it would be an icon indicating nothing.
                //
                // POSITIONS ARE UNCHANGED, as instructed. Sleep keeps the leading region's second
                // half and Water the trailing region, so removing HR leaves a gap on the left rather
                // than sliding everything across — the layout the maintainer just approved stays put.
                //
                // THE CORNERS: the expanded presentation wraps the sensor cutout and its
                // leading/trailing regions run into the rounded corners, so content pinned to an
                // outer edge is clipped by the curve — reported as "hr and charge are getting cutoff
                // at the corners, same with effort on the bottom left". Both halves of the fix are
                // needed and are kept here: centre each region's content AND inset its outer edge.
                //
                // `.center` is deliberately unused: it sits directly under the sensor cutout and is
                // the narrowest of the three top slots, so a value there risks the very clipping
                // this layout exists to avoid.
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 0) {
                        // The empty half HR used to occupy. Kept as a spacer rather than collapsed
                        // so Sleep stays exactly where it is.
                        Color.clear.frame(maxWidth: .infinity)
                        statColumn(label: "Sleep", value: sleepText(context.state))
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    statColumn(label: "Water", value: waterText(context.state))
                        .frame(maxWidth: .infinity)
                        .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    // The three progress pairs. Evenly divided rather than Spacer-separated:
                    // spacers push the outermost columns hard against the region's edges, which is
                    // what put them in the corner curve. Equal `maxWidth: .infinity` shares centre
                    // each value in its own third instead.
                    //
                    // Steps shows its FULL count here ("4412/8000"), not the widget faces'
                    // thousands-abbreviated form — a third of this region is wide enough for it, and
                    // the maintainer asked for it expanded.
                    HStack(spacing: 0) {
                        statColumn(label: "Effort", value: effortNTText(context.state))
                            .frame(maxWidth: .infinity)
                        statColumn(label: "Steps", value: stepsText(context.state))
                            .frame(maxWidth: .infinity)
                        statColumn(label: "Cal", value: calText(context.state))
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                // Grey heart = link down (the compact face of the same cue). Deliberately NOT applied
                // to the minimal slot below: demoted next to another app's activity, the red tint is
                // the only thing identifying the number as ours.
                Image(systemName: "heart.fill")
                    .foregroundStyle(context.state.bonded
                                     ? StrandPalette.statusCritical : StrandPalette.textSecondary)
            } compactTrailing: {
                // The compact slot carries the LIVE HEART RATE alone (260905). This is the slot seen
                // in passing whenever the island is collapsed, and the maintainer asked for the
                // island to show HR — so it carries the number that is actually moving, marked `~`
                // while it is a live beat.
                //
                // HISTORY: this held today's effort from 260830 until now. Effort has not left the
                // island — it reads in the EXPANDED region below, alongside Charge, Cal and Sleep.
                Text(hrText(context.state))
                    .minimumScaleFactor(0.8)
                    .lineLimit(1)
            } minimal: {
                // The minimal slot is what iOS demotes us to whenever a SECOND Live Activity is running
                // — it is the only presentation the user sees then, so it has to carry a number. Only
                // ONE of icon-or-number fits (the slot is a ~24pt circle), so the HEART RATE wins
                // (260905) and the red tint (the same statusCritical the rest of the widget uses) is
                // what keeps it identifiable as ours next to another app's activity. With no reading
                // yet, fall back to the heart rather than a dash: an en-dash alone reads as a broken
                // widget, while the heart honestly says "NOOP is here, no number yet".
                //
                // The bare number, without the `~` marker: at this size the tilde costs a digit of
                // width for a distinction the slot has no room to make.
                if let bpm = context.state.bpm {
                    Text("\(bpm)")
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

/// The heart rate for the banner's HR column (260905).
///
/// `~` marks a LIVE beat; a plain number is a settled window average — the wearer's Lock-Screen
/// refresh setting decides which, and the `-1` sentinel averages over the sync window itself. The
/// direction was chosen when the `live` flag was introduced and still holds: a card frozen because
/// no push can reach it is left holding the honest PLAIN form, never the live marker, so the tilde
/// can always be trusted to mean "this is beating now".
///
/// A dash when there is no reading at all, matching every other column's degrade rule — better than
/// presenting a stale number as current.
private func hrText(_ state: NOOPActivityAttributes.ContentState) -> String {
    guard let bpm = state.bpm else { return "–" }
    return (state.live == true ? "~" : "") + "\(bpm)"
}

/// The Water pair, whole cups ("5/21"). Half-cups are the stored resolution — the tracker logs half
/// a cup at a time — and the column renders cups, matching the widget faces and the Today row.
/// A nil target means hydration tracking is off, so the column reads as a dash rather than "0/0".
private func waterText(_ state: NOOPActivityAttributes.ContentState) -> String {
    guard let target = state.waterTargetCups, target > 0 else { return "–" }
    return "\((state.waterHalfCups ?? 0) / 2)/\(target)"
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
        // .title3 BOLD ("as large as possible without spoiling the formatting", 260830 third
        // review): four n/t pairs at this size nominally overrun a narrow banner, so the
        // minimumScaleFactor floor is what guarantees the formatting — the wide pairs shrink to
        // fit their column while the short ones (Effort, Sleep) keep the full size.
        Text(value).font(.title3).fontWeight(.bold)
            .foregroundStyle(StrandPalette.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.55)
    }
    .multilineTextAlignment(.center)
}

/// Dynamic Island expanded-region stat column (label over value). File-scope for the same reason as
/// `bannerStat`. #759 - centre-aligned + `fixedSize` for the same value-under-its-label fix as the banner.
@ViewBuilder
private func statColumn(label: String, value: String) -> some View {
    VStack(alignment: .center, spacing: 1) {
        Text(label).font(.caption2).foregroundStyle(.secondary)
        Text(value)
            .font(.headline)
            // 260905: shrink rather than clip. `fixedSize` below keeps a column from being squeezed
            // narrower than its content, which is what stops a value wrapping mid-number — but with
            // four equal columns sharing the bottom region, a wide pair ("1830/2650") can want more
            // than its quarter. Allowing one step of shrink means it narrows to fit instead of
            // overflowing its share into the neighbour or the corner curve.
            .minimumScaleFactor(0.75)
            .lineLimit(1)
    }
    .multilineTextAlignment(.center)
    .fixedSize(horizontal: false, vertical: true)
}
