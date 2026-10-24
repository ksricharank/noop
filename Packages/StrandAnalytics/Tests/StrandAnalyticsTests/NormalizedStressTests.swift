import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// NSS (`NormalizedStress`, 261024). Synthetic, so it pins the arithmetic rather than validating the
/// signal; the validation the type doc asks for is on-device, against known moments. What these do
/// insist on, per the derived-signal rule: the score TRACKS a varying input — several injected excess
/// heart rates map to several distinct, ordered scores — and movement is EXPLAINED rather than read as
/// stress (a usual walking heart rate scores the same 50 as a usual still one).
final class NormalizedStressTests: XCTestCase {

    // MARK: - Fixtures

    /// A 5-minute window built directly (no streams), for model / score tests.
    private func w(_ end: Int, _ pace: NormalizedStress.Pace, hr: Double,
                   si: Double? = nil, rmssd: Double? = nil) -> NormalizedStress.Window {
        .init(endTs: end, pace: pace, hr: hr, lnSI: si, lnRMSSD: rmssd)
    }

    /// History: `n` windows per pace, HR spread evenly ±4 around `center` (so median = center and the
    /// robust SD is known).
    private func history(_ pace: NormalizedStress.Pace, center: Double, n: Int = 21) -> [NormalizedStress.Window] {
        (0..<n).map { i in w(i * 300, pace, hr: center + Double(i - n / 2) * (8.0 / Double(n - 1))) }
    }

    // MARK: - Pace

    func testPaceFollowsTicksPerMinuteAndMotion() {
        func steps(perMin: Int) -> [StepSample] {
            // One sample a second over 5 minutes; the counter climbs `perMin` per minute, walking class.
            (0...300).map { s in StepSample(ts: s, counter: (perMin * s) / 60, activityClass: 1) }
        }
        XCTAssertEqual(NormalizedStress.pace(steps: steps(perMin: 0), activity: []), .still)
        XCTAssertEqual(NormalizedStress.pace(steps: steps(perMin: 20), activity: []), .light)
        XCTAssertEqual(NormalizedStress.pace(steps: steps(perMin: 70), activity: []), .walk)
        XCTAssertEqual(NormalizedStress.pace(steps: steps(perMin: 110), activity: []), .brisk)
        XCTAssertEqual(NormalizedStress.pace(steps: steps(perMin: 160), activity: []), .run)
        let moving = (0..<100).map { WorkoutDetector.ActivityPoint(ts: $0, intensity: $0 < 40 ? 0.5 : 0.05) }
        XCTAssertEqual(NormalizedStress.pace(steps: [], activity: moving), .movingNoSteps)
        let still = (0..<100).map { WorkoutDetector.ActivityPoint(ts: $0, intensity: 0.05) }
        XCTAssertEqual(NormalizedStress.pace(steps: [], activity: still), .still)
    }

    // MARK: - Model

    func testTheModelIsMedianAndRobustSpreadPerPace() {
        let model = NormalizedStress.buildModel(history(.still, center: 62) + history(.walk, center: 98),
                                                days: 14)
        let still = model.baseline(for: .still)!
        XCTAssertEqual(still.hr, 62, accuracy: 1e-9)
        XCTAssertEqual(model.baseline(for: .walk)!.hr, 98, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(still.sdHR, NormalizedStress.minSdHR)
        XCTAssertNil(model.baseline(for: .brisk), "a pace with no history is not modelled")
        XCTAssertNil(still.lnSI, "no SI history, no SI term")
    }

    func testTooLittleHistoryLeavesAPaceUnmodelled() {
        let model = NormalizedStress.buildModel(history(.still, center: 62, n: NormalizedStress.minWindowsPerPace - 1),
                                                days: 2)
        XCTAssertNil(model.baseline(for: .still))
        XCTAssertNil(NormalizedStress.score(w(0, .still, hr: 80), model: model))
    }

    // MARK: - Score: tracks the input, and movement is explained

    func testUsualHeartRateScoresFiftyWhetherStillOrWalking() {
        let model = NormalizedStress.buildModel(history(.still, center: 62) + history(.walk, center: 98),
                                                days: 14)
        XCTAssertEqual(NormalizedStress.score(w(0, .still, hr: 62), model: model)!.raw, 50, accuracy: 1e-9)
        // A walking heart rate of 98 would be "36 above resting" to a still-only rule; here it is usual.
        XCTAssertEqual(NormalizedStress.score(w(0, .walk, hr: 98), model: model)!.raw, 50, accuracy: 1e-9)
    }

    func testSeveralInjectedExcessesGiveSeveralOrderedScores() {
        let model = NormalizedStress.buildModel(history(.still, center: 62) + history(.walk, center: 98),
                                                days: 14)
        for pace in [NormalizedStress.Pace.still, .walk] {
            let b = model.baseline(for: pace)!
            // HR-only windows: raw = 50 + 15 × zHR exactly (the weight renormalises to HR alone).
            let scores = [0.0, 1.0, 2.0, -1.0].map { k in
                NormalizedStress.score(w(0, pace, hr: b.hr + k * b.sdHR), model: model)!.raw
            }
            XCTAssertEqual(scores[0], 50, accuracy: 1e-9)
            XCTAssertEqual(scores[1], 65, accuracy: 1e-9)
            XCTAssertEqual(scores[2], 80, accuracy: 1e-9)
            XCTAssertEqual(scores[3], 35, accuracy: 1e-9)
        }
    }

    func testHRVTermsUseTheSpecWeightsAndDirections() {
        var hist: [NormalizedStress.Window] = []
        for i in 0..<21 {
            let d = Double(i - 10) / 10   // −1 … +1
            hist.append(w(i * 300, .still, hr: 62 + 4 * d, si: 4 + 0.2 * d, rmssd: 3.5 + 0.2 * d))
        }
        let model = NormalizedStress.buildModel(hist, days: 14)
        let b = model.baseline(for: .still)!
        // +1 SD on every term in the stressed direction: SI UP, RMSSD DOWN.
        let s = NormalizedStress.score(
            w(0, .still, hr: b.hr + b.sdHR, si: b.lnSI! + b.sdSI!, rmssd: b.lnRMSSD! - b.sdRMSSD!), model: model)!
        XCTAssertEqual(s.zHR, 1, accuracy: 1e-9)
        XCTAssertEqual(s.zSI!, 1, accuracy: 1e-9)
        XCTAssertEqual(s.zRMSSD!, 1, accuracy: 1e-9)
        XCTAssertEqual(s.raw, 65, accuracy: 1e-9)
        // Only HRV lower than usual (heart rate usual): 50 + 15 × 0.25 / 1.0.
        let hrvOnly = NormalizedStress.score(
            w(0, .still, hr: b.hr, si: b.lnSI!, rmssd: b.lnRMSSD! - b.sdRMSSD!), model: model)!
        XCTAssertEqual(hrvOnly.raw, 50 + 15 * 0.25, accuracy: 1e-9)
    }

    func testRunningIsNotScoredAndArtifactsAreClamped() {
        let model = NormalizedStress.buildModel(history(.still, center: 62), days: 14)
        XCTAssertNil(NormalizedStress.score(w(0, .run, hr: 170), model: model))
        let wild = NormalizedStress.score(w(0, .still, hr: 200), model: model)!
        XCTAssertEqual(wild.zHR, NormalizedStress.zClamp)
        XCTAssertEqual(wild.raw, 100, "50 + 15 × 4 clamps at the top of the scale")
    }

    // MARK: - Smoothing and episodes

    func testTheEMASmoothsAndRestartsAfterAGap() {
        let model = NormalizedStress.buildModel(history(.still, center: 62), days: 14)
        let b = model.baseline(for: .still)!
        let windows = [w(1_000, .still, hr: b.hr), w(1_060, .still, hr: b.hr + 2 * b.sdHR),
                       w(1_060 + 3_600, .still, hr: b.hr + 2 * b.sdHR)]
        let r = NormalizedStress.readings(windows, model: model)
        XCTAssertEqual(r[0].nss, 50, accuracy: 1e-9)
        XCTAssertEqual(r[1].nss, 0.2 * 80 + 0.8 * 50, accuracy: 1e-9, "one step towards the jump")
        XCTAssertEqual(r[2].nss, 80, accuracy: 1e-9, "an hour's gap restarts the average")
    }

    func testALongEnoughHighStretchIsAnEpisodeAndAShortOneIsNot() {
        func readings(_ values: [Double], from start: Int) -> [NormalizedStress.Reading] {
            values.enumerated().map { i, v in
                .init(ts: start + i * 60, nss: v, raw: v, pace: .still, hr: 70, hrPred: 62,
                      zHR: 1, zSI: nil, zRMSSD: nil)
            }
        }
        let long = readings([50] + Array(repeating: 75, count: 6) + [82] + Array(repeating: 72, count: 4) + [55],
                            from: 10_000)
        let e = NormalizedStress.lastHighEpisode(long)!
        XCTAssertEqual(e.peak.nss, 82)
        XCTAssertEqual(e.endTs - e.startTs, 11 * 60)
        XCTAssertNil(NormalizedStress.lastHighEpisode(readings([50] + Array(repeating: 75, count: 8) + [50],
                                                               from: 10_000)), "8 minutes is not 10")
    }

    // MARK: - From streams

    /// End to end on synthetic streams: still at 62 bpm, walking (70 ticks/min) at 98 bpm. The model
    /// learns both; a usual walk then scores ~50 and a walk 12 bpm hotter scores clearly higher.
    func testStreamsToWindowsToAScoreThatExplainsTheWalk() {
        func day(_ dayStart: Int, walkHR: Int) -> (hr: [HRSample], steps: [StepSample]) {
            var hr: [HRSample] = []
            var steps: [StepSample] = []
            var counter = 0
            for s in 0..<7_200 {   // two hours: still, then walking
                let walking = s >= 3_600
                hr.append(HRSample(ts: dayStart + s, bpm: walking ? walkHR + (s % 3) - 1 : 62 + (s % 3) - 1))
                // A step sample every 6 s (the plausibility gate allows 4 ticks a second), 7 ticks each
                // while walking: 70 ticks per minute.
                guard s % 6 == 0 else { continue }
                if walking { counter += 7 }
                steps.append(StepSample(ts: dayStart + s, counter: counter & 0xFFFF,
                                        activityClass: walking ? 1 : 0))
            }
            return (hr, steps)
        }
        var history: [NormalizedStress.Window] = []
        for d in 0..<3 {
            let streams = day(d * 86_400, walkHR: 98)
            history += NormalizedStress.windows(from: d * 86_400, to: d * 86_400 + 7_200, stepSeconds: 300,
                                                hr: streams.hr, rr: [], steps: streams.steps, gravity: [])
        }
        XCTAssertTrue(history.contains { $0.pace == .walk } && history.contains { $0.pace == .still })
        let model = NormalizedStress.buildModel(history, days: 3)
        XCTAssertEqual(model.baseline(for: .walk)!.hr, 98, accuracy: 1.5)
        let today = 10 * 86_400
        let usual = day(today, walkHR: 98), hot = day(today, walkHR: 110)
        let usualWalk = NormalizedStress.windows(from: today + 5_400, to: today + 5_700, stepSeconds: 300,
                                                 hr: usual.hr, rr: [], steps: usual.steps, gravity: [])
        let hotWalk = NormalizedStress.windows(from: today + 5_400, to: today + 5_700, stepSeconds: 300,
                                               hr: hot.hr, rr: [], steps: hot.steps, gravity: [])
        let usualScore = NormalizedStress.score(usualWalk[0], model: model)!.raw
        let hotScore = NormalizedStress.score(hotWalk[0], model: model)!.raw
        XCTAssertEqual(usualWalk[0].pace, .walk)
        XCTAssertEqual(usualScore, 50, accuracy: 8)
        XCTAssertGreaterThan(hotScore, usualScore + 20)
    }
}
