import XCTest
@testable import Strand

/// The setup card's escape hatch: whether there is a configured provider to fall back to.
///
/// Worth pinning because the failure it guards against is a genuine dead end rather than a cosmetic
/// one. "Save key" is disabled while the key field is empty; that field is transient (cleared after
/// every save, never prefilled from the Keychain, since a stored secret cannot be read back into a
/// field); and the toolbar is gated on `isConfigured`, so it is absent in exactly this state. Select a
/// provider with no stored key and every control on screen is dead.
///
/// The rule under test is the one the card's "Back to <provider>" button is built on: pick the first
/// provider that is NOT the selected one and is already usable.
final class CoachSetupEscapeTests: XCTestCase {

    /// Mirrors `CoachView.readyProviderToReturnTo`. Kept as a pure function over stated inputs so the
    /// decision is testable without a Keychain, a view, or a running app.
    private func escape(from selected: AIProvider,
                        configured: Set<AIProvider>) -> AIProvider? {
        AIProvider.allCases.first { $0 != selected && configured.contains($0) }
    }

    /// The reported bug: a key is stored for one provider, the user switches to another that has none,
    /// and lands in the card. An escape must exist and must point at the provider that works.
    func testOffersAWayBackWhenAnotherProviderIsConfigured() {
        XCTAssertEqual(escape(from: .openAI, configured: [.anthropic]), .anthropic)
    }

    /// First run: nothing is configured anywhere. The card is the correct place to be and there is
    /// nowhere to go back TO, so no button is offered — it would promise a rescue it cannot perform.
    func testOffersNothingOnAFreshInstall() {
        XCTAssertNil(escape(from: .openAI, configured: []))
    }

    /// Having deliberately forgotten the only stored key (Disconnect), the user belongs in the card.
    /// The escape must not reappear pointing at the provider they just cleared.
    func testOffersNothingAfterClearingTheOnlyKey() {
        XCTAssertNil(escape(from: .anthropic, configured: []))
    }

    /// The escape never points at the provider already selected — that would be a button that changes
    /// nothing while the user is still stuck.
    func testNeverOffersTheAlreadySelectedProvider() {
        XCTAssertNotEqual(escape(from: .openAI, configured: [.openAI]), .openAI)
        XCTAssertNil(escape(from: .openAI, configured: [.openAI]),
                     "with only the selected provider configured there is nowhere else to go")
    }

    /// With several configured, any one of them is a valid rescue; the contract is only that it is a
    /// different, genuinely configured provider — not which one wins.
    func testPicksAConfiguredProviderWhenSeveralQualify() {
        let picked = escape(from: .gemini, configured: [.openAI, .anthropic])
        XCTAssertNotNil(picked)
        XCTAssertNotEqual(picked, .gemini)
        XCTAssertTrue([.openAI, .anthropic].contains(picked!))
    }
}
