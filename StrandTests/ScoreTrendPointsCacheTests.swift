import XCTest
@testable import Strand

/// `ScoreTrendSection.points` is memoized (260919) because it re-sorted and re-parsed the whole
/// day-keyed series on every body evaluation: 1.2 ms at 58 stored days, 6.2 ms at a year, against a
/// 16.7 ms frame budget — and the section appears on BOTH the Sleep and Recap tabs.
///
/// The memoization's own hazard is worse than the cost it removes: the two tabs pass DIFFERENT
/// series (`restByDay` and `scoresByDay`), so a cache keyed on size alone would serve one tab's
/// points to the other's chart whenever the two happened to be the same length. Silently wrong data
/// beats slow data only in the sense that nobody notices it.
final class ScoreTrendPointsCacheTests: XCTestCase {

    private let parser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func series(_ values: [Double]) -> [String: Double] {
        var out: [String: Double] = [:]
        for (i, v) in values.enumerated() {
            out[parser.string(from: Date().addingTimeInterval(-Double(i) * 86_400))] = v
        }
        return out
    }

    /// The pure windowing is unchanged by the cache — this is the behaviour the memo must preserve.
    func testTheWindowKeepsOnlyDaysInsideIt() {
        let pts = ScoreTrendSection.points(valuesByDay: series(Array(repeating: 50, count: 60)),
                                           windowDays: 14)
        XCTAssertLessThanOrEqual(pts.count, 15, "a 14-day window must not return 60 days")
        XCTAssertGreaterThan(pts.count, 10)
    }

    /// Oldest first, which the chart depends on — a cache that returned a stale ORDER would draw a
    /// scrambled line rather than an obviously empty one.
    func testPointsAreOldestFirst() {
        let pts = ScoreTrendSection.points(valuesByDay: series([1, 2, 3, 4, 5]), windowDays: 30)
        XCTAssertEqual(pts.map(\.date), pts.map(\.date).sorted())
    }

    /// TWO SERIES OF THE SAME LENGTH must not collide. This is the whole reason the cache carries an
    /// owner: without it, Sleep's Rest trend and Recap's Day quality trend are interchangeable to a
    /// count-keyed cache, and the wearer sees one tab's numbers under the other tab's title.
    func testTwoEqualLengthSeriesProduceDifferentPoints() {
        let rest = series([10, 20, 30, 40, 50])
        let quality = series([90, 80, 70, 60, 50])
        let restPts = ScoreTrendSection.points(valuesByDay: rest, windowDays: 30)
        let qualityPts = ScoreTrendSection.points(valuesByDay: quality, windowDays: 30)
        XCTAssertEqual(restPts.count, qualityPts.count, "the premise: same length")
        XCTAssertNotEqual(restPts.map(\.value), qualityPts.map(\.value),
                          "same-length series must not be treated as interchangeable")
    }

    /// An empty series is empty, not a crash and not a stale previous result.
    func testAnEmptySeriesHasNoPoints() {
        XCTAssertTrue(ScoreTrendSection.points(valuesByDay: [:], windowDays: 30).isEmpty)
    }

    /// The window is what makes the cache key meaningful: the same series at two windows is two
    /// different answers, so a key that ignored the window would pin the chart to whichever window
    /// was drawn first.
    func testTheSameSeriesAtDifferentWindowsDiffers() {
        let s = series(Array(repeating: 42, count: 60))
        let narrow = ScoreTrendSection.points(valuesByDay: s, windowDays: 7)
        let wide = ScoreTrendSection.points(valuesByDay: s, windowDays: 60)
        XCTAssertNotEqual(narrow.count, wide.count)
    }
}
