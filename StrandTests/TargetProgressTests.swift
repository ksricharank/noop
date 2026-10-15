import XCTest
@testable import Strand

/// The Targets widget draws a progress track per metric (260919). These pin the fractions behind
/// them, because an arc that is subtly wrong is far worse than no arc: it is a confident picture of
/// a day that did not happen.
final class TargetProgressTests: XCTestCase {

    private func snap(steps: Int? = nil, stepsTarget: Int? = nil,
                      kcal: Int? = nil, kcalTarget: Int? = nil,
                      waterHalfCups: Int? = nil, waterTargetCups: Int? = nil,
                      effortDisplay: String? = nil, effortTargetDisplay: String? = nil) -> WidgetSnapshot {
        WidgetSnapshot(recovery: nil, bpm: nil, batteryPct: nil, bonded: true, updated: Date(),
                       effortDisplay: effortDisplay, effortTargetDisplay: effortTargetDisplay,
                       kcal: kcal, kcalTarget: kcalTarget,
                       steps: steps, stepsTarget: stepsTarget,
                       waterHalfCups: waterHalfCups, waterTargetCups: waterTargetCups)
    }

    func testAFractionIsTheHonestRatio() {
        XCTAssertEqual(snap(steps: 4_475, stepsTarget: 8_950).stepsFraction ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(snap(kcal: 1_125, kcalTarget: 2_250).calFraction ?? 0, 0.5, accuracy: 0.0001)
    }

    /// Clamped at 1: an arc cannot draw past full, and a 200%-of-target day must not wrap around to
    /// look like the day had barely started.
    func testOverTargetSaturatesRatherThanWrapping() {
        XCTAssertEqual(snap(steps: 18_000, stepsTarget: 8_950).stepsFraction ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(snap(kcal: 9_000, kcalTarget: 2_250).calFraction ?? 0, 1.0, accuracy: 0.0001)
    }

    /// The units trap: water counts HALF-cups against a target in WHOLE cups. Comparing them
    /// directly would report 15 half-cups of a 19-cup target as 79% when it is 39%.
    func testWaterComparesHalfCupsAgainstDoubledCups() {
        XCTAssertEqual(snap(waterHalfCups: 15, waterTargetCups: 19).waterFraction ?? 0,
                       15.0 / 38.0, accuracy: 0.0001)
        // The maintainer's own screenshot: "4/21" is 8 half-cups against 21 cups.
        XCTAssertEqual(snap(waterHalfCups: 8, waterTargetCups: 21).waterFraction ?? 0,
                       8.0 / 42.0, accuracy: 0.0001)
    }

    /// nil, not 0, when a target is absent or zero — the widget draws an EMPTY track for nil and a
    /// zero-length fill for 0, and "not tracked" must not look like "none done".
    func testAnAbsentOrZeroTargetHasNoFraction() {
        XCTAssertNil(snap(steps: 3_000, stepsTarget: nil).stepsFraction)
        XCTAssertNil(snap(steps: 3_000, stepsTarget: 0).stepsFraction)
        XCTAssertNil(snap(waterHalfCups: 4, waterTargetCups: nil).waterFraction)
        XCTAssertNil(snap().calFraction)
    }

    /// A fresh day is 0, which is a real reading and distinct from nil.
    func testAFreshDayIsZeroNotAbsent() {
        XCTAssertEqual(snap(steps: 0, stepsTarget: 8_950).stepsFraction, 0)
        XCTAssertNotNil(snap(steps: 0, stepsTarget: 8_950).stepsFraction)
    }

    /// Effort arrives only as pre-formatted strings (the scale preference lives in the app), so its
    /// fraction is parsed back out. A pair that does not parse yields nil rather than a guess.
    func testEffortParsesItsDisplayStringsAndRefusesNonsense() {
        XCTAssertEqual(snap(effortDisplay: "10.8", effortTargetDisplay: "21.6").effortFraction ?? 0,
                       0.5, accuracy: 0.0001)
        XCTAssertEqual(snap(effortDisplay: "0", effortTargetDisplay: "54").effortFraction, 0)
        XCTAssertNil(snap(effortDisplay: "--", effortTargetDisplay: "54").effortFraction)
        XCTAssertNil(snap(effortDisplay: "10", effortTargetDisplay: nil).effortFraction)
        XCTAssertNil(snap(effortDisplay: "10", effortTargetDisplay: "0").effortFraction)
    }
}
