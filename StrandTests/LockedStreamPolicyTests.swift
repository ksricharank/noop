import XCTest
@testable import Strand

/// `LockedStreamPolicy` v2 — the pure two-state policy behind the locked-phone realtime-stream duty
/// cycle (Lock-Screen refresh = -1). The stream stays armed through the sleep window (dense night
/// R-R = HRV coverage) and while unlocked; a locked daytime phone silences it, and the Lock Screen
/// is repainted from persisted offload data instead. The policy only ever NARROWS the pre-existing
/// want. No CoreBluetooth or UIKit here; `BLEManager` and `LiveActivityController` are thin shells
/// over these predicates.
final class LockedStreamPolicyTests: XCTestCase {
    private typealias Policy = LockedStreamPolicy

    // 1. ANY negative opts into the duty cycle; 0 (fully live) and positive cadences keep today's
    // behaviour.
    func testAnyNegativeEnablesTheDutyCycle() {
        XCTAssertTrue(Policy.dutyCycleEnabled(lockedMinutes: -1))
        XCTAssertTrue(Policy.dutyCycleEnabled(lockedMinutes: -15))
        XCTAssertTrue(Policy.dutyCycleEnabled(lockedMinutes: -240))
        XCTAssertFalse(Policy.dutyCycleEnabled(lockedMinutes: 0))
        XCTAssertFalse(Policy.dutyCycleEnabled(lockedMinutes: 1))
        XCTAssertFalse(Policy.dutyCycleEnabled(lockedMinutes: 60))
    }

    // 2. Duty cycle OFF is a pure pass-through of the pre-existing want, whatever the lock or
    // window inputs claim — flipping the setting back must be byte-identical to today.
    func testDisabledModePassesFallbackThrough() {
        for locked in [true, false] {
            for window in [true, false] {
                XCTAssertTrue(Policy.streamWanted(dutyCycle: false, fallbackWant: true,
                                                  locked: locked, inSleepWindow: window))
                XCTAssertFalse(Policy.streamWanted(dutyCycle: false, fallbackWant: false,
                                                   locked: locked, inSleepWindow: window))
            }
        }
    }

    // 3. The duty cycle can only narrow: a false fallback (continuous capture off, strap-battery
    // pause, #927 window closed) stays false in EVERY duty-cycle state, sleep window included.
    // This is the "never arms a silenced stream" contract.
    func testFalseFallbackIsNeverOverridden() {
        for locked in [true, false] {
            for window in [true, false] {
                XCTAssertFalse(Policy.streamWanted(dutyCycle: true, fallbackWant: false,
                                                   locked: locked, inSleepWindow: window))
            }
        }
    }

    // 4. The two armed states — sleep window or unlocked — each alone keep the stream on, and the
    // silenced state is exactly one: locked, daytime.
    func testTheThreeModeTruthTable() {
        XCTAssertTrue(Policy.streamWanted(dutyCycle: true, fallbackWant: true,
                                          locked: true, inSleepWindow: true))
        XCTAssertTrue(Policy.streamWanted(dutyCycle: true, fallbackWant: true,
                                          locked: false, inSleepWindow: false))
        XCTAssertFalse(Policy.streamWanted(dutyCycle: true, fallbackWant: true,
                                           locked: true, inSleepWindow: false))
    }

    // 5. The live-tick gate — the fix for v1's "Lock Screen kept updating while locked": under the
    // duty cycle a LOCKED phone never accepts a live-tick push, whatever channel the tick arrived
    // on. Every other combination stays open (unlocked duty mode is live; plain cadence keeps its
    // own throttle downstream of this gate).
    func testLockedDutyModeRefusesLiveTickPushes() {
        XCTAssertFalse(Policy.lockedLiveTickPushAllowed(dutyCycle: true, locked: true))
        XCTAssertTrue(Policy.lockedLiveTickPushAllowed(dutyCycle: true, locked: false))
        XCTAssertTrue(Policy.lockedLiveTickPushAllowed(dutyCycle: false, locked: true))
        XCTAssertTrue(Policy.lockedLiveTickPushAllowed(dutyCycle: false, locked: false))
    }

    // 6. The locked average window: -1 (auto) follows the offload cadence that produces the data —
    // pinned against the BLEManager constants so a cadence change cannot silently desynchronise the
    // shown average — while any other negative is the user's explicit window in minutes, clamped to
    // the sane range.
    func testAveragingWindowAutoAndExplicit() {
        XCTAssertEqual(Policy.averagingWindowMinutes(lockedMinutes: -1, lowRefresh: false), 15)
        XCTAssertEqual(Policy.averagingWindowMinutes(lockedMinutes: -1, lowRefresh: true), 60)
        XCTAssertEqual(Policy.averagingWindowMinutes(lockedMinutes: -1, lowRefresh: false) * 60,
                       BLEManager.backfillIntervalSeconds)
        XCTAssertEqual(Policy.averagingWindowMinutes(lockedMinutes: -1, lowRefresh: true) * 60,
                       BLEManager.lowRefreshBackfillIntervalSeconds)
        XCTAssertEqual(Policy.averagingWindowMinutes(lockedMinutes: -15, lowRefresh: false), 15)
        XCTAssertEqual(Policy.averagingWindowMinutes(lockedMinutes: -20, lowRefresh: false), 20)
        XCTAssertEqual(Policy.averagingWindowMinutes(lockedMinutes: -20, lowRefresh: true), 20)
        XCTAssertEqual(Policy.averagingWindowMinutes(lockedMinutes: -999, lowRefresh: false), 240)
    }

    // 7. RETIRED: `liveActivityStaleSeconds` (cadence + slack) is gone — iOS 26 REMOVES a stale
    // Live Activity from both surfaces instead of greying it, so locked repaints carry no staleDate
    // at all (260828-0914: the card vanished ~20 min into every away span). See LockedStreamPolicy's
    // HISTORY note.

    // 8. The Units clamp passes explicit negative windows through and folds anything beyond the
    // sane range onto its edge (a fat-fingered "-999" becomes a 240-minute window, not undefined
    // behaviour).
    func testUnitPrefsClampKeepsSentinel() {
        let d = UserDefaults.standard
        let saved = d.object(forKey: UnitPrefs.liveActivityLockedMinutesKey)
        defer {
            if let saved { d.set(saved, forKey: UnitPrefs.liveActivityLockedMinutesKey) }
            else { d.removeObject(forKey: UnitPrefs.liveActivityLockedMinutesKey) }
        }
        d.set(-1, forKey: UnitPrefs.liveActivityLockedMinutesKey)
        XCTAssertEqual(UnitPrefs.liveActivityLockedMinutes(), -1)
        d.set(-20, forKey: UnitPrefs.liveActivityLockedMinutesKey)
        XCTAssertEqual(UnitPrefs.liveActivityLockedMinutes(), -20)
        d.set(-999, forKey: UnitPrefs.liveActivityLockedMinutesKey)
        XCTAssertEqual(UnitPrefs.liveActivityLockedMinutes(), -240)
        d.set(0, forKey: UnitPrefs.liveActivityLockedMinutesKey)
        XCTAssertEqual(UnitPrefs.liveActivityLockedMinutes(), 0)
        d.set(90, forKey: UnitPrefs.liveActivityLockedMinutesKey)
        XCTAssertEqual(UnitPrefs.liveActivityLockedMinutes(), 60)
    }

    // 8. A link drop HOLDS the Live Activity exactly while the duty cycle owns a locked phone —
    // there, the idle link timing out is routine and the end was one-way (no background starts;
    // the 260828-0731 "island dead after lock + a few minutes" bug). Every other state keeps the
    // immediate end: a frozen number presented as live is the #911 bug the hold must not
    // reintroduce.
    func testDisconnectHoldsOnlyWhileLockedUnderTheDutyCycle() {
        XCTAssertTrue(Policy.holdOnDisconnect(dutyCycle: true, locked: true))
        XCTAssertFalse(Policy.holdOnDisconnect(dutyCycle: true, locked: false))
        XCTAssertFalse(Policy.holdOnDisconnect(dutyCycle: false, locked: true))
        XCTAssertFalse(Policy.holdOnDisconnect(dutyCycle: false, locked: false))
    }
}
