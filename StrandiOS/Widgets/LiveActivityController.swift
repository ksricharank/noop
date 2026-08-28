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

    /// Drive the activity from the latest live values. Lazily starts when the strap is CONNECTED (the
    /// live link, not the sticky "paired" flag) and a heart rate is present; ends the moment the link
    /// drops. Cadence is lock-aware (`LiveActivityHrPolicy`): ~once every 2 s while the phone is
    /// unlocked (the Dynamic Island reads as live), once a minute with a one-minute HR average while
    /// it is locked (nobody can watch beat-level movement there, and on an Always-On display every
    /// push repaints the Lock Screen — the live cadence was a measurable all-day battery cost).
    func update(bpm: Int?, recovery: Int?, connected: Bool, effort: Int? = nil, rest: Int? = nil) {
        guard authInfo.areActivitiesEnabled else { return }

        // Re-adopt an activity that outlived a previous app session. ActivityKit keeps Live Activities
        // alive across launches/relaunches, but a fresh controller starts with `activity == nil`, so
        // without recovering the handle here we can neither update nor END an already-showing activity
        // — which made the #336 opt-out a no-op (#341: toggle off, heart stays) and risked spawning a
        // duplicate on the start path below. Done on the HR tick rather than in `init` because
        // `Activity.activities` isn't reliably hydrated at the instant of process launch.
        if activity == nil { activity = Activity<NOOPActivityAttributes>.activities.first }

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
            }
            isStarting = false
        }
    }

    /// Repaint the activity from PERSISTED data — the locked-phone path under the stream duty cycle
    /// (Lock-Screen refresh = -1). Called once per completed offload (`AppModel.lockedActivityRefresh`),
    /// so no throttle: each call is already one sync apart. `bpm` is the mean over the offload
    /// cadence's own window (15/60 min); recovery/effort are the last recorded values, same anchor the
    /// widget uses. The stale window covers one full cadence plus sync slack — the next repaint
    /// genuinely cannot arrive sooner, and greying in between would misread "quiet by design" as
    /// "stale". Deliberately does NOT touch `lastPush`: the live cadence's own throttle state belongs
    /// to live ticks, and an unlock moments after a data repaint should push live immediately.
    func updateFromData(bpm: Int?, recovery: Int?, effort: Int?, rest: Int?, connected: Bool, windowMinutes: Int) {
        guard authInfo.areActivitiesEnabled, UnitPrefs.liveActivityEnabled() else { return }
        if activity == nil { activity = Activity<NOOPActivityAttributes>.activities.first }
        if !connected {
            Task { await end() }
            return
        }
        guard let bpm else { return }
        let state = NOOPActivityAttributes.ContentState(bpm: bpm, recovery: recovery,
                                                        bonded: connected, effort: effort, rest: rest)
        let staleDate = Date().addingTimeInterval(
            Self.staleAfter + LockedStreamPolicy.liveActivityStaleSeconds(
                windowMinutes: windowMinutes, lowRefresh: PuffinExperiment.lowRefreshEnabled))
        if let activity {
            Task { await activity.update(ActivityContent(state: state, staleDate: staleDate)) }
        } else {
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
