import XCTest
@testable import Strand

/// The one-shot timeout fallback: which failures earn a retry, and which model the retry uses.
///
/// The retry spends a second request on the user's behalf, so the rules around it are worth pinning.
/// Retrying the wrong class of failure (a rejected key, a rate limit) doubles the wait before showing
/// an error that was never going to change; retrying on the wrong model wastes the attempt on
/// something no faster than the one that just timed out.
final class AICoachTimeoutFallbackTests: XCTestCase {

    /// Every cloud provider must name a fallback, or a timeout on it silently retries the same model
    /// and the feature does nothing. The ids are asserted exactly because "the cheapest one" is a claim
    /// about each provider's catalogue, not something derivable at runtime.
    func testCloudProvidersNameACheapestModel() {
        XCTAssertEqual(AIProvider.openAI.cheapestModel, "gpt-4.1-nano")
        XCTAssertEqual(AIProvider.anthropic.cheapestModel, "claude-haiku-4-5-20251001")
        XCTAssertEqual(AIProvider.gemini.cheapestModel, "gemini-flash-lite-latest")
    }

    /// Custom deliberately has none: it points at whatever server the user runs, so there is no basis
    /// for calling one of its ids cheaper. `callProvider` falls back to the SAME model in that case
    /// rather than inventing one, which is the documented behaviour and the reason this is nil.
    func testCustomHasNoCheapestModel() {
        XCTAssertNil(AIProvider.custom.cheapestModel)
    }

    /// The fallback id must be one the provider actually serves — a typo here turns every timeout into
    /// a second failure, and a model-not-found is a worse error than the timeout it replaced.
    func testCheapestModelIsInTheProvidersOwnCatalogue() {
        for provider in AIProvider.allCases {
            guard let cheapest = provider.cheapestModel else { continue }
            XCTAssertTrue(provider.modelOptions.contains(cheapest),
                          "\(provider.rawValue)'s cheapest model \(cheapest) is not in its own "
                          + "modelOptions, so the fallback would request an id the picker never offers")
        }
    }

    /// A plain timeout retries. A stalled connection reaped mid-request retries too — on a long LLM
    /// call that is overwhelmingly a slow request being cut off, not a real link drop.
    func testTimeoutCodesEarnARetry() {
        XCTAssertTrue(AICoachError.isTimeoutCode(.timedOut))
        XCTAssertTrue(AICoachError.isTimeoutCode(.networkConnectionLost))
    }

    /// Fail-fast connection errors do NOT retry: the endpoint is wrong or unreachable, and a cheaper
    /// model against the same URL fails identically. Retrying would only double the wait.
    func testUnreachableHostDoesNotEarnARetry() {
        XCTAssertFalse(AICoachError.isTimeoutCode(.cannotConnectToHost))
        XCTAssertFalse(AICoachError.isTimeoutCode(.cannotFindHost))
        XCTAssertFalse(AICoachError.isTimeoutCode(.notConnectedToInternet))
        XCTAssertFalse(AICoachError.isTimeoutCode(.userAuthenticationRequired))
    }

    /// The timeout message must say a fallback was already attempted — otherwise the user reads it as
    /// "try again" and repeats by hand what the app already did for them.
    func testTimeoutMessageMentionsTheRetry() {
        let text = AICoachError.timedOut.errorDescription ?? ""
        XCTAssertTrue(text.lowercased().contains("retry") || text.lowercased().contains("faster"),
                      "the message should say a faster-model retry was already tried; got: \(text)")
    }
}
