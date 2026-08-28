import Foundation

/// Pure policy for the locked-phone realtime-stream duty cycle.
///
/// The always-on realtime HR stream (`TOGGLE_REALTIME_HR` + 0x2A37) wakes the app for every beat,
/// ~86,000 times a day — which iOS bills as hours of background activity. But the stream's value is
/// concentrated: the NIGHT needs dense R-R (that is where HRV coverage and recovery come from), and
/// an UNLOCKED phone has a user who may be watching live surfaces. A LOCKED phone during the day
/// needs neither — daytime consumers (stress index, daytime RMSSD baselines, spot HRV, the
/// Lock-Screen average) are all satisfied by short periodic bursts.
///
/// So the duty cycle keeps the stream armed in exactly three states — asleep-window, unlocked, or
/// inside a burst — and silences it otherwise. Bursts piggyback on moments the app is already awake
/// (an offload just completed) plus a best-effort timer, because a silenced app may be suspended and
/// cannot wake itself on a schedule (that is the whole point).
///
/// The mode is opted into through the existing Lock-Screen refresh setting
/// (`UnitPrefs.liveActivityLockedMinutes`): `-1` enables the duty cycle; `>= 0` keeps the plain
/// cadence behaviour with the stream policy untouched.
///
/// Platform-free and stateless so StrandTests can pin the truth table without CoreBluetooth or a
/// device. The lock/burst inputs are read by the caller (BLEManager on iOS); macOS never duty-cycles.
enum LockedStreamPolicy {
    /// The Settings sentinel: a Lock-Screen refresh of `-1` minutes means "duty-cycle the stream"
    /// rather than "refresh every -1 minutes". Any other stored value keeps today's behaviour.
    static let dutyCycleSentinel = -1

    /// Whether the stored Lock-Screen refresh value opts into the duty cycle.
    static func dutyCycleEnabled(lockedMinutes: Int) -> Bool {
        lockedMinutes == dutyCycleSentinel
    }

    /// How long one spot burst holds the stream open. Long enough for a clean ~60 s R-R window
    /// (spot HRV / stress need 1–5 min of beats; the Lock-Screen average uses 60 s) plus arm/settle
    /// slack on either side.
    static let burstSeconds: TimeInterval = 75

    /// Target spacing between bursts while locked. Matches the periodic offload cadence so a burst
    /// usually rides an offload wake instead of needing its own; the timer is best-effort (a
    /// suspended app fires it on its next wake, whenever that is).
    static let burstGapSeconds: TimeInterval = 600

    /// How long a locked Live Activity push stays fresh under the duty cycle: one full burst gap,
    /// a burst, and slack — the next update genuinely cannot arrive sooner, and iOS greying the
    /// card in between would misread "by design quiet" as "stale".
    static let liveActivityStaleSlack: TimeInterval = burstGapSeconds + burstSeconds + 120

    /// The three-mode want. `fallbackWant` is what the pre-existing policy (continuous capture,
    /// #927 overnight window, strap-battery throttle) would decide; the duty cycle only ever
    /// NARROWS it — a false fallback stays false, so "Continuous HRV capture" off, the strap-battery
    /// pause, and #927's own window all keep their authority.
    static func streamWanted(dutyCycle: Bool, fallbackWant: Bool,
                             locked: Bool, inSleepWindow: Bool, burstActive: Bool) -> Bool {
        guard fallbackWant else { return false }
        guard dutyCycle else { return true }
        return inSleepWindow || !locked || burstActive
    }

    /// Whether a burst window is still open. `nil` = no burst ever started.
    static func burstActive(now: Date, burstUntil: Date?) -> Bool {
        guard let burstUntil else { return false }
        return now < burstUntil
    }

    /// Whether an offload completion (or the best-effort timer) should open a burst: only in duty
    /// mode, only while locked (unlocked already streams), and only outside the sleep window (the
    /// night already streams). An already-open burst just extends.
    static func shouldStartBurst(dutyCycle: Bool, locked: Bool, inSleepWindow: Bool) -> Bool {
        dutyCycle && locked && !inSleepWindow
    }
}
