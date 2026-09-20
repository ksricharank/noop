import XCTest
@testable import Strand

/// The Trends tab's cards became arrangeable at 260919. These pin the recovery rules that stop a
/// stored layout from stranding a card — the failure that matters is a wearer upgrading and finding
/// a section has silently vanished from both the page AND the Arrange sheet.
final class TrendsLayoutPrefsTests: XCTestCase {

    /// 260920: decode returns EVERY card, so an empty store yields `canonicalOrder` — the default
    /// order followed by the per-metric blocks. Those blocks must be reachable in the Arrange sheet
    /// even though they do not render until switched on, which is `defaultHidden`'s job, not this
    /// one. Asserting `defaultOrder` here is what caught them being unreachable.
    func testAnEmptyStoredOrderIsTheCanonicalOrder() {
        XCTAssertEqual(TrendsLayoutPrefs.decodeOrder(""), TrendsSection.canonicalOrder)
        XCTAssertEqual(TrendsLayoutPrefs.decodeOrder("").prefix(TrendsSection.defaultOrder.count).map { $0 },
                       TrendsSection.defaultOrder,
                       "the original cards keep their original order and positions")
    }

    /// The page and the Arrange sheet must agree about what is hidden, or the sheet lists a card as
    /// Shown that the page is hiding.
    func testPerMetricBlocksAreHiddenUntilArrangeIsSaved() {
        let visible = TrendsLayoutPrefs.visibleOrder(orderRaw: "", hiddenRaw: "")
        // 260920: `allMetrics` is the ONE new section shown by default — the maintainer asked for a
        // single card that could replace the rest of the page, which it cannot do while hidden.
        // Every per-metric block stays opt-in.
        // 260920: the row card ships SHOWN — a card meant to replace the page cannot do that while
        // hidden. The heatmap that briefly shipped beside it was removed the same day at the
        // maintainer's request ("I don't like the new heatmap widget"); the CALENDAR, which was
        // already on the page, absorbed its configurability instead.
        XCTAssertEqual(visible, TrendsSection.defaultOrder + [.allMetrics],
                       "the pre-260920 page, plus the row card")
        for block in TrendsLayoutPrefs.defaultHidden {
            XCTAssertFalse(visible.contains(block), "\(block) must not appear uninvited")
        }
        // Once Arrange has been saved, the STORED set is authoritative — otherwise a card could be
        // switched on and would silently hide itself again on the next launch.
        let afterSave = TrendsLayoutPrefs.visibleOrder(
            orderRaw: "", hiddenRaw: TrendsLayoutPrefs.encodeHidden([.yearStrip]))
        XCTAssertTrue(afterSave.contains(.hrvTrend))
        XCTAssertFalse(afterSave.contains(.yearStrip))
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
        // A full arrangement round-trips unchanged.
        let order = TrendsSection.canonicalOrder.reversed().map { $0 }
        XCTAssertEqual(TrendsLayoutPrefs.decodeOrder(TrendsLayoutPrefs.encode(order)), order)
        // A PARTIAL one keeps its stored prefix and appends the rest, rather than losing either.
        let partial: [TrendsSection] = [.yearStrip, .insight, .trainingLoad]
        let decoded = TrendsLayoutPrefs.decodeOrder(TrendsLayoutPrefs.encode(partial))
        XCTAssertEqual(decoded.prefix(3).map { $0 }, partial)
        XCTAssertEqual(Set(decoded), Set(TrendsSection.allCases))
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
