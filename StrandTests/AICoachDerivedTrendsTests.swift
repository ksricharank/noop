import XCTest
import WhoopStore
@testable import Strand

/// The two PURE context formatters behind the third coach opt-in (`includeDerivedTrends`):
/// `AICoachEngine.dayLine(_:wide:)` and `AICoachEngine.derivedTrendsBlock(days:)`.
///
/// Both are static precisely so they can be pinned without a store, a provider or a live engine — the
/// same reason `stressIndexSummary` is. What matters here is not prose but three properties that decide
/// whether the model is handed a truth or a plausible fiction: a nil field must be ABSENT rather than
/// rendered as a zero, the bimodal skin-temperature column must be labelled for what it actually holds,
/// and a roll-up with too little history must be omitted rather than stated at full confidence.
final class AICoachDerivedTrendsTests: XCTestCase {

    // MARK: - dayLine

    /// Narrow mode is the pre-existing five-column line. Pinned so the default (opt-in OFF) context
    /// cannot drift: every wearer who never touches the toggle keeps exactly this shape.
    func testNarrowLineIsUnchangedByTheWideFields() {
        let d = metric(day: "2026-08-01", recovery: 62, strain: 11.4, totalSleepMin: 431,
                       avgHrv: 48, restingHr: 54, deepMin: 88, remMin: 96, efficiency: 91,
                       disturbances: 7, avgSdnn: 62, skinTempDevC: -0.3)
        let line = AICoachEngine.dayLine(d, wide: false)
        XCTAssertEqual(line, "2026-08-01:, charge 62, effort 11.4, rest 7.2h, HRV 48ms, RHR 54bpm")
        // The wide-only columns must not leak into the narrow line. Matched on the rendered token
        // (", eff ") rather than the bare prefix, since "eff" also occurs inside the always-present
        // "effort" — a substring check there passes for the wrong reason and would hide a real leak.
        for absent in [", deep ", ", REM ", ", eff ", ", wakes ", ", SDNN ", ", skin "] {
            XCTAssertFalse(line.contains(absent), "narrow line leaked \(absent)")
        }
    }

    /// Wide mode appends the columns the coach already held but never sent.
    func testWideLineAddsTheHeldButUnsentColumns() {
        let d = metric(day: "2026-08-01", recovery: 62, strain: 11.4, totalSleepMin: 431,
                       avgHrv: 48, restingHr: 54, deepMin: 88, remMin: 96, efficiency: 91,
                       disturbances: 7, avgSdnn: 62, skinTempDevC: -0.3)
        let line = AICoachEngine.dayLine(d, wide: true)
        XCTAssertTrue(line.contains("deep 88m"), line)
        XCTAssertTrue(line.contains("REM 96m"), line)
        XCTAssertTrue(line.contains("eff 91%"), line)
        XCTAssertTrue(line.contains("wakes 7"), line)
        XCTAssertTrue(line.contains("SDNN 62ms"), line)
    }

    /// A missing field is simply absent — never "0", never an em-dash placeholder in the wide columns.
    /// This is the property that keeps a night that did not record deep sleep from reading as a night of
    /// ZERO deep sleep, which is a clinically different claim and one the model would act on.
    func testWideLineOmitsMissingFieldsRatherThanZeroingThem() {
        let d = metric(day: "2026-08-02", recovery: 55, strain: nil, totalSleepMin: 400,
                       avgHrv: nil, restingHr: nil, deepMin: nil, remMin: nil, efficiency: nil,
                       disturbances: nil, avgSdnn: nil, skinTempDevC: nil)
        let line = AICoachEngine.dayLine(d, wide: true)
        for absent in [", deep ", ", REM ", ", eff ", ", wakes ", ", SDNN ", ", skin "] {
            XCTAssertFalse(line.contains(absent), "absent field \(absent) was rendered anyway: \(line)")
        }
        XCTAssertFalse(line.contains("0m"), line)
    }

    /// `skinTempDevC` is BIMODAL — strap nights bank a deviation, CSV/Apple imports an absolute wrist °C.
    /// Emitting one fixed meaning would misreport every row of the other kind, so each value is labelled
    /// by magnitude. A small signed value is a deviation...
    func testSmallSkinTempIsLabelledAsADeviation() {
        let d = metric(day: "2026-08-03", recovery: 60, strain: nil, totalSleepMin: 420,
                       avgHrv: nil, restingHr: nil, deepMin: nil, remMin: nil, efficiency: nil,
                       disturbances: nil, avgSdnn: nil, skinTempDevC: 0.4)
        let line = AICoachEngine.dayLine(d, wide: true)
        XCTAssertTrue(line.contains("vs baseline"), line)
        XCTAssertTrue(line.contains("+0.4"), line)
    }

    /// ...and a body-temperature-magnitude value is an absolute, stated without the "vs baseline" suffix
    /// that would turn 31.2 °C into a nonsensical +31.2 delta.
    func testBodyMagnitudeSkinTempIsLabelledAsAnAbsolute() {
        let d = metric(day: "2026-08-04", recovery: 60, strain: nil, totalSleepMin: 420,
                       avgHrv: nil, restingHr: nil, deepMin: nil, remMin: nil, efficiency: nil,
                       disturbances: nil, avgSdnn: nil, skinTempDevC: 31.2)
        let line = AICoachEngine.dayLine(d, wide: true)
        XCTAssertTrue(line.contains("31.2"), line)
        XCTAssertFalse(line.contains("vs baseline"), line)
    }

    // MARK: - derivedTrendsBlock

    /// No days → no block at all, rather than a header with nothing under it.
    func testEmptyHistoryProducesNoBlock() {
        XCTAssertTrue(AICoachEngine.derivedTrendsBlock(days: []).isEmpty)
    }

    /// A thin history still yields the sleep-debt ledger and an explicit density caveat, but must NOT
    /// assert a training-load model: the engine needs a minimum contiguous window, and a fabricated
    /// chronic/acute balance off three days is exactly the confident-wrong-answer this gate prevents.
    func testThinHistoryHedgesAndOmitsTrainingLoad() {
        let days = (1...3).map { i in
            metric(day: String(format: "2026-08-%02d", i), recovery: 60, strain: 10,
                   totalSleepMin: 400, avgHrv: 50, restingHr: 55)
        }
        let block = AICoachEngine.derivedTrendsBlock(days: days)
        XCTAssertFalse(block.isEmpty)
        XCTAssertTrue(block.contains("thin history"), block)
        XCTAssertFalse(block.contains("Training load:"), block)
    }

    /// A long, steady history: the ledger reports a real shortfall against the 8h need, and the density
    /// line stops hedging. 6h nightly over 40 nights is an unambiguous debt, so this pins the DIRECTION
    /// of the ledger rather than a formatting detail.
    func testSustainedShortSleepReportsADebt() {
        let days = (1...40).map { i in
            metric(day: dayKey(i), recovery: 60, strain: 10, totalSleepMin: 360,
                   avgHrv: 50, restingHr: 55)
        }
        let block = AICoachEngine.derivedTrendsBlock(days: days)
        XCTAssertTrue(block.contains("Sleep debt:"), block)
        XCTAssertTrue(block.contains("SHORT"), block)
        XCTAssertFalse(block.contains("thin history"), block)
    }

    /// Sleeping the full need must not be reported as a debt — the opposite-direction guard on the test
    /// above, so a formatter that always printed "SHORT" could not pass both.
    func testSleepingToNeedIsNotADebt() {
        let days = (1...40).map { i in
            metric(day: dayKey(i), recovery: 60, strain: 10, totalSleepMin: 480,
                   avgHrv: 50, restingHr: 55)
        }
        let block = AICoachEngine.derivedTrendsBlock(days: days)
        XCTAssertFalse(block.contains("SHORT"), block)
    }

    /// Every emitted figure must be attributable to on-device computation — the block is prefixed as
    /// deterministic so the model does not present it as its own estimate.
    func testBlockDeclaresItselfDeterministic() {
        let days = (1...40).map { i in
            metric(day: dayKey(i), recovery: 60, strain: 10, totalSleepMin: 420,
                   avgHrv: 50, restingHr: 55)
        }
        let block = AICoachEngine.derivedTrendsBlock(days: days)
        XCTAssertTrue(block.hasPrefix("DERIVED TRENDS"), block)
        XCTAssertTrue(block.contains("deterministic"), block)
    }


    /// POSITIVE control for the training-load line: with a long contiguous history the engine becomes
    /// available and the line must actually render. Without this, the thin-history test above would pass
    /// just as happily if the load block were dead code that never emitted anything.
    func testLongHistoryEmitsTrainingLoad() {
        let days = (1...70).map { i -> DailyMetric in
            let m = i <= 31 ? 8 : (i <= 61 ? 9 : 10)
            let d = i <= 31 ? i : (i <= 61 ? i - 31 : i - 61)
            return metric(day: String(format: "2026-%02d-%02d", m, d), recovery: 60, strain: 12,
                          totalSleepMin: 420, avgHrv: 50, restingHr: 55)
        }
        let block = AICoachEngine.derivedTrendsBlock(days: days)
        XCTAssertTrue(block.contains("Training load:"), block)
        XCTAssertTrue(block.contains("chronic"), block)
    }

    // MARK: - Helpers

    /// Day keys across a 40-night span, rolling into September so the sequence stays strictly ordered
    /// (the ledger and the load engine both read them as ordered day keys).
    private func dayKey(_ i: Int) -> String {
        i <= 31 ? String(format: "2026-08-%02d", i) : String(format: "2026-09-%02d", i - 31)
    }

    private func metric(day: String, recovery: Double?, strain: Double?, totalSleepMin: Double?,
                        avgHrv: Double?, restingHr: Int?, deepMin: Double? = nil,
                        remMin: Double? = nil, efficiency: Double? = nil, disturbances: Int? = nil,
                        avgSdnn: Double? = nil, skinTempDevC: Double? = nil) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: totalSleepMin, efficiency: efficiency, deepMin: deepMin,
                    remMin: remMin, lightMin: nil, disturbances: disturbances, restingHr: restingHr,
                    avgHrv: avgHrv, recovery: recovery, strain: strain, exerciseCount: nil,
                    skinTempDevC: skinTempDevC, avgSdnn: avgSdnn)
    }
}
