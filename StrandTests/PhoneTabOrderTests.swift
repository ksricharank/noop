import XCTest
@testable import Strand

/// The iPhone tab order (260908: Trends moved from second to fourth).
///
/// These run on the macOS leg, which is the point: `RootTabView` is `#if os(iOS)` and has no CI at all,
/// so the order it renders can only be pinned through the shared `PhoneTab` it now reads from. What
/// makes this worth a test is the failure mode — a reorder that misses a call site opens a tab that
/// loads perfectly and is simply the wrong one, with nothing on screen or in the log to say so.
final class PhoneTabOrderTests: XCTestCase {

    /// The order the maintainer asked for, left to right.
    func testTabOrderIsTodayDaySleepTrendsMore() {
        XCTAssertEqual(PhoneTab.displayOrder, [.today, .day, .sleep, .trends, .more])
    }

    /// Trends is fourth. Stated on its own because this is the move that motivated the change, and a
    /// future reorder that puts it back should have to change this line deliberately.
    func testTrendsIsTheFourthTab() {
        XCTAssertEqual(PhoneTab.trends.rawValue, 3)
        XCTAssertEqual(PhoneTab.day.rawValue, 1, "Day quality takes the slot Trends used to hold")
    }

    /// Indices must be contiguous from zero: they subscript the per-tab path and scroll arrays, so a
    /// gap or a duplicate is an out-of-bounds crash or two tabs sharing one navigation stack.
    func testIndicesAreContiguousFromZero() {
        XCTAssertEqual(PhoneTab.allCases.map(\.rawValue), Array(0..<PhoneTab.count))
        XCTAssertEqual(Set(PhoneTab.allCases.map(\.rawValue)).count, PhoneTab.count,
                       "duplicate indices would make two tabs share one navigation stack")
    }

    /// The swipe clamp reads `lastIndex`; left as a literal it silently made the final tab unreachable
    /// by swipe while every other route still worked (the 260906 half-failure).
    func testLastIndexMatchesTheFinalTab() {
        XCTAssertEqual(PhoneTab.lastIndex, PhoneTab.more.rawValue)
        XCTAssertEqual(PhoneTab.lastIndex, PhoneTab.count - 1)
    }

    /// The per-tab arrays are sized from `count`, so it must match the case list exactly.
    func testCountMatchesTheCaseList() {
        XCTAssertEqual(PhoneTab.count, 5)
        XCTAssertEqual(PhoneTabIndex.count, PhoneTab.count)
    }

    /// The bare-Int mirror the tab shell subscripts with must agree with the enum, or the two drift
    /// and the wrong tab gets the wrong navigation stack.
    func testIndexMirrorAgreesWithTheEnum() {
        XCTAssertEqual(PhoneTabIndex.today, PhoneTab.today.rawValue)
        XCTAssertEqual(PhoneTabIndex.day, PhoneTab.day.rawValue)
        XCTAssertEqual(PhoneTabIndex.sleep, PhoneTab.sleep.rawValue)
        XCTAssertEqual(PhoneTabIndex.trends, PhoneTab.trends.rawValue)
        XCTAssertEqual(PhoneTabIndex.more, PhoneTab.more.rawValue)
    }

    /// Every tab needs a label and an icon, and adjacent icons must differ — a tab bar with two
    /// identical glyphs is unreadable.
    func testEveryTabHasADistinctIconAndATitle() {
        for tab in PhoneTab.allCases {
            XCTAssertFalse(tab.title.isEmpty, "\(tab) has no title")
            XCTAssertFalse(tab.systemImage.isEmpty, "\(tab) has no icon")
        }
        let icons = PhoneTab.allCases.map(\.systemImage)
        XCTAssertEqual(Set(icons).count, icons.count, "two tabs share an icon")
        let titles = PhoneTab.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count, "two tabs share a title")
    }

    /// `sparkles` is the Coach's mark (the More row and the macOS sidebar). A tab reusing it would read
    /// as a second door to the coach.
    func testNoTabReusesTheCoachIcon() {
        XCTAssertFalse(PhoneTab.allCases.map(\.systemImage).contains("sparkles"))
    }
}
