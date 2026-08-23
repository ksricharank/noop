import XCTest
@testable import Strand

/// Pins the conditional daytime lane of Continuous HRV capture: outside the nightly #927 window, hold
/// the EXPENSIVE R10/R11 stream open only while the phone is unlocked.
///
/// SCOPE — this predicate governs the heavy stream ONLY. Live capture splits across two independently
/// armed commands, and the split is the whole design: the cheap TOGGLE_REALTIME_HR (HR + R-R at ~1 Hz
/// over 0x2A37) stays armed continuously so the Dynamic Island always has a number, while
/// SEND_R10R11_REALTIME — the battery-hungry one — is what this schedule gates. An earlier version drove
/// both from this one want, so disarming the drain also blanked the live HR; these tests exist partly to
/// stop that coupling coming back.
///
/// So the two properties worth pinning are symmetric: outside the window the lock state decides, and
/// inside the window it decides nothing (a phone locked on the nightstand must still bank the night).
///
/// Pure predicate, no seams — `deviceUnlocked` is passed in exactly as `BLEManager.deviceUnlockedNow()`
/// resolves it at each arm site (iOS Data Protection; always false on macOS, where the lane is inert).
final class ContinuousHrvDaytimeUnlockedTests: XCTestCase {

    private let start = ContinuousHrvSchedule.defaultStartMinutes   // 22:00
    private let end = ContinuousHrvSchedule.defaultEndMinutes       // 07:00

    /// Every minute-of-day used below, with whether it sits inside the default 22:00→07:00 window.
    private let noon = 12 * 60
    private let midMorning = 9 * 60
    private let deepNight = 3 * 60

    private func wanted(minute: Int, daytimeLane: Bool, unlocked: Bool,
                        overnightOnly: Bool = true, continuousHrv: Bool = true) -> Bool {
        ContinuousHrvSchedule.streamWanted(
            continuousHrv: continuousHrv, overnightOnly: overnightOnly,
            minuteOfDay: minute, startMin: start, endMin: end,
            daytimeWhileUnlocked: daytimeLane, deviceUnlocked: unlocked)
    }

    // MARK: The lane itself

    /// The headline behaviour: daytime + lane on ⇒ the heavy stream is armed while unlocked and silent
    /// while locked. This is the whole battery argument. (The cheap toggle keeps running throughout —
    /// it is not governed by this predicate at all, so a locked phone still shows live HR.)
    func testDaytimeLaneFollowsLockState() {
        XCTAssertTrue(wanted(minute: noon, daytimeLane: true, unlocked: true))
        XCTAssertFalse(wanted(minute: noon, daytimeLane: true, unlocked: false))
        XCTAssertTrue(wanted(minute: midMorning, daytimeLane: true, unlocked: true))
        XCTAssertFalse(wanted(minute: midMorning, daytimeLane: true, unlocked: false))
    }

    /// Inside the overnight window the lane is irrelevant: the night is captured whether the phone is
    /// locked or not. A regression here would silently stop recording the night for anyone who locks
    /// their phone at bedtime — i.e. everyone — which is the exact data this feature exists to protect.
    func testOvernightWindowIgnoresLockState() {
        for unlocked in [true, false] {
            for lane in [true, false] {
                XCTAssertTrue(wanted(minute: deepNight, daytimeLane: lane, unlocked: unlocked),
                              "deep night must capture (lane=\(lane), unlocked=\(unlocked))")
                XCTAssertTrue(wanted(minute: 23 * 60, daytimeLane: lane, unlocked: unlocked))
                XCTAssertTrue(wanted(minute: 0, daytimeLane: lane, unlocked: unlocked))
            }
        }
    }

    /// Lane OFF is byte-for-byte the pre-existing #927 OVERNIGHT behaviour at every hour, unlocked or
    /// not — the new parameters default to false, so an install that never touches the toggle is
    /// unchanged.
    func testLaneOffMatchesOvernightOnly() {
        for minute in [0, deepNight, 6 * 60 + 59, 7 * 60, midMorning, noon, 21 * 60 + 59, 22 * 60, 1439] {
            let legacy = ContinuousHrvSchedule.streamWanted(
                continuousHrv: true, overnightOnly: true,
                minuteOfDay: minute, startMin: start, endMin: end)
            for unlocked in [true, false] {
                XCTAssertEqual(wanted(minute: minute, daytimeLane: false, unlocked: unlocked), legacy,
                               "minute \(minute) drifted from #927 with the lane off")
            }
        }
    }

    // MARK: Composition with the modes above it

    /// The lane cannot resurrect capture the master switch turned off. Continuous HRV off ⇒ never
    /// wanted, unlocked or not.
    func testMasterOffBeatsTheLane() {
        for unlocked in [true, false] {
            XCTAssertFalse(wanted(minute: noon, daytimeLane: true, unlocked: unlocked,
                                  continuousHrv: false))
        }
    }

    /// The lane cannot NARROW ALWAYS mode. Someone on continuous-on + overnight-off opted into 24/7
    /// capture; a stray daytime-lane flag (e.g. left set from an earlier overnight configuration) must
    /// not start gating their afternoon on the lock screen.
    func testAlwaysModeIsNotNarrowedByTheLane() {
        for unlocked in [true, false] {
            XCTAssertTrue(wanted(minute: noon, daytimeLane: true, unlocked: unlocked,
                                 overnightOnly: false))
        }
    }

    // MARK: Boundaries — the lane takes over exactly where the window stops

    /// The handover is seamless and shares the window's own inclusive-start / exclusive-end semantics:
    /// 07:00 (the first daytime minute) is lane territory, 06:59 is still the window; 22:00 is the
    /// window again, 21:59 is still the lane.
    func testHandoverAtWindowEdges() {
        // 06:59 — inside the window: captured even locked.
        XCTAssertTrue(wanted(minute: 6 * 60 + 59, daytimeLane: true, unlocked: false))
        // 07:00 — the window has ended: now the lock state decides.
        XCTAssertFalse(wanted(minute: 7 * 60, daytimeLane: true, unlocked: false))
        XCTAssertTrue(wanted(minute: 7 * 60, daytimeLane: true, unlocked: true))
        // 21:59 — still daytime: lock state decides.
        XCTAssertFalse(wanted(minute: 21 * 60 + 59, daytimeLane: true, unlocked: false))
        XCTAssertTrue(wanted(minute: 21 * 60 + 59, daytimeLane: true, unlocked: true))
        // 22:00 — the window resumes: captured even locked.
        XCTAssertTrue(wanted(minute: 22 * 60, daytimeLane: true, unlocked: false))
    }

    /// A user with a non-wrapping window (01:00→05:00) gets the same split: inside it, always; outside
    /// it, unlocked-only. No modular surprises from the lane sitting on top of `windowContains`.
    func testNonWrappingWindowSplitsTheSameWay() {
        let s = 1 * 60, e = 5 * 60
        func w(_ minute: Int, unlocked: Bool) -> Bool {
            ContinuousHrvSchedule.streamWanted(
                continuousHrv: true, overnightOnly: true,
                minuteOfDay: minute, startMin: s, endMin: e,
                daytimeWhileUnlocked: true, deviceUnlocked: unlocked)
        }
        XCTAssertTrue(w(2 * 60, unlocked: false))    // inside: locked is fine
        XCTAssertFalse(w(12 * 60, unlocked: false))  // outside + locked: silent
        XCTAssertTrue(w(12 * 60, unlocked: true))    // outside + unlocked: armed
        XCTAssertTrue(w(0, unlocked: true))          // 00:00 is outside [01:00,05:00) — lane applies
        XCTAssertFalse(w(0, unlocked: false))
    }

    /// A degenerate empty window (start == end) leaves the lane as the ONLY thing that can arm capture:
    /// there is no "inside" to fall back on, so an unlocked phone streams and a locked one does not, at
    /// every hour. Pins that the empty-window convention doesn't accidentally read as "all day".
    func testEmptyWindowLeavesOnlyTheLane() {
        let s = 8 * 60
        for minute in [0, s - 1, s, s + 1, 23 * 60] {
            XCTAssertTrue(ContinuousHrvSchedule.streamWanted(
                continuousHrv: true, overnightOnly: true,
                minuteOfDay: minute, startMin: s, endMin: s,
                daytimeWhileUnlocked: true, deviceUnlocked: true))
            XCTAssertFalse(ContinuousHrvSchedule.streamWanted(
                continuousHrv: true, overnightOnly: true,
                minuteOfDay: minute, startMin: s, endMin: s,
                daytimeWhileUnlocked: true, deviceUnlocked: false))
        }
    }

    // MARK: Preference default

    /// The lane is opt-in. An install that has never seen the toggle must read OFF, so nobody's battery
    /// gets quietly spent by an upgrade.
    func testPreferenceDefaultsOff() {
        let key = PuffinExperiment.continuousHrvDaytimeUnlockedKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(PuffinExperiment.continuousHrvDaytimeUnlockedEnabled)
        UserDefaults.standard.set(true, forKey: key)
        XCTAssertTrue(PuffinExperiment.continuousHrvDaytimeUnlockedEnabled)
    }
}
