import XCTest
import WhoopProtocol
@testable import Strand

/// Guards that ONE physical double-tap logs exactly ONE action.
///
/// The 260906 strap log caught the defect precisely: the strap reported a single
/// `SENSORS: IMU double tap detected` / `UI_MANAGER: One Double Tap detected`, and the app logged two
/// cups of water — "(15 cups today)" at 21:28:13 and "(16 cups today)" at 21:28:14. The wearer reported
/// it as the gesture being "too sensitive", but the strap's IMU was right and the duplicate was ours.
///
/// The cause is structural, not a threshold: during an offload the same EVENT reaches the gesture
/// handlers through TWO paths — `handle(parsed:)` and the mid-offload carve-out
/// `dispatchLiveGestureIfFresh` (#69) — and the strap re-sends the event inside its 45 s freshness
/// window. AppModel's 1.2 s wall-clock debounce could not cover that: the two deliveries landed ~1.3 s
/// apart, and the real gap is however long an offload chunk takes, so no fixed window is safe.
///
/// These tests therefore assert the timestamp-keyed behaviour rather than any particular delay: the
/// SAME event (same `event_timestamp`) acts once no matter which path or how many paths deliver it, and
/// a genuinely NEW tap still acts. A test that only pinned "two deliveries → one action" would also pass
/// if we broke the second tap, so the distinct-timestamp case is asserted alongside it.
@MainActor
final class DoubleTapDedupTests: XCTestCase {

    /// A WHOOP 4.0 EVENT frame (type 48): `event` u8 @6, `event_timestamp` u32 LE @8.
    /// `frameFromPayload` lays [type, seq, cmd] at frame offsets 4/5/6, so the event number rides the
    /// `cmd` slot and the timestamp needs exactly ONE pad byte before it to land at @8. The offsets are
    /// verified against the real decoder below rather than assumed — `testTheFixtureDecodesAsIntended`.
    private func eventFrame(event: UInt8, ts: UInt32) -> [UInt8] {
        let t = [UInt8(ts & 0xFF), UInt8((ts >> 8) & 0xFF),
                 UInt8((ts >> 16) & 0xFF), UInt8((ts >> 24) & 0xFF)]
        return frameFromPayload([0x00] + t, type: 48, seq: 0, cmd: event)
    }

    /// The fixture is only evidence if it decodes as a real DOUBLE_TAP carrying the timestamp we meant.
    /// A frame that silently decoded with the wrong `event_timestamp` would make every dedup assertion
    /// below vacuous — the same class of mistake as the steps fixtures that fabricated an impossible row.
    func testTheFixtureDecodesAsIntended() {
        let ts: UInt32 = 1_851_827_976
        let parsed = parseFrame(eventFrame(event: 14, ts: ts), family: .whoop4)
        XCTAssertTrue(parsed.ok, "fixture frame must pass framing/CRC")
        XCTAssertEqual(parsed.typeName, "EVENT")
        XCTAssertEqual(parsed.parsed["event"]?.stringValue, "DOUBLE_TAP(14)")
        XCTAssertEqual(parsed.parsed["event_timestamp"]?.intValue, Int(ts),
                       "the dedup key is this field; if the fixture misplaces it the tests prove nothing")
    }

    private func makeRouter() -> (LiveState, FrameRouter, Box) {
        let live = LiveState()
        let router = FrameRouter(state: live)
        router.family = .whoop4
        let box = Box()
        live.onDoubleTap = { box.count += 1 }
        return (live, router, box)
    }

    final class Box { var count = 0 }

    /// The exact log scenario: one tap, delivered by the live path AND the offload carve-out.
    /// Before the fix this logged two cups.
    func testOneGestureDeliveredByBothPathsFiresOnce() {
        let (_, router, box) = makeRouter()
        let ts: UInt32 = 1_851_827_976        // the timestamp from the 260906 log's tap
        let frame = eventFrame(event: 14, ts: ts)   // 14 = DOUBLE_TAP
        router.handle(frame: frame)
        router.dispatchLiveGestureIfFresh(frame: frame, now: Int(ts))
        XCTAssertEqual(box.count, 1,
                       "one physical tap must log one cup; the live path and the mid-offload carve-out "
                       + "both deliver the same EVENT, which is how 260906 logged two cups from one tap")
    }

    /// The strap re-sends the same event inside its freshness window; a repeat is still one gesture.
    func testTheSameEventRepeatedIsStillOneGesture() {
        let (_, router, box) = makeRouter()
        let frame = eventFrame(event: 14, ts: 1_851_827_976)
        for _ in 0..<5 { router.handle(frame: frame) }
        XCTAssertEqual(box.count, 1, "a re-sent EVENT carries the same timestamp and is the same gesture")
    }

    /// The other half: a REAL second tap must still fire. Without this, deleting the callback entirely
    /// would satisfy the tests above.
    func testADistinctTapStillFires() {
        let (_, router, box) = makeRouter()
        router.handle(frame: eventFrame(event: 14, ts: 1_851_827_976))
        router.handle(frame: eventFrame(event: 14, ts: 1_851_827_990))   // 14 s later, a new tap
        XCTAssertEqual(box.count, 2, "a genuinely new tap (different event_timestamp) must still act")
    }

    /// A reconnect legitimately re-reads recent events, and per-connection state is cleared with the
    /// rest of the routing state — a stale key must not swallow the first gesture after a reconnect.
    func testAReconnectDoesNotSwallowTheNextGesture() {
        let (_, router, box) = makeRouter()
        let frame = eventFrame(event: 14, ts: 1_851_827_976)
        router.handle(frame: frame)
        router.family = .whoop4          // per-connection reset (didSet clears the routing state)
        router.handle(frame: frame)
        XCTAssertEqual(box.count, 2, "the dedup map is per connection; a reconnect must start clean")
    }

    /// Fails OPEN: a gesture whose identity we cannot establish is passed through rather than dropped.
    /// Silently swallowing a real tap is the worse failure — a double-tap has no on-screen feedback.
    func testAGestureWithNoUsableTimestampStillFires() {
        let (_, router, box) = makeRouter()
        router.handle(frame: eventFrame(event: 14, ts: 0))
        router.handle(frame: eventFrame(event: 14, ts: 0))
        XCTAssertEqual(box.count, 2, "with no usable timestamp the gesture must pass through, not be dropped")
    }
}
