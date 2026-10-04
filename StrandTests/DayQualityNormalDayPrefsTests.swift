import XCTest
@testable import Strand
@testable import StrandAnalytics

/// The normal-day anchor as a stored preference (260909).
///
/// Reported: "I don't see the customization params for what a normal day looks like", and separately
/// that a re-scored day was not reaching the trend below it. Both traced to the same place — the
/// anchor was a code constant the prefs layer knew nothing about, so it could be neither tuned nor
/// included in the fingerprint that decides when history re-scores.
@MainActor
final class DayQualityNormalDayPrefsTests: XCTestCase {

    private let keys = ["dayquality.normal.steps", "dayquality.normal.kcal",
                        "dayquality.normal.effort", "dayquality.normal.waterCups",
                        "dayquality.normal.sleepMin"]

    override func setUp() {
        super.setUp()
        for k in keys { UserDefaults.standard.removeObject(forKey: k) }
    }
    override func tearDown() {
        for k in keys { UserDefaults.standard.removeObject(forKey: k) }
        super.tearDown()
    }

    /// Unset must mean "the shipped default", read from the scorer rather than restated — the trap
    /// plain `@AppStorage` falls into by reading an unset key as 0, which would put the zero point at
    /// a day with no steps, no calories and no sleep.
    func testUnsetFallsBackToTheShippedAnchor() {
        XCTAssertEqual(DayQualityPrefs.normalDay, DayQualityScore.NormalDay.default)
        XCTAssertEqual(DayQualityPrefs.normalSteps, Int(DayQualityScore.NormalDay.default.steps))
        XCTAssertFalse(DayQualityPrefs.normalDayIsCustomised)
    }

    func testAStoredAnchorIsReadBack() {
        DayQualityPrefs.setNormalSteps(6000)
        DayQualityPrefs.setNormalSleepMin(450)
        XCTAssertEqual(DayQualityPrefs.normalSteps, 6000)
        XCTAssertEqual(DayQualityPrefs.normalDay.steps, 6000)
        XCTAssertEqual(DayQualityPrefs.normalDay.sleepMin, 450)
        XCTAssertTrue(DayQualityPrefs.normalDayIsCustomised)
    }

    /// Clamped on READ, so a corrupt or hand-edited preference cannot produce a nonsense zero point.
    func testValuesAreClampedOnRead() {
        UserDefaults.standard.set(-5000, forKey: "dayquality.normal.steps")
        UserDefaults.standard.set(999_999, forKey: "dayquality.normal.kcal")
        XCTAssertEqual(DayQualityPrefs.normalSteps, 0)
        XCTAssertEqual(DayQualityPrefs.normalKcal, 6000)
    }

    func testResetRestoresTheShippedAnchor() {
        DayQualityPrefs.setNormalSteps(9999)
        XCTAssertTrue(DayQualityPrefs.normalDayIsCustomised)
        DayQualityPrefs.resetNormalDay()
        XCTAssertEqual(DayQualityPrefs.normalDay, DayQualityScore.NormalDay.default)
    }

    /// THE bug behind the stale trend: `DayQualityPrefs.config` built the scorer's config and never
    /// applied the anchor, so the card (which reads the anchor directly) and the stored series
    /// computed different numbers for the same day.
    func testConfigCarriesTheAnchorThroughToTheScorer() {
        DayQualityPrefs.setNormalSteps(7000)
        XCTAssertEqual(DayQualityPrefs.config.normalDay.steps, 7000,
                       "every scorer input must come through this one builder, or two surfaces "
                       + "compute different scores from the same day")
    }

    /// And the anchor must be in the FINGERPRINT, or tuning it changes future scores while leaving
    /// history on the old zero — a trend mixing two definitions of zero with nothing to say so.
    func testTheAnchorIsPartOfTheConfigFingerprint() {
        let before = DayQualityPrefs.configFingerprint
        DayQualityPrefs.setNormalSteps(5500)
        XCTAssertNotEqual(DayQualityPrefs.configFingerprint, before,
                          "moving the zero point must invalidate the latch and re-score history")
        XCTAssertTrue(DayQualityPrefs.configChanged)
    }

    /// A stored preference whose MEANING changed needs a new key, not a migration guess. Build 332
    /// wrote 125 to the old overshoot key under the old semantics; read as the new overshoot MULTIPLE
    /// that silently caps the scale's ceiling at 77 instead of 100.
    func testTheOvershootKeyIsNamespacedAwayFromTheRetiredMeaning() {
        XCTAssertEqual(DayQualityPrefs.K.overshootCapPct, "dayquality.v3.overshootCapPct")
        // A leftover value under the OLD key must not be picked up.
        UserDefaults.standard.set(125, forKey: "dayquality.overshootCapPct")
        defer { UserDefaults.standard.removeObject(forKey: "dayquality.overshootCapPct") }
        XCTAssertEqual(DayQualityPrefs.overshootCapPct,
                       Int((DayQualityScore.Config.default.overshootCap * 100).rounded()),
                       "the retired key must be ignored, not reinterpreted")
    }

    /// A tuned anchor must actually move the published score — the end-to-end property all of the
    /// above exists to deliver.
    func testATunedAnchorMovesThePublishedScore() throws {
        let input = DayQualityScore.DayInput(
            steps: 4000, stepsTarget: 9550, kcal: 1600, kcalTarget: 2250,
            effort: 8, effortTarget: 54, waterCups: 8, waterTargetCups: 21,
            sleepMin: 420, sleepNeedMin: 480, hrv: 30, hrvBaseline: 30,
            restingHr: 64, restingHrBaseline: 64)
        let atDefault = try XCTUnwrap(DayQualityScore.score(input, config: DayQualityPrefs.config))
        XCTAssertEqual(atDefault.total, 0, "this IS the shipped normal day")

        DayQualityPrefs.setNormalSteps(2000)   // "a normal day for me is quieter than that"
        let tuned = try XCTUnwrap(DayQualityScore.score(input, config: DayQualityPrefs.config))
        XCTAssertGreaterThan(tuned.total, 0,
                             "4000 steps is now ABOVE this wearer's normal day, so it must earn points")
    }
}
