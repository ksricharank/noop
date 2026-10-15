import Foundation
import SwiftUI

/// The iPhone tab bar's order, in a file BOTH platforms compile.
///
/// `RootTabView` is `#if os(iOS)`, so its own indices are invisible to `StrandTests` (which runs on the
/// macOS/`Strand` leg). Every index the tab shell uses therefore lives here instead: the tab list, the
/// swipe clamp, the deep-link handlers and the per-tab path/scroll arrays all read from it, and the
/// order can be pinned by a test that actually runs.
///
/// This exists because of the failure mode a reorder has. 260908 moved Trends from second to fourth at
/// the maintainer's request; the Trends deep-link was the literal `selectedTab = 1`, which after the
/// move would have opened Day quality instead — a tab that loads perfectly and is simply the wrong one,
/// with nothing in the log or on screen to say so. Named indices make the reorder one edit; the test
/// makes a future reorder that forgets a call site fail loudly.
///
/// 261014: Coach is a tab again, fifth, between Insights and More, at the maintainer's request — six
/// tabs, which the native iPhone tab bar cannot show (past five it folds the rest into a system "More"),
/// so the shell draws its own bar (`NoopTabBar`).
enum PhoneTab: Int, CaseIterable {
    case today = 0
    case day = 1
    case sleep = 2
    case trends = 3
    case coach = 4
    case more = 5

    /// The order the bar renders left to right — `allCases` by construction, named for readers.
    static var displayOrder: [PhoneTab] { allCases }

    /// The last tab's index. The swipe clamp reads this; left as a literal it silently made the final
    /// tab unreachable by swipe while every other route still worked (260906).
    static var lastIndex: Int { (allCases.map(\.rawValue).max()) ?? 0 }

    /// How many tabs there are — sizes the per-tab `NavigationPath` / scroll-token arrays, so adding a
    /// tab cannot leave them short.
    static var count: Int { allCases.count }

    /// The label shown in the tab bar.
    ///
    /// `.day` reads "Recap", not "Day": the screen is the retrospective read on a FINISHED day
    /// ("How a finished day actually went"), which "Day" did not convey beside "Today". It is a
    /// browsable date navigator rather than strictly yesterday, so a literal "Yesterday" would be
    /// wrong on every other day the user scrolls to.
    var title: String {
        switch self {
        case .today: return "Today"
        case .day: return "Recap"
        case .sleep: return "Sleep"
        case .trends: return "Insights"
        case .coach: return "Coach"
        case .more: return "More"
        }
    }

    /// The tab-bar label as a SwiftUI `LocalizedStringKey`, so the bar stays translatable while still
    /// reading its text from this one enum. `title` remains a plain `String` for the tests, which run
    /// on the macOS leg and compare text directly.
    ///
    /// Both spellings must stay in step: a literal in the shell is how the bar came to say "Day" while
    /// this file said something else, with every index test still green (260914).
    var titleKey: LocalizedStringKey { LocalizedStringKey(title) }

    /// The SF Symbol shown in the tab bar. Each must be distinct from its neighbours. `sparkles` is the
    /// Coach's mark and belongs to the Coach tab alone — on any other tab it would read as a second
    /// door to the coach.
    var systemImage: String {
        switch self {
        case .today: return "square.grid.2x2"
        case .day: return "calendar.badge.checkmark"
        case .sleep: return "bed.double"
        case .trends: return "chart.line.uptrend.xyaxis"
        case .coach: return "sparkles"
        case .more: return "ellipsis"
        }
    }

    /// The tabs the bar shows. Coach goes when the coach master switch (`noop.coachEnabled`) is off —
    /// with it off the AI is off, so a tab for it would open a feature that is switched off.
    static func visible(coachEnabled: Bool) -> [PhoneTab] {
        displayOrder.filter { $0 != .coach || coachEnabled }
    }

    /// The tab a horizontal swipe lands on, stepping over hidden tabs and clamping at both ends.
    /// `forward` is a leftward swipe (towards More).
    static func swipeTarget(from current: Int, forward: Bool, coachEnabled: Bool) -> Int {
        let order = visible(coachEnabled: coachEnabled).map(\.rawValue)
        guard let at = order.firstIndex(of: current) else { return current }
        let next = min(order.count - 1, max(0, at + (forward ? 1 : -1)))
        return order[next]
    }
}

/// Bare `Int` indices for the tab shell's array subscripts and `selectedTab` comparisons, so those
/// call sites read `Tab.trends` rather than `PhoneTab.trends.rawValue` at every use.
enum PhoneTabIndex {
    static let today = PhoneTab.today.rawValue
    static let day = PhoneTab.day.rawValue
    static let sleep = PhoneTab.sleep.rawValue
    static let trends = PhoneTab.trends.rawValue
    static let coach = PhoneTab.coach.rawValue
    static let more = PhoneTab.more.rawValue
    static let count = PhoneTab.count
}

/// How much room a screen leaves at its bottom edge for the iPhone shell's floating tab bar (261014).
///
/// Set by the tab shell on each tab ROOT (the bar hides on a push); everywhere else — pushed screens,
/// macOS, sheets presented over the shell — it stays 0, which is correct there because no bar is
/// drawn. Screens that lay out their own bottom dock (the Coach composer) read it; scrolling screens
/// keep `NoopMetrics.tabBarClearance`.
private struct NoopTabBarClearanceKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var noopTabBarClearance: CGFloat {
        get { self[NoopTabBarClearanceKey.self] }
        set { self[NoopTabBarClearanceKey.self] = newValue }
    }
}

extension PhoneTab {
    /// The bar's footprint above the bottom safe area — its 46 pt items, 4 pt inset on each side and
    /// 2 pt lift — plus a small gap, so docked content sits clear of it.
    static let barClearance: CGFloat = 46 + 8 + 2 + 6
}
