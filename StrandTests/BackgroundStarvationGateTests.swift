import XCTest
@testable import Strand

/// 260929, the iOS-27 posture gate: pins the rule and the probe so an uplift that deletes either is
/// caught by a red test, not by a week of 8000-second passes on a wearer's phone. The root-cause
/// record lives on `RescoreBackgroundPolicy.backgroundStarvationFactor` and in the 18.31 notes.
final class BackgroundStarvationGateTests: XCTestCase {

    /// The rule: healthy and mildly-contended background execution proceeds; genuine starvation
    /// (the measured episodes ran ×100+) defers. Non-finite (a zero-CPU probe) must defer, never run.
    func testInlineBackgroundAllowedThreshold() {
        XCTAssertTrue(RescoreBackgroundPolicy.inlineBackgroundAllowed(canaryFactor: 1.0))
        XCTAssertTrue(RescoreBackgroundPolicy.inlineBackgroundAllowed(canaryFactor: 3.9),
                      "mild contention (a photo pass, an index) must not defer scoring")
        XCTAssertFalse(RescoreBackgroundPolicy.inlineBackgroundAllowed(canaryFactor: 4.0))
        XCTAssertFalse(RescoreBackgroundPolicy.inlineBackgroundAllowed(canaryFactor: 117.0),
                       "the measured 260929 episode — 585 s of wall for 5 s of CPU")
        XCTAssertFalse(RescoreBackgroundPolicy.inlineBackgroundAllowed(canaryFactor: .infinity))
    }

    /// The probe burns what it claims and computes the factor it defines. Loose bounds by design:
    /// a CI machine under load must not flake this, only a broken probe should fail it.
    func testCanaryMeasuresRoughlyItsTarget() {
        let r = BackgroundCPUCanary.measureSync()
        XCTAssertGreaterThanOrEqual(r.cpuMs, BackgroundCPUCanary.targetCPUMillis * 0.8,
                                    "the probe must actually burn its CPU budget")
        XCTAssertLessThan(r.cpuMs, 5_000, "and stop near it")
        XCTAssertGreaterThanOrEqual(r.factor, 0.8, "wall can never be meaningfully below CPU")
        XCTAssertEqual(BackgroundCPUCanary.Reading(cpuMs: 50, wallMs: 585_000).factor, 11_700,
                       accuracy: 1, "the 260929 signature, as the factor the gate would see")
        XCTAssertEqual(BackgroundCPUCanary.Reading(cpuMs: 0, wallMs: 10).factor, .infinity)
    }

    /// The new deferral bucket renders in the strap-log header like its siblings, so a deferred-for-
    /// starvation day is attributable on sight.
    func testCpuStarvedIsACountedDeferralCause() {
        XCTAssertEqual(RescoreStats.DeferralCause.cpuStarved.rawValue, "cpu-starved")
        XCTAssertTrue(RescoreStats.DeferralCause.allCases.contains(.cpuStarved))
    }
}
