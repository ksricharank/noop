import XCTest

/// 260919: scrolling went choppy on every tab, and the cause was mine.
///
/// The three tab roots gained `@EnvironmentObject var coach: AICoachEngine` so their LLM summary
/// could reach the engine. But `@EnvironmentObject` subscribes to the WHOLE object's
/// `objectWillChange` regardless of which properties the body reads — and `AICoachEngine` has 32
/// `@Published` properties, one of which (`synthesisRefreshing`) toggles while a summary generates.
/// So landing on a tab re-evaluated a ~2000-line body twice, and any later publish did it again.
///
/// Worse, none of the three bodies READ the engine at all: they only captured it for a closure. The
/// subscription bought nothing and cost everything. The dependency now lives on `TabInsightCard`,
/// the leaf that actually uses it — the same scoping `SleepView` already documents for `LiveState`
/// and `AppModel`.
///
/// Source-level, because the cost is a property of WHERE the declaration sits, which no runtime
/// assertion on these views can observe.
final class TabRootObservationTests: XCTestCase {

    private func source(_ relative: String) throws -> String {
        // From StrandTests/<file> up to the repo root.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The heavy tab roots must not observe the coach engine. Each of these bodies is thousands of
    /// lines and is re-evaluated in full on every publish of anything it observes.
    func testHeavyTabRootsDoNotObserveTheCoachEngine() throws {
        for path in ["Strand/Screens/TrendsView.swift",
                     "Strand/Screens/SleepView.swift",
                     "Strand/Screens/DayQualityView.swift"] {
            let src = try source(path)
            XCTAssertFalse(src.contains("var coach: AICoachEngine"),
                           "\(path) observes AICoachEngine (32 @Published properties) from a heavy "
                           + "tab root — put it on the leaf that reads it, as TabInsightCard does. "
                           + "This is the 260919 choppy-scrolling regression.")
        }
    }

    /// Same reasoning for the router: it publishes far less often, but a tab root that does not read
    /// it in its body has no reason to subscribe to it either.
    func testHeavyTabRootsDoNotObserveTheRouterWithoutUsingIt() throws {
        for path in ["Strand/Screens/TrendsView.swift",
                     "Strand/Screens/SleepView.swift",
                     "Strand/Screens/DayQualityView.swift"] {
            let src = try source(path)
            guard src.contains("var router: NavRouter") else { continue }
            XCTAssertTrue(src.contains("router."),
                          "\(path) observes NavRouter but never reads it — an unused subscription "
                          + "re-evaluates the whole body for nothing")
        }
    }

    /// The leaf DOES own both, which is what makes the assertions above a relocation rather than a
    /// removal — the summaries must still reach the engine and the chat.
    func testTheInsightCardOwnsWhatTheTabRootsGaveUp() throws {
        let src = try source("Strand/Screens/TabInsightCard.swift")
        XCTAssertTrue(src.contains("var coach: AICoachEngine"),
                      "the insight card must own the engine it generates from")
        XCTAssertTrue(src.contains("var router: NavRouter"),
                      "the insight card must own the router its Ask-the-Coach link uses")
    }
}
