#if os(iOS)
import Foundation
import ActivityKit
import UIKit

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
    /// on top of the connected-driven end below). Locked-mode pushes are a minute apart, so their
    /// staleDate adds that spacing on top — the freshness window must sit on the cadence, not race it.
    private static let staleAfter: TimeInterval = 120
    /// Rolling last-minute of display-HR ticks, feeding the locked-mode average
    /// (`LiveActivityHrPolicy.windowAverage`). Fed on every tick regardless of lock state, so the
    /// first locked push already has a full window behind it.
    private var hrSamples: [LiveActivityHrPolicy.Sample] = []
    /// Whether the previous push happened while locked — the lock EDGE detector: the first locked
    /// tick pushes the window average immediately instead of waiting out a whole `lockedSpacing`
    /// with the last live beat frozen on the card.
    private var lastPushWasLocked = false
    /// The last state actually pushed to the card, whatever path pushed it. What `noteDisconnected`
    /// repaints from: on a link drop there is no live tick to carry values, so the cue push re-sends
    /// what the card is already showing with only the honesty bits changed (not live, not connected).
    private var lastPushedState: NOOPActivityAttributes.ContentState?
    /// Whether the last push carried `bonded == true` — the CONNECTION edge detector, twin of
    /// `lastPushWasLocked`: the first tick after a reconnect repaints immediately (clearing the
    /// not-connected cue) instead of waiting out the locked spacing with the grey cue still up.
    private var lastPushedBonded: Bool?
    /// When the CURRENT activity was requested — the system ends every Live Activity ~8 h after
    /// creation, so `update` renews the lease (end + fresh request) once an activity crosses this
    /// age and the app is foreground-active. Approximated with the adoption time for an activity
    /// inherited from a previous process (a too-early renewal is a blink; a too-late one is the cap).
    private var activityStartedAt: Date?
    private static let leaseRenewalAge: TimeInterval = 6.5 * 3600
    /// Rare-event sink into the strap log (wired by the app layer). Start failures and dropped dead
    /// handles were both silent, which is exactly what made "the island never comes back" a
    /// phone-in-hand mystery instead of one log line.
    var log: ((String) -> Void)?

    /// Re-point `activity` at reality before every push. Two corpse sources, one symptom (the #341
    /// class): a handle whose activity was ended ELSEWHERE (the sleep-window pause, a disconnect
    /// end, the system's own lifetime cap) stays non-nil here, so every push vanishes into it and
    /// the non-nil check blocks the restart path — the island then never returns until the user
    /// bounces the toggle. And `Activity.activities` keeps `.ended`/`.dismissed` handles around for
    /// a while after they stop showing, so blindly adopting `.first` re-poisons the handle the same
    /// way (how the locked-span link drops killed the island for the rest of the day, 260828-0731).
    /// `.stale` is NOT a corpse — a push revives it — so both the held handle and adoption keep it.
    private func revalidateHandle() {
        if let activity, activity.activityState != .active, activity.activityState != .stale {
            log?("Live Activity: dropped a dead handle (state=\(activity.activityState)) — restart path open again")
            self.activity = nil
        }
        // Not while a start is in flight: `Activity.request` will assign the fresh handle itself.
        if activity == nil, !isStarting {
            activity = Activity<NOOPActivityAttributes>.activities
                .first { $0.activityState == .active || $0.activityState == .stale }
            // Adopted from a previous process: the true birth time is unknown, so the lease clock
            // starts at adoption. A too-early renewal is one invisible blink; too late is the cap.
            if activity != nil, activityStartedAt == nil { activityStartedAt = Date() }
        }
    }

    /// Drive the activity from the latest live values. Lazily starts when the strap is CONNECTED (the
    /// live link, not the sticky "paired" flag) and a heart rate is present; ends the moment the link
    /// drops. Cadence is lock-aware (`LiveActivityHrPolicy`): ~once every 2 s while the phone is
    /// unlocked (the Dynamic Island reads as live), once a minute with a one-minute HR average while
    /// it is locked (nobody can watch beat-level movement there, and on an Always-On display every
    /// push repaints the Lock Screen — the live cadence was a measurable all-day battery cost).
    func update(bpm: Int?, recovery: Int?, connected: Bool, effort: Int? = nil, rest: Int? = nil,
                targets: LiveTargets? = nil) {
        guard authInfo.areActivitiesEnabled else { return }

        // Re-adopt an activity that outlived a previous app session (ActivityKit keeps Live
        // Activities alive across relaunches; a fresh controller starts with `activity == nil` —
        // #336/#341), and drop a handle whose activity has since died. Both live in
        // `revalidateHandle` (a superset of the old inline `.active`-filtered adoption) — done per
        // tick rather than in `init` because `Activity.activities` isn't reliably hydrated at the
        // instant of process launch.
        revalidateHandle()

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

        let now = Date()
        // The locked cadence is user-tunable (Settings → Live Activity): N minutes between locked
        // pushes, each showing the mean HR over that window; 0 disables the locked slowdown entirely
        // (fully live, the pre-cadence behaviour). Read per tick so a Settings edit applies at once.
        let lockedMinutes = UnitPrefs.liveActivityLockedMinutes()
        let dutyCycle = LockedStreamPolicy.dutyCycleEnabled(lockedMinutes: lockedMinutes)
        let lockedSpacing = TimeInterval(max(lockedMinutes, 1)) * 60
        hrSamples = LiveActivityHrPolicy.appending(hrSamples, bpm: bpm, at: now, window: lockedSpacing)
        // Locked = the shared latch-or-keybag signal. The keybag alone flips 10–60 s AFTER the
        // physical lock, so a keybag-only read kept live pushes repainting the locked Lock Screen for
        // that whole grace window (the 260827-2142 rapid lock/unlock churn); the latch — set the
        // instant the lock notification fires — is what freezes the number AT the lock. Re-read per
        // tick rather than observed: a tick is already the only moment a push can happen.
        // `lockedMinutes == 0` opts out of lock-awareness altogether.
        let locked = lockedMinutes != 0
            && DeviceLockState.isLocked(protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable)

        // Duty cycle (-1): while locked, LIVE ticks never push — the stream is supposed to be silent,
        // and any stray tick (the strap can keep pushing HR over the puffin data channels whatever the
        // TOGGLE says) repainting the Lock Screen is exactly the v1 bug. The locked presentation is
        // owned by `updateFromData`, driven once per completed offload.
        guard LockedStreamPolicy.lockedLiveTickPushAllowed(dutyCycle: dutyCycle, locked: locked) else {
            return
        }

        // Lease renewal against the system's ~8 h Live Activity lifetime (counted from creation;
        // updates never extend it). An activity older than the renewal age is ended and immediately
        // re-requested by the start path below with this tick's state — foreground-active only, so
        // in practice it happens invisibly on an app open. Without this, a card born in the morning
        // is ended by iOS mid-afternoon and (no background starts) stays gone until the next open.
        if let a = activity, let born = activityStartedAt,
           now.timeIntervalSince(born) > Self.leaseRenewalAge,
           UIApplication.shared.applicationState == .active, !isStarting {
            log?("Live Activity: renewing the 8 h lease (activity is \(Int(now.timeIntervalSince(born) / 3600)) h old)")
            Task { await a.end(nil, dismissalPolicy: .immediate) }
            activity = nil
            activityStartedAt = nil
        }

        if let activity {
            // The LOCK EDGE pushes immediately: the first spaced push otherwise arrives a full
            // `lockedSpacing` after locking, so for those minutes the card held the last LIVE beat —
            // the "captures the last HR value and freezes it" report on +5 (the -1 mode has its own
            // lock-edge repaint; this is the +N twin, driven by the ticks that keep flowing there).
            let lockEdge = locked && !lastPushWasLocked
            // The RECONNECT edge pushes immediately too: after `noteDisconnected` painted the
            // not-connected cue, the first tick of the restored link must clear it now, not a full
            // locked spacing later.
            let bondedEdge = connected != (lastPushedBonded ?? connected)
            guard lockEdge || bondedEdge
                || LiveActivityHrPolicy.shouldPush(locked: locked, now: now, lastPush: lastPush,
                                                   lockedSpacing: lockedSpacing) else { return }
            lastPush = now
            lastPushWasLocked = locked
            // Locked: show the window's average — steadier, and honest about its cadence. The
            // instantaneous fallback only fires if the window is somehow empty (it can't be: the
            // current tick was just appended above).
            let shownBpm = locked
                ? (LiveActivityHrPolicy.windowAverage(hrSamples, now: now, window: lockedSpacing) ?? bpm)
                : bpm
            let state = NOOPActivityAttributes.ContentState(bpm: shownBpm, recovery: recovery,
                                                            bonded: connected, effort: effort, rest: rest,
                                                            live: !locked,
                                                            hrCeiling: targets?.hrCeilingBpm,
                                                            kcal: targets?.kcalToday,
                                                            kcalTarget: targets?.kcalTargetKcal,
                                                            sleepNeedMin: targets?.sleepNeedTonightMin)
            // Locked pushes carry NO staleDate for the same reason updateFromData's don't: iOS 26
            // REMOVES a stale activity from both surfaces rather than greying it, and a locked span
            // can legitimately go quiet past any window we'd pick. Live pushes keep the short net —
            // they refresh every ~2 s, so it only ever catches a crashed app.
            let staleDate: Date? = locked ? nil : now.addingTimeInterval(Self.staleAfter)
            lastPushedState = state
            lastPushedBonded = connected
            Task { await activity.update(ActivityContent(state: state, staleDate: staleDate)) }
        } else {
            let state = NOOPActivityAttributes.ContentState(bpm: bpm, recovery: recovery,
                                                            bonded: connected, effort: effort, rest: rest,
                                                            live: !locked,
                                                            hrCeiling: targets?.hrCeilingBpm,
                                                            kcal: targets?.kcalToday,
                                                            kcalTarget: targets?.kcalTargetKcal,
                                                            sleepNeedMin: targets?.sleepNeedTonightMin)
            let staleDate = now.addingTimeInterval(Self.staleAfter)
            // Local Live Activities can only be STARTED while the app is foreground-active; a
            // background request throws every time. Skipping quietly matters beyond tidiness: after
            // a legitimate end, ticks otherwise re-request (and re-throw) at ~1 Hz for as long as
            // the app stays backgrounded. The start then happens on the next foreground — the
            // scenePhase kick or the first live tick, whichever lands first.
            guard UIApplication.shared.applicationState == .active else { return }
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
                    attributes: NOOPActivityAttributes(title: String(localized: "HR")),
                    content: ActivityContent(state: state, staleDate: staleDate),
                    pushType: nil
                )
                lastPush = Date()
                lastPushWasLocked = locked
                lastPushedState = state
                lastPushedBonded = connected
                activityStartedAt = Date()
            } catch {
                activity = nil
                log?("Live Activity: start failed — \(error.localizedDescription)")
            }
            isStarting = false
        }
    }

    /// Repaint the card as NOT CONNECTED on the link-drop edge, holding the values it already shows.
    ///
    /// A drop never ENDS the card any more (260829): the end was one-way — iOS forbids background
    /// starts — so charging the strap, or a transient timeout with the phone locked in a pocket,
    /// killed the island until the next app open. There is no live tick to carry a repaint at the
    /// moment of the drop, so this pushes the LAST pushed state with only the honesty bits changed:
    /// `live` off (the plain number never claims a moving reading) and `bonded` off (the widget greys
    /// its identity icons — the "not connected" cue). Idempotent per drop edge: once the cue is up,
    /// further disconnect emissions have nothing to change. The reconnect edge is the live path's
    /// `bondedEdge`, which repaints immediately.
    func noteDisconnected() {
        guard authInfo.areActivitiesEnabled, UnitPrefs.liveActivityEnabled() else { return }
        revalidateHandle()
        guard let activity, var state = lastPushedState, lastPushedBonded != false else { return }
        state.live = false
        state.bonded = false
        lastPushedState = state
        lastPushedBonded = false
        log?("Live Activity: link dropped — holding the card with a not-connected cue (the standing reconnect repaints it)")
        // No staleDate: a disconnected span can legitimately outlast any window (a strap charges for
        // an hour+), and iOS 26 REMOVES a stale activity rather than greying it.
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    /// Repaint the activity from PERSISTED data — the locked-phone path under the stream duty cycle
    /// (Lock-Screen refresh = -1). Called once per completed offload (`AppModel.lockedActivityRefresh`),
    /// so no throttle: each call is already one sync apart. `bpm` is the mean over the averaging
    /// window (15/60 min auto, or the user's explicit -N); recovery/effort are the last recorded
    /// values, same anchor the widget uses. Pushes carry NO staleDate — see the comment at the push
    /// below (iOS 26 removes, not greys, a stale activity). Deliberately does NOT touch `lastPush`:
    /// the live cadence's own throttle state belongs to live ticks, and an unlock moments after a
    /// data repaint should push live immediately.
    func updateFromData(bpm: Int?, recovery: Int?, effort: Int?, rest: Int?, connected: Bool,
                        targets: LiveTargets? = nil) {
        guard authInfo.areActivitiesEnabled, UnitPrefs.liveActivityEnabled() else { return }
        revalidateHandle()
        // A drop never ends the card (260829) — whatever the mode or lock state. It used to end here
        // unless the -1 duty cycle had the phone locked, which is exactly how charging the strap
        // killed the island one-way (no background starts). The not-connected cue is painted by
        // `noteDisconnected` on the drop edge; this data path simply has nothing new to say.
        guard connected else { return }
        guard let bpm else { return }
        let state = NOOPActivityAttributes.ContentState(bpm: bpm, recovery: recovery,
                                                        bonded: connected, effort: effort, rest: rest,
                                                        live: false,
                                                        hrCeiling: targets?.hrCeilingBpm,
                                                        kcal: targets?.kcalToday,
                                                        kcalTarget: targets?.kcalTargetKcal,
                                                        sleepNeedMin: targets?.sleepNeedTonightMin)
        // NO staleDate on locked repaints — deliberately never stale. The cadence-sized stale window
        // (~22 min) was meant to grey a card whose successor stopped coming, but iOS 26 does not
        // grey a stale Live Activity: it REMOVES it from the Lock Screen AND the Dynamic Island
        // (260828-0914: both vanish ~15–25 min into every away span — a locked link drop or a
        // background process kill stops the repaints — then both reappear the instant the app opens,
        // because the activity still existed and one push revived it; no end ran, no start failed).
        // A vanished card misreads as "the app broke"; the frozen window average never claimed
        // liveness, so persisting it is honest. The exit is explicit instead of clock-driven: on
        // unlock the live path refreshes it within a tick, or the unlock/foreground kicks end it
        // properly if the strap is genuinely gone.
        let staleDate: Date? = nil
        if let activity {
            lastPushWasLocked = true
            lastPushedState = state
            lastPushedBonded = connected
            Task { await activity.update(ActivityContent(state: state, staleDate: staleDate)) }
        } else {
            // Foreground-active only, same as the live path: a request from anywhere else throws.
            // This path runs almost exclusively while locked/backgrounded, so in practice the start
            // it skips is handled by the next foreground (scenePhase kick / first live tick). Logged
            // (rare-event): recurring copies of this line are the "dead until next app open"
            // signature, one per sync.
            guard UIApplication.shared.applicationState == .active else {
                log?("Live Activity: locked repaint found nothing to adopt — a start needs the next foreground")
                return
            }
            // Same synchronous start gate as the live path — two offloads finishing close together
            // must not race two `Activity.request`s.
            guard !isStarting else { return }
            isStarting = true
            // Same epoch bump as the live start: invalidate any end still queued from the previous
            // generation, or it would tear down the activity this request is about to create.
            generation &+= 1
            isEnding = false
            do {
                activity = try Activity.request(
                    attributes: NOOPActivityAttributes(title: String(localized: "HR")),
                    content: ActivityContent(state: state, staleDate: staleDate),
                    pushType: nil
                )
                lastPushWasLocked = true
                lastPushedState = state
                lastPushedBonded = connected
                activityStartedAt = Date()
            } catch {
                activity = nil
                log?("Live Activity: start failed — \(error.localizedDescription)")
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
        self.activityStartedAt = nil
    }
}
#endif
