import XCTest
@testable import Strand

/// The Shortcut chained onto each digest write (260924): the pure parts — the run URL a user-typed
/// name becomes, and the due rule behind "run at the delay, or at the next possible instance".
final class MuseShortcutRunnerTests: XCTestCase {

    /// The name is user-typed: spaces, ampersands and unicode must survive into a well-formed
    /// shortcuts:// URL, and a blank name is the OFF state, never a URL.
    func testRunURLEncodesTheTypedName() {
        XCTAssertEqual(MuseShortcutRunner.runURL(name: "Ship Digest")?.absoluteString,
                       "shortcuts://run-shortcut?name=Ship%20Digest")
        XCTAssertEqual(MuseShortcutRunner.runURL(name: "  Ship Digest  ")?.absoluteString,
                       "shortcuts://run-shortcut?name=Ship%20Digest", "surrounding whitespace is trimmed")
        XCTAssertEqual(MuseShortcutRunner.runURL(name: "Muse & NOOP")?.absoluteString,
                       "shortcuts://run-shortcut?name=Muse%20%26%20NOOP",
                       "& would otherwise start a second query parameter")
        XCTAssertNil(MuseShortcutRunner.runURL(name: ""))
        XCTAssertNil(MuseShortcutRunner.runURL(name: "   "))
    }

    /// Due exactly at or after the armed instant; an empty slot is never due. The slot survives a
    /// missed window because "run at the next possible instance" is the contract, so there is no
    /// expiry case to pin.
    func testDueRule() {
        XCTAssertFalse(MuseShortcutRunner.isDue(nowMs: 1_000, dueAtMs: nil))
        XCTAssertFalse(MuseShortcutRunner.isDue(nowMs: 999, dueAtMs: 1_000))
        XCTAssertTrue(MuseShortcutRunner.isDue(nowMs: 1_000, dueAtMs: 1_000))
        XCTAssertTrue(MuseShortcutRunner.isDue(nowMs: 999_999_999, dueAtMs: 1_000),
                      "a long-missed slot still fires at the next opportunity, never silently lapses")
    }
}
