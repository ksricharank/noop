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

    // 1. The sentinel is exactly -1: 0 (fully live) and positive cadences keep today's behaviour,
    // and the Units clamp maps anything below -1 back onto the sentinel rather than past it.
    func testSentinelIsExactlyMinusOne() {
        XCTAssertTrue(Policy.dutyCycleEnabled(lockedMinutes: -1))
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

    // 6. The locked average window follows the offload cadence that produces the data: 15 minutes on
    // the normal 900 s cadence, 60 on the low-refresh 3600 s one — pinned against the BLEManager
    // constants so a cadence change cannot silently desynchronise the shown average.
    func testAveragingWindowTracksTheOffloadCadence() {
        XCTAssertEqual(Policy.averagingWindowMinutes(lowRefresh: false), 15)
        XCTAssertEqual(Policy.averagingWindowMinutes(lowRefresh: true), 60)
        XCTAssertEqual(Policy.averagingWindowMinutes(lowRefresh: false) * 60,
                       BLEManager.backfillIntervalSeconds)
        XCTAssertEqual(Policy.averagingWindowMinutes(lowRefresh: true) * 60,
                       BLEManager.lowRefreshBackfillIntervalSeconds)
    }

    // 7. A data-driven push stays fresh across one full window plus sync slack — the next repaint
    // cannot arrive sooner, and anything shorter would grey a healthy card.
    func testDataPushStaleWindowCoversOneCadence() {
        XCTAssertGreaterThanOrEqual(Policy.liveActivityStaleSeconds(windowMinutes: 15), 15 * 60)
        XCTAssertGreaterThanOrEqual(Policy.liveActivityStaleSeconds(windowMinutes: 60), 60 * 60)
    }

    // 8. The Units clamp accepts the sentinel and folds deeper negatives onto it (a fat-fingered
    // "-5" opts into the duty cycle rather than into undefined behaviour).
    func testUnitPrefsClampKeepsSentinel() {
        let d = UserDefaults.standard
        let saved = d.object(forKey: UnitPrefs.liveActivityLockedMinutesKey)
        defer {
            if let saved { d.set(saved, forKey: UnitPrefs.liveActivityLockedMinutesKey) }
            else { d.removeObject(forKey: UnitPrefs.liveActivityLockedMinutesKey) }
        }
        d.set(-1, forKey: UnitPrefs.liveActivityLockedMinutesKey)
        XCTAssertEqual(UnitPrefs.liveActivityLockedMinutes(), -1)
        d.set(-5, forKey: UnitPrefs.liveActivityLockedMinutesKey)
        XCTAssertEqual(UnitPrefs.liveActivityLockedMinutes(), -1)
        d.set(0, forKey: UnitPrefs.liveActivityLockedMinutesKey)
        XCTAssertEqual(UnitPrefs.liveActivityLockedMinutes(), 0)
        d.set(90, forKey: UnitPrefs.liveActivityLockedMinutesKey)
        XCTAssertEqual(UnitPrefs.liveActivityLockedMinutes(), 60)
    }
}
