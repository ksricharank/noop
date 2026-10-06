import XCTest
@testable import Strand

/// Covers the editable Today-synthesis instruction: persisted under
/// `AICoachEngine.synthesisPromptKey`, read FRESH per generation via `synthesisPrompt`, with a
/// Reset-to-default that clears the override.
///
/// A sibling of the coach-prompt cases in `AICoachPromptAndStressTests`, kept separate because the
/// two prompts frame different surfaces and must not leak into one another — the last test here is
/// the one that would catch a copy-paste that pointed both editors at the same key.
///
/// UserDefaults-only — no network, no Keychain — so it runs headlessly.
@MainActor
final class AICoachSynthesisPromptTests: XCTestCase {

    private func makeEngine() -> AICoachEngine {
        UserDefaults.standard.removeObject(forKey: AICoachEngine.synthesisPromptKey)
        UserDefaults.standard.removeObject(forKey: AICoachEngine.systemPromptKey)
        return AICoachEngine(repo: Repository(deviceId: "test-aicoach-synthesis-prompt"))
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AICoachEngine.synthesisPromptKey)
        UserDefaults.standard.removeObject(forKey: AICoachEngine.systemPromptKey)
        super.tearDown()
    }

    func testDefaultsToBuiltInPromptWhenNothingStored() {
        let engine = makeEngine()
        XCTAssertEqual(engine.synthesisPrompt, AICoachEngine.defaultSynthesisPrompt)
        XCTAssertFalse(engine.hasCustomSynthesisPrompt)
    }

    func testEditPersistsAndIsReadFreshOnNextRefresh() {
        let engine = makeEngine()
        let custom = "Write two sentences on today, mentioning my charge."
        engine.customSynthesisPrompt = custom

        XCTAssertEqual(UserDefaults.standard.string(forKey: AICoachEngine.synthesisPromptKey), custom)
        XCTAssertEqual(engine.synthesisPrompt, custom)
        XCTAssertTrue(engine.hasCustomSynthesisPrompt)

        // Read fresh per generation: a write straight to UserDefaults is picked up without a rebuild.
        let edited = custom + " Never greet me."
        UserDefaults.standard.set(edited, forKey: AICoachEngine.synthesisPromptKey)
        XCTAssertEqual(engine.synthesisPrompt, edited)
    }

    func testResetRestoresDefaultAndClearsTheKey() {
        let engine = makeEngine()
        engine.customSynthesisPrompt = "Custom override."
        XCTAssertTrue(engine.hasCustomSynthesisPrompt)

        engine.resetSynthesisPrompt()
        XCTAssertNil(UserDefaults.standard.string(forKey: AICoachEngine.synthesisPromptKey))
        XCTAssertEqual(engine.synthesisPrompt, AICoachEngine.defaultSynthesisPrompt)
        XCTAssertFalse(engine.hasCustomSynthesisPrompt)
    }

    func testBlankOverrideNeverSendsAnEmptyInstruction() {
        let engine = makeEngine()
        engine.customSynthesisPrompt = "   \n  "   // whitespace only
        XCTAssertNil(UserDefaults.standard.string(forKey: AICoachEngine.synthesisPromptKey))
        XCTAssertEqual(engine.synthesisPrompt, AICoachEngine.defaultSynthesisPrompt)
        XCTAssertFalse(engine.hasCustomSynthesisPrompt)
    }

    /// The two prompts are independent: editing one must not disturb the other, in either direction.
    func testSynthesisAndCoachPromptsAreIndependent() {
        let engine = makeEngine()

        engine.customSynthesisPrompt = "Synthesis override."
        XCTAssertEqual(engine.systemPrompt, AICoachEngine.defaultSystemPrompt)
        XCTAssertFalse(engine.hasCustomSystemPrompt)

        engine.customSystemPrompt = "Coach override."
        XCTAssertEqual(engine.synthesisPrompt, "Synthesis override.")
        XCTAssertTrue(engine.hasCustomSynthesisPrompt)

        // Resetting one leaves the other standing.
        engine.resetSystemPrompt()
        XCTAssertEqual(engine.synthesisPrompt, "Synthesis override.")
        XCTAssertEqual(engine.systemPrompt, AICoachEngine.defaultSystemPrompt)
    }

    /// 260919: the three mandated sections are GONE. They guaranteed a drab summary — three
    /// headings to fill whether or not anything had happened, so the model padded the quiet ones
    /// and a genuinely unusual reading sat in the same typeface as the filler around it.
    ///
    /// What replaces them is salience: lead with what actually deviates from the wearer's own
    /// baselines, and say plainly when nothing does. These pin that intent, because a future edit
    /// that quietly reintroduces a fixed template would restore exactly the behaviour complained of.
    func testDefaultNamesTheSurfaceAndAsksForWhatIsNotable() {
        let d = AICoachEngine.defaultSynthesisPrompt
        XCTAssertTrue(d.contains("Today screen"))
        XCTAssertTrue(d.contains("MY BODY IN THE PRESENT"))
        // 260919: the prompt no longer says "summarise every metric" — it now fences the targets
        // explicitly instead, which is the stronger form of the same instruction and is what the
        // reported failure ("a plain recap of the targets") actually needed.
        XCTAssertTrue(d.contains("Do NOT narrate my progress against them"))
        XCTAssertTrue(d.contains("LAST 6 HOURS"))
        // Salience, in the model's own terms: the wearer's baselines, not population norms.
        XCTAssertTrue(d.contains("z-scores"))
        XCTAssertTrue(d.contains("MY OWN baseline"))
        XCTAssertTrue(d.contains("NOT news"))
        XCTAssertTrue(d.contains("watchout"))
        // 260919: "trend" is deliberately NOT pinned here any more. Today gained three sibling
        // summaries, and the multi-week read is the Trends tab's lens — pinning it on this prompt
        // would re-create the overlap the split exists to remove. Today may still reach back a few
        // days, but only far enough to explain the present.
        XCTAssertTrue(d.contains("only far enough to make right"))
        // The agreement contract with the Lock-Screen card survives the rewrite untouched.
        XCTAssertTrue(d.contains("TODAY'S TARGETS"))
        XCTAssertTrue(d.contains("total calories"))
        // 261004: Now and Next became real section lines with bullets beneath (maintainer ask), so
        // the blanket "No headings" pin is replaced by the exact two-section contract: those two and
        // nothing else, Watch retired (a forming watchout now rides inside Now), Tonight stays folded.
        XCTAssertTrue(d.contains("**Now**"))
        XCTAssertTrue(d.contains("**Next**"))
        XCTAssertTrue(d.contains("no other headings"))
        XCTAssertTrue(d.contains("2 to 4 bullets"), "Now must be richer than one line")
        // 261005: the maintainer's menu + progress rules — every suggestion offers alternatives, and
        // a met target is congratulated, never re-prescribed ("go burn X cals" on a day the target
        // was already exceeded was the reported failure).
        XCTAssertTrue(d.contains("TWO OR MORE"), "every suggestion must be a menu of alternatives")
        XCTAssertTrue(d.contains("ALREADY done today"), "Next must check progress before prescribing")
        XCTAssertTrue(d.contains("a RESULT, not a gap"), "a met target is congratulated, not re-asked")
        // 261006: the maintainer's delta rule — Next speaks in the REMAINDER to each target, not the
        // target itself ("2.1k more steps", never "the 10k target"), and the menu alternatives are
        // sized against that remainder.
        XCTAssertTrue(d.contains("DELTA between the TARGET"),
                      "menu alternatives are sized against the remaining delta")
        XCTAssertTrue(d.contains("INSTEAD of mentioning the target, mention the DELTA"),
                      "Next speaks in what remains, not in the target the screen already shows")
        XCTAssertFalse(d.contains("**Watch**"), "the Watch section is retired; watchouts live in Now")
        XCTAssertFalse(d.contains("**Tonight**"), "Tonight stays folded into Next")
        // A quiet day must be ALLOWED to be quiet. Without this the model pads to reach a count,
        // which is the failure the rewrite exists to fix.
        XCTAssertTrue(d.contains("FEWER IS BETTER"))
        XCTAssertTrue(d.contains("Never invent a finding"))
        XCTAssertTrue(d.contains("unremarkable"))
    }

    /// The retired three-section template must not creep back. Each of these strings was load-
    /// bearing in the shape the maintainer asked to be rid of.
    func testTheRetiredFixedSectionTemplateIsGone() {
        let d = AICoachEngine.defaultSynthesisPrompt
        XCTAssertFalse(d.contains("**Heart**"), "the mandated Heart section must not return")
        XCTAssertFalse(d.contains("**Activity**"), "the mandated Activity section must not return")
        XCTAssertFalse(d.contains("**Rest & sleep**"), "the mandated Rest & sleep section must not return")
        XCTAssertFalse(d.contains("three titled sections"))
        // 260919: fenced off the other three tabs' lenses, now that each has its own summary.
        XCTAssertFalse(d.contains("grade yesterday as a finished day") == false && d.contains("Do NOT") == false,
                       "Today must be fenced off the other tabs")
        XCTAssertFalse(d.contains("blank line between sections"))
        XCTAssertFalse(d.contains("STRESSED"), "the retired live verdict must not linger")
        XCTAssertFalse(d.contains("turning RED"), "the retired red-digits cue must not linger")
    }
}
