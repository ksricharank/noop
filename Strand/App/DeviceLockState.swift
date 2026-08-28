import Foundation

/// The device-lock signal every duty-cycle consumer reads — latched at the LOCK NOTIFICATION, not
/// at the keybag flip.
///
/// `UIApplication.isProtectedDataAvailable` is the truthful lock state, but iOS flips it 10–60 s
/// AFTER the physical lock (the keybag grace window). Reading it alone meant the whole minute after
/// locking behaved as "unlocked": the stream stayed armed and live ticks kept repainting the locked
/// Lock Screen — the exact churn the 260827 rapid lock/unlock test showed. The
/// `protectedDataWillBecomeUnavailable` notification, by contrast, fires the moment the lock happens
/// (21:39:57 in that log, the second the button was pressed) — so the LATCH is what makes the edge
/// crisp, and the keybag is what makes it durable:
///
///   locked = keybag unavailable  OR  latch fresh (< TTL)
///
/// The TTL exists for the one stale-latch hole: lock latches while the app is awake, the app
/// suspends, the user unlocks, and BOTH unlock notes are missed — the latch would freeze an unlocked
/// phone forever. The keybag flips within ~15 s of a real lock, so a latch older than the TTL with
/// an OPEN keybag means the lock never completed (or was undone unseen); the keybag becomes
/// authoritative again.
///
/// State is a single timestamp on the main actor; the decision itself is pure and pinned by
/// `DeviceLockStateTests`.
@MainActor
enum DeviceLockState {
    /// How long the will-lock latch outranks an open keybag. Longer than the keybag's real grace
    /// (~10–15 s observed) with margin; short enough that a stale latch can't freeze an unlocked
    /// phone for more than half a minute.
    static let latchTTL: TimeInterval = 30

    private static var lockLatchUntil: Date?

    /// The lock notification fired (`protectedDataWillBecomeUnavailable`). Called by BLEManager's
    /// duty-cycle observers; harmless to re-latch.
    static func noteWillLock(now: Date = Date()) {
        lockLatchUntil = now.addingTimeInterval(latchTTL)
    }

    /// A positive unlock signal (`protectedDataDidBecomeAvailable`, or the app becoming active —
    /// which can only happen unlocked). Clears the latch so the very next read is live.
    static func noteUnlocked() {
        lockLatchUntil = nil
    }

    /// The combined signal. `protectedDataAvailable` is passed in (it is a main-actor UIKit read the
    /// caller already makes) so this stays testable and platform-free.
    static func isLocked(protectedDataAvailable: Bool, now: Date = Date()) -> Bool {
        decide(protectedDataAvailable: protectedDataAvailable, latchUntil: lockLatchUntil, now: now)
    }

    /// The pure rule — see the type doc for why each branch exists.
    static func decide(protectedDataAvailable: Bool, latchUntil: Date?, now: Date) -> Bool {
        if !protectedDataAvailable { return true }
        if let latchUntil, now < latchUntil { return true }
        return false
    }

    /// Test seam.
    static func reset() { lockLatchUntil = nil }
}
