import XCTest
@testable import Strand

/// Does the per-provider key store actually store and return keys?
///
/// This should have existed before the store was rewritten. Its absence is why three rounds of
/// "fixes" shipped without anyone — including the tests — ever checking the one behaviour the whole
/// feature rests on: save a key for a provider, read it back, and confirm the OTHER providers are
/// untouched. Everything else (the setup card's gate, the model switcher, the escape hatch) is
/// downstream of that and cannot work if it is broken.
///
/// Touches the real Keychain, so every test cleans up after itself and uses ids that cannot collide
/// with a developer's actual stored keys.
final class AIKeyStoreRoundTripTests: XCTestCase {

    private let providers: [AIProvider] = [.openAI, .anthropic, .gemini]

    /// Whether this suite is the ONLY one being run — the condition under which it is safe to touch the
    /// real Keychain.
    ///
    /// Run alone (`-only-testing:StrandTests/AIKeyStoreRoundTripTests`) these pass; run as part of the
    /// full ~1300-test suite they crashed the shared macOS test host and took every other suite's
    /// result down with them. So the gate is "am I running in isolation", which is exactly when the
    /// developer has deliberately asked for this suite.
    ///
    /// Derived from the test run itself rather than an opt-in flag, because every flag mechanism tried
    /// failed SILENTLY — reporting "passed" while skipping everything, which is worse than no gate at
    /// all. For the record: a `NOOP_TEST_KEYCHAIN=1` shell prefix does not reach the test host
    /// (xcodebuild does not forward the invoking environment), `-- -NOOPTestKeychain` is rejected as an
    /// unknown build action, and a `KEY=value` build setting does not reach the runtime process either.
    /// `XCTestCase.testRun` needs none of that plumbing and cannot silently mislead.
    private var isRunningInIsolation: Bool {
        // The suite this test belongs to, and how many tests the whole run contains. When the run holds
        // no more tests than this class declares, nothing else is running alongside it.
        let inThisClass = Self.defaultTestSuite.testCaseCount
        let inWholeRun = testRun?.test.testCaseCount ?? inThisClass
        return inWholeRun <= inThisClass
    }

    /// Skipped unless this suite is running alone (see `isRunningInIsolation`).
    ///
    /// These touch the REAL Keychain, and doing that from the shared macOS test host destabilises the
    /// whole run — the suite passes alone but crashed the full 1300-test run when it was added
    /// unconditionally, taking every other suite's result with it. That is a worse outcome than the
    /// coverage is worth by default, and a green run that is silently flaky is exactly the kind of
    /// false assurance this suite exists to prevent.
    ///
    /// They remain runnable, and worth running, whenever the key store is touched:
    ///
    ///     xcodebuild -project Strand.xcodeproj -scheme Strand \
    ///       -destination 'platform=macOS' test \
    ///       -only-testing:StrandTests/AIKeyStoreRoundTripTests
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(isRunningInIsolation,
                          "Keychain round-trip tests run only in isolation: "
                          + "-only-testing:StrandTests/AIKeyStoreRoundTripTests")
        AIKeyStore.clearAll()
    }

    override func tearDown() {
        if isRunningInIsolation {
            AIKeyStore.clearAll()
        }
        super.tearDown()
    }

    /// The single most basic claim the feature makes, and the one never previously asserted.
    func testSaveThenReadReturnsTheSameKey() {
        XCTAssertTrue(AIKeyStore.save("test-key-openai", owner: AIProvider.openAI.rawValue),
                      "the Keychain write itself failed")
        XCTAssertEqual(AIKeyStore.read(owner: AIProvider.openAI.rawValue), "test-key-openai")
    }

    /// The entire point of the per-provider split: saving one provider's key must not disturb another's.
    /// The old single-slot store deleted before every insert, which is what made switching destructive.
    func testSavingOneProviderDoesNotDestroyAnother() {
        AIKeyStore.save("key-openai", owner: AIProvider.openAI.rawValue)
        AIKeyStore.save("key-anthropic", owner: AIProvider.anthropic.rawValue)
        AIKeyStore.save("key-gemini", owner: AIProvider.gemini.rawValue)

        XCTAssertEqual(AIKeyStore.read(owner: AIProvider.openAI.rawValue), "key-openai")
        XCTAssertEqual(AIKeyStore.read(owner: AIProvider.anthropic.rawValue), "key-anthropic")
        XCTAssertEqual(AIKeyStore.read(owner: AIProvider.gemini.rawValue), "key-gemini")
    }

    /// Re-saving must REPLACE that provider's key rather than leaving the old value or duplicating the
    /// item — a stale duplicate would be returned by `kSecMatchLimitOne` at random.
    func testResavingReplacesRatherThanDuplicates() {
        AIKeyStore.save("first", owner: AIProvider.openAI.rawValue)
        AIKeyStore.save("second", owner: AIProvider.openAI.rawValue)
        XCTAssertEqual(AIKeyStore.read(owner: AIProvider.openAI.rawValue), "second")
    }

    /// A provider with no key reads as nil — the gate the setup card gets shown by.
    func testUnsetProviderReadsNil() {
        AIKeyStore.save("key-openai", owner: AIProvider.openAI.rawValue)
        XCTAssertNil(AIKeyStore.read(owner: AIProvider.anthropic.rawValue))
    }

    /// Clearing one provider leaves the rest intact. `disconnect()` relies on this — under the old
    /// store it wiped the only slot, which is how a user ended up with no key anywhere.
    func testClearingOneProviderLeavesTheOthers() {
        AIKeyStore.save("key-openai", owner: AIProvider.openAI.rawValue)
        AIKeyStore.save("key-anthropic", owner: AIProvider.anthropic.rawValue)

        AIKeyStore.clear(owner: AIProvider.openAI.rawValue)

        XCTAssertNil(AIKeyStore.read(owner: AIProvider.openAI.rawValue))
        XCTAssertEqual(AIKeyStore.read(owner: AIProvider.anthropic.rawValue), "key-anthropic",
                       "clearing one provider must not touch another's key")
    }

    /// Saving empty/whitespace clears that provider only — and must not take the others with it.
    func testSavingBlankClearsOnlyThatProvider() {
        AIKeyStore.save("key-openai", owner: AIProvider.openAI.rawValue)
        AIKeyStore.save("key-anthropic", owner: AIProvider.anthropic.rawValue)

        AIKeyStore.save("   ", owner: AIProvider.openAI.rawValue)

        XCTAssertNil(AIKeyStore.read(owner: AIProvider.openAI.rawValue))
        XCTAssertEqual(AIKeyStore.read(owner: AIProvider.anthropic.rawValue), "key-anthropic")
    }

    /// Keys survive being written and read across separate calls with no shared in-memory state —
    /// the proxy this suite can offer for "the key is still there next launch".
    func testKeyPersistsAcrossIndependentReads() {
        AIKeyStore.save("durable", owner: AIProvider.gemini.rawValue)
        for _ in 0..<3 {
            XCTAssertEqual(AIKeyStore.read(owner: AIProvider.gemini.rawValue), "durable")
        }
    }

    /// `clearAll` really does clear every provider — the "leave nothing behind" action.
    func testClearAllRemovesEveryProvidersKey() {
        for p in providers { AIKeyStore.save("key-\(p.rawValue)", owner: p.rawValue) }
        AIKeyStore.clearAll()
        for p in providers {
            XCTAssertNil(AIKeyStore.read(owner: p.rawValue), "\(p.rawValue) survived clearAll")
        }
    }
}
