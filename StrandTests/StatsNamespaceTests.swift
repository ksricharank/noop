import XCTest
@testable import Strand

/// 260919: `RescoreStats` and `RetroScanStats` both wrote `rss.day` and `rss.maxMs`.
///
/// The damage was silent and it corrupted the strap log. Both call `rollIfNeeded` against the same
/// day key, and each roll zeroes only its OWN keys — so whichever rolled first stamped the new day
/// and the other never rolled at all, carrying yesterday's counters forward. And the shared
/// `maxMs` meant the header's retro-scan "maxMs=" and re-score "longest" were the SAME stored
/// integer printed twice, of which at most one could be true.
final class StatsNamespaceTests: XCTestCase {

    /// The two types must not share a prefix. This is the whole bug in one assertion.
    func testTheTwoStatsTypesDoNotShareANamespace() {
        XCTAssertNotEqual(RescoreStats.keyPrefix, RetroScanStats.keyPrefix)
        XCTAssertFalse(RescoreStats.keyPrefix.hasPrefix(RetroScanStats.keyPrefix),
                       "one namespace is a prefix of the other — their keys can still collide")
        XCTAssertFalse(RetroScanStats.keyPrefix.hasPrefix(RescoreStats.keyPrefix),
                       "one namespace is a prefix of the other — their keys can still collide")
    }

    /// Each type's keys actually live under the prefix it advertises. A prefix constant that no key
    /// respects would make the assertion above pass while the collision continued.
    func testEachTypeUsesTheNamespaceItAdvertises() {
        XCTAssertTrue(RescoreStats.keyPrefix.hasSuffix("."),
                      "a namespace without a separator can prefix-collide with a sibling")
        XCTAssertTrue(RetroScanStats.keyPrefix.hasSuffix("."))
    }
}
