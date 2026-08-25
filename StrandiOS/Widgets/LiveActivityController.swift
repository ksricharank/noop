#if os(iOS)
import Foundation
import ActivityKit

/// Starts, updates, and ends the live-HR Live Activity. The activity appears on the Lock Screen and
/// in the Dynamic Island while the strap is bonded and streaming heart rate.
@MainActor
final class LiveActivityController {
    private var activity: Activity<NOOPActivityAttributes>?
    private var lastPush: Date = .distantPast
    /// Cached `ActivityAuthorizationInfo` — `update` runs at ~1 Hz off the live HR stream, and
    /// instantiating this system bridge per tick is needless allocation. ActivityKit's auth status
    /// only changes via Settings, so caching for the controller's lifetime is safe.
    private let authInfo = ActivityAuthorizationInfo()
    /// Monotonic counter identifying the current start/end epoch. `end()` captures the generation it
    /// was enqueued for and no-ops if a newer start has happened since — see `endIfCurrent`.
    private var generation = 0
    /// Whether an `end()` is already queued for the CURRENT generation, so N consecutive ticks with
    /// the toggle off (or the link down) enqueue one end instead of one per tick at ~1 Hz. Cleared
    /// when that end runs, or when a start opens a new generation.
    private var isEnding = false
    /// Gate against concurrent `Activity.request` calls, held across the whole start window. The
    /// request itself is synchronous, but `activity` is only assigned after it returns, so this also
    /// keeps a start distinguishable from "no activity" for anything running in between.
    private var isStarting = false
    /// How long after the last push iOS may keep showing the activity as fresh. The activity is
    /// refreshed every ~2 s while streaming, so this never bites a live session; it auto-greys a
    /// frozen activity if the app is suspended/killed without an explicit end (a missed-tick safety net
    /// on top of the connected-driven end below).
    private static let staleAfter: TimeInterval = 120

    /// Drive the activity from the latest live values. Lazily starts when the strap is CONNECTED (the
    /// live link, not the sticky "paired" flag) and a heart rate is present; ends the moment the link
    /// drops. Throttled to ~once every 2 s so we stay well under the Live Activity update budget.
    func update(bpm: Int?, recovery: Int?, connected: Bool, effort: Int? = nil) {
        guard authInfo.areActivitiesEnabled else { return }

        // Re-adopt an activity that outlived a previous app session. ActivityKit keeps Live Activities
        // alive across launches/relaunches, but a fresh controller starts with `activity == nil`, so
        // without recovering the handle here we can neither update nor END an already-showing activity
        // — which made the #336 opt-out a no-op (#341: toggle off, heart stays) and risked spawning a
        // duplicate on the start path below. Done on the HR tick rather than in `init` because
        // `Activity.activities` isn't reliably hydrated at the instant of process launch.
        //
        // Only adopt an ACTIVE activity: `Activity.activities` also carries handles in `.ended` /
        // `.dismissed` for a while after they stop being visible. Adopting a dead one sent every
        // subsequent `update` into the void — no visible activity and no attempt to start a fresh one,
        // because the non-nil handle keeps taking the update branch below.
        if activity == nil, !isStarting {
            activity = Activity<NOOPActivityAttributes>.activities
                .first { $0.activityState == .active }
        }

        // Should the activity be on screen at all? The rule itself lives in
        // `LiveActivityPresentationPolicy` (pure, unit-tested); this side owns only the ActivityKit
        // handles. Covers the #336 user opt-out, the sleep-window pause (the presentation half of the
        // re-score deferral — same `isInSleepWindow` source of truth, so the two can never drift), and
        // the live-link drop that once left a frozen, fabricated HR on the Lock Screen after the strap
        // went out of range (`bonded` stays true across disconnects; `connected` does not).
        let decision = LiveActivityPresentationPolicy.decide(
            enabledByUser: UnitPrefs.liveActivityEnabled(),
            inSleepWindow: RescoreBackgroundScheduler.isInSleepWindow,
            connected: connected,
            hasBPM: bpm != nil)

        switch decision {
        case .suppress:
            // Tear down through the generation gate, not a bare `Task { await end() }`. Suppression
            // holds across EVERY ~1 Hz tick (toggle off, sleep window, link down), so the bare form
            // enqueued one end per tick, and each ends every NOOP activity — including one a later
            // tick had just restarted. `endIfCurrent` collapses that to one end per generation and
            // drops it outright if a start has superseded it. It also checks whether anything is
            // showing, making the `activity != nil` test it replaces redundant.
            endIfCurrent()
            return
        case .holdIfShowing:
            // Leave a running activity exactly as it is — no push, no teardown.
            return
        case .present:
            break
        }
        guard let bpm else { return }

        let state = NOOPActivityAttributes.ContentState(bpm: bpm, recovery: recovery, bonded: connected,
                                                        effort: effort)
        let staleDate = Date().addingTimeInterval(Self.staleAfter)

        if let activity {
            guard Date().timeIntervalSince(lastPush) > 2 else { return }
            lastPush = Date()
            Task { await activity.update(ActivityContent(state: state, staleDate: staleDate)) }
        } else {
            // Set the start gate SYNCHRONOUSLY before any await so a second `update` arriving on the
            // main actor while `Activity.request` is still in flight bails here instead of issuing a
            // second request. The 2-second throttle above only guards the update path.
            guard !isStarting else { return }
            isStarting = true
            // Open a new generation BEFORE requesting, so any `end()` already queued from a previous
            // toggle-off / disconnect is stale by the time it runs and leaves this activity alone.
            // Without this, the queued end iterated `Activity.activities` and killed the activity the
            // user had just re-enabled — the "doesn't show up until I toggle a few times" bug.
            generation &+= 1
            isEnding = false
            do {
                activity = try Activity.request(
                    attributes: NOOPActivityAttributes(title: String(localized: "Live HR")),
                    content: ActivityContent(state: state, staleDate: staleDate),
                    pushType: nil
                )
                lastPush = Date()
            } catch {
                activity = nil
            }
            isStarting = false
        }
    }

    /// Enqueue an end for the current generation, at most once per generation. A start bumps the
    /// generation, which both invalidates any end still queued and re-arms this for the new activity.
    private func endIfCurrent() {
        guard !isEnding else { return }
        guard activity != nil || !Activity<NOOPActivityAttributes>.activities.isEmpty else { return }
        isEnding = true
        let requested = generation
        Task { await end(ifGeneration: requested) }
    }

    /// End every NOOP Live Activity unless a newer start has superseded this request.
    private func end(ifGeneration requested: Int) async {
        // A start that landed between this task being enqueued and it running bumped `generation`;
        // the activity now showing is NOT the one this end was asked to remove, so drop the request.
        // Clearing the flag unconditionally keeps a dropped end from wedging the gate: the start that
        // superseded us also clears it, but a stale end must never leave `isEnding` latched true.
        isEnding = false
        guard requested == generation else { return }
        await end()
    }

    func end() async {
        // End every NOOP Live Activity, not just our cached handle — covers a straggler from a prior
        // session we never re-adopted (#341) and any rare duplicate. Iterating the live list is the
        // only way to reach activities this controller instance never started.
        for act in Activity<NOOPActivityAttributes>.activities {
            await act.end(nil, dismissalPolicy: .immediate)
        }
        self.activity = nil
    }
}
#endif
