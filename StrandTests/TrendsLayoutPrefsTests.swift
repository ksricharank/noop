import XCTest
@testable import Strand

/// The Trends tab's cards became arrangeable at 260919. These pin the recovery rules that stop a
/// stored layout from stranding a card — the failure that matters is a wearer upgrading and finding
/// a section has silently vanished from both the page AND the Arrange sheet.
final class TrendsLayoutPrefsTests: XCTestCase {

    func testAnEmptyStoredOrderIsTheDefaultOrder() {
        XCTAssertEqual(TrendsLayoutPrefs.decodeOrder(""), TrendsSection.defaultOrder)
    }

    /// Every card appears exactly once, whatever the stored string says. This is the invariant the
    /// Arrange sheet depends on: it lists `visible + hidden`, so a duplicate would render twice and
    /// a missing one would be unreachable.
    func testDecodeAlwaysYieldsEveryCardExactlyOnce() {
        for raw in ["", "insight", "yearStrip,insight", "bogus,insight,bogus",
                    "insight,insight,weekInReview"] {
            let decoded = TrendsLayoutPrefs.decodeOrder(raw)
            XCTAssertEqual(Set(decoded).count, decoded.count, "duplicate in \(raw)")
            XCTAssertEqual(Set(decoded), Set(TrendsSection.allCases), "missing card in \(raw)")
        }
    }

    /// A rawValue this build does not know is dropped rather than crashing or being preserved as a
    /// ghost entry — a layout written by a NEWER build must still open on this one.
    func testUnknownCardsAreDropped() {
        let decoded = TrendsLayoutPrefs.decodeOrder("insight,somethingFromTheFuture,yearStrip")
        XCTAssertEqual(decoded.prefix(2), [.insight, .yearStrip])
    }

    /// A card added AFTER a layout was stored is appended rather than lost — the upgrade case.
    func testCardsMissingFromAStoredOrderAreAppended() {
        let decoded = TrendsLayoutPrefs.decodeOrder("yearStrip,insight")
        XCTAssertEqual(decoded.prefix(2), [.yearStrip, .insight])
        XCTAssertEqual(Set(decoded), Set(TrendsSection.allCases))
    }

    func testHiddenCardsAreExcludedFromTheVisibleOrder() {
        let visible = TrendsLayoutPrefs.visibleOrder(orderRaw: TrendsLayoutPrefs.encode(TrendsSection.defaultOrder),
                                                     hiddenRaw: "yearStrip,trainingLoad")
        XCTAssertFalse(visible.contains(.yearStrip))
        XCTAssertFalse(visible.contains(.trainingLoad))
        XCTAssertTrue(visible.contains(.insight))
    }

    /// The round trip is lossless, which is what lets the sheet store "shown ++ hidden" and read
    /// back the same arrangement.
    func testEncodeDecodeRoundTrips() {
        let order: [TrendsSection] = [.yearStrip, .insight, .trainingLoad,
                                      .weekInReview, .recoveryHero, .smallMultiples, .exportReport]
        XCTAssertEqual(TrendsLayoutPrefs.decodeOrder(TrendsLayoutPrefs.encode(order)), order)
    }

    /// The default order is exactly the pre-arrangeable hard-coded order, so an install that never
    /// opens Arrange sees precisely what it saw before this shipped.
    func testTheDefaultOrderMatchesTheOriginalHardCodedOrder() {
        XCTAssertEqual(TrendsSection.defaultOrder,
                       [.insight, .weekInReview, .recoveryHero, .smallMultiples,
                        .trainingLoad, .yearStrip, .exportReport])
    }

    /// The LLM summary leads the page on every tab that has one.
    func testTheInsightCardLeadsTheDefaultOrder() {
        XCTAssertEqual(TrendsSection.defaultOrder.first, .insight)
    }
}
