import XCTest
@testable import Strand
import WhoopProtocol

/// Pins WHICH LANE the #927 continuous-capture schedule drives, per strap family.
///
/// This exists because of a regression that shipped and was caught only on hardware. Live capture rides
/// two commands: the cheap `TOGGLE_REALTIME_HR` and the dense `SEND_R10R11_REALTIME`. Splitting them so
/// the schedule gated only the expensive one is correct — on a WHOOP 4.0. On a 5/MG it silently disabled
/// the whole feature, because `send()`'s puffin allow-list has no framing for R10/R11: every write is
/// dropped before it leaves the phone, so the gate governed a command the strap never receives. The code
/// read as though capture paused on lock; the strap streamed straight through it.
///
/// The invariant, then, is not "gate the heavy lane" but "gate a lane that actually reaches the strap".
/// These tests pin the two halves of that separately from any BLE plumbing:
///
///   1. the allow-list really does drop R10/R11 on a 5/MG and really does admit TOGGLE, and
///   2. the schedule predicate still resolves correctly for the composed want either way.
///
/// A CoreBluetooth connection cannot be stood up in a unit test (see the BLE notes in CONTRIBUTING), so
/// what is provable here is the family/command contract and the pure predicate. The end-to-end behaviour
/// — lock the phone, watch the stream stop — remains a hardware check.
final class ContinuousHrvCheapStreamGateTests: XCTestCase {

    // MARK: The command contract the gate depends on

    /// The load-bearing fact: on the 5/MG family the dense burst has no framing, so gating only that lane
    /// would gate nothing. If a future change adds 5/MG framing for R10/R11, THIS test is the one that
    /// should fail first — at which point `heavyStreamReachesStrap` can return true for the family and
    /// the cheap toggle can go back to being unconditional there.
    func testHeavyStreamHasNoWhoop5Framing() {
        XCTAssertFalse(BLEManager.whoop5AcceptsForTesting(.sendR10R11Realtime),
                       "5/MG gained R10/R11 framing — revisit heavyStreamReachesStrap and the cheap-lane gate")
    }

    /// …while the cheap toggle DOES reach a 5/MG. Both halves matter: the gate moves to the toggle on
    /// that family precisely because the toggle is the one command that lands.
    func testCheapToggleReachesWhoop5() {
        XCTAssertTrue(BLEManager.whoop5AcceptsForTesting(.toggleRealtimeHR))
    }

    /// WHOOP 4.0 has no send allow-list at all, so both commands reach it and the split is real there.
    /// Pinned so the asymmetry is documented as a property, not just a comment.
    func testWhoop4TakesBothCommands() {
        XCTAssertTrue(BLEManager.heavyStreamReaches(family: WhoopModel.whoop4.deviceFamily))
        XCTAssertFalse(BLEManager.heavyStreamReaches(family: WhoopModel.whoop5mg.deviceFamily))
    }

    // MARK: The composed want the gate feeds

    /// With the daytime lane on, an unlocked daytime phone wants capture and a locked one does not.
    /// On a 5/MG this is the answer that now drives the cheap toggle directly — which is what restores
    /// the pause-on-lock behaviour the split had removed.
    func testDaytimeLaneStillDistinguishesLockState() {
        let start = ContinuousHrvSchedule.defaultStartMinutes
        let end = ContinuousHrvSchedule.defaultEndMinutes
        func want(unlocked: Bool) -> Bool {
            ContinuousHrvSchedule.streamWanted(
                continuousHrv: true, overnightOnly: true,
                minuteOfDay: 12 * 60, startMin: start, endMin: end,
                daytimeWhileUnlocked: true, deviceUnlocked: unlocked)
        }
        XCTAssertTrue(want(unlocked: true))
        XCTAssertFalse(want(unlocked: false))
    }

    /// Inside the overnight window the answer is true regardless of lock state, so routing the schedule
    /// onto the cheap toggle cannot cost a 5/MG owner their night — the case that would matter most.
    func testOvernightCaptureSurvivesALockedPhone() {
        for unlocked in [true, false] {
            XCTAssertTrue(ContinuousHrvSchedule.streamWanted(
                continuousHrv: true, overnightOnly: true,
                minuteOfDay: 3 * 60,
                startMin: ContinuousHrvSchedule.defaultStartMinutes,
                endMin: ContinuousHrvSchedule.defaultEndMinutes,
                daytimeWhileUnlocked: true, deviceUnlocked: unlocked),
                "a locked phone on the nightstand must still bank the night")
        }
    }

    /// With the daytime lane OFF, a 5/MG behaves exactly as #927 always intended: captures overnight,
    /// silent through the day, lock state irrelevant. Routing the schedule onto the cheap toggle must not
    /// change that composition.
    func testLaneOffKeepsPlainOvernightBehaviour() {
        let start = ContinuousHrvSchedule.defaultStartMinutes
        let end = ContinuousHrvSchedule.defaultEndMinutes
        for unlocked in [true, false] {
            XCTAssertTrue(ContinuousHrvSchedule.streamWanted(
                continuousHrv: true, overnightOnly: true, minuteOfDay: 2 * 60,
                startMin: start, endMin: end,
                daytimeWhileUnlocked: false, deviceUnlocked: unlocked))
            XCTAssertFalse(ContinuousHrvSchedule.streamWanted(
                continuousHrv: true, overnightOnly: true, minuteOfDay: 14 * 60,
                startMin: start, endMin: end,
                daytimeWhileUnlocked: false, deviceUnlocked: unlocked))
        }
    }
}
