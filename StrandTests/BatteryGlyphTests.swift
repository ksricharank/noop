import XCTest
#if canImport(AppKit)
import AppKit
#endif
@testable import Strand

/// The widgets drew a hardcoded `battery.50` beside a live percentage (reported 260919): the number
/// moved on every sync and the glyph never did, at 8% exactly as at 100%. The banding existed — in
/// `TodayView` — but was not reachable from the widget extension, which shares `StrandiOSShared` and
/// not `Strand`. These pin the shared banding so the two surfaces cannot drift apart again.
final class BatteryGlyphTests: XCTestCase {

    /// The reported bug, stated directly: a full strap and a flat one must not wear the same glyph.
    func testTheGlyphActuallyChangesWithTheLevel() {
        let glyphs = [0, 20, 50, 70, 100].map { BatteryGlyph.symbol(forPercent: $0) }
        XCTAssertEqual(Set(glyphs).count, glyphs.count,
                       "every band must render a distinct glyph — \(glyphs)")
    }

    /// Each band, at a value inside it.
    func testEachBand() {
        XCTAssertEqual(BatteryGlyph.symbol(forPercent: 0), "battery.0")
        XCTAssertEqual(BatteryGlyph.symbol(forPercent: 25), "battery.25")
        XCTAssertEqual(BatteryGlyph.symbol(forPercent: 50), "battery.50")
        XCTAssertEqual(BatteryGlyph.symbol(forPercent: 70), "battery.75")
        XCTAssertEqual(BatteryGlyph.symbol(forPercent: 100), "battery.100")
    }

    /// The boundaries, stated rather than inherited: a band edge is where an off-by-one hides.
    func testTheBandBoundaries() {
        XCTAssertEqual(BatteryGlyph.symbol(forPercent: 12), "battery.0")
        XCTAssertEqual(BatteryGlyph.symbol(forPercent: 13), "battery.25")
        XCTAssertEqual(BatteryGlyph.symbol(forPercent: 37), "battery.25")
        XCTAssertEqual(BatteryGlyph.symbol(forPercent: 38), "battery.50")
        XCTAssertEqual(BatteryGlyph.symbol(forPercent: 62), "battery.50")
        XCTAssertEqual(BatteryGlyph.symbol(forPercent: 63), "battery.75")
        XCTAssertEqual(BatteryGlyph.symbol(forPercent: 87), "battery.75")
        XCTAssertEqual(BatteryGlyph.symbol(forPercent: 88), "battery.100")
    }

    /// Charging outranks the level — a strap on the charger reads as charging at any percentage.
    func testChargingOutranksTheLevel() {
        XCTAssertEqual(BatteryGlyph.symbol(forPercent: 5, charging: true), "battery.100.bolt")
        XCTAssertEqual(BatteryGlyph.symbol(forPercent: 99, charging: true), "battery.100.bolt")
        XCTAssertEqual(BatteryGlyph.symbol(forPercent: nil, charging: true), "battery.100.bolt")
    }

    /// "No reading" is NOT "flat". A strap that has not reported must not be drawn as empty — that
    /// would be the widget asserting a measurement it does not have.
    func testNoReadingIsNotDrawnAsFlat() {
        XCTAssertEqual(BatteryGlyph.symbol(forPercent: nil), "batteryblock.slash")
        XCTAssertNotEqual(BatteryGlyph.symbol(forPercent: nil), BatteryGlyph.symbol(forPercent: 0))
    }

    /// Out-of-range values still resolve to a glyph rather than trapping: a strap reporting nonsense
    /// should draw something, not crash a widget timeline.
    func testOutOfRangeValuesStillResolve() {
        XCTAssertEqual(BatteryGlyph.symbol(forPercent: -5), "battery.0")
        XCTAssertEqual(BatteryGlyph.symbol(forPercent: 150), "battery.100")
    }
    /// EVERY name this returns must resolve against the system symbol set. An unknown SF Symbol name
    /// renders as EMPTY SPACE and compiles without complaint, so a typo silently deletes the icon —
    /// which is exactly what `battery.slash` (not a real symbol) did on the first attempt here.
    func testEveryGlyphNameIsARealSystemSymbol() {
        var names = Set<String>()
        for pct in [nil, -5, 0, 12, 13, 37, 38, 62, 63, 87, 88, 100, 150] as [Int?] {
            names.insert(BatteryGlyph.symbol(forPercent: pct))
            names.insert(BatteryGlyph.symbol(forPercent: pct, charging: true))
        }
        for name in names.sorted() {
            #if canImport(AppKit)
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil),
                            "\(name) is not a real SF Symbol — it would render as nothing")
            #endif
        }
    }
}
