import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Apple Intelligence, on-device (260922)
//
// The one coach provider that never opens a socket. Apple's FoundationModels framework exposes the
// ~3B-parameter language model behind Apple Intelligence to third-party apps from iOS 26 / macOS 26,
// running entirely on the device's Neural Engine. No key, no account, no network: it is the provider
// that fits NOOP's offline-by-default posture without a caveat, and the one that keeps working on a
// plane or with the data switch off.
//
// It is a SMALL model. Two consequences are handled here rather than left for the wearer to hit:
//   - a 4,096-token context window, shared between the instructions, the data, the history and the
//     answer. The coach's own context (a fortnight of day-lines, targets, the last six hours,
//     optionally the derived-trends block) plus a tab's facts block can exceed that. Every request
//     passes through `OnDeviceContextBudget.fit` first; a request the model still turns away for size
//     is retried ONCE at half the budget, then reported as `.contextTooLarge`.
//   - Apple's guardrails can decline a prompt outright. That is surfaced as what it is, so the wearer
//     sees "declined under its safety rules" rather than a generic failure.
//
// No Android twin: FoundationModels is Apple-only, and the Android coach keeps its own provider list.
// Fork-only surface.

/// Availability of Apple's on-device model on THIS device, answered without instantiating a session.
enum AppleOnDeviceModel {

    /// The single "model id" the provider reports — there is exactly one on-device model and the
    /// system picks its version, so the picker shows one stable entry.
    static let modelID = "on-device"

    /// True when the on-device model can answer right now: the OS is new enough, the framework is
    /// linked, the device qualifies, Apple Intelligence is on and the model assets are present.
    static var isAvailable: Bool { unavailabilityNote == nil }

    /// Why the on-device model cannot be used, in the wearer's terms, or nil when it can.
    /// The wording is what the setup card shows, so each reason names the fix.
    static var unavailabilityNote: String? {
        #if canImport(FoundationModels)
        guard #available(iOS 26, macOS 26, *) else {
            return String(localized: "Apple's on-device model needs iOS 26 or later.")
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return String(localized: "This device can't run Apple Intelligence.")
            case .appleIntelligenceNotEnabled:
                return String(localized: "Turn on Apple Intelligence in Settings to use the on-device coach.")
            case .modelNotReady:
                return String(localized: "The on-device model is still downloading. Try again in a few minutes.")
            @unknown default:
                return String(localized: "Apple's on-device model isn't available right now.")
            }
        }
        #else
        return String(localized: "Apple's on-device model isn't available in this build.")
        #endif
    }

    /// Load the model's resources ahead of the first request so the first token arrives sooner. Called
    /// when the Coach screen appears with this provider selected — the model is otherwise loaded on the
    /// first `respond`, which is the visible pause after the first question. Harmless when unavailable.
    static func prewarm(instructions: String) {
        #if canImport(FoundationModels)
        guard #available(iOS 26, macOS 26, *), SystemLanguageModel.default.isAvailable else { return }
        let session = LanguageModelSession(instructions: instructions)
        session.prewarm()
        #endif
    }
}

/// Fits a request into the on-device model's context window. Pure and unit-tested; no framework.
enum OnDeviceContextBudget {

    /// Characters of prompt + history the request may carry. The window is 4,096 tokens shared with the
    /// instructions (≈450 tokens) and the answer (`AppleOnDeviceClient.maxResponseTokens`); the coach's
    /// text is number-dense, which tokenises at roughly three characters a token, so 8,000 characters
    /// is about 2,700 tokens — inside the window with room for both. Halved for the one retry.
    static let defaultChars = 8_000

    /// Marks where a message was cut so the model does not read the seam as continuous data.
    static let marker = "\n[… earlier lines trimmed to fit the on-device model …]\n"

    /// Trim `messages` to at most `maxChars` in total. Oldest MIDDLE turns go first (the first user
    /// turn carries the data context and the last carries the question, so both are kept); when the
    /// two that remain are still too long, the longer one loses its middle, keeping its head (the
    /// newest day-lines, which are printed newest-first) and its tail (the question or instruction).
    static func fit(_ messages: [(role: ChatMessage.Role, content: String)],
                    maxChars: Int = defaultChars) -> [(role: ChatMessage.Role, content: String)] {
        var msgs = messages
        func total() -> Int { msgs.reduce(0) { $0 + $1.content.count } }
        while total() > maxChars, msgs.count > 2 { msgs.remove(at: 1) }
        if total() > maxChars, let idx = msgs.indices.max(by: { msgs[$0].content.count < msgs[$1].content.count }) {
            let others = total() - msgs[idx].content.count
            let allowed = max(600, maxChars - others)
            msgs[idx] = (msgs[idx].role, trimMiddle(msgs[idx].content, to: allowed))
        }
        return msgs
    }

    /// Cut the middle out of `text` so it is at most `allowed` characters, keeping the head and a tail
    /// large enough to hold the coach's longest instruction block (≈2,000 characters).
    static func trimMiddle(_ text: String, to allowed: Int) -> String {
        guard text.count > allowed else { return text }
        let tailKeep = min(2_400, allowed / 2)
        let headKeep = max(0, allowed - tailKeep - marker.count)
        return String(text.prefix(headKeep)) + marker + String(text.suffix(tailKeep))
    }

    /// The text to emit for a cumulative stream snapshot given what was already emitted. Apple's stream
    /// yields the WHOLE answer so far on every snapshot, and the coach's `onDelta` contract is
    /// append-only, so the new suffix is what goes out. A snapshot that is not an extension of the
    /// previous one (the model revised earlier text) emits nothing rather than duplicating.
    static func delta(previous: String, cumulative: String) -> String {
        guard cumulative.hasPrefix(previous) else { return "" }
        return String(cumulative.dropFirst(previous.count))
    }
}

struct AppleOnDeviceClient: AIProviderClient {

    /// The cap on the answer, in tokens. ~180 words is what the on-device instruction asks for; 600
    /// leaves room for a list without letting a runaway answer eat the context the next turn needs.
    static let maxResponseTokens = 600

    func send(
        key: String,
        model: String,
        systemPrompt: String,
        messages: [(role: ChatMessage.Role, content: String)],
        session: URLSession
    ) async throws -> String {
        var out = ""
        try await stream(key: key, model: model, systemPrompt: systemPrompt, messages: messages,
                         session: session) { out += $0 }
        let clean = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            throw AICoachError.emptyReply("The on-device model returned an empty reply.")
        }
        return clean
    }

    /// One id, always: the system owns the model and its version.
    func fetchModels(key: String, session: URLSession) async throws -> [String] {
        [AppleOnDeviceModel.modelID]
    }

    func stream(
        key: String,
        model: String,
        systemPrompt: String,
        messages: [(role: ChatMessage.Role, content: String)],
        session: URLSession,
        onDelta: (String) -> Void
    ) async throws {
        if let note = AppleOnDeviceModel.unavailabilityNote { throw AICoachError.onDevice(note) }
        #if canImport(FoundationModels)
        guard #available(iOS 26, macOS 26, *) else { throw AICoachError.onDevice(AppleOnDeviceModel.unavailabilityNote ?? "") }
        let fitted = OnDeviceContextBudget.fit(messages)
        do {
            try await Self.streamOnce(systemPrompt: systemPrompt, messages: fitted, onDelta: onDelta)
        } catch AICoachError.contextTooLarge {
            // Once, at half the budget. The first fit is sized for the common case; a wearer with every
            // opt-in on and a long question can still overflow, and losing older day-lines beats losing
            // the answer. A second overflow is reported.
            let tighter = OnDeviceContextBudget.fit(messages, maxChars: OnDeviceContextBudget.defaultChars / 2)
            try await Self.streamOnce(systemPrompt: systemPrompt, messages: tighter, onDelta: onDelta)
        }
        #endif
    }

    #if canImport(FoundationModels)
    /// One streamed generation over a session seeded with the history. Every prior turn rides in the
    /// transcript rather than being folded into the prompt text, so the model sees them as turns.
    @available(iOS 26, macOS 26, *)
    private static func streamOnce(systemPrompt: String,
                                   messages: [(role: ChatMessage.Role, content: String)],
                                   onDelta: (String) -> Void) async throws {
        guard let last = messages.last else { throw AICoachError.emptyQuestion }
        var entries: [Transcript.Entry] = [
            .instructions(Transcript.Instructions(segments: [.text(.init(content: systemPrompt))],
                                                  toolDefinitions: []))
        ]
        // The final user turn is the prompt; everything before it is history. A history that does not
        // end on an assistant turn (two user turns in a row) is folded into the prompt instead, since
        // the transcript expects prompt/response pairs.
        var history = Array(messages.dropLast())
        var promptText = last.content
        if last.role != .user {
            history = messages
            promptText = "Continue."
        }
        if let trailing = history.last, trailing.role == .user {
            history.removeLast()
            promptText = trailing.content + "\n\n" + promptText
        }
        for m in history {
            switch m.role {
            case .user:
                entries.append(.prompt(Transcript.Prompt(segments: [.text(.init(content: m.content))])))
            case .assistant:
                entries.append(.response(Transcript.Response(assetIDs: [],
                                                             segments: [.text(.init(content: m.content))])))
            }
        }
        let session = LanguageModelSession(transcript: Transcript(entries: entries))
        let options = GenerationOptions(temperature: 0.7, maximumResponseTokens: maxResponseTokens)
        var emitted = ""
        do {
            for try await snapshot in session.streamResponse(to: promptText, options: options) {
                let cumulative = snapshot.content
                let delta = OnDeviceContextBudget.delta(previous: emitted, cumulative: cumulative)
                if !delta.isEmpty {
                    emitted = cumulative
                    onDelta(delta)
                }
            }
        } catch {
            throw mapError(error)
        }
    }

    /// The framework's failures in the coach's vocabulary. Every case names what the wearer can do.
    @available(iOS 26, macOS 26, *)
    private static func mapError(_ error: Error) -> AICoachError {
        if let coachError = error as? AICoachError { return coachError }
        if error is CancellationError { return .network("cancelled") }
        guard let generation = error as? LanguageModelSession.GenerationError else {
            return .onDevice(error.localizedDescription)
        }
        switch generation {
        case .exceededContextWindowSize:
            return .contextTooLarge
        case .guardrailViolation, .refusal:
            return .onDevice(String(localized: "Apple's on-device model declined this request under its safety rules. Try rephrasing the question."))
        case .assetsUnavailable:
            return .onDevice(String(localized: "The on-device model isn't downloaded yet. Check Apple Intelligence in Settings, then try again."))
        case .rateLimited:
            return .onDevice(String(localized: "The on-device model is rate-limited while the app is in the background. Try again with the app open."))
        case .concurrentRequests:
            return .onDevice(String(localized: "The on-device model is already answering another request. Wait for it to finish."))
        case .unsupportedLanguageOrLocale:
            return .onDevice(String(localized: "The on-device model doesn't support this language yet."))
        case .decodingFailure, .unsupportedGuide:
            return .onDevice(String(localized: "The on-device model returned something unreadable. Try again."))
        @unknown default:
            return .onDevice(generation.localizedDescription)
        }
    }
    #endif
}
