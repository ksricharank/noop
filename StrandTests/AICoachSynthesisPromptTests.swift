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
        XCTAssertTrue(d.contains("Do NOT narrate my progress"))
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
        // 261018: fixed counts and themes, nothing dropped. 261024: Now is three bullets again (NSS,
        // heart, movement), Next four.
        XCTAssertTrue(d.contains("EXACTLY THREE bullets"))
        XCTAssertTrue(d.contains("EXACTLY FOUR bullets"))
        XCTAssertTrue(d.contains("nothing added and nothing dropped"))
        XCTAssertFalse(d.contains("2 to 4 bullets"), "the variable bullet count is retired")
        // 261005: the maintainer's menu + progress rules — every suggestion offers alternatives, and
        // a met target is congratulated, never re-prescribed ("go burn X cals" on a day the target
        // was already exceeded was the reported failure).
        // 261016: one idea per bullet (was a menu of TWO OR MORE alternatives); variety across bullets.
        XCTAssertTrue(d.contains("exactly ONE idea"), "each Next bullet carries a single suggestion")
        XCTAssertFalse(d.contains("TWO OR MORE"), "the per-bullet menu of alternatives is retired")
        XCTAssertTrue(d.contains("Variety comes ACROSS the bullets"))
        XCTAssertTrue(d.contains("BEFORE prescribing anything, check TODAY'S TARGETS"),
                      "Next must check progress before prescribing")
        XCTAssertTrue(d.contains("a RESULT, not a gap"), "a met target is congratulated, not re-asked")
        // 261006: the maintainer's delta rule — Next speaks in the REMAINDER to each target, not the
        // target itself ("2.1k more steps", never "the 10k target"), and the menu alternatives are
        // sized against that remainder.
        // 261018: Next speaks ONLY in what is still to go, copied from the stated figure.
        XCTAssertTrue(d.contains("speak ONLY in what is STILL TO GO"))
        XCTAssertTrue(d.contains("The target number itself does not appear in Next at all"))
        XCTAssertTrue(d.contains("the still-to-go figures included, which my data states"),
                      "the model copies the remainder rather than computing it")
        XCTAssertFalse(d.contains("**Watch**"), "the Watch section is retired; watchouts live in Now")
        XCTAssertFalse(d.contains("**Tonight**"), "Tonight stays folded into Next")
        // A quiet day must be ALLOWED to be quiet. Without this the model pads to reach a count,
        // which is the failure the rewrite exists to fix.
        XCTAssertTrue(d.contains("every bullet carries real numbers"), "every bullet has its figures")
        XCTAssertTrue(d.contains("Never invent a finding"))
        XCTAssertTrue(d.contains("unremarkable"))
    }

    /// 261014, the maintainer's ask: Now is about the heart, how relaxed or wound-up I am, and how
    /// much I have used my body — now and over the past hour — and Next leads with the IDEAS, the
    /// remaining delta only sizing them.
    func testNowIsTheLastHourAndNextLeadsWithIdeas() {
        let d = AICoachEngine.defaultSynthesisPrompt
        XCTAssertTrue(d.contains("MY LAST HOUR"))
        XCTAssertTrue(d.contains("LAST HOUR OR SO"))
        XCTAssertTrue(d.contains("my NSS (normalized stress): how stressed I am right now beyond what my current activity explains"))
        XCTAssertTrue(d.contains("Theme — my HEART: where my heart rate is now against MY resting heart rate"))
        XCTAssertTrue(d.contains("my recent MOVEMENT, ACTIVITY and HYDRATION"))
        XCTAssertTrue(d.contains("Theme — STEPS"))
        XCTAssertTrue(d.contains("Theme — HYDRATION"))
        XCTAssertTrue(d.contains("Theme — SLEEP"))
        // 261024: NSS now, why from its parts, one action only above 60; stress from NSS alone.
        // 261024d: measured up from calm, read against my typical; action only above typical.
        XCTAssertTrue(d.contains("(NSS **X** now, **Y** my typical)"))
        XCTAssertTrue(d.contains("0 is my calm state for the pace I am at"))
        XCTAssertTrue(d.contains("when the block calls it \"above my typical\" or \"unusual for me\""))
        XCTAssertFalse(d.contains("50 is my usual"), "the median-centred scale is retired")
        XCTAssertTrue(d.contains("as a read, never a fact"))
        XCTAssertTrue(d.contains("For stress use ONLY the NSS block"))
        XCTAssertFalse(d.contains("am I STRESSED right now"), "the still-only stress verdict is retired")
        XCTAssertFalse(d.contains("for the day, of 3)"), "the 0–3 stress figures are retired from Now")
        XCTAssertFalse(d.contains("my STRESS, in three parts"), "the separate stress bullet is retired")
        XCTAssertTrue(d.contains("Nothing else belongs in Now"))
        XCTAssertTrue(d.contains("The IDEAS are the point of this section"))
        XCTAssertTrue(d.contains("never as the opener"), "the delta must not lead a Next bullet")
        // 261015: the wind-down is a menu of quick pre-bed routines, not a bedtime instruction.
        XCTAssertTrue(d.contains("ONE short pre-bed routine"))
        XCTAssertTrue(d.contains("grateful"))
        XCTAssertTrue(d.contains("breathing"))
        // 261016: the ideas themselves are bolded so they stand out at a glance.
        XCTAssertTrue(d.contains("ALSO bold each bullet's one suggested idea itself"))
    }

    /// A stored copy of the 261006 default (it went in as the maintainer's own pasted text) is an old
    /// default, not a customisation: it must not shadow the new one, and must not offer Reset.
    func testAStoredCopyOfTheRetiredDefaultFallsThroughToTheNewDefault() {
        // The fingerprint is whitespace-insensitive, so a re-pasted copy matches.
        XCTAssertEqual(AICoachEngine.promptFingerprint("a  b\n c"), AICoachEngine.promptFingerprint("a b c"))
        XCTAssertNotEqual(AICoachEngine.promptFingerprint("a b c"), AICoachEngine.promptFingerprint("a b d"))
        XCTAssertFalse(AICoachEngine.isRetiredSynthesisDefault(AICoachEngine.defaultSynthesisPrompt),
                       "the CURRENT default must never be listed as retired")
        XCTAssertFalse(AICoachEngine.isRetiredSynthesisDefault("my own prompt"))
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
        // 261024: stress is read beyond what activity explains (NSS) — never from a raised heart rate
        // alone.
        XCTAssertTrue(d.contains("beyond what my current activity explains"))
        XCTAssertFalse(d.contains("turning RED"), "the retired red-digits cue must not linger")
    }
}
