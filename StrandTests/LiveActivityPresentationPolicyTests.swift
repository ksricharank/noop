import XCTest
@testable import Strand

/// When the live-HR Lock Screen / Dynamic Island surface is allowed to be on screen.
///
/// Pinned here because every one of these rules is invisible from inside a single run: the surface is
/// system-drawn, the failures are "it stayed up all night" or "it flickered off and on", and both are
/// noticed on a wrist hours later rather than in a debugger. The sleep-window rule in particular has a
/// twin — `RescoreBackgroundPolicy` pauses SCORING over the same window — and the pair only stays
/// coherent if the boundaries are asserted rather than assumed.
final class LiveActivityPresentationPolicyTests: XCTestCase {

    /// The ordinary live case: toggle on, awake, connected, a sample in hand.
    func testPresentsWhileStreamingOutsideTheSleepWindow() {
        let decision = LiveActivityPresentationPolicy.decide(
            enabledByUser: true, inSleepWindow: false, connected: true, hasBPM: true)
        XCTAssertEqual(decision, .present)
    }

    /// The point of this change: inside the sleep window the surface goes away, even though the strap
    /// is connected and streaming perfectly well. Streaming and banking are deliberately untouched —
    /// only the presentation pauses.
    func testSuppressesInsideTheSleepWindowDespiteALiveStream() {
        let decision = LiveActivityPresentationPolicy.decide(
            enabledByUser: true, inSleepWindow: true, connected: true, hasBPM: true)
        guard case .suppress(let reason) = decision else {
            return XCTFail("expected suppression inside the sleep window, got \(decision)")
        }
        XCTAssertTrue(reason.contains("sleep window"),
                      "the reason is logged verbatim and must name the cause; got: \(reason)")
    }

    /// The window must not leak into the rest of the day: the same inputs one minute outside it present
    /// normally. This is the assertion that would catch an inverted or off-by-one window check.
    func testOutsideTheWindowIsUnaffected() {
        XCTAssertEqual(
            LiveActivityPresentationPolicy.decide(
                enabledByUser: true, inSleepWindow: false, connected: true, hasBPM: true),
            .present)
    }

    /// #336: an explicit user opt-out outranks every other input, including a healthy live stream.
    func testUserOptOutWinsOverEverything() {
        let decision = LiveActivityPresentationPolicy.decide(
            enabledByUser: false, inSleepWindow: false, connected: true, hasBPM: true)
        guard case .suppress(let reason) = decision else {
            return XCTFail("expected suppression when the toggle is off, got \(decision)")
        }
        XCTAssertTrue(reason.contains("toggle"), "got: \(reason)")
    }

    /// The opt-out is checked BEFORE the window, so a user who turned the feature off gets the toggle
    /// reason rather than a sleep-window one. Ordering matters for the log, which is the only place
    /// "why did it disappear" gets answered.
    func testToggleReasonOutranksWindowReason() {
        let decision = LiveActivityPresentationPolicy.decide(
            enabledByUser: false, inSleepWindow: true, connected: true, hasBPM: true)
        guard case .suppress(let reason) = decision else {
            return XCTFail("expected suppression, got \(decision)")
        }
        XCTAssertTrue(reason.contains("toggle"),
                      "the explicit opt-out should be reported ahead of the window; got: \(reason)")
    }

    /// A dropped live link ends the activity — `bonded` stays true across disconnects, and keying off it
    /// is what once left a frozen, fabricated HR on the Lock Screen after the strap went out of range.
    func testDisconnectSuppresses() {
        let decision = LiveActivityPresentationPolicy.decide(
            enabledByUser: true, inSleepWindow: false, connected: false, hasBPM: true)
        guard case .suppress(let reason) = decision else {
            return XCTFail("expected suppression when disconnected, got \(decision)")
        }
        XCTAssertTrue(reason.contains("not connected"), "got: \(reason)")
    }

    /// A connected strap with no sample on this tick must NOT tear the activity down — that is the
    /// flicker case. It holds instead, which is a different decision from suppression precisely so the
    /// controller can tell "nothing to push" from "take it off screen".
    func testMissingSampleHoldsRatherThanSuppresses() {
        let decision = LiveActivityPresentationPolicy.decide(
            enabledByUser: true, inSleepWindow: false, connected: true, hasBPM: false)
        guard case .holdIfShowing = decision else {
            return XCTFail("a missing sample must hold, not suppress; got \(decision)")
        }
    }

    /// But a missing sample never overrides a real teardown reason: inside the window, or disconnected,
    /// the activity still comes down rather than lingering on the last value.
    func testWindowAndDisconnectOutrankAMissingSample() {
        guard case .suppress = LiveActivityPresentationPolicy.decide(
            enabledByUser: true, inSleepWindow: true, connected: true, hasBPM: false) else {
            return XCTFail("sleep window must suppress even with no sample")
        }
        guard case .suppress = LiveActivityPresentationPolicy.decide(
            enabledByUser: true, inSleepWindow: false, connected: false, hasBPM: false) else {
            return XCTFail("a dropped link must suppress even with no sample")
        }
    }
}
