import XCTest
@testable import Strand

/// The on-device coach provider (260922): the pure parts — the context budget that keeps a request
/// inside the 4,096-token window, the stream-snapshot-to-delta rule, and the provider's wiring — pinned
/// without the framework, which cannot run under `xcodebuild test` on a Mac without Apple Intelligence.
final class AppleOnDeviceProviderTests: XCTestCase {

    private typealias Wire = (role: ChatMessage.Role, content: String)

    // MARK: Provider wiring

    /// Keyless and self-describing: one model id, no lighter fallback, and the catalogue call returns
    /// the same single id the picker seeds — so `refreshModels` on this provider is a no-op, not a
    /// blank list.
    func testProviderIsKeylessWithOneModel() async throws {
        let p = AIProvider.appleOnDevice
        XCTAssertTrue(p.isKeyless)
        XCTAssertNil(p.cheapestModel)
        XCTAssertEqual(p.modelOptions, [AppleOnDeviceModel.modelID])
        XCTAssertEqual(p.defaultModel, AppleOnDeviceModel.modelID)
        let ids = try await p.client.fetchModels(key: "", session: .shared)
        XCTAssertEqual(ids, [AppleOnDeviceModel.modelID])
        XCTAssertFalse(AIProvider.openAI.isKeyless)
        XCTAssertFalse(AIProvider.custom.isKeyless, "Custom is keyless only once connected — not by type")
    }

    /// The picker never offers a provider that cannot run here. Whatever this Mac's answer is, the
    /// selectable list must agree with the availability probe, and the four network providers are
    /// always offered.
    func testSelectableHidesTheOnDeviceModelWhereItCannotRun() {
        let selectable = AIProvider.selectable
        XCTAssertEqual(selectable.contains(.appleOnDevice), AppleOnDeviceModel.isAvailable)
        for p in [AIProvider.openAI, .anthropic, .gemini, .custom] {
            XCTAssertTrue(selectable.contains(p))
        }
    }

    /// Both new failures are terminal: there is no lighter model, and a context that overflowed once
    /// overflows again. Retrying them would only double the wait before the same message.
    func testOnDeviceFailuresAreNotRetried() {
        XCTAssertFalse(AICoachError.contextTooLarge.deservesLighterModelRetry)
        XCTAssertFalse(AICoachError.onDevice("declined").deservesLighterModelRetry)
        XCTAssertEqual(AICoachError.onDevice("declined").errorDescription, "declined")
        XCTAssertEqual(AICoachError.onDevice("x").shortLabel, "on-device model")
        XCTAssertEqual(AICoachError.contextTooLarge.shortLabel, "too much context")
    }

    // MARK: Context budget

    /// Under budget, nothing changes — byte for byte.
    func testFitLeavesASmallRequestAlone() {
        let msgs: [Wire] = [(.user, "DATA\n\n---\n\nQuestion: how did I sleep?"), (.assistant, "Fine."), (.user, "And today?")]
        let fitted = OnDeviceContextBudget.fit(msgs, maxChars: 1_000)
        XCTAssertEqual(fitted.map(\.content), msgs.map(\.content))
        XCTAssertEqual(fitted.map(\.role), msgs.map(\.role))
    }

    /// Over budget, the oldest MIDDLE turns go first and the two anchors stay: the first user turn (it
    /// carries the data context) and the last (the question being asked).
    func testFitDropsTheOldestMiddleTurnsFirst() {
        let first = String(repeating: "d", count: 400)
        let msgs: [Wire] = [(.user, first), (.assistant, String(repeating: "a", count: 300)),
                            (.user, String(repeating: "b", count: 300)), (.assistant, String(repeating: "c", count: 300)),
                            (.user, "latest question")]
        let fitted = OnDeviceContextBudget.fit(msgs, maxChars: 800)
        XCTAssertEqual(fitted.count, 3, "two middle turns dropped, the third fits")
        XCTAssertEqual(fitted.first?.content, first)
        XCTAssertEqual(fitted.last?.content, "latest question")
        XCTAssertEqual(fitted[1].content, String(repeating: "c", count: 300),
                       "the NEWEST middle turn survives, not the oldest")
        XCTAssertLessThanOrEqual(fitted.reduce(0) { $0 + $1.content.count }, 800)
    }

    /// When even the two anchors overflow, the longer one loses its MIDDLE: the head (newest day-lines,
    /// printed newest-first) and the tail (the question or the tab's instruction) both survive, with a
    /// visible seam so the model does not read across the cut.
    func testFitTrimsTheMiddleOfTheLongestMessageKeepingHeadAndTail() {
        let head = "USER BIOMETRIC SUMMARY\n" + String(repeating: "2026-09-21 charge 62 hrv 48\n", count: 200)
        let tail = "\n\n---\n\nQuestion: what should I do today?"
        let msgs: [Wire] = [(.user, head + tail)]
        let fitted = OnDeviceContextBudget.fit(msgs, maxChars: 2_000)
        XCTAssertEqual(fitted.count, 1)
        let out = fitted[0].content
        XCTAssertLessThanOrEqual(out.count, 2_000)
        XCTAssertTrue(out.hasPrefix("USER BIOMETRIC SUMMARY\n2026-09-21"))
        XCTAssertTrue(out.hasSuffix(tail))
        XCTAssertTrue(out.contains(OnDeviceContextBudget.marker))
    }

    /// A tail large enough for the coach's longest instruction block. The tab prompts run to ~2,000
    /// characters and ride at the END of a single-turn request; a trim that kept less than that would
    /// hand the model half an instruction, which it follows literally.
    func testTrimKeepsAtLeastTheInstructionSizedTail() {
        let allowed = OnDeviceContextBudget.defaultChars
        let text = String(repeating: "x", count: 30_000) + String(repeating: "I", count: 2_000)
        let out = OnDeviceContextBudget.trimMiddle(text, to: allowed)
        XCTAssertLessThanOrEqual(out.count, allowed)
        XCTAssertTrue(out.hasSuffix(String(repeating: "I", count: 2_000)))
    }

    /// The default budget is what the design note says: sized so instructions + data + a 600-token
    /// answer fit the 4,096-token window with number-dense text at ~3 characters a token.
    func testDefaultBudgetLeavesRoomForInstructionsAndTheAnswer() {
        let promptTokens = OnDeviceContextBudget.defaultChars / 3
        let instructionTokens = (AICoachEngine.defaultSystemPrompt.count
                                 + AICoachEngine.onDeviceInstructionSuffix.count) / 3
        XCTAssertLessThan(promptTokens + instructionTokens + AppleOnDeviceClient.maxResponseTokens, 4_096)
    }

    // MARK: Stream snapshots → deltas

    /// Apple's stream yields the whole answer so far; the coach appends deltas. The rule emits exactly
    /// the new suffix, and nothing for a snapshot that does not extend the previous one.
    func testDeltaEmitsOnlyTheNewSuffix() {
        XCTAssertEqual(OnDeviceContextBudget.delta(previous: "", cumulative: "Your"), "Your")
        XCTAssertEqual(OnDeviceContextBudget.delta(previous: "Your", cumulative: "Your charge"), " charge")
        XCTAssertEqual(OnDeviceContextBudget.delta(previous: "Your charge", cumulative: "Your charge"), "")
        XCTAssertEqual(OnDeviceContextBudget.delta(previous: "Your charge", cumulative: "Revised"), "",
                       "a rewrite is not appended on top of the text already shown")
    }

    /// Concatenating the deltas of a monotonic stream reproduces the final snapshot — the append-only
    /// contract `AIProviderClient.stream` promises.
    func testDeltasReassembleTheFinalSnapshot() {
        let snapshots = ["Sleep", "Sleep was", "Sleep was short:", "Sleep was short: 6h 12m."]
        var shown = ""
        var emitted = ""
        for s in snapshots {
            let d = OnDeviceContextBudget.delta(previous: emitted, cumulative: s)
            if !d.isEmpty { emitted = s; shown += d }
        }
        XCTAssertEqual(shown, snapshots.last)
    }

    // MARK: Engine

    /// The rider is appended only while the on-device model answers, and the wearer's editable prompt
    /// is untouched by it — switching provider must never rewrite their instructions.
    @MainActor
    func testOnDeviceRiderIsAppendedOnlyForThatProvider() async throws {
        let engine = AICoachEngine(repo: Repository(deviceId: "test-aicoach-on-device"))
        let before = engine.provider
        defer { engine.provider = before }
        engine.provider = .gemini
        XCTAssertEqual(engine.effectiveSystemPrompt, engine.systemPrompt)
        engine.provider = .appleOnDevice
        XCTAssertTrue(engine.effectiveSystemPrompt.hasPrefix(engine.systemPrompt))
        XCTAssertTrue(engine.effectiveSystemPrompt.hasSuffix(AICoachEngine.onDeviceInstructionSuffix))
        XCTAssertEqual(engine.model, AppleOnDeviceModel.modelID)
        XCTAssertEqual(engine.isConfigured, AppleOnDeviceModel.isAvailable,
                       "keyless: configured exactly when the device can run it")
    }
}
