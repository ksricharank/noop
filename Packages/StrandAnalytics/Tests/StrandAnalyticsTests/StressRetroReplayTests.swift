import XCTest
@testable import StrandAnalytics

/// `StressOnsetDetector.replayOffloaded` — the burst-retrospective path (260830): offloaded R-R is
/// replayed beat-by-beat through the SAME `evaluate` the live loop calls, so a sustained
/// non-metabolic dip found in synced data fires exactly one nudge, and re-running the same window
/// with the returned state can never re-fire (the detector's replay-safety, inherited verbatim).
final class StressRetroReplayTests: XCTestCase {

    private let config = StressOnsetDetector.Config(enabled: true, autoNudge: true,
                                                    quietHoursEnabled: false)

    /// High-variability resting beats (RMSSD ≈ 120 ms at HR ≈ 60) — the baseline diet.
    private func calmBeats(from ts: Int, count: Int) -> [(ts: Int, rrMs: Int)] {
        (0..<count).map { i in (ts: ts + i, rrMs: 1000 + (i % 2 == 0 ? 60 : -60)) }
    }

    /// Near-flat beats (RMSSD ≈ 10 ms) — a deep dip. `rrMs` sets the HR the exercise gate sees.
    private func dipBeats(from ts: Int, count: Int, aroundMs: Int = 1000) -> [(ts: Int, rrMs: Int)] {
        (0..<count).map { i in (ts: ts + i, rrMs: aroundMs + (i % 2 == 0 ? 5 : -5)) }
    }

    func testSustainedRestingDipFiresOnceAndIsReplaySafe() {
        let t0 = 1_700_000_000
        let beats = calmBeats(from: t0, count: 300) + dipBeats(from: t0 + 300, count: 240)
        let scan = StressOnsetDetector.replayOffloaded(beats: beats, sessionActive: false,
                                                       state: .initial, config: config,
                                                       tzOffsetSec: 0)
        let at = try! XCTUnwrap(scan.nudgeAtSec, "a sustained resting dip must fire")
        XCTAssertGreaterThan(at, t0 + 300, "the fire lands inside the dip, not the calm stretch")
        XCTAssertNotNil(scan.fastRMSSD)
        XCTAssertNotNil(scan.baselineRMSSD)

        // Replay-safety: the SAME window with the advanced state has nothing new to say.
        let again = StressOnsetDetector.replayOffloaded(beats: beats, sessionActive: false,
                                                        state: scan.nextState, config: config,
                                                        tzOffsetSec: 0)
        XCTAssertNil(again.nudgeAtSec, "re-scanning already-processed beats must never re-fire")
    }

    /// A dip at HR ≈ 120 is metabolic — the exercise gate (HR derived from the beats themselves)
    /// must suppress it, exactly like the live loop.
    func testOutOfBandDipIsExerciseGated() {
        let t0 = 1_700_000_000
        let beats = calmBeats(from: t0, count: 300) + dipBeats(from: t0 + 300, count: 240,
                                                               aroundMs: 500)
        let scan = StressOnsetDetector.replayOffloaded(beats: beats, sessionActive: false,
                                                       state: .initial, config: config,
                                                       tzOffsetSec: 0)
        XCTAssertNil(scan.nudgeAtSec, "HR ~120 means exercise, never 'go breathe'")
    }

    /// Quiet hours are computed at each BEAT's own historical time — a dip whose timestamps fall
    /// inside the quiet window stays suppressed even though the scan itself runs later.
    func testQuietHoursApplyAtTheBeatsOwnTime() {
        var quiet = config
        quiet.quietHoursEnabled = true
        quiet.quietStartMinutes = 0
        quiet.quietEndMinutes = 1_439   // quiet all day (UTC) — every beat is inside the window
        let t0 = 1_700_000_000
        let beats = calmBeats(from: t0, count: 300) + dipBeats(from: t0 + 300, count: 240)
        let scan = StressOnsetDetector.replayOffloaded(beats: beats, sessionActive: false,
                                                       state: .initial, config: quiet,
                                                       tzOffsetSec: 0)
        XCTAssertNil(scan.nudgeAtSec)
    }

    func testTooFewBeatsAbstains() {
        let scan = StressOnsetDetector.replayOffloaded(
            beats: calmBeats(from: 1_700_000_000, count: 5),
            sessionActive: false, state: .initial, config: config, tzOffsetSec: 0)
        XCTAssertNil(scan.nudgeAtSec)
    }
}
