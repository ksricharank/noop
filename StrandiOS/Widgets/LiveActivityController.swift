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
    /// Synchronous gate against concurrent `Activity.request` calls. The `else` branch below is
    /// re-entered while the first request is still in flight (it hasn't assigned `self.activity`
    /// yet), so without this guard two close-together HR samples could both fire `Activity.request`
    /// and create duplicate Live Activities.
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
        }
    }

    /// Drive the activity from the latest live values. Lazily starts when the strap is CONNECTED (the
    /// live link, not the sticky "paired" flag) and a heart rate is present; ends the moment the link
    /// drops. Cadence is lock-aware (`LiveActivityHrPolicy`): ~once every 2 s while the phone is
    /// unlocked (the Dynamic Island reads as live), once a minute with a one-minute HR average while
    /// it is locked (nobody can watch beat-level movement there, and on an Always-On display every
    /// push repaints the Lock Screen — the live cadence was a measurable all-day battery cost).
    func update(bpm: Int?, recovery: Int?, connected: Bool, effort: Int? = nil, rest: Int? = nil) {
        guard authInfo.areActivitiesEnabled else { return }

        // Re-adopt an activity that outlived a previous app session (ActivityKit keeps Live
        // Activities alive across relaunches; a fresh controller starts with `activity == nil` —
        // #336/#341), and drop a handle whose activity has since died. Both live in
        // `revalidateHandle` — done per tick rather than in `init` because `Activity.activities`
        // isn't reliably hydrated at the instant of process launch.
        revalidateHandle()

        // User opt-out (#336): if the in-app toggle is off, never start — and end any activity that's
        // already showing (the user just turned it off; this fires on the next ~1 Hz HR tick).
        guard UnitPrefs.liveActivityEnabled() else {
            if activity != nil { Task { await end() } }
            return
        }

        // End the moment the live link drops — `bonded` stays true across every disconnect (it means
        // "this strap is paired"), so keying off it left a frozen, fabricated "live" HR on the Lock
        // Screen / Dynamic Island indefinitely after the strap went out of range.
        if !connected {
            Task { await end() }
            return
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

        if let activity {
            guard LiveActivityHrPolicy.shouldPush(locked: locked, now: now, lastPush: lastPush,
                                                  lockedSpacing: lockedSpacing) else { return }
            lastPush = now
            // Locked: show the window's average — steadier, and honest about its cadence. The
            // instantaneous fallback only fires if the window is somehow empty (it can't be: the
            // current tick was just appended above).
            let shownBpm = locked
                ? (LiveActivityHrPolicy.windowAverage(hrSamples, now: now, window: lockedSpacing) ?? bpm)
                : bpm
            let state = NOOPActivityAttributes.ContentState(bpm: shownBpm, recovery: recovery,
                                                            bonded: connected, effort: effort, rest: rest)
            let staleDate = now.addingTimeInterval(Self.staleAfter + (locked ? lockedSpacing : 0))
            Task { await activity.update(ActivityContent(state: state, staleDate: staleDate)) }
        } else {
            let state = NOOPActivityAttributes.ContentState(bpm: bpm, recovery: recovery,
                                                            bonded: connected, effort: effort, rest: rest)
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
            do {
                activity = try Activity.request(
                    attributes: NOOPActivityAttributes(title: String(localized: "HR")),
                    content: ActivityContent(state: state, staleDate: staleDate),
                    pushType: nil
                )
                lastPush = Date()
            } catch {
                activity = nil
                log?("Live Activity: start failed — \(error.localizedDescription)")
            }
            isStarting = false
        }
    }

    /// Repaint the activity from PERSISTED data — the locked-phone path under the stream duty cycle
    /// (Lock-Screen refresh = -1). Called once per completed offload (`AppModel.lockedActivityRefresh`),
    /// so no throttle: each call is already one sync apart. `bpm` is the mean over the averaging
    /// window (15/60 min auto, or the user's explicit -N); recovery/effort are the last recorded
    /// values, same anchor the widget uses. Pushes carry NO staleDate — see the comment at the push
    /// below (iOS 26 removes, not greys, a stale activity). Deliberately does NOT touch `lastPush`:
    /// the live cadence's own throttle state belongs to live ticks, and an unlock moments after a
    /// data repaint should push live immediately.
    func updateFromData(bpm: Int?, recovery: Int?, effort: Int?, rest: Int?, connected: Bool) {
        guard authInfo.areActivitiesEnabled, UnitPrefs.liveActivityEnabled() else { return }
        revalidateHandle()
        if !connected {
            // A drop while the duty cycle has the phone locked is routine — the link is idle BY
            // DESIGN, and the standing reconnect restores it. Ending here was one-way (no background
            // starts), so it left the Lock Screen empty until the next app open. Hold the frozen
            // average instead; unlocked or duty-cycle-off drops still end immediately (#911).
            let lockedMinutes = UnitPrefs.liveActivityLockedMinutes()
            if LockedStreamPolicy.holdOnDisconnect(
                dutyCycle: LockedStreamPolicy.dutyCycleEnabled(lockedMinutes: lockedMinutes),
                locked: DeviceLockState.isLocked(
                    protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable)) {
                return
            }
            Task { await end() }
            return
        }
        guard let bpm else { return }
        let state = NOOPActivityAttributes.ContentState(bpm: bpm, recovery: recovery,
                                                        bonded: connected, effort: effort, rest: rest)
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
            do {
                activity = try Activity.request(
                    attributes: NOOPActivityAttributes(title: String(localized: "HR")),
                    content: ActivityContent(state: state, staleDate: staleDate),
                    pushType: nil
                )
            } catch {
                activity = nil
                log?("Live Activity: start failed — \(error.localizedDescription)")
            }
            isStarting = false
        }
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
