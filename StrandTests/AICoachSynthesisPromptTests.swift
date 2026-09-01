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

    /// The default names the surface and its three-bullet shape (260829): the card-mirroring labels
    /// in their stated order, explain-before-prescribe, other metrics only when strictly relevant,
    /// and the instruction to cite the deterministic TODAY'S TARGETS rather than invent parallel
    /// numbers — the agreement contract with the Lock-Screen card.
    func testDefaultNamesTheSurfaceAndItsShape() {
        let d = AICoachEngine.defaultSynthesisPrompt
        XCTAssertTrue(d.contains("Today screen"))
        XCTAssertTrue(d.contains("**Heart**"))
        XCTAssertTrue(d.contains("**Activity**"))
        XCTAssertTrue(d.contains("**Rest & sleep**"))
        XCTAssertTrue(d.contains("BEFORE prescribing"))
        XCTAssertTrue(d.contains("only when it strictly serves"))
        XCTAssertTrue(d.contains("TODAY'S TARGETS"))
        XCTAssertTrue(d.contains("No greeting"))
        // The Heart section is about the heart's TRAJECTORY (260830, second revision): overall
        // state, trends vs personal baselines, watchouts — never a this-minute verdict. The
        // live-read vocabulary (calm/STRESSED/not judgeable, the red digits) left with the card's
        // HR column; the z-score framing is explained so the model can actually use the baselines.
        XCTAssertTrue(d.contains("resting heart rate"))
        XCTAssertTrue(d.contains("z-scores"))
        XCTAssertTrue(d.contains("watchout"))
        XCTAssertTrue(d.contains("total calories"))
        // Fourth revision (260830 night — prose sections still read as "a wall of text"): each
        // section is a bold title, ONE ten-word bolded takeaway line, then 2-4 fragment sub-bullets
        // ("Thing — fact"), numbers bolded. The format rules are stated to the model verbatim.
        XCTAssertTrue(d.contains("OWN line"))
        XCTAssertTrue(d.contains("takeaway line"))
        XCTAssertTrue(d.contains("sub-bullets"))
        XCTAssertTrue(d.contains("never a full flowing sentence"))
        XCTAssertTrue(d.contains("blank line between sections"))
        XCTAssertFalse(d.contains("markdown bullets"), "the retired everything-is-one-bullet shape must not linger")
        XCTAssertFalse(d.contains("STRESSED"), "the retired live verdict must not linger")
        XCTAssertFalse(d.contains("turning RED"), "the retired red-digits cue must not linger")
        XCTAssertFalse(d.contains("calm ceiling"), "the retired ceiling must not linger in the prompt")
        XCTAssertFalse(d.contains("elevated,"), "undefined 'elevated' phrasing must not return")
    }
}
