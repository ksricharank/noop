import Foundation

/// Pure policy for the locked-phone realtime-stream duty cycle (v2 — data-driven, no bursts).
///
/// The always-on realtime HR stream (`TOGGLE_REALTIME_HR` + 0x2A37) wakes the app for every beat,
/// ~86,000 times a day — which iOS bills as hours of background activity. But the stream's value is
/// concentrated: the NIGHT needs dense R-R (that is where HRV coverage and recovery come from), and
/// an UNLOCKED phone has a user who may be watching live surfaces. So the duty cycle keeps the
/// stream armed in exactly two states — the sleep window, or unlocked — and silences it otherwise.
///
/// While locked in the daytime the Lock-Screen Live Activity is driven by PERSISTED data instead:
/// each completed offload refreshes it once with the mean HR over the offload cadence's own window
/// (15 min normally, 60 in low-refresh mode) plus the last recorded recovery and effort. v1 tried
/// short live-stream bursts here and failed twice on hardware: stray live ticks kept repainting the
/// locked Lock Screen (the strap can keep pushing HR over the puffin data channels the offload
/// needs, whatever the TOGGLE says), and the burst's 0x2A37 unsubscribe/resubscribe churn raced
/// CoreBluetooth's async notify state, leaving the Dynamic Island stale after unlock. Data-driven
/// updates have neither mechanism: the stream is simply OFF while locked, and
/// `lockedLiveTickPushAllowed` is the hard gate that makes any stray tick unable to repaint.
///
/// The mode is opted into through the existing Lock-Screen refresh setting
/// (`UnitPrefs.liveActivityLockedMinutes`): `-1` enables the duty cycle; `>= 0` keeps the plain
/// cadence behaviour with the stream policy untouched.
///
/// Platform-free and stateless so StrandTests can pin the truth table without CoreBluetooth or a
/// device. The lock input is read by the caller (BLEManager / the app layer on iOS); macOS never
/// duty-cycles.
enum LockedStreamPolicy {
    /// The Settings sentinel: a Lock-Screen refresh of `-1` minutes means "duty-cycle the stream"
    /// rather than "refresh every -1 minutes". Any other stored value keeps today's behaviour.
    static let dutyCycleSentinel = -1

    /// Whether the stored Lock-Screen refresh value opts into the duty cycle.
    static func dutyCycleEnabled(lockedMinutes: Int) -> Bool {
        lockedMinutes == dutyCycleSentinel
    }

    /// The two-state want. `fallbackWant` is what the pre-existing policy (continuous capture,
    /// #927 overnight window, strap-battery throttle) would decide; the duty cycle only ever
    /// NARROWS it — a false fallback stays false, so "Continuous HRV capture" off, the strap-battery
    /// pause, and #927's own window all keep their authority.
    static func streamWanted(dutyCycle: Bool, fallbackWant: Bool,
                             locked: Bool, inSleepWindow: Bool) -> Bool {
        guard fallbackWant else { return false }
        guard dutyCycle else { return true }
        return inSleepWindow || !locked
    }

    /// Whether a LIVE HR tick may push the Live Activity. False exactly when the duty cycle owns the
    /// locked presentation — there, only the offload-driven data refresh may repaint. This is the
    /// hard gate that fixes v1's "Lock Screen kept updating while locked": whatever channel a stray
    /// live tick arrives on, it cannot reach the activity.
    static func lockedLiveTickPushAllowed(dutyCycle: Bool, locked: Bool) -> Bool {
        !(dutyCycle && locked)
    }

    /// The locked Lock-Screen average window, tied to the offload cadence that produces the data:
    /// 15 minutes on the normal cadence (`BLEManager.backfillIntervalSeconds` = 900), 60 in
    /// low-refresh mode (3600). The number shown is always "the mean over roughly one sync's worth
    /// of data", whatever the cadence.
    static func averagingWindowMinutes(lowRefresh: Bool) -> Int {
        lowRefresh ? 60 : 15
    }

    /// How long a data-driven locked push stays fresh: one full averaging window until the next
    /// offload can produce a successor, plus slack for the sync itself — iOS greying the card in
    /// between would misread "by design quiet" as "stale".
    static func liveActivityStaleSeconds(windowMinutes: Int) -> TimeInterval {
        TimeInterval(windowMinutes * 60) + 300
    }
}
