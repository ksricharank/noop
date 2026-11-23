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
    func testTabOrderIsTodayDaySleepTrendsCoachMore() {
        XCTAssertEqual(PhoneTab.displayOrder, [.today, .day, .sleep, .trends, .coach, .more])
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
        XCTAssertEqual(PhoneTab.count, 6)
        XCTAssertEqual(PhoneTabIndex.count, PhoneTab.count)
    }

    /// The bare-Int mirror the tab shell subscripts with must agree with the enum, or the two drift
    /// and the wrong tab gets the wrong navigation stack.
    func testIndexMirrorAgreesWithTheEnum() {
        XCTAssertEqual(PhoneTabIndex.today, PhoneTab.today.rawValue)
        XCTAssertEqual(PhoneTabIndex.day, PhoneTab.day.rawValue)
        XCTAssertEqual(PhoneTabIndex.sleep, PhoneTab.sleep.rawValue)
        XCTAssertEqual(PhoneTabIndex.trends, PhoneTab.trends.rawValue)
        XCTAssertEqual(PhoneTabIndex.coach, PhoneTab.coach.rawValue)
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

    /// `sparkles` is the Coach's mark; only the Coach tab may carry it, or another tab reads as a
    /// second door to the coach.
    func testOnlyTheCoachTabUsesTheCoachIcon() {
        XCTAssertEqual(PhoneTab.allCases.filter { $0.systemImage == "sparkles" }, [.coach])
    }

    /// 261014: Coach is a tab again, fifth — between Insights and More — at the maintainer's request.
    /// Tag 3 is still Trends, so a Coach route by the bare literal upstream used would still be wrong.
    func testCoachIsTheFifthTabBetweenInsightsAndMore() {
        XCTAssertEqual(PhoneTab.coach.rawValue, 4)
        XCTAssertEqual(PhoneTab.coach.title, "Coach")
        XCTAssertEqual(PhoneTab(rawValue: 3), .trends,
                       "tag 3 is Trends in this fork — a Coach route to index 3 opens Trends")
        XCTAssertEqual(PhoneTab.lastIndex, PhoneTab.more.rawValue, "More stays last")
    }

    /// With the coach master switch off the AI is off, so its tab leaves the bar — and a swipe steps
    /// over the gap rather than landing on a tab that is not there.
    func testCoachSwitchHidesTheTabAndSwipesStepOverIt() {
        XCTAssertEqual(PhoneTab.visible(coachEnabled: true).count, 6)
        XCTAssertFalse(PhoneTab.visible(coachEnabled: false).contains(.coach))
        XCTAssertEqual(PhoneTab.swipeTarget(from: PhoneTabIndex.trends, forward: true, coachEnabled: false),
                       PhoneTabIndex.more)
        XCTAssertEqual(PhoneTab.swipeTarget(from: PhoneTabIndex.more, forward: false, coachEnabled: false),
                       PhoneTabIndex.trends)
        XCTAssertEqual(PhoneTab.swipeTarget(from: PhoneTabIndex.trends, forward: true, coachEnabled: true),
                       PhoneTabIndex.coach)
        // Clamped at both ends.
        XCTAssertEqual(PhoneTab.swipeTarget(from: PhoneTabIndex.more, forward: true, coachEnabled: true),
                       PhoneTabIndex.more)
        XCTAssertEqual(PhoneTab.swipeTarget(from: PhoneTabIndex.today, forward: false, coachEnabled: true),
                       PhoneTabIndex.today)
    }

    /// The retrospective tab is named for what it shows — a FINISHED day — not "Day", which read as a
    /// near-duplicate of "Today" next to it in the bar.
    func testTheRetrospectiveTabIsNotNamedLikeToday() {
        XCTAssertEqual(PhoneTab.day.title, "Recap")
        XCTAssertNotEqual(PhoneTab.day.title, PhoneTab.today.title)
        XCTAssertFalse(PhoneTab.day.title.localizedCaseInsensitiveContains("today"),
                       "the finished-day tab must not read like the live one")
        XCTAssertNotEqual(PhoneTab.day.systemImage, "medal",
                          "a medal implies an award, not a retrospective")
    }
}
