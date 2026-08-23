import XCTest
@testable import Strand

/// `LiveActivityHrPolicy` — the pure lock-aware cadence + one-minute-average behind the live-HR
/// Live Activity. Unlocked keeps the pre-existing ~2 s live cadence; locked slows to one push per
/// minute carrying a one-minute HR average (an Always-On Lock Screen repaints on every push, so the
/// live cadence while locked was ~1,800 wakes/hour of invisible fidelity). No ActivityKit or UIKit
/// runtime needed here; `LiveActivityController` is a thin shell over these predicates.
final class LiveActivityHrPolicyTests: XCTestCase {
    private typealias Policy = LiveActivityHrPolicy
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // 1. Unlocked spacing is the original strict "> 2 s" throttle — exactly 2 s is still too soon.
    // This pins that the lock-aware split did not change the live cadence.
    func testUnlockedKeepsLiveCadence() {
        XCTAssertFalse(Policy.shouldPush(locked: false, now: t0.addingTimeInterval(2.0), lastPush: t0))
        XCTAssertTrue(Policy.shouldPush(locked: false, now: t0.addingTimeInterval(2.1), lastPush: t0))
    }

    // 2. Locked spacing is a strict minute — exactly 60 s is still too soon, 61 s pushes.
    func testLockedSlowsToOnePerMinute() {
        XCTAssertFalse(Policy.shouldPush(locked: true, now: t0.addingTimeInterval(60.0), lastPush: t0))
        XCTAssertTrue(Policy.shouldPush(locked: true, now: t0.addingTimeInterval(61.0), lastPush: t0))
    }

    // 3. Unlocking re-livens promptly: a locked push 30 s ago does NOT hold the next unlocked push
    // to the minute cadence — the 2 s rule applies the moment the lock state reads unlocked.
    func testUnlockTransitionPushesPromptly() {
        XCTAssertTrue(Policy.shouldPush(locked: false, now: t0.addingTimeInterval(30), lastPush: t0))
        XCTAssertFalse(Policy.shouldPush(locked: true, now: t0.addingTimeInterval(30), lastPush: t0))
    }

    // 4. The average is the rounded mean of everything inside the window. 60 and 61 → 60.5 → 61
    // (`.rounded()` rounds half away from zero); pinning the rounding stops a truncation slip.
    func testWindowAverageRoundsMean() {
        var s: [Policy.Sample] = []
        s = Policy.appending(s, bpm: 60, at: t0)
        s = Policy.appending(s, bpm: 61, at: t0.addingTimeInterval(1))
        XCTAssertEqual(Policy.windowAverage(s, now: t0.addingTimeInterval(2)), 61)

        s = Policy.appending(s, bpm: 62, at: t0.addingTimeInterval(2))
        XCTAssertEqual(Policy.windowAverage(s, now: t0.addingTimeInterval(3)), 61)   // 183/3 = 61 exactly
    }

    // 5. Samples age out of BOTH sides: `appending` prunes the buffer, and `windowAverage` ignores
    // anything older than the window even if the buffer still holds it (the two filters must agree,
    // or a stale burst could tilt the first locked average after a long unlocked stretch).
    func testWindowDropsAgedSamples() {
        var s: [Policy.Sample] = []
        s = Policy.appending(s, bpm: 180, at: t0)                          // old spike
        s = Policy.appending(s, bpm: 60, at: t0.addingTimeInterval(70))   // 70 s later: spike aged out
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(Policy.windowAverage(s, now: t0.addingTimeInterval(70)), 60)

        // Hand the average a buffer that was never pruned: the aged spike must still be ignored.
        let unpruned = [Policy.Sample(at: t0, bpm: 180),
                        Policy.Sample(at: t0.addingTimeInterval(70), bpm: 60)]
        XCTAssertEqual(Policy.windowAverage(unpruned, now: t0.addingTimeInterval(70)), 60)
    }

    // 6. An empty window yields nil (caller falls back to the instantaneous reading), and the
    // ~1 Hz stream keeps the buffer bounded to roughly one window of entries.
    func testEmptyWindowIsNilAndBufferStaysBounded() {
        XCTAssertNil(Policy.windowAverage([], now: t0))

        var s: [Policy.Sample] = []
        for i in 0..<300 {   // 5 minutes of 1 Hz ticks
            s = Policy.appending(s, bpm: 60 + (i % 5), at: t0.addingTimeInterval(Double(i)))
        }
        XCTAssertLessThanOrEqual(s.count, Int(Policy.averagingWindow) + 1)
    }
}
