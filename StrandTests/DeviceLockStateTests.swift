import XCTest
@testable import Strand

/// `DeviceLockState` — the latch-or-keybag lock signal behind the duty cycle's edges. The keybag
/// (`isProtectedDataAvailable`) flips 10–60 s AFTER the physical lock, so keybag-only reads left the
/// locked Lock Screen repainting through the whole grace window (the 260827-2142 rapid lock/unlock
/// churn); the latch is what makes the lock edge crisp, and the TTL is what keeps a stale latch from
/// freezing an unlocked phone. The decision is pure; these pin it.
@MainActor
final class DeviceLockStateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() async throws {
        DeviceLockState.reset()
    }

    // 1. Keybag closed is locked, latch or no latch — the durable half of the signal.
    func testClosedKeybagIsAlwaysLocked() {
        XCTAssertTrue(DeviceLockState.decide(protectedDataAvailable: false, latchUntil: nil, now: t0))
        XCTAssertTrue(DeviceLockState.decide(protectedDataAvailable: false,
                                             latchUntil: t0.addingTimeInterval(30), now: t0))
    }

    // 2. THE GRACE-WINDOW FIX: keybag still open but the lock notification just latched — locked.
    // This is the read that used to say "unlocked" for the 10–60 s after pressing the button.
    func testFreshLatchOutranksAnOpenKeybag() {
        XCTAssertTrue(DeviceLockState.decide(protectedDataAvailable: true,
                                             latchUntil: t0.addingTimeInterval(30), now: t0))
    }

    // 3. THE STALE-LATCH FIX: a latch older than its TTL with an OPEN keybag means the lock never
    // completed (or was undone while the app slept) — the keybag becomes authoritative again, so a
    // missed unlock notification cannot freeze an unlocked phone.
    func testExpiredLatchYieldsToTheOpenKeybag() {
        XCTAssertFalse(DeviceLockState.decide(protectedDataAvailable: true,
                                              latchUntil: t0, now: t0))
        XCTAssertFalse(DeviceLockState.decide(protectedDataAvailable: true,
                                              latchUntil: t0, now: t0.addingTimeInterval(1)))
    }

    // 4. No latch, open keybag: unlocked — the steady state.
    func testNoLatchOpenKeybagIsUnlocked() {
        XCTAssertFalse(DeviceLockState.decide(protectedDataAvailable: true, latchUntil: nil, now: t0))
    }

    // 5. The stateful wrapper: will-lock latches for the TTL, an unlock note clears it immediately —
    // the unlock edge must be as crisp as the lock edge.
    func testLatchLifecycle() {
        DeviceLockState.noteWillLock(now: t0)
        XCTAssertTrue(DeviceLockState.isLocked(protectedDataAvailable: true, now: t0))
        XCTAssertTrue(DeviceLockState.isLocked(protectedDataAvailable: true,
                                               now: t0.addingTimeInterval(DeviceLockState.latchTTL - 1)))
        XCTAssertFalse(DeviceLockState.isLocked(protectedDataAvailable: true,
                                                now: t0.addingTimeInterval(DeviceLockState.latchTTL)))
        DeviceLockState.noteWillLock(now: t0)
        DeviceLockState.noteUnlocked()
        XCTAssertFalse(DeviceLockState.isLocked(protectedDataAvailable: true, now: t0))
    }

    // 6. The TTL is longer than the keybag's real grace (~10–15 s observed) with margin, and short
    // enough that the stale-latch hole self-heals within half a minute.
    func testTTLBounds() {
        XCTAssertGreaterThanOrEqual(DeviceLockState.latchTTL, 20)
        XCTAssertLessThanOrEqual(DeviceLockState.latchTTL, 60)
    }
}
