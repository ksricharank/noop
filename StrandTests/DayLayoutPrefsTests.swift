import XCTest
@testable import Strand

/// The Day tab's arrangeable layout (260908). Twin of `SleepLayoutPrefsTests` — the decoder's
/// guarantees are what stop a saved layout from losing a card or duplicating one.
final class DayLayoutPrefsTests: XCTestCase {

    func testEmptyOrBlankDecodesToTheDefaultOrder() {
        XCTAssertEqual(DayLayoutPrefs.decodeOrder(""), DaySection.defaultOrder)
        XCTAssertEqual(DayLayoutPrefs.decodeOrder("   "), DaySection.defaultOrder)
    }

    func testARoundTripPreservesACustomOrder() {
        let reordered: [DaySection] = [
            .settings, .streaks, .breakdown, .trend, .calendar, .weekSummary,
            .counterfactual, .attribution,
        ]
        XCTAssertEqual(DayLayoutPrefs.decodeOrder(DayLayoutPrefs.encode(reordered)), reordered)
    }

    /// Every known card must always render, even if the saved order predates it.
    func testACardMissingFromASavedOrderIsInsertedAtItsDefaultPosition() {
        // A saved order from a build that had no Insights cards at all.
        let old = DayLayoutPrefs.encode([.breakdown, .weekSummary, .trend, .calendar, .settings])
        let decoded = DayLayoutPrefs.decodeOrder(old)
        XCTAssertEqual(Set(decoded), Set(DaySection.allCases), "no card may be dropped")
        XCTAssertEqual(decoded.count, DaySection.allCases.count, "and none duplicated")
        // The new cards land where the default order puts them — after the breakdown, before the
        // week summary — rather than at the bottom.
        let iBreakdown = try! XCTUnwrap(decoded.firstIndex(of: .breakdown))
        let iAttribution = try! XCTUnwrap(decoded.firstIndex(of: .attribution))
        let iWeek = try! XCTUnwrap(decoded.firstIndex(of: .weekSummary))
        XCTAssertLessThan(iBreakdown, iAttribution)
        XCTAssertLessThan(iAttribution, iWeek,
                          "a card added later must surface where users expect it, not teleport to "
                          + "the bottom of an existing saved order")
    }

    func testUnknownTokensAreIgnoredAndDuplicatesCollapsed() {
        XCTAssertEqual(DayLayoutPrefs.decodeOrder("nope,,zzz"), DaySection.defaultOrder,
                       "a wholly unrecognised order falls back to the default")
        let dupes = "breakdown,breakdown,streaks,streaks"
        let decoded = DayLayoutPrefs.decodeOrder(dupes)
        XCTAssertEqual(decoded.count, DaySection.allCases.count)
        XCTAssertEqual(Set(decoded).count, DaySection.allCases.count, "no duplicates survive")
        // The two saved cards keep their RELATIVE order; the cards absent from the saved string are
        // inserted at their default positions between them, which is why the prefix is not literally
        // [breakdown, streaks] — `attribution` and `counterfactual` sort in between by default.
        let iBreakdown = try! XCTUnwrap(decoded.firstIndex(of: .breakdown))
        let iStreaks = try! XCTUnwrap(decoded.firstIndex(of: .streaks))
        XCTAssertLessThan(iBreakdown, iStreaks, "the saved relative order is kept")
        XCTAssertEqual(iBreakdown, 0, "and the first saved card stays first")
    }

    func testHiddenDecodingTreatsAbsenceAsVisible() {
        XCTAssertTrue(DayLayoutPrefs.decodeHidden("").isEmpty)
        XCTAssertEqual(DayLayoutPrefs.decodeHidden("streaks,calendar"), [.streaks, .calendar])
        // Unlike decodeOrder, a missing case is NOT inserted: absence here means visible, which is
        // what makes a card added by a future version default to shown.
        XCTAssertFalse(DayLayoutPrefs.decodeHidden("streaks").contains(.calendar))
    }

    func testVisibleOrderFiltersOnlyTheExplicitHiddenSet() {
        let order = DayLayoutPrefs.encode(DaySection.defaultOrder)
        let visible = DayLayoutPrefs.visibleOrder(orderRaw: order, hiddenRaw: "streaks,settings")
        XCTAssertFalse(visible.contains(.streaks))
        XCTAssertFalse(visible.contains(.settings))
        XCTAssertEqual(visible.count, DaySection.allCases.count - 2)
        // And the surviving cards keep their saved relative order.
        XCTAssertEqual(visible, DaySection.defaultOrder.filter { $0 != .streaks && $0 != .settings })
    }

    /// A hidden card keeps a stable slot, so unhiding it returns it to where it was rather than to
    /// the bottom.
    func testHidingThenUnhidingRestoresThePosition() {
        let order = DayLayoutPrefs.encode(DaySection.defaultOrder)
        let hidden = "attribution"
        XCTAssertFalse(DayLayoutPrefs.visibleOrder(orderRaw: order, hiddenRaw: hidden).contains(.attribution))
        let restored = DayLayoutPrefs.visibleOrder(orderRaw: order, hiddenRaw: "")
        XCTAssertEqual(restored.firstIndex(of: .attribution),
                       DaySection.defaultOrder.firstIndex(of: .attribution))
    }

    /// `defaultOrder` must cover every case, or `decodeOrder`'s insertion logic has no position for
    /// the missing one and it sorts to the end silently.
    func testDefaultOrderCoversEveryCase() {
        XCTAssertEqual(Set(DaySection.defaultOrder), Set(DaySection.allCases))
        XCTAssertEqual(DaySection.defaultOrder.count, DaySection.allCases.count)
    }

    /// Persisted identifiers must be stable — a rename silently discards every saved layout.
    func testRawValuesAreTheExpectedStableKeys() {
        XCTAssertEqual(Set(DaySection.allCases.map(\.rawValue)),
                       ["breakdown", "attribution", "counterfactual", "streaks",
                        "weekSummary", "trend", "calendar", "settings"])
    }

    /// The coach narrative is deliberately NOT a section: it lives inside the score card's own
    /// collapsible area, and a row that does nothing when hidden would be a control that lies.
    func testTheNarrativeIsNotAnArrangeableSection() {
        XCTAssertFalse(DaySection.allCases.map(\.rawValue).contains("narrative"))
    }

    /// Every card needs a label and an icon for the Arrange sheet, and no two may share either.
    func testEverySectionHasDistinctArrangeMetadata() {
        for s in DaySection.allCases {
            XCTAssertFalse(s.title.isEmpty, "\(s) has no title")
            XCTAssertFalse(s.customizationIcon.isEmpty, "\(s) has no icon")
            XCTAssertNotNil(s.customizationSubtitle, "\(s) has no subtitle")
        }
        let icons = DaySection.allCases.map(\.customizationIcon)
        XCTAssertEqual(Set(icons).count, icons.count, "two cards share an Arrange icon")
        let titles = DaySection.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count, "two cards share a title")
    }
}
