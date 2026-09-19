import XCTest
@testable import Strand

/// The four per-tab LLM summaries (260919). Today reads the current moment, Recap grades a finished
/// day, Trends reads direction over weeks, Sleep reads one night.
///
/// The failure worth guarding against is not a crash — it is FOUR TABS SAYING THE SAME THING. Each
/// prompt earns its place only by covering ground the others are told to avoid, and that is a
/// property of the text, so it is pinned here.
final class TabInsightPromptTests: XCTestCase {

    private var allPrompts: [(name: String, text: String)] {
        [("Today", AICoachEngine.defaultSynthesisPrompt),
         ("Recap", AICoachEngine.defaultDayQualityPrompt),
         ("Trends", AICoachEngine.defaultTrendsPrompt),
         ("Sleep", AICoachEngine.defaultSleepPrompt)]
    }

    /// Each prompt names its own subject. A prompt that does not state its scope will drift toward
    /// the generic summary all four would otherwise produce.
    func testEachPromptNamesItsOwnScope() {
        XCTAssertTrue(AICoachEngine.defaultSynthesisPrompt.contains("Today screen"))
        XCTAssertTrue(AICoachEngine.defaultSynthesisPrompt.contains("MY CURRENT STATE"))
        XCTAssertTrue(AICoachEngine.defaultDayQualityPrompt.contains("ONE FINISHED DAY"))
        XCTAssertTrue(AICoachEngine.defaultTrendsPrompt.contains("weeks, not one day"))
        XCTAssertTrue(AICoachEngine.defaultSleepPrompt.contains("ONE NIGHT"))
    }

    /// Trends is explicitly fenced OFF the other three lenses. Without this it reverts to
    /// summarising today, which is what Today already does one tab away.
    func testTrendsIsFencedOffTheOtherTabs() {
        let p = AICoachEngine.defaultTrendsPrompt
        XCTAssertTrue(p.contains("Do NOT report today's values"), p)
        XCTAssertTrue(p.contains("grade a single day"), p)
        XCTAssertTrue(p.contains("discuss last night"), p)
        XCTAssertTrue(p.contains("DIRECTION"), p)
    }

    /// Today is fenced off the other three too — it gained siblings, so "recent days" had to stop
    /// meaning "the multi-week picture", which Trends now owns.
    func testTodayIsFencedOffTheOtherTabs() {
        let p = AICoachEngine.defaultSynthesisPrompt
        XCTAssertTrue(p.contains("Do NOT grade yesterday"), p)
        XCTAssertTrue(p.contains("summarise the week"), p)
        XCTAssertTrue(p.contains("last night"), p)
    }

    /// Sleep is fenced off day-grading and week-scale summary for the same reason.
    func testSleepIsFencedOffTheOtherTabs() {
        let p = AICoachEngine.defaultSleepPrompt
        XCTAssertTrue(p.contains("Do NOT grade the day"), p)
        XCTAssertTrue(p.contains("summarise the week"), p)
        XCTAssertTrue(p.contains("ARCHITECTURE"), p)
    }

    /// Every prompt must protect against the same two failures: inventing a finding to fill space,
    /// and reading missing data as a bad result. Both produce confident, wrong text.
    func testEveryPromptProtectsAgainstPaddingAndMissingData() {
        for (name, text) in allPrompts {
            XCTAssertTrue(text.contains("NOT RECORDED") || text.contains("A dash means")
                          || text.contains("no data") || text.contains("never invent")
                          || text.contains("Never invent"),
                          "\(name) does not tell the model how to treat missing data")
        }
        // The three that can pad (Today, Trends, Sleep — Recap is bounded to 2-3 sentences) must
        // each be given explicit permission to be brief.
        XCTAssertTrue(AICoachEngine.defaultSynthesisPrompt.contains("FEWER IS BETTER"))
        XCTAssertTrue(AICoachEngine.defaultTrendsPrompt.contains("no trend worth reporting"))
    }

    /// No two prompts are the same text. A copy-paste that forgot to change the body would pass
    /// every scope test above by accident if one prompt were simply duplicated.
    func testNoTwoPromptsAreIdentical() {
        let texts = allPrompts.map(\.text)
        XCTAssertEqual(Set(texts).count, texts.count, "two tab prompts are byte-identical")
    }

    /// Every prompt is user-overridable under its OWN key, so editing one tab's instructions cannot
    /// silently change another's.
    func testEveryPromptHasItsOwnOverrideKey() {
        let keys = [AICoachEngine.synthesisPromptKey,
                    AICoachEngine.dayQualityPromptKey,
                    AICoachEngine.trendsPromptKey,
                    AICoachEngine.sleepPromptKey]
        XCTAssertEqual(Set(keys).count, keys.count, "two tab prompts share a UserDefaults key")
        for key in keys {
            XCTAssertTrue(key.hasPrefix("ai."), "\(key) is outside the ai. namespace")
        }
    }
}
