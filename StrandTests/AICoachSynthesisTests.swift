import XCTest
@testable import Strand

/// `AICoachEngine.synthesisIsCurrent` — the day-rollover gate on the coach-written Today synthesis.
/// The generation itself needs a live provider and is not testable here; what IS pinnable is the rule
/// that decides whether a stored paragraph may still be shown. Getting it wrong is quietly bad in one
/// direction only: yesterday's narrative pinned to today's numbers reads as a confident wrong answer,
/// whereas a dropped current text merely falls back to the rule-based read.
final class AICoachSynthesisTests: XCTestCase {

    /// No generation has ever landed → nothing to show. The nil path is the everyday one (Coach
    /// unconfigured), so it must be false, not a crash or a stale default.
    func testNilGenerationIsNotCurrent() {
        XCTAssertFalse(AICoachEngine.synthesisIsCurrent(generatedAt: nil))
    }

    /// A text generated earlier the same local day is still current, however early — the morning
    /// generation must survive until midnight, not decay on some sliding window.
    func testSameLocalDayIsCurrent() {
        let now = Date()
        XCTAssertTrue(AICoachEngine.synthesisIsCurrent(generatedAt: now, now: now))
        let startOfDay = Calendar.current.startOfDay(for: now)
        XCTAssertTrue(AICoachEngine.synthesisIsCurrent(generatedAt: startOfDay.addingTimeInterval(60),
                                                       now: now))
    }

    /// A text from the previous local day is stale the moment the day rolls — even one minute across
    /// midnight — so a provider that stopped answering degrades to the rule-based read by morning.
    func testPreviousLocalDayIsStale() {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        let lateYesterday = startOfToday.addingTimeInterval(-60)
        let earlyToday = startOfToday.addingTimeInterval(60)
        XCTAssertFalse(AICoachEngine.synthesisIsCurrent(generatedAt: lateYesterday, now: earlyToday))
        XCTAssertFalse(AICoachEngine.synthesisIsCurrent(generatedAt: startOfToday.addingTimeInterval(-86_400),
                                                        now: earlyToday))
    }
}
