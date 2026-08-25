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

    /// The failure that made the fallback look broken. A Gemini reasoning model can spend the whole
    /// shared token budget THINKING and return `finishReason: MAX_TOKENS` with no text parts — an
    /// empty reply, delivered fast over HTTP 200. That is not a timeout, so a timeout-only retry never
    /// fired and the heavy model simply produced nothing. It must earn the retry.
    func testEmptyReplyEarnsARetry() {
        XCTAssertTrue(AICoachError.emptyReply("finishReason MAX_TOKENS").deservesLighterModelRetry,
                      "a thinking-exhausted empty reply is the main heavy-model failure and must retry")
    }

    /// A timeout still earns it — the original case, unchanged.
    func testTimeoutEarnsARetry() {
        XCTAssertTrue(AICoachError.timedOut.deservesLighterModelRetry)
    }

    /// Everything a lighter model cannot fix must NOT retry: these fail identically on any model, so a
    /// second request only doubles the wait before showing the same error.
    func testFailuresALighterModelCannotFixDoNotRetry() {
        XCTAssertFalse(AICoachError.badKey.deservesLighterModelRetry,
                       "a rejected key is rejected by every model")
        XCTAssertFalse(AICoachError.rateLimited.deservesLighterModelRetry,
                       "a rate limit applies to the account, not the model")
        XCTAssertFalse(AICoachError.noKey.deservesLighterModelRetry)
        XCTAssertFalse(AICoachError.decode.deservesLighterModelRetry)
        XCTAssertFalse(AICoachError.server(500, "boom").deservesLighterModelRetry)
        XCTAssertFalse(AICoachError.network("offline").deservesLighterModelRetry)
        XCTAssertFalse(AICoachError.badCustomURL("nope").deservesLighterModelRetry)
        XCTAssertFalse(AICoachError.emptyQuestion.deservesLighterModelRetry)
        XCTAssertFalse(AICoachError.keySaveFailed.deservesLighterModelRetry)
    }

    /// The timeout message must NOT claim a retry happened: one only runs when a genuinely faster model
    /// exists to switch to, so asserting it unconditionally would send someone hunting for a second
    /// attempt that never occurred.
    func testTimeoutMessageDoesNotClaimARetryHappened() {
        let text = (AICoachError.timedOut.errorDescription ?? "").lowercased()
        XCTAssertFalse(text.contains("didn't finish either"),
                       "the message must not assert a retry that may never have run; got: \(text)")
        XCTAssertTrue(text.contains("too long"), "it should still name the cause; got: \(text)")
    }

    /// The request budget must comfortably exceed `URLSession.shared`'s 60 s default — the specific
    /// value that made a powerful model look like it produced nothing. These requests are
    /// non-streaming and capped at 4096 tokens, so a reasoning-class model writing a long answer passes
    /// 60 s and was being killed mid-generation every time.
    func testRequestTimeoutIsLongEnoughForALargeModel() {
        XCTAssertGreaterThan(AICoachEngine.requestTimeoutSeconds, 60,
                             "a budget at or under URLSession's 60 s default reproduces the original bug")
    }

    /// The constant is worthless if the session the app actually builds ignores it, so assert the
    /// configuration carries it rather than trusting that it was applied.
    func testDefaultSessionCarriesTheConfiguredTimeout() {
        let session = AICoachEngine.makeDefaultSession()
        XCTAssertEqual(session.configuration.timeoutIntervalForRequest,
                       AICoachEngine.requestTimeoutSeconds)
        XCTAssertGreaterThanOrEqual(session.configuration.timeoutIntervalForResource,
                                    AICoachEngine.requestTimeoutSeconds,
                                    "the resource ceiling must not undercut the per-request budget")
    }
}
