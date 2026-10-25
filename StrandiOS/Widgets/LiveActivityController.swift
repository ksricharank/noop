#if os(iOS)
import Foundation
import ActivityKit
import Combine
import UIKit

/// Starts, updates, and ends the live-HR Live Activity on the Lock Screen and in the Dynamic Island: the heart rate
/// while the strap measures it, the dash while it does not. It follows the strap from process start (`follow`).
@MainActor
final class LiveActivityController {
    private var activity: Activity<NOOPActivityAttributes>?
    /// What the banner reads — the live heart rate, the link, the day's recovery and effort — set once by `follow`.
    private weak var model: AppModel?
    /// Whether the Lift Log banner is on screen, which the heart rate banner makes room for.
    private var standsAside: () -> Bool = { false }
    private var cancellables: Set<AnyCancellable> = []
    private var lastPush: Date = .distantPast
    /// What the banner was last pushed with, so an unchanged banner is not pushed again
    /// (`LiveHRBannerPushPolicy`). Nil until this controller pushes, and again once it ends the activity.
    private var shownState: NOOPActivityAttributes.ContentState?
    /// Cached `ActivityAuthorizationInfo` — `update` runs at ~1 Hz off the live HR stream, and
    /// instantiating this system bridge per tick is needless allocation. ActivityKit's auth status
    /// only changes via Settings, so caching for the controller's lifetime is safe.
    private let authInfo = ActivityAuthorizationInfo()
    /// Synchronous gate against concurrent `Activity.request` calls. The `else` branch below is
    /// re-entered while the first request is still in flight (it hasn't assigned `self.activity`
    /// yet), so without this guard two close-together HR samples could both fire `Activity.request`
    /// and create duplicate Live Activities.
    private var isStarting = false
    /// Rolling last-minute of display-HR ticks, feeding the locked-mode average
    /// (`LiveActivityHrPolicy.windowAverage`). Fed on every tick regardless of lock state, so the
    /// first locked push already has a full window behind it.
    private var hrSamples: [LiveActivityHrPolicy.Sample] = []
    /// When the banner being fed was started, for iOS's eight-hour limit (`LiveHRBannerLifecycle.renewAfter`). Kept in
    /// the defaults with the banner's id, because a banner outlives the run that started it. Nil when unknown.
    private var startedAt: Date?
    private static let startedKey = "liveActivity.hr.startedAt"
    /// An end is in flight, so the ticks that arrive meanwhile neither end it again nor log it twice.
    private var isEnding = false
    /// iOS refused a start, and it was logged: once, not on every tick while NOOP is on screen.
    private var refusalLogged = false
    /// Banners NOOP has asked iOS to remove (`removeLeftovers`), so a tick that arrives before iOS has dropped one from
    /// its list neither asks again nor logs it twice.
    private var removing: Set<String> = []
    /// How long after the last push iOS treats the banner as fresh; after that the banner draws the dash
    /// (`NOOPLiveActivity.shownBpm`). A WHOOP 5.0 taken off the wrist goes quiet, and with nothing arriving iOS
    /// suspends NOOP, so no timer of NOOP's can clear the number: iOS's own stale date is what does it, in at most
    /// this long (a tester's log, 23 Sep 2026). A steady number is re-pushed once half of this has passed
    /// (`LiveHRBannerPushPolicy`), so a banner fed by a worn strap never goes stale.
    static let staleAfter: TimeInterval = 30
    /// Whether the previous push happened while locked — the lock EDGE detector: the first locked
    /// tick pushes the window average immediately instead of waiting out a whole `lockedSpacing`
    /// with the last live beat frozen on the card.
    private var lastPushWasLocked = false

    /// Re-point `activity` at reality before a DATA repaint (`updateFromData`, the locked duty-cycle
    /// path, which runs outside the live-tick machinery above). Two corpse sources, one symptom (the
    /// #341 class): a handle whose activity was ended ELSEWHERE (the sleep-window pause, the system's
    /// own lifetime cap) stays non-nil, so every push vanishes into it and the non-nil check blocks
    /// the restart path. And `Activity.activities` keeps `.ended`/`.dismissed` handles around for a
    /// while after they stop showing, so blindly adopting `.first` re-poisons the handle the same way
    /// (how the locked-span link drops killed the island for the rest of the day, 260828-0731).
    /// `.stale` is NOT a corpse — a push revives it — so both the held handle and adoption keep it.
    private func revalidateHandle() {
        if let activity, activity.activityState != .active, activity.activityState != .stale {
            log("dropped a dead handle (state=\(activity.activityState)) — restart path open again")
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

    /// Follow the strap from process start, not from a screen. iOS starts NOOP in the background — the strap
    /// reconnecting, a sync, the Sync Strap shortcut — and a process started that way need not build any screen (the
    /// shortcut's never does), while a banner the previous run left on the Lock Screen is there to be picked up and
    /// fed from the first reading. Called once, from the app's `init`, like the Lift Log's own resume.
    func follow(_ model: AppModel, standsAside: @escaping () -> Bool) {
        self.model = model
        self.standsAside = standsAside
        // Refreshed once a change has landed, never from inside it (`LiveHRBannerInputs`). AppModel's median (`bpm`)
        // is an input in its own right: it moves on the R-R alone, and a clear that reached it that way refreshed
        // nothing, so the banner kept the last number until iOS's stale date drew the dash.
        LiveHRBannerInputs.settled([model.live.$heartRate.map { _ in () }.eraseToAnyPublisher(),
                                    model.live.$connected.map { _ in () }.eraseToAnyPublisher(),
                                    model.$bpm.map { _ in () }.eraseToAnyPublisher()])
            .sink { [weak self] in self?.refreshBanner() }
            .store(in: &cancellables)
        // The switch is the one way to be rid of the banner, so it acts at once — not at the next heart-rate tick,
        // which a strap off the wrist may not send for hours.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .map { _ in UnitPrefs.liveActivityEnabled() }
            .prepend(UnitPrefs.liveActivityEnabled())
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.refreshBanner() }
            .store(in: &cancellables)
    }

    /// NOOP came on screen, the only time iOS lets it start the banner: offered now rather than at the next heart-rate
    /// change, which a strap off the wrist may not bring for a long while. Said by the caller, from the scene phase,
    /// because `applicationState` can still read inactive while the scene turns active.
    func appBecameActive() {
        refreshBanner(appActive: true)
    }

    /// #911: recovery and effort come from the SAME shared `Repository.widgetAnchor` the widget and the watch use, so
    /// the banner cannot name a different day at the rollover; memoized, because this runs on every heart-rate tick
    /// (re-deriving it once scanned the whole history, #1051).
    private func refreshBanner(appActive: Bool? = nil) {
        guard let model else { return }
        let connected = model.live.connected
        let day = model.repo.cachedWidgetAnchor()
        update(bpm: connected ? (model.bpm ?? model.live.heartRate) : nil,
               recovery: day?.recovery.map { Int($0.rounded()) }, connected: connected, standsAside: standsAside(),
               appActive: appActive ?? (UIApplication.shared.applicationState == .active),
               effort: day?.strain.map { Int($0.rounded()) }, rest: day.flatMap { model.repo.restScore(for: $0) })
    }

    /// Drive the activity from the latest live values (`LiveHRBannerLifecycle` decides start / push / end). Starts
    /// only in the foreground (`appActive`), with the strap CONNECTED (the live link, not the sticky "paired" flag),
    /// before a heart rate arrives if need be; a running banner shows the dash through a dropped link or a strap
    /// that is not measuring, and ends only when its switch is off or the Lift Log banner takes the screen
    /// (`standsAside`). Pushed when what it shows changes, and often enough to stay fresh (`LiveHRBannerPushPolicy`,
    /// `staleAfter`).
    private func update(bpm: Int?, recovery: Int?, connected: Bool, standsAside: Bool, appActive: Bool,
                        effort: Int?, rest: Int? = nil) {
        guard authInfo.areActivitiesEnabled else { return }

        // A banner iOS ended (after about eight hours) or the user swiped away is gone: forget it, so the next time
        // NOOP is on screen it starts one again rather than pushing to nothing. (One NOOP is ending is not gone yet.)
        if !isEnding, let activity, !Self.isShowing(activity) {
            self.activity = nil
            shownState = nil
            startedAt = nil
            log((Self.listed(activity) == .ended ? "ended by iOS" : "gone from the Lock Screen (dismissed)")
                + "; started again when NOOP is next on screen")
        }
        // Re-adopt an activity that outlived a previous app session. ActivityKit keeps Live Activities
        // alive across launches/relaunches, but a fresh controller starts with `activity == nil`, so
        // without recovering the handle here we can neither update nor END an already-showing activity
        // — which made the #336 opt-out a no-op (#341: toggle off, heart stays) and risked spawning a
        // duplicate on the start path below. Done on the HR tick rather than in `init` because
        // `Activity.activities` isn't reliably hydrated at the instant of process launch. A banner iOS ended is
        // removed here too, whichever run fed it: it can only show its last number.
        if activity == nil {
            let listed = Activity<NOOPActivityAttributes>.activities
            removeLeftovers(listed, beside: nil)
            if let adopted = listed.first(where: Self.isShowing) {
                activity = adopted
                startedAt = (UserDefaults.standard.dictionary(forKey: Self.startedKey)?[adopted.id] as? Double)
                    .map(Date.init(timeIntervalSince1970:))
                log("picked up the one already on the Lock Screen")
            }
        }

        // The sleep-window pause (fork): the presentation half of the re-score deferral — the same
        // wall-clock window that pauses background scoring pauses the surface, from one source of
        // truth (`RescoreBackgroundScheduler.isInSleepWindow`), so the two can never drift. The rule
        // lives in `LiveActivityPresentationPolicy` (pure, unit-tested); only the window rides here —
        // the switch, the gym hand-off and the link state belong to `LiveHRBannerLifecycle` below,
        // which keeps the dash-on-disconnect instead of this policy's older teardown-on-drop.
        if case .suppress(let reason) = LiveActivityPresentationPolicy.decide(
                enabledByUser: true, inSleepWindow: RescoreBackgroundScheduler.isInSleepWindow,
                connected: true, hasBPM: true) {
            if activity != nil, !isEnding {
                isEnding = true
                log("ended: " + reason)
                Task { await end() }
            }
            return
        }

        // The switch (#336) and the gym banner on screen end it; nothing that passes does (`LiveHRBannerLifecycle`).
        let now = Date()
        let switchOn = UnitPrefs.liveActivityEnabled()
        let age = startedAt.map { now.timeIntervalSince($0) }
        let step = LiveHRBannerLifecycle.step(
            switchOn: switchOn, standsAside: standsAside, linkUp: connected,
            showing: activity != nil, age: age, appActive: appActive)
        switch step {
        case .nothing: return
        case .end:
            guard !isEnding else { return }
            isEnding = true
            log(switchOn ? "ended: the Lift Log banner takes its place" : "ended: its switch is off")
            Task { await end() }
            return
        case .start, .push, .renew: break
        }

        // Lock-aware cadence (fork): while the phone is locked nobody can watch beat-level movement, and
        // on an Always-On display every push repaints the Lock Screen, so locked pushes slow down,
        // carrying a window average (`LiveActivityHrPolicy`). The cadence is user-tunable (Settings →
        // Live notifications): N minutes between locked pushes, each showing the mean HR over that same
        // window; 0 disables the locked slowdown entirely (fully live, the pre-cadence behaviour). Read
        // per tick so a Settings edit applies at once. Locked = protected data (keychain/file keybag)
        // unavailable: the keybag tracks the passcode lock, not the screen, but on current hardware/iOS
        // it follows the physical lock near-instantly in both directions.
        let lockedMinutes = UnitPrefs.liveActivityLockedMinutes()
        let dutyCycle = LockedStreamPolicy.dutyCycleEnabled(lockedMinutes: lockedMinutes)
        let lockedSpacing = TimeInterval(max(lockedMinutes, 1)) * 60
        if let bpm { hrSamples = LiveActivityHrPolicy.appending(hrSamples, bpm: bpm, at: now, window: lockedSpacing) }
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
        // Locked: show the window's average — steadier, and honest about its cadence. The
        // instantaneous fallback only fires if the window is somehow empty.
        let shownBpm = (locked && bpm != nil)
            ? (LiveActivityHrPolicy.windowAverage(hrSamples, now: now, window: lockedSpacing) ?? bpm) : bpm

        // Link down: the dash, never the last number (`bonded` stays true across a disconnect, and keying off it once
        // left a fabricated "live" HR standing). No timed end: a timer in a suspended app fires at its next wake,
        // which is typically the strap coming back — exactly when the banner should stay.
        let state = NOOPActivityAttributes.ContentState(bpm: connected ? shownBpm : nil, recovery: recovery,
                                                        bonded: connected, effort: effort, rest: rest,
                                                        live: !locked)

        if step == .renew, activity != nil {
            // The fresh banner first, then the old one goes, so the Lock Screen is never without one; if iOS refuses
            // the fresh one, the old one stays.
            if start(state, at: now) {
                log("renewed after \(age.map { "\(Int($0 / 60)) min" } ?? "an unknown time"), "
                    + "so iOS's eight-hour limit starts again")
                removeLeftovers(Activity<NOOPActivityAttributes>.activities, beside: activity)
            }
        } else if let activity {
            // The number giving way to the dash (the strap off the wrist, the link dropping) is pushed at once: no
            // tick follows it, so a push skipped for spacing would leave the last number standing.
            guard LiveHRBannerPushPolicy.due(shown: shownState, next: state, reading: \.bpm,
                                             sinceLastPush: now.timeIntervalSince(lastPush),
                                             staleAfter: Self.staleAfter) else { return }
            // Locked cadence (fork): the configured window between pushes — except the dash transition
            // (often the last tick a quiet strap sends) and the LOCK EDGE: the first locked tick pushes
            // the window average immediately, otherwise the card holds the last LIVE beat for a whole
            // `lockedSpacing` ("captures the last HR value and freezes it", the +5 report).
            let dashFlip = shownState.map { ($0.bpm == nil) != (state.bpm == nil) } ?? true
            let lockEdge = locked && !lastPushWasLocked
            if locked, !dashFlip, !lockEdge,
               !LiveActivityHrPolicy.shouldPush(locked: true, now: now, lastPush: lastPush,
                                                lockedSpacing: lockedSpacing) { return }
            if let shown = shownState, (shown.bpm == nil) != (state.bpm == nil) { logReading(state) }
            lastPush = now
            lastPushWasLocked = locked
            shownState = state
            // Locked pushes carry NO staleDate for the same reason updateFromData's don't: iOS 26
            // REMOVES a stale activity from both surfaces rather than greying it, and a locked span
            // can legitimately go quiet past any window we'd pick. Live pushes keep the short net —
            // they refresh every ~2 s, so it only ever catches a crashed app.
            let staleDate: Date? = locked ? nil : now.addingTimeInterval(Self.staleAfter)
            Task { await activity.update(ActivityContent(state: state, staleDate: staleDate)) }
        } else if start(state, at: now) {
            lastPushWasLocked = locked
            log(state.bpm == nil ? "started, showing – until a heart rate arrives" : "started")
            removeLeftovers(Activity<NOOPActivityAttributes>.activities, beside: activity)
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
                                                        bonded: connected, effort: effort, rest: rest,
                                                        live: false)
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
                lastPushWasLocked = true
                activityStartedAt = Date()
            } catch {
                activity = nil
                log?("Live Activity: start failed — \(error.localizedDescription)")
            }
            isStarting = false
        }
    }

    /// Removes at once each banner in `listed` that `LiveHRBannerLifecycle.removes` says goes: one iOS has ended, which
    /// stays on the Lock Screen frozen on its last number and takes no update, and — once NOOP has started `fresh` —
    /// any other one still showing. Each removal of an ended one leaves a line: it is what a second banner beside the
    /// live one would have been.
    private func removeLeftovers(_ listed: [Activity<NOOPActivityAttributes>],
                                 beside fresh: Activity<NOOPActivityAttributes>?) {
        for act in listed where act.id != fresh?.id {
            let state = Self.listed(act)
            guard LiveHRBannerLifecycle.removes(state, besideFresh: fresh != nil),
                  removing.insert(act.id).inserted else { continue }
            if state == .ended { log("removed one iOS had ended, which could only show its last number") }
            Task { await act.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// Ask iOS for a new banner, which it grants only while NOOP is on screen. Returns whether it did.
    @discardableResult
    private func start(_ state: NOOPActivityAttributes.ContentState, at now: Date) -> Bool {
        // Set the start gate SYNCHRONOUSLY before any await so a second `update` arriving on the
        // main actor while `Activity.request` is still in flight bails here instead of issuing a
        // second request. The 2-second throttle above only guards the update path.
        guard !isStarting else { return false }
        isStarting = true
        defer { isStarting = false }
        do {
            let started = try Activity.request(
                attributes: NOOPActivityAttributes(title: String(localized: "HR")),
                content: ActivityContent(state: state, staleDate: now.addingTimeInterval(Self.staleAfter)),
                pushType: nil
            )
            activity = started
            startedAt = now
            UserDefaults.standard.set([started.id: now.timeIntervalSince1970], forKey: Self.startedKey)
            lastPush = now
            shownState = state
            refusalLogged = false
            return true
        } catch {
            if !refusalLogged {
                refusalLogged = true
                log("iOS did not start it: \(error.localizedDescription)")
            }
            return false
        }
    }

    /// The banner turning to the dash, or back to a number: pushed at once (`LiveHRBannerPushPolicy`), and logged.
    private func logReading(_ state: NOOPActivityAttributes.ContentState) {
        if state.bpm != nil {
            log("heart rate again")
        } else {
            log(state.bonded ? "– (strap connected, no heart rate)" : "– (strap not connected)")
        }
    }

    /// One line in NOOP's strap log for each thing that happens to the banner: started, picked up, renewed, ended,
    /// gone, and each turn to the dash and back. Rare, so always on. A tester's banner once showed the dash for a
    /// strap he was wearing, and a log without a word about the banner could not say why (24 Sep 2026).
    private func log(_ line: String) {
        model?.live.append(log: AppModel.stamped("Live HR banner: " + line))
    }

    /// Still on the Lock Screen and able to take an update: not ended by iOS, the user or NOOP.
    private static func isShowing(_ activity: Activity<NOOPActivityAttributes>) -> Bool {
        listed(activity) == .showing
    }

    /// The banner's state in `LiveHRBannerLifecycle`'s terms. `pending` (a start iOS 26 schedules) never comes from
    /// NOOP, which only starts banners at once, so it counts as gone: not NOOP's to feed or remove.
    private static func listed(_ activity: Activity<NOOPActivityAttributes>) -> LiveHRBannerLifecycle.Listed {
        switch activity.activityState {
        case .active, .stale: return .showing
        case .ended: return .ended
        default: return .gone
        }
    }

    private func end() async {
        // End every NOOP Live Activity, not just our cached handle — covers a straggler from a prior
        // session we never re-adopted (#341) and any rare duplicate. Iterating the live list is the
        // only way to reach activities this controller instance never started.
        for act in Activity<NOOPActivityAttributes>.activities {
            await act.end(nil, dismissalPolicy: .immediate)
        }
        self.activity = nil
        shownState = nil
        startedAt = nil
        isEnding = false
    }
}
#endif
