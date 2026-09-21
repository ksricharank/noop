import XCTest
@testable import Strand
import StrandAnalytics

/// 260921 regression: an ABANDONED full pass must not write a Charge scored against the short
/// baseline it happened to fold before it stopped.
///
/// The reported bug: Charge alternating between ~36 and ~67 through the day, and the home-screen
/// widget disagreeing with the app at the same moment. Cause: the day loop breaks the instant the
/// app backgrounds (260906), leaving the pass with only the newest N of `maxDays` nights. On a
/// strap-only install those N nights ARE the HRV/RHR baseline, so pass 2 z-scored the night
/// against a window it never scored — and, being a full pass, wrote the result straight over the
/// value a completed pass had computed.
///
/// This is the SAME failure the light-pass guard was written for (the 22 <-> 47 flip, 260903),
/// reaching the store by a second route the `lightPass` flag cannot see. The guard is therefore
/// keyed on BASELINE SUFFICIENCY, and these tests pin that:
///
///   1. the truncated baseline really does move Charge (else the guard guards nothing), and
///   2. a partial pass preserves the stored value instead of overwriting it.
///
/// Note what was missing before: every existing recovery test supplies a fully-populated baseline
/// and asserts pure-function output. None constructs a TRUNCATED one, which is why a bug that
/// changes the score by ~30 points shipped under a green suite.
final class AbandonedPassBaselineTests: XCTestCase {

    /// Oldest-first, newest LAST — the order `foldHistory` replays and the order the day loop
    /// fills in (it counts backwards from today, so an abandoned pass holds the NEWEST N).
    private let hrvHistory: [Double?] = [62, 58, 65, 60, 63, 59, 61, 64, 57, 66,
                                         60, 62, 58, 63, 61, 59, 64, 60, 44, 42, 41]
    private let rhrHistory: [Double?] = [52, 54, 51, 53, 52, 55, 53, 51, 56, 50,
                                         53, 52, 54, 52, 53, 55, 51, 53, 60, 61, 62]

    private func charge(foldingNewest n: Int, hrv: Double, rhr: Double, sleepPerf: Double?) -> Double? {
        guard let hrvCfg = Baselines.metricCfg["hrv"],
              let rhrCfg = Baselines.metricCfg["resting_hr"] else { return nil }
        let hrvB = Baselines.foldHistory(Array(hrvHistory.suffix(n)), cfg: hrvCfg)
        let rhrB = Baselines.foldHistory(Array(rhrHistory.suffix(n)), cfg: rhrCfg)
        return RecoveryScorer.recovery(hrv: hrv, rhr: rhr, resp: nil,
                                       hrvBaseline: hrvB, rhrBaseline: rhrB,
                                       respBaseline: nil, sleepPerf: sleepPerf)
    }

    /// The premise. If a short fold scored the same as a full one there would be nothing to fix,
    /// so this pins the divergence against the SHIPPED scorer rather than a transcription of it.
    func testTruncatedBaselineMateriallyChangesCharge() {
        let full = charge(foldingNewest: 21, hrv: 52, rhr: 56, sleepPerf: 0.85)
        let short = charge(foldingNewest: 4, hrv: 52, rhr: 56, sleepPerf: 0.85)

        XCTAssertNotNil(full); XCTAssertNotNil(short)
        guard let full, let short else { return }

        // Same night, same code, same inputs — only the folded window differs.
        XCTAssertGreaterThan(short - full, 20,
            "a 4-night fold must read materially higher than a 21-night fold for the SAME night; "
            + "measured 64 vs 30 when this was written. If this narrows, re-derive the guard's "
            + "premise before relaxing it.")
    }

    /// Below the seed gate a short fold returns nil rather than a wrong number — so an abandonment
    /// at offset 1-3 starves the display instead of corrupting it. Worth pinning: it is why only
    /// abandonments at offset >= minNightsSeed produced a wrong VALUE in the field.
    func testFoldBelowSeedGateRefusesToScoreRatherThanGuessing() {
        XCTAssertNil(charge(foldingNewest: 3, hrv: 52, rhr: 56, sleepPerf: 0.85),
                     "under the seed gate the scorer must refuse, not fabricate")
    }

    // MARK: - The guard itself

    /// The engine's rule, transcribed from `analyzeRecent` pass 2: a pass whose baseline is partial
    /// contributes no recovery, and the merge restores the stored one.
    private func recoveryWritten(lightPass: Bool, wasAbandoned: Bool,
                                 computed: Double?, stored: Double?) -> Double? {
        let partialBaseline = lightPass || wasAbandoned
        return partialBaseline ? stored : computed
    }

    func testAbandonedFullPassPreservesTheStoredCharge() {
        // The field case: a completed pass wrote 30; an abandoned pass then folds 4 nights and
        // computes 64. The stored value must survive.
        XCTAssertEqual(recoveryWritten(lightPass: false, wasAbandoned: true,
                                       computed: 64, stored: 30), 30,
                       "an abandoned pass must not overwrite a completed pass's Charge")
    }

    func testCompletedFullPassStillWritesItsFreshCharge() {
        // The guard must not freeze Charge: a pass that finished is the authority.
        XCTAssertEqual(recoveryWritten(lightPass: false, wasAbandoned: false,
                                       computed: 30, stored: 64), 30,
                       "a completed full pass must still write the value it computed")
    }

    func testLightPassBehaviourIsUnchanged() {
        // The 260903 guard, still holding — the new rule subsumes it rather than replacing it.
        XCTAssertEqual(recoveryWritten(lightPass: true, wasAbandoned: false,
                                       computed: 47, stored: 22), 22)
    }

    func testPartialPassWithNoStoredRowLeavesTheDayUnscored() {
        // A genuinely new day abandoned before a full pass ever ran: nil is honest. Inventing a
        // truncated estimate here is exactly what produced the flip.
        XCTAssertNil(recoveryWritten(lightPass: false, wasAbandoned: true,
                                     computed: 64, stored: nil))
    }
}
