import Foundation

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
enum PhoneTab: Int, CaseIterable {
    case today = 0
    case day = 1
    case sleep = 2
    case trends = 3
    case more = 4

    /// The order the bar renders left to right — `allCases` by construction, named for readers.
    static var displayOrder: [PhoneTab] { allCases }

    /// The last tab's index. The swipe clamp reads this; left as a literal it silently made the final
    /// tab unreachable by swipe while every other route still worked (260906).
    static var lastIndex: Int { (allCases.map(\.rawValue).max()) ?? 0 }

    /// How many tabs there are — sizes the per-tab `NavigationPath` / scroll-token arrays, so adding a
    /// tab cannot leave them short.
    static var count: Int { allCases.count }

    /// The label shown in the tab bar.
    var title: String {
        switch self {
        case .today: return "Today"
        case .day: return "Day"
        case .sleep: return "Sleep"
        case .trends: return "Trends"
        case .more: return "More"
        }
    }

    /// The SF Symbol shown in the tab bar. Each must be distinct from its neighbours, and none may
    /// reuse `sparkles` — that is the Coach's mark, and reusing it makes a tab look like a second door
    /// to the coach.
    var systemImage: String {
        switch self {
        case .today: return "square.grid.2x2"
        case .day: return "medal"
        case .sleep: return "bed.double"
        case .trends: return "chart.line.uptrend.xyaxis"
        case .more: return "ellipsis"
        }
    }
}

/// Bare `Int` indices for the tab shell's array subscripts and `selectedTab` comparisons, so those
/// call sites read `Tab.trends` rather than `PhoneTab.trends.rawValue` at every use.
enum PhoneTabIndex {
    static let today = PhoneTab.today.rawValue
    static let day = PhoneTab.day.rawValue
    static let sleep = PhoneTab.sleep.rawValue
    static let trends = PhoneTab.trends.rawValue
    static let more = PhoneTab.more.rawValue
    static let count = PhoneTab.count
}
