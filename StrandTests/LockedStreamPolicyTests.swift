import XCTest
@testable import Strand

/// `LockedStreamPolicy` — the pure three-mode policy behind the locked-phone realtime-stream duty
/// cycle (Lock-Screen refresh = -1). The stream stays armed through the sleep window (dense night
/// R-R = HRV coverage), while unlocked, and inside a spot burst; a locked daytime phone otherwise
/// silences it. The policy only ever NARROWS the pre-existing want — it can never arm a stream that
/// continuous-capture, the strap-battery pause, or #927's window already refused. No CoreBluetooth
/// or UIKit here; `BLEManager` is a thin shell over these predicates.
final class LockedStreamPolicyTests: XCTestCase {
    private typealias Policy = LockedStreamPolicy
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

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
                                                  locked: locked, inSleepWindow: window,
                                                  burstActive: false))
                XCTAssertFalse(Policy.streamWanted(dutyCycle: false, fallbackWant: false,
                                                   locked: locked, inSleepWindow: window,
                                                   burstActive: true))
            }
        }
    }

    // 3. The duty cycle can only narrow: a false fallback (continuous capture off, strap-battery
    // pause, #927 window closed) stays false in EVERY duty-cycle state, sleep window and burst
    // included. This is the "never arms a silenced stream" contract.
    func testFalseFallbackIsNeverOverridden() {
        for locked in [true, false] {
            for window in [true, false] {
                for burst in [true, false] {
                    XCTAssertFalse(Policy.streamWanted(dutyCycle: true, fallbackWant: false,
                                                       locked: locked, inSleepWindow: window,
                                                       burstActive: burst))
                }
            }
        }
    }

    // 4. The three armed states: sleep window, unlocked, burst — each alone keeps the stream on.
    func testEachArmedStateAloneKeepsStreaming() {
        XCTAssertTrue(Policy.streamWanted(dutyCycle: true, fallbackWant: true,
                                          locked: true, inSleepWindow: true, burstActive: false))
        XCTAssertTrue(Policy.streamWanted(dutyCycle: true, fallbackWant: true,
                                          locked: false, inSleepWindow: false, burstActive: false))
        XCTAssertTrue(Policy.streamWanted(dutyCycle: true, fallbackWant: true,
                                          locked: true, inSleepWindow: false, burstActive: true))
    }

    // 5. The silenced state is exactly one: locked, daytime, no burst.
    func testLockedDaytimeOutsideBurstSilences() {
        XCTAssertFalse(Policy.streamWanted(dutyCycle: true, fallbackWant: true,
                                           locked: true, inSleepWindow: false, burstActive: false))
    }

    // 6. Burst window edges: open strictly before `burstUntil`, closed at and after it, and a nil
    // window (no burst ever started) reads closed.
    func testBurstWindowEdges() {
        let until = t0.addingTimeInterval(Policy.burstSeconds)
        XCTAssertTrue(Policy.burstActive(now: t0, burstUntil: until))
        XCTAssertTrue(Policy.burstActive(now: until.addingTimeInterval(-1), burstUntil: until))
        XCTAssertFalse(Policy.burstActive(now: until, burstUntil: until))
        XCTAssertFalse(Policy.burstActive(now: until.addingTimeInterval(1), burstUntil: until))
        XCTAssertFalse(Policy.burstActive(now: t0, burstUntil: nil))
    }

    // 7. Bursts start only where they add anything: duty mode, locked, outside the sleep window.
    // Unlocked already streams; the night already streams; other modes never burst.
    func testBurstStartGate() {
        XCTAssertTrue(Policy.shouldStartBurst(dutyCycle: true, locked: true, inSleepWindow: false))
        XCTAssertFalse(Policy.shouldStartBurst(dutyCycle: true, locked: false, inSleepWindow: false))
        XCTAssertFalse(Policy.shouldStartBurst(dutyCycle: true, locked: true, inSleepWindow: true))
        XCTAssertFalse(Policy.shouldStartBurst(dutyCycle: false, locked: true, inSleepWindow: false))
    }

    // 8. The Live Activity freshness slack covers a full burst gap plus a burst — the next locked
    // push genuinely cannot arrive sooner, so anything shorter would grey a healthy card.
    func testLiveActivityStaleSlackCoversTheGap() {
        XCTAssertGreaterThanOrEqual(Policy.liveActivityStaleSlack,
                                    Policy.burstGapSeconds + Policy.burstSeconds)
    }

    // 9. The Units clamp accepts the sentinel and folds deeper negatives onto it (a fat-fingered
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
