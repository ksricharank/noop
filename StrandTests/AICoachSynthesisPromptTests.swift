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

    /// The default is the instruction the Today turn actually shipped with before it became editable.
    func testDefaultNamesTheSurfaceAndItsShape() {
        let d = AICoachEngine.defaultSynthesisPrompt
        XCTAssertTrue(d.contains("Today screen"))
        XCTAssertTrue(d.contains("paragraph"))
        XCTAssertTrue(d.contains("No headings, no lists, no greeting."))
    }
}
