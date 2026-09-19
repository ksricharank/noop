import XCTest
@testable import Strand
import WhoopProtocol

/// The "last few hours" context (260919). The Today summary was reading as "a plain recap of the
/// targets I need to hit" — and the cause was upstream of the prompt: a right-now HR block had been
/// retired in 260830, so the context held day-lines and targets and nothing about the present. A
/// model asked for current state from that can only restate the targets.
///
/// These pin the sedentary read, which is the one claim in that block that is derived rather than
/// reported, and therefore the one that can be wrong.
final class RecentStateBlockTests: XCTestCase {

    private func samples(_ bpms: [(ts: Int, bpm: Int)]) -> [HRSample] {
        bpms.map { HRSample(ts: $0.ts, bpm: $0.bpm) }
    }

    /// A recent rise means NOT sedentary — nil, so the block says nothing rather than something
    /// false. Under 20 minutes is not a stretch worth naming.
    func testARecentRiseIsNotASedentaryStretch() {
        let now = 10_000
        var pts: [(ts: Int, bpm: Int)] = (0..<20).map { (now - 3600 + $0 * 60, 60) }
        pts.append((now - 300, 95))   // five minutes ago, well above the floor
        XCTAssertNil(AICoachEngine.minutesSinceLastActive(samples: samples(pts), now: now))
    }

    /// A long quiet stretch after a rise reports the gap since that rise.
    func testALongQuietStretchReportsTheGap() {
        let now = 10_000
        var pts: [(ts: Int, bpm: Int)] = [(now - 7200, 95)]   // active two hours ago
        pts += (0..<30).map { (now - 6000 + $0 * 60, 58) }    // quiet since
        let mins = AICoachEngine.minutesSinceLastActive(samples: samples(pts), now: now)
        XCTAssertEqual(mins, 120)
    }

    /// A window that NEVER rises reports the whole window rather than nil. "You have not moved at
    /// all in six hours" is the most actionable thing this block can say, and returning nil would
    /// suppress exactly that.
    func testAWindowThatNeverRisesReportsTheWholeWindow() {
        let now = 10_000
        let pts: [(ts: Int, bpm: Int)] = (0..<40).map { (now - 7200 + $0 * 60, 61) }
        let mins = AICoachEngine.minutesSinceLastActive(samples: samples(pts), now: now)
        XCTAssertEqual(mins, 120, "should report back to the earliest sample in the window")
    }

    /// The threshold is relative to THIS window's floor, not a fixed bpm: a fixed one would call a
    /// resting 70 bpm "active" for one person and never fire for another.
    func testTheThresholdIsRelativeToTheWindowsOwnFloor() {
        let now = 10_000
        // A high-resting wearer: floor 82, so 95 is only +13 and must NOT count as active.
        var high: [(ts: Int, bpm: Int)] = (0..<20).map { (now - 3600 + $0 * 60, 82) }
        high.append((now - 600, 95))
        XCTAssertNotNil(AICoachEngine.minutesSinceLastActive(samples: samples(high), now: now),
                        "+13 over this window's floor is not a sustained rise")

        // A low-resting wearer: floor 50, so 95 is +45 and clearly active.
        var low: [(ts: Int, bpm: Int)] = (0..<20).map { (now - 3600 + $0 * 60, 50) }
        low.append((now - 600, 95))
        XCTAssertNil(AICoachEngine.minutesSinceLastActive(samples: samples(low), now: now),
                     "+45 over this window's floor is a rise, so the wearer is not sedentary")
    }

    /// Too little data says nothing. A sedentary claim from three samples would be a guess wearing
    /// the clothes of a measurement.
    func testTooFewSamplesSaysNothing() {
        let now = 10_000
        let pts: [(ts: Int, bpm: Int)] = [(now - 600, 60), (now - 300, 61)]
        XCTAssertNil(AICoachEngine.minutesSinceLastActive(samples: samples(pts), now: now))
    }
}
