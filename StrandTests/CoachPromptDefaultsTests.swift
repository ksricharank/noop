import XCTest
@testable import Strand

/// "My default" prompts (261024g): an edit the wearer promotes becomes the default the getters fall
/// back to; a build that adopts it verbatim retires the saved copy; and the strap-log export carries
/// the saved text so a later build can read it.
@MainActor
final class CoachPromptDefaultsTests: XCTestCase {

    private func suite() -> UserDefaults { UserDefaults(suiteName: "coach-prompt-defaults-\(UUID().uuidString)")! }

    func testMyDefaultWinsOverTheBuiltInUntilTheBuildAdoptsIt() {
        let d = suite()
        let key = AICoachEngine.trendsPromptKey
        XCTAssertEqual(AICoachEngine.effectiveDefault("BUILT-IN", key: key, defaults: d), "BUILT-IN")
        d.set("  mine  ", forKey: AICoachEngine.myDefaultKey(key))
        XCTAssertEqual(AICoachEngine.effectiveDefault("BUILT-IN", key: key, defaults: d), "mine")
        // Not adopted yet: absorption keeps it.
        AICoachEngine.absorbMyDefaultsIntoBuild(defaults: d)
        XCTAssertNotNil(AICoachEngine.myDefault(key, defaults: d))
        // Adopted verbatim (whitespace aside) by the build: the saved copy is retired.
        d.set(AICoachEngine.defaultTrendsPrompt.replacingOccurrences(of: " ", with: "  "),
              forKey: AICoachEngine.myDefaultKey(key))
        AICoachEngine.absorbMyDefaultsIntoBuild(defaults: d)
        XCTAssertNil(AICoachEngine.myDefault(key, defaults: d))
    }

    func testTheExportCarriesSavedDefaultsAndEditsVerbatim() {
        let d = suite()
        d.set("my sleep prompt", forKey: AICoachEngine.myDefaultKey(AICoachEngine.sleepPromptKey))
        d.set("an edit in progress", forKey: AICoachEngine.insightPromptKey)
        let text = AICoachEngine.promptExportLines(defaults: d).joined(separator: "\n")
        XCTAssertTrue(text.contains("Sleep summary instructions [ai.sleepPrompt]: MY DEFAULT"), text)
        XCTAssertTrue(text.contains(">>> MY DEFAULT — ai.sleepPrompt\nmy sleep prompt\n  <<< END MY DEFAULT"), text)
        XCTAssertTrue(text.contains("Daily insight instructions [ai.insightPrompt]: EDITED"), text)
        XCTAssertTrue(text.contains("an edit in progress"), text)
        XCTAssertTrue(text.contains("Coach instructions [ai.systemPrompt]: built-in"), text)
    }
}
