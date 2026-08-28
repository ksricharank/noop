import WidgetKit
import SwiftUI
import ActivityKit
import StrandDesign

/// Live Activity for an active live-HR session — shown on the Lock Screen and in the Dynamic Island.
struct NOOPLiveActivity: Widget {
    /// The heart rate to draw: none once iOS has marked the banner stale. Each push is fresh for 30 s
    /// (`LiveActivityController.staleAfter`) and NOOP re-pushes a steady number well inside that, so a stale banner
    /// means the readings stopped — the strap off the wrist, or out of reach — even while NOOP itself is asleep and
    /// cannot say so: iOS redraws the banner at the stale date on its own.
    static func shownBpm(_ context: ActivityViewContext<NOOPActivityAttributes>) -> Int? {
        context.isStale ? nil : context.state.bpm
    }

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NOOPActivityAttributes.self) { context in
            // Lock Screen / banner presentation: four EQUAL stat columns — HR, Charge, Effort,
            // Rest — one shared type size, no oversized hero number. HR is a labelled peer of the
            // others (the old caption-title + 26 pt bpm read as "live beat" even when the locked
            // duty cycle is showing a window average; equal columns read as the summary they are).
            HStack(spacing: 14) {
                Image(systemName: "waveform.path.ecg")
                    .font(.title2)
                    .foregroundStyle(StrandPalette.statusCritical)
                Spacer()
<<<<<<< HEAD
                bannerStat(label: "HR", value: Self.shownBpm(context).map(String.init) ?? "–")
=======
                // The tilde marks a LIVE beat ("~72", still moving); a window average / frozen value
                // is the plain settled number. Deliberately this way round: when the phone locks and
                // pushes stop reaching the card, whatever is on it is by definition not live — the
                // plain form it is left holding stays honest without needing a repaint.
                bannerStat(label: "HR", value: hrText(context.state))
>>>>>>> 6687427ec (Live Activity: tilde marks LIVE beats; +N lock-edge average; 8 h lease renewal)
                Spacer()
                bannerStat(label: "Charge",
                           value: context.state.recovery.map(String.init) ?? "–")
                Spacer()
                bannerStat(label: "Effort",
                           value: context.state.effort.map(String.init) ?? "–")
                Spacer()
                bannerStat(label: "Rest",
                           value: context.state.rest.map(String.init) ?? "–")
            }
            .padding()
            .activityBackgroundTint(StrandPalette.surfaceBase)
            .activitySystemActionForegroundColor(StrandPalette.textPrimary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
<<<<<<< HEAD
                    Label("\(Self.shownBpm(context).map(String.init) ?? "–")", systemImage: "heart.fill")
=======
                    Label(hrText(context.state), systemImage: "heart.fill")
>>>>>>> 6687427ec (Live Activity: tilde marks LIVE beats; +N lock-edge average; 8 h lease renewal)
                        .foregroundStyle(StrandPalette.statusCritical)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    // Charge + Effort (#446) + Rest — the same stats the banner carries, one size.
                    HStack(spacing: 10) {
                        if let r = context.state.recovery {
                            statColumn(label: "Charge", value: "\(r)")
                        }
                        if let e = context.state.effort {
                            statColumn(label: "Effort", value: "\(e)")
                        }
                        if let rhr = context.state.rest {
                            statColumn(label: "Rest", value: "\(rhr)")
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.attributes.title).font(.caption).foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "heart.fill").foregroundStyle(StrandPalette.statusCritical)
            } compactTrailing: {
<<<<<<< HEAD
                Text("\(Self.shownBpm(context).map(String.init) ?? "–")")
=======
                Text(hrText(context.state))
>>>>>>> 6687427ec (Live Activity: tilde marks LIVE beats; +N lock-edge average; 8 h lease renewal)
            } minimal: {
                Image(systemName: "heart.fill").foregroundStyle(StrandPalette.statusCritical)
            }
        }
    }
}

/// The HR display string: a LIVE beat carries the tilde ("~72" — still moving), a window average /
/// frozen value is the plain settled number. `live` is nil on activities written by older builds —
/// treated as not-live, so an inherited card never claims liveness it can't back. File-scope for the
/// same reason as `bannerStat`. The `minimal` slot deliberately does NOT use this: it clips rather
/// than shrinks, and the tilde would cost the third digit of a workout HR.
private func hrText(_ state: NOOPActivityAttributes.ContentState) -> String {
    guard let bpm = state.bpm else { return "–" }
    return state.live == true ? "~\(bpm)" : "\(bpm)"
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
private func bannerStat(label: String, value: String) -> some View {
    VStack(alignment: .center, spacing: 2) {
        Text(label).font(.caption2).foregroundStyle(StrandPalette.textSecondary)
        // .title3 (one step up from .headline): the four values are the banner's whole payload and
        // read from a nightstand distance; the labels stay caption2 so the numbers carry the row.
        Text(value).font(.title3).fontWeight(.semibold).foregroundStyle(StrandPalette.textPrimary)
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
