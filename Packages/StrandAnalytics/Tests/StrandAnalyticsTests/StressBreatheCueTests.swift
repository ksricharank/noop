import XCTest
@testable import StrandAnalytics

/// `StressOnsetDetector.breatheCue` — the LEVEL read behind the Live Activity's `#` marker. Pinned
/// separately from the nudge's tests because the cue deliberately drops the nudge's event machinery
/// (edge, sustain, rate limit, quiet hours): its contract is "is the body in a non-metabolic HRV dip
/// right now", held for the whole dip, abstaining when it cannot judge.
final class StressBreatheCueTests: XCTestCase {

    /// R-R series with a chosen beat-to-beat swing: alternating 800±delta ms. RMSSD ≈ 2×delta·…/…
    /// — what matters here is monotonic: bigger delta, bigger RMSSD.
    private func rr(count: Int, delta: Int) -> [Int] {
        (0..<count).map { 800 + ($0 % 2 == 0 ? delta : -delta) }
    }

    private func state(baseline: Double) -> StressOnsetDetector.State {
        StressOnsetDetector.State(baselineRMSSD: baseline, wasBelow: false,
                                  lastFireAt: 0, pendingEdgeAt: 0)
    }

    /// Collapsed variability against an 80 ms baseline while resting → breathe; healthy variability
    /// against the same baseline → calm. The threshold is the nudge's own `dropRatio` — one
    /// physiology, two consumers.
    func testDipWhileRestingReadsBreathe() {
        let dipped = StressOnsetDetector.breatheCue(rrBuffer: rr(count: 70, delta: 2),
                                                    currentHR: 72, recentMotionG: nil,
                                                    state: state(baseline: 80))
        XCTAssertEqual(dipped.cue, .breathe)
        let healthy = StressOnsetDetector.breatheCue(rrBuffer: rr(count: 70, delta: 40),
                                                     currentHR: 72, recentMotionG: nil,
                                                     state: state(baseline: 80))
        XCTAssertEqual(healthy.cue, .calm)
    }

    /// The exercise gate, level-form: the same dip with HR out of the resting band, or with recent
    /// motion at the gate, is METABOLIC — calm (the heart is working, not stressed), and explicitly
    /// not "unknown": exercising must never render as "go breathe".
    func testMetabolicElevationReadsCalm() {
        let exercising = StressOnsetDetector.breatheCue(rrBuffer: rr(count: 70, delta: 2),
                                                        currentHR: 130, recentMotionG: nil,
                                                        state: state(baseline: 80))
        XCTAssertEqual(exercising.cue, .calm)
        let moving = StressOnsetDetector.breatheCue(rrBuffer: rr(count: 70, delta: 2),
                                                    currentHR: 72,
                                                    recentMotionG: StressOnsetDetector.motionGateG,
                                                    state: state(baseline: 80))
        XCTAssertEqual(moving.cue, .calm)
        let unknownHR = StressOnsetDetector.breatheCue(rrBuffer: rr(count: 70, delta: 2),
                                                       currentHR: nil, recentMotionG: nil,
                                                       state: state(baseline: 80))
        XCTAssertEqual(unknownHR.cue, .calm, "an unconfirmable resting state cannot claim stress")
    }

    /// Abstain, never guess: too few clean beats, or a baseline that only just seeded this tick
    /// (comparing the seed against itself would be meaningless).
    func testUnjudgeableMinutesAbstain() {
        let thin = StressOnsetDetector.breatheCue(rrBuffer: rr(count: 5, delta: 2),
                                                  currentHR: 72, recentMotionG: nil,
                                                  state: state(baseline: 80))
        XCTAssertEqual(thin.cue, .unknown)
        let seeding = StressOnsetDetector.breatheCue(rrBuffer: rr(count: 70, delta: 2),
                                                     currentHR: 72, recentMotionG: nil,
                                                     state: .initial)
        XCTAssertEqual(seeding.cue, .unknown)
        XCTAssertGreaterThan(seeding.nextState.baselineRMSSD, 0, "the seed itself must still bank")
    }

    /// The cue advances ONLY the shared EMA + below-state — the nudge's edge/rate-limit clocks are
    /// its own, and the cue must never consume or stamp them.
    func testCueLeavesTheNudgeClocksAlone() {
        var s = state(baseline: 80)
        s.pendingEdgeAt = 123
        s.lastFireAt = 456
        let out = StressOnsetDetector.breatheCue(rrBuffer: rr(count: 70, delta: 2),
                                                 currentHR: 72, recentMotionG: nil, state: s)
        XCTAssertEqual(out.nextState.pendingEdgeAt, 123)
        XCTAssertEqual(out.nextState.lastFireAt, 456)
        XCTAssertTrue(out.nextState.wasBelow)
        XCTAssertNotEqual(out.nextState.baselineRMSSD, 80, "the EMA must advance here — it owns it")
    }
}
