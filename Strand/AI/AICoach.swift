import Foundation
import Combine
import Security
import WhoopStore
import StrandAnalytics
import StrandImport

// MARK: - AI Coach (the one networked feature, strictly opt-in, bring-your-own-key)
//
// NOOP is offline by design. This file is the single exception: when the user pastes their OWN
// API key for a provider they choose, NOOP can send a compact text summary of their metrics plus
// their question to that provider and surface coaching advice. Nothing leaves the device until a
// key is set AND a question is asked. We never embed our own key, never auto-send, and only ever
// transmit the small text context built in `buildContext()` + the running chat, no raw streams.
//
// Pure macOS: Foundation + URLSession + Security (Keychain). Compiles on macOS 13, Swift 5.
// Provider wire formats live in Providers/: OpenAI.swift, Anthropic.swift, Gemini.swift.

/// One-line privacy note the UI should display verbatim near the composer / settings.
public let aiCoachPrivacyNote =
    "Private by default: nothing is sent until you add your own key and ask a question - only a short text summary of your metrics goes to the provider you pick."

// MARK: - Chat model

/// One turn in the coaching conversation.
struct ChatMessage: Identifiable, Equatable {
    enum Role: String { case user, assistant }
    let id: UUID
    let role: Role
    let text: String
    /// The model that produced this reply. Nil for user turns.
    ///
    /// Always recorded, not only when a fallback answered. Showing it exclusively for the retry made
    /// the label itself carry hidden meaning — its ABSENCE silently meant "your chosen model", which
    /// is only legible to someone who already knows the rule. Naming the model every time makes the
    /// answer self-describing, and a fallback then stands out because the name differs from the
    /// picker, not because a label appeared from nowhere.
    ///
    /// Carried on the message rather than held as one "last model" value because the transcript keeps
    /// history: scroll back and each reply must still name the model that actually wrote it, not the
    /// most recent request's.
    let generatedByModel: String?

    /// Whether this reply came from the one-shot fallback rather than the selected model. Drives the
    /// emphasis on the attribution — the name alone does not say whether a substitution happened.
    let cameFromFallback: Bool

    init(id: UUID = UUID(), role: Role, text: String,
         generatedByModel: String? = nil, cameFromFallback: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.generatedByModel = generatedByModel
        self.cameFromFallback = cameFromFallback
    }
}

// MARK: - Secure key storage (Keychain)

/// Keychain Services wrapper for the user's API keys. Uses generic-password items under a fixed
/// service so a key never lands in UserDefaults, a plist, or on disk in the clear.
///
/// **One slot PER PROVIDER.** The store used to hold a single item under a fixed `api-key` account,
/// tagged with a UserDefaults marker naming its owner. That made the providers mutually exclusive in
/// the worst way: `save` begins by deleting the existing item, so pasting an OpenAI key silently
/// destroyed the stored Anthropic one, and switching back meant re-entering it — every time, forever.
/// The keys never conflicted in the first place; only the storage did. Each provider now owns
/// `api-key.<provider>`, so all of them coexist and switching provider is a read, not a re-entry.
///
/// The cross-provider leak the old owner marker existed to prevent is now structural rather than
/// checked: a key is stored under its provider's account and can only be read back by asking for that
/// provider, so there is no path that sends one provider's secret to another's endpoint (above all the
/// arbitrary user-typed Custom URL). The marker is retained for one job only — migrating the legacy
/// item — and is deleted once that is done.
enum AIKeyStore {
    private static let service = "com.noop.aicoach"

    /// The pre-multi-slot account. Read (once, by `migrateLegacyKeyIfNeeded`) and then removed; never
    /// written again.
    private static let legacyAccount = "api-key"

    /// UserDefaults marker naming the legacy item's owner. Only meaningful during migration.
    private static let ownerKey = "ai.keyProvider"

    /// Set once the legacy single-slot item has been dealt with, so the migration is attempted at most
    /// once per install even though the entry points that call it run on every launch.
    private static let migratedKey = "ai.keyStoreMigratedToPerProvider"

    /// The Keychain account for one provider's key.
    private static func account(for provider: String) -> String { "api-key.\(provider)" }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    // MARK: Legacy migration

    /// Move a pre-multi-slot key into its owner's slot, once.
    ///
    /// The legacy item carried no provider of its own — the owner lived in a UserDefaults marker
    /// alongside it. Where that marker names a provider, the key belongs in that provider's slot. Where
    /// it is ABSENT (a key saved before owner-tracking existed) the old `resolvedKey` treated it as
    /// belonging to whichever cloud provider was selected, so the safest equivalent is to file it under
    /// the currently-selected provider — unless that is Custom, which the old code explicitly refused to
    /// auto-send an unowned key to, and which is refused here for the same reason.
    ///
    /// Idempotent and non-destructive: it never overwrites a slot that already holds a key, and it only
    /// deletes the legacy item after a successful write, so an interrupted or failed migration leaves
    /// the user's key exactly where it was rather than losing it between two slots.
    static func migrateLegacyKeyIfNeeded(selectedProvider: String) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migratedKey) else { return }

        guard let legacy = read(account: legacyAccount) else {
            // Nothing to move (fresh install, or already migrated by an earlier launch).
            defaults.set(true, forKey: migratedKey)
            defaults.removeObject(forKey: ownerKey)
            return
        }

        // An unowned legacy key is never filed under Custom — same refusal the old resolver made.
        let owner = defaults.string(forKey: ownerKey)
            ?? (selectedProvider == AIProvider.custom.rawValue ? nil : selectedProvider)
        guard let owner else {
            // Leave the legacy item alone and try again next launch, when a cloud provider may be
            // selected. Deleting it here would destroy a key we simply cannot place yet.
            return
        }

        // Never clobber a slot the user has already populated.
        if read(account: account(for: owner)) == nil {
            guard write(legacy, account: account(for: owner)) else { return }   // retry next launch
        }

        SecItemDelete(baseQuery(legacyAccount) as CFDictionary)
        defaults.removeObject(forKey: ownerKey)
        defaults.set(true, forKey: migratedKey)
    }

    // MARK: Read / write

    /// Store (or replace) the API key for `owner`. Empty/whitespace input is treated as a clear of that
    /// provider's slot ONLY — the other providers' keys are untouched, which is the whole point.
    /// Returns true once the key is in the Keychain (or was cleared); false if the write failed (#872),
    /// so the caller can surface that rather than silently proceeding.
    @discardableResult
    static func save(_ key: String, owner: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { clear(owner: owner); return true }
        return write(trimmed, account: account(for: owner))
    }

    private static func write(_ value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // Delete first so we always insert a single, fresh value for this account.
        SecItemDelete(baseQuery(account) as CFDictionary)

        var attrs = baseQuery(account)
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    /// Read the stored API key for `provider`, or nil if that provider has none.
    static func read(owner: String) -> String? { read(account: account(for: owner)) }

    private static func read(account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8),
              !str.isEmpty else { return nil }
        return str
    }

    /// Forget one provider's key, leaving every other provider's key in place.
    static func clear(owner: String) {
        SecItemDelete(baseQuery(account(for: owner)) as CFDictionary)
    }

    /// Forget EVERY provider's key, plus any legacy item. For an explicit "forget everything" action.
    static func clearAll() {
        for provider in AIProvider.allCases {
            SecItemDelete(baseQuery(account(for: provider.rawValue)) as CFDictionary)
        }
        SecItemDelete(baseQuery(legacyAccount) as CFDictionary)
        UserDefaults.standard.removeObject(forKey: ownerKey)
    }
}

// MARK: - Errors

/// User-facing failure reasons mapped to clear, non-crashing messages.
enum AICoachError: LocalizedError {
    case noKey
    case emptyQuestion
    case badKey
    case rateLimited
    /// The request ran out of time — either client-side (`URLError.timedOut` and friends) or reported
    /// by the provider as a gateway timeout. Its own case, rather than a `.network` with a timeout-ish
    /// message, so the one-shot fallback retry can recognise it without comparing localized strings.
    case timedOut
    case server(Int, String)
    /// A TRANSIENT server-side failure — 500/502/503/529. Distinct from `.server` because that is
    /// terminal and this is not: the request was fine and the provider was simply busy, so it is worth
    /// one more attempt. Gemini's 503-when-overloaded is the common one.
    case transientServer(Int, String)
    case network(String)
    case decode
    case emptyReply(String)   // #1074: verbatim provider-error / empty-reply text (byte-parity with Android emptyReplyMessage)
    case keySaveFailed
    case badCustomURL(String)

    var errorDescription: String? {
        switch self {
        case .badCustomURL(let message):
            return message
        case .noKey:
            return "Add your own API key first to use the coach."
        case .keySaveFailed:
            return "Couldn't save the key to the Keychain. The key was not stored, so try again."
        case .emptyQuestion:
            return "Type a question for the coach."
        case .badKey:
            return "That API key was rejected. Check the key and the provider you selected."
        case .rateLimited:
            return "The provider is rate-limiting requests right now. Wait a moment and try again."
        case .timedOut:
            // Deliberately does NOT claim a retry happened — one only runs when a genuinely faster
            // model exists to switch to. Saying otherwise would send someone hunting for a second
            // attempt that never occurred.
            return "The model took too long to answer. Try again, or pick a faster model."
        case .transientServer(let code, let detail):
            let extra = detail.isEmpty ? "" : " - \(detail)"
            return "The provider is busy right now (\(code))\(extra). Try again in a moment."
        case .server(let code, let detail):
            let extra = detail.isEmpty ? "" : " - \(detail)"
            return "The provider returned an error (\(code))\(extra)."
        case .network(let detail):
            return "Network problem: \(detail). The coach is the only feature that needs the internet."
        case .decode:
            return "Couldn't read the provider's reply. Try again."
        case .emptyReply(let message):
            return message
        }
    }

    /// A few words naming the failure, for the attempt trace. The full `errorDescription` is a
    /// sentence written for someone reading one error; the trace strings several together and needs
    /// each to be short enough to stay legible.
    var shortLabel: String {
        switch self {
        case .noKey:            return "no key"
        case .emptyQuestion:    return "empty question"
        case .badKey:           return "key rejected"
        case .rateLimited:      return "rate limited"
        case .timedOut:         return "timed out"
        case .server(let code, _): return "HTTP \(code)"
        case .transientServer(let code, _): return "provider busy (\(code))"
        case .network:          return "network error"
        case .decode:           return "unreadable reply"
        case .emptyReply:       return "empty reply"
        case .keySaveFailed:    return "key save failed"
        case .badCustomURL:     return "bad server URL"
        }
    }

    /// Whether this failure is worth one automatic retry on the provider's lightest model.
    ///
    /// Two failures qualify, and they are the two a smaller model plausibly survives:
    ///
    /// - `.timedOut` — the reply did not finish inside the budget. A faster model may.
    /// - `.emptyReply` — a 200 with no usable text. On Gemini 2.5 this is the *common* heavy-model
    ///   failure and the reason a retry was invisible until now: thinking tokens count against
    ///   `maxOutputTokens`, so a reasoning model can spend the whole budget thinking and return
    ///   `finishReason: MAX_TOKENS` with no text parts. That arrives FAST and with HTTP 200 — it is
    ///   not a timeout, so a timeout-only retry never fired. It is also why the same model works on
    ///   one request and not the next: how much it thinks varies per prompt, so the failure is
    ///   intermittent rather than a fixed ceiling that would fail every time.
    ///
    /// - `.rateLimited` — HTTP 429. Excluded at first on the reasoning that a rate limit "applies to
    ///   the account, not the model", which is simply wrong for the providers here: Gemini meters
    ///   per-model, so `gemini-pro-latest` can be exhausted while `gemini-flash-lite-latest` has its
    ///   own untouched budget. This turned out to be the failure users actually hit — a heavy model
    ///   429s on a free tier within a few requests — and the exact case a lighter-model fallback
    ///   exists to rescue. Retrying costs one request against a different quota.
    ///
    /// Everything else is excluded deliberately: a rejected key, a bad URL, a 4xx or a decode failure
    /// fail identically on a smaller model, so retrying only doubles the wait before the same error.
    ///
    /// A caveat worth stating: `.emptyReply` also covers a genuinely wrong model id typed by hand, and
    /// for that case the retry produces an answer from a DIFFERENT model than the one named in the
    /// picker. `lastTimeoutFallbackModel` records when that happened so the UI can say so rather than
    /// quietly attributing the light model's answer to the heavy one.
    var deservesLighterModelRetry: Bool {
        switch self {
        // Failures that are about the REQUEST rather than the model, where a second attempt on any
        // model would fail identically and only cost the user another wait. Excluded so the one retry
        // is spent where it can actually help.
        case .noKey, .emptyQuestion, .badKey, .keySaveFailed, .badCustomURL: return false
        // Everything else retries. Enumerating what CANNOT work, rather than guessing which failures
        // can, is the lesson of this bug: each attempt to predict the retry-worthy set missed the one
        // that mattered — first timeouts only (missed empty replies), then rate limits (missed 503s).
        // The list above is short and provably model-independent; the rest is not worth predicting.
        case .timedOut, .emptyReply, .rateLimited, .transientServer, .server, .network, .decode:
            return true
        }
    }

    /// Which `URLError` codes count as "ran out of time" for retry purposes.
    ///
    /// `.timedOut` is the plain case. `.cannotConnectToHost` / `.cannotFindHost` are deliberately NOT
    /// here — those fail fast and mean the endpoint is wrong or unreachable, so a retry on a cheaper
    /// model would just fail again against the same URL. `.networkConnectionLost` IS included: on a
    /// long-running LLM request it is overwhelmingly a stalled connection being reaped rather than a
    /// genuine link drop, and it is the shape a slow model most often fails in on mobile.
    static func isTimeoutCode(_ code: URLError.Code) -> Bool {
        code == .timedOut || code == .networkConnectionLost
    }
}

// MARK: - Engine

/// Drives the AI Coach: holds the chat, the chosen provider/model, the secure key, and performs the
/// networked request. `@MainActor` so all `@Published` mutations are main-thread; the actual HTTP
/// call hops off-main via `URLSession`'s async API and results are applied back on the main actor.
@MainActor
final class AICoachEngine: ObservableObject {

    // Published state the UI binds to.
    @Published var messages: [ChatMessage] = []

    /// Local day the current transcript was last written on; nil while it is empty. Drives the day
    /// boundary in `send` — see `isStaleConversation`. Kotlin twin: `CoachViewModel.conversationDay`.
    private var conversationDay: Int?
    @Published var sending = false
    @Published var errorText: String?
    @Published var provider: AIProvider {
        didSet {
            guard provider != oldValue else { return }
            UserDefaults.standard.set(provider.rawValue, forKey: Self.providerKey)
            // Reset the model list to the new provider's built-in options.
            availableModels = provider.modelOptions
            // Keep the model valid for the newly-selected provider.
            if !provider.modelOptions.contains(model) {
                model = provider.defaultModel
            }
        }
    }
    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: Self.modelKey) }
    }
    /// The model ids offered in the picker. Seeded from `provider.modelOptions`, reset when the
    /// provider changes, and optionally extended by `refreshModels()` with the provider's live list.
    @Published var availableModels: [String] = []
    /// Explicit permission for the coach to read & transmit the user's biometric data. OFF by
    /// default, until this is true, NO metrics are included in any request (only the question).
    @Published var dataConsent: Bool {
        didSet { UserDefaults.standard.set(dataConsent, forKey: Self.consentKey) }
    }
    /// Base URL for the Custom (OpenAI-compatible) provider, e.g. `http://localhost:11434/v1` for a
    /// local LLM server. Only used when `provider == .custom`. Persisted so it survives relaunch.
    @Published var customBaseURL: String {
        didSet { UserDefaults.standard.set(customBaseURL, forKey: AIProvider.customBaseURLKey) }
    }
    @Published var customAuthHeader: CustomAIAuthHeader {
        didSet { UserDefaults.standard.set(customAuthHeader.rawValue, forKey: AIProvider.customAuthHeaderKey) }
    }
    /// Whether the user has committed the Custom provider (tapped Connect with a base URL). Lets the
    /// keyless local path reach the chat without a stored key, while avoiding a flip mid-typing.
    @Published var customConnected: Bool {
        didSet { UserDefaults.standard.set(customConnected, forKey: Self.customConnectedKey) }
    }
    /// SECOND opt-in (v5): also fold a SUMMARY of the new on-device signals, your strongest n-of-1
    /// correlations and your Lab Book markers, into the coach context. OFF by default and gated behind
    /// `dataConsent` too, so it never adds anything without both consents. Summary-only: a few one-line
    /// sentences, NEVER raw readings, the anonymity / no-raw-egress posture is preserved.
    @Published var includeOnDeviceSignals: Bool {
        didSet { UserDefaults.standard.set(includeOnDeviceSignals, forKey: Self.onDeviceSignalsKey) }
    }
    /// THIRD opt-in: widen the per-day lines with the sleep-architecture / autonomic fields already held
    /// in `DailyMetric` (stages, efficiency, disturbances, SDNN, absolute skin temp) and append a TRENDS
    /// block of deterministic roll-ups (training load, sleep debt, baseline deviations, data density).
    /// OFF by default and gated behind `dataConsent` too, so it never adds anything without both consents.
    ///
    /// Nothing here reaches past the data the core summary is already built from: the extra day fields ride
    /// the SAME `repo.days` rows the coach already reads five columns off, and every trend is a pure
    /// function over those rows. So this widens RESOLUTION, not scope — no new store reads, no raw-sample
    /// egress, same text-only channel.
    ///
    /// NOTE: `buildFullContext()` also backs `refreshSynthesis()`, so this enriches the Today synthesis
    /// paragraph as well as the Coach chat. That is intended — the synthesis is the surface this data was
    /// asked for — and the toggle's copy says so.
    @Published var includeDerivedTrends: Bool {
        didSet { UserDefaults.standard.set(includeDerivedTrends, forKey: Self.derivedTrendsKey) }
    }

    private let repo: Repository
    /// The live autonomic read (`AppModel.breatheCue` — the card's # marker), lent by the app layer
    /// so the synthesis states the SAME verdict the card is showing. Nil closure (tests, macOS
    /// wiring gaps) or nil value both read as "not judgeable" — no claim either way.
    var currentBreathe: (() -> Bool?)?
    private let session: URLSession

    private static let providerKey = "ai.provider"
    private static let modelKey = "ai.model"
    private static let consentKey = "ai.dataConsent"
    private static let customConnectedKey = "ai.customConnected"
    private static let onDeviceSignalsKey = "ai.includeOnDeviceSignals"
    private static let derivedTrendsKey = "ai.includeDerivedTrends"
    /// UserDefaults key holding the user's EDITED system prompt. Absent (or blank) means "use the
    /// built-in default". Small text key, never a secret, so plain UserDefaults is fine. Read FRESH
    /// per request (see `systemPrompt`) so an edit takes effect on the very next message.
    static let systemPromptKey = "ai.systemPrompt"
    static let synthesisPromptKey = "ai.synthesisPrompt"

    /// The built-in system prompt that frames every request. Anonymous, frames the assistant only as a
    /// coach. Exposed (read-only) so the UI's "Reset to default" can restore it and show it when nothing
    /// custom is stored. Editing the live prompt overrides this via `systemPromptKey`.
    static let defaultSystemPrompt = """
    You are an elite, supportive recovery and performance coach with a real training methodology. \
    You may be given a summary of the user's own wearable data (charge 0-100, effort 0-100, rest 0-100, \
    HRV, resting heart rate) and recent workouts. Charge is the daily recovery/readiness score, effort \
    is the daily cardiovascular load score, and rest is the nightly sleep-quality score. \
    Coach using autoregulation:
    • Readiness → prescription: charge 67-100 = green light to build/push, higher effort is fine; \
    34-66 = maintain, quality over volume, keep it controlled; 0-33 = active recovery only \
    (Zone 2, mobility, extra sleep) and protect against accumulating effort debt.
    • Workout optimisation: progressive overload, polarised ~80/20 intensity, space hard sessions, \
    program deloads/periodisation, and treat sleep as the single biggest recovery lever.
    • Always cite the user's ACTUAL numbers, give a concrete plan (today and the week ahead), and \
    be specific, punchy and motivating - like a coach who knows them.
    If no data is provided, coach generally and invite them to turn on data access for personalised \
    advice. You are NOT a doctor - never diagnose; suggest a professional for genuine health concerns.
    Format replies in simple Markdown, chat-sized: short paragraphs, **bold** for key numbers, \
    bullet or numbered lists for plans, ### headings only when structure genuinely helps, and a \
    small table only for a week-ahead plan. No code blocks.
    """

    /// The system prompt actually sent, read FRESH from UserDefaults on every request so an edit in
    /// the settings takes effect on the next message, with no engine rebuild. A blank/absent stored
    /// value falls back to `defaultSystemPrompt`, so a user who clears it never sends an empty prompt.
    var systemPrompt: String {
        let stored = UserDefaults.standard.string(forKey: Self.systemPromptKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let stored, !stored.isEmpty { return stored }
        return Self.defaultSystemPrompt
    }

    /// The user's stored prompt override, or the default when nothing custom is set. The UI binds its
    /// editor to this: writing persists the override; writing a blank string clears it (back to default).
    var customSystemPrompt: String {
        get { systemPrompt }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == Self.defaultSystemPrompt {
                UserDefaults.standard.removeObject(forKey: Self.systemPromptKey)
            } else {
                UserDefaults.standard.set(newValue, forKey: Self.systemPromptKey)
            }
            objectWillChange.send()
        }
    }

    /// True when the user has an edited prompt that differs from the built-in default, gates the
    /// "Reset to default" affordance in the UI.
    var hasCustomSystemPrompt: Bool {
        let stored = UserDefaults.standard.string(forKey: Self.systemPromptKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !(stored ?? "").isEmpty && stored != Self.defaultSystemPrompt
    }

    /// Restore the built-in system prompt by clearing the stored override.
    func resetSystemPrompt() {
        UserDefaults.standard.removeObject(forKey: Self.systemPromptKey)
        objectWillChange.send()
    }

    /// The built-in instruction for the Today synthesis turn. The coach's own instructions still own
    /// the voice; this names the surface and its SHAPE — three pillars, one line each, citing the
    /// deterministic targets from the TODAY'S TARGETS block (the same numbers the Lock-Screen card
    /// prints) so the synthesis and the card can never disagree. Exposed like `defaultSystemPrompt`
    /// so the UI can show it and restore it.
    static let defaultSynthesisPrompt = """
    Following your coaching instructions and using my data above, write today's synthesis for my \
    Today screen as exactly three markdown bullets, mirroring my Lock-Screen card in this order:
    - **Heart** — my live autonomic read, stated in TODAY'S TARGETS as exactly one of: calm (my \
    heart-rate variability is in its normal range, or a high heart rate is just exercise), \
    STRESSED (my beat-to-beat variability has dipped well below my own rolling baseline while I \
    am at rest — a fight-or-flight signature, shown on my Lock-Screen card as a # after the heart \
    rate), or not judgeable (too few clean beats — make no claim). Explain what has LED to that \
    read, then the step to actively take; when it is STRESSED, prescribe a specific short \
    breathing or meditation exercise (name the technique and duration).
    - **Activity** — my calories and effort so far against today's targets: explain what produced \
    those numbers, then the concrete session (or rest) that closes the gap.
    - **Rest & sleep** — what last night and today's load mean for resting properly today, then \
    tonight's plan: cite the precise target bedtime and sleep target from TODAY'S TARGETS.
    In each bullet, explain what led to the numbers BEFORE prescribing, and bring in another metric \
    from my data only when it strictly serves that bullet's story (for example an elevated skin \
    temperature explaining poor rest, or a low HRV explaining a recovery day — illustrative, not \
    required). Cite my actual numbers; never invent targets that differ from TODAY'S TARGETS. \
    No greeting, nothing outside the three bullets.
    """

    /// The synthesis instruction actually sent, read FRESH from UserDefaults on every generation so an
    /// edit takes effect on the next refresh. Blank/absent falls back to `defaultSynthesisPrompt`, so
    /// clearing it never sends an empty instruction.
    var synthesisPrompt: String {
        let stored = UserDefaults.standard.string(forKey: Self.synthesisPromptKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let stored, !stored.isEmpty { return stored }
        return Self.defaultSynthesisPrompt
    }

    /// The user's stored synthesis override, or the default when nothing custom is set. The UI binds
    /// its editor to this; writing a blank string clears the override.
    var customSynthesisPrompt: String {
        get { synthesisPrompt }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == Self.defaultSynthesisPrompt {
                UserDefaults.standard.removeObject(forKey: Self.synthesisPromptKey)
            } else {
                UserDefaults.standard.set(newValue, forKey: Self.synthesisPromptKey)
            }
            objectWillChange.send()
        }
    }

    /// True when the stored synthesis instruction differs from the built-in default; gates "Reset".
    var hasCustomSynthesisPrompt: Bool {
        let stored = UserDefaults.standard.string(forKey: Self.synthesisPromptKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !(stored ?? "").isEmpty && stored != Self.defaultSynthesisPrompt
    }

    /// Restore the built-in synthesis instruction by clearing the stored override.
    func resetSynthesisPrompt() {
        UserDefaults.standard.removeObject(forKey: Self.synthesisPromptKey)
        objectWillChange.send()
    }

    /// Used in place of the metrics context when the user has NOT granted data access.
    private let noConsentNote = """
    NOTE: The user has not granted access to their biometric data. Coach generally and encourage \
    them to enable "Let the coach use my data" for guidance tailored to their real numbers.
    """

    /// How long one coach request may take before URLSession gives up.
    ///
    /// `URLSession.shared` defaults to 60 s, which is simply too short for this workload and was the
    /// real reason a powerful model appeared to produce nothing at all: the requests are
    /// NON-STREAMING and capped at `max_tokens: 4096`, so nothing arrives until the whole reply is
    /// written. A reasoning-class model (Opus, GPT-4.1) composing a long answer routinely passes 60 s,
    /// so the request was killed mid-generation every time and the user saw a failure rather than a
    /// slow success. The fallback retry then made it worse, spending a second full budget before
    /// surfacing anything.
    ///
    /// 180 s is chosen to cover a slow large model rather than to be generous: the coach is an
    /// explicitly user-initiated action with a visible "Thinking" state, so waiting is legible, and a
    /// request that genuinely hangs is still bounded. `timeoutIntervalForRequest` measures the gap
    /// between bytes rather than total wall time, so this is a stall budget, not a deadline on the
    /// answer's length.
    nonisolated static let requestTimeoutSeconds: TimeInterval = 180

    /// A session configured for LLM latency. Used whenever a caller does not inject its own (the tests
    /// do), so the app never runs the coach on `URLSession.shared`'s 60 s default again.
    ///
    /// `nonisolated` because it builds a fresh value from constants and touches no engine state; the
    /// class's `@MainActor` isolation would otherwise ride along and force callers onto the main actor
    /// for what is a pure factory.
    nonisolated static func makeDefaultSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = requestTimeoutSeconds
        // The ceiling for the whole resource, retry included, so one wedged request cannot outlive the
        // screen the user is looking at.
        config.timeoutIntervalForResource = requestTimeoutSeconds * 2
        return URLSession(configuration: config)
    }

    init(repo: Repository, session: URLSession? = nil) {
        self.repo = repo
        self.session = session ?? Self.makeDefaultSession()

        // Restore persisted provider / model (falling back to sane defaults).
        let storedProvider = UserDefaults.standard.string(forKey: Self.providerKey)
            .flatMap(AIProvider.init(rawValue:)) ?? .openAI
        self.provider = storedProvider

        let storedModel = UserDefaults.standard.string(forKey: Self.modelKey)
        // A persisted custom id is honoured even if it's not in the built-in list.
        if let storedModel, !storedModel.isEmpty {
            self.model = storedModel
        } else {
            self.model = storedProvider.defaultModel
        }

        // Seed the picker with the provider's built-in options; include any persisted custom id.
        var seeded = storedProvider.modelOptions
        if let storedModel, !storedModel.isEmpty, !seeded.contains(storedModel) {
            seeded.insert(storedModel, at: 0)
        }
        self.availableModels = seeded

        self.dataConsent = UserDefaults.standard.bool(forKey: Self.consentKey)
        self.customBaseURL = UserDefaults.standard.string(forKey: AIProvider.customBaseURLKey) ?? ""
        self.customAuthHeader = AIProvider.customAuthHeader
        self.customConnected = UserDefaults.standard.bool(forKey: Self.customConnectedKey)
        self.includeOnDeviceSignals = UserDefaults.standard.bool(forKey: Self.onDeviceSignalsKey)
        self.includeDerivedTrends = UserDefaults.standard.bool(forKey: Self.derivedTrendsKey)

        // Move a pre-multi-slot key into its provider's slot so an existing install keeps the key it
        // already had. Runs after `provider` is set because an unowned legacy key is filed under the
        // selected provider. Self-gating and non-destructive — see `migrateLegacyKeyIfNeeded`.
        AIKeyStore.migrateLegacyKeyIfNeeded(selectedProvider: storedProvider.rawValue)
    }

    // MARK: Key management

    /// True when a key is present for the CURRENTLY SELECTED provider. Per-provider by construction:
    /// each provider has its own Keychain slot, so switching provider changes the answer without any
    /// key being written or destroyed.
    var hasKey: Bool { AIKeyStore.read(owner: provider.rawValue) != nil }

    /// Whether a GIVEN provider is ready to use — not just the selected one. Lets the UI show which
    /// providers can be switched to without typing anything, so a switch that would strand the user in
    /// the setup card is visibly distinct from one that lands straight in the chat.
    func hasStoredKey(for candidate: AIProvider) -> Bool {
        candidate == .custom ? customConnected : AIKeyStore.read(owner: candidate.rawValue) != nil
    }

    /// True once the coach can actually send: a stored key for the cloud providers, or, for the
    /// Custom (local) provider, a committed base URL (a key is optional there, as local servers
    /// usually need none). Gates the setup card vs. the live chat.
    var isConfigured: Bool { provider == .custom ? customConnected : hasKey }

    /// The key to send with a request: the stored key, or an empty string for the keyless Custom
    /// provider. `nil` means "not configured", the caller surfaces `.noKey`.
    /// A key is read from the selected provider's OWN slot, so one provider's secret can never be sent
    /// to another provider's endpoint (above all the arbitrary user-typed Custom URL). That used to be
    /// an owner-marker comparison; it is now structural — there is no query that returns another
    /// provider's key.
    private var resolvedKey: String? {
        if let k = AIKeyStore.read(owner: provider.rawValue) { return k }
        return provider == .custom ? "" : nil
    }

    /// Commit the Custom (local) provider once the user has entered a server URL. Optionally stores a
    /// key first if they pasted one. Pulls the server's live model list so the picker isn't empty.
    func connectCustom() {
        let url = customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        errorText = nil
        customConnected = true
        // Pull the server's model list; if the user hasn't picked one yet, default to the first.
        Task {
            await refreshModels()
            if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let first = availableModels.first {
                model = first
            }
        }
    }

    /// Disconnect the CURRENTLY SELECTED provider: forget its key and, for Custom, un-commit it. The
    /// base URL is kept so reconnecting pre-fills it.
    ///
    /// Scoped to the selected provider on purpose. It used to clear the single shared slot, which meant
    /// disconnecting one provider silently discarded whatever key the others had. Forgetting every key
    /// at once is still available as `forgetAllKeys()`, but it is now a distinct, explicit action rather
    /// than a side effect of switching away from a provider.
    func disconnect() {
        AIKeyStore.clear(owner: provider.rawValue)
        if provider == .custom { customConnected = false }
        objectWillChange.send()
    }

    /// Forget EVERY provider's key and un-commit Custom. The "leave nothing behind" action.
    func forgetAllKeys() {
        AIKeyStore.clearAll()
        customConnected = false
        // Retire the transcript with the connection. Kotlin has done this since the method existed
        // (CoachViewModel.disconnect) and this side never did, so returning to the setup screen on Apple
        // left the whole conversation sitting behind it — including whatever the user had told a coach
        // they were in the middle of disconnecting from.
        messages = []
        conversationDay = nil
        objectWillChange.send()
    }

    /// Store the user's pasted key securely. Clears any prior error. If the Keychain write fails the
    /// key is NOT saved, so surface that to the UI instead of silently proceeding (#872).
    func setKey(_ key: String) {
        guard AIKeyStore.save(key, owner: provider.rawValue) else {
            errorText = AICoachError.keySaveFailed.errorDescription
            objectWillChange.send()
            return
        }
        errorText = nil
        objectWillChange.send() // `hasKey` is computed; nudge SwiftUI to re-read it.
        // #288: do NOT auto-fetch the provider's model list on key-save. For a cloud provider that GET
        // egresses to the provider the MOMENT a key is saved (IP + request timing + key-validity) — before
        // any send, in an app that is zero-network by default. The picker shows the curated models; the LIVE
        // list is pulled only when the user taps Refresh (an explicit action that is its own consent) or
        // sends. Local Custom servers still refresh on Connect.
    }

    /// Forget the selected provider's key, leaving the other providers' keys in place.
    func clearKey() {
        AIKeyStore.clear(owner: provider.rawValue)
        // Same reasoning as `disconnect`: clearing the key returns the user to the setup screen, and
        // Kotlin empties the transcript when it does. Leaving it meant a "clear my key" on Apple removed
        // the credential and kept the conversation.
        messages = []
        conversationDay = nil
        objectWillChange.send()
    }

    // MARK: Live model list

    /// Set a custom model id (any string). Adds it to the picker if it isn't already listed.
    func setCustomModel(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !availableModels.contains(trimmed) {
            availableModels.insert(trimmed, at: 0)
        }
        model = trimmed
    }

    /// Test seam (DEBUG only): lets a test stand in for the live `fetchModels` network call so it can
    /// control timing and which provider's ids come back. Production never sets this, so the real path
    /// below is byte-identical in release builds.
    #if DEBUG
    var fetchModelsOverride: ((_ provider: AIProvider, _ key: String) async throws -> [String])?
    #endif

    /// Best-effort: GET the chosen provider's models endpoint with the saved key and merge the
    /// returned ids into `availableModels`. Never crashes; failures land in `errorText` and leave
    /// the existing list intact. Requires a saved key.
    func refreshModels() async {
        guard let key = resolvedKey else {
            errorText = AICoachError.noKey.errorDescription
            return
        }
        errorText = nil

        // Snapshot the provider BEFORE the await. The Picker isn't disabled during a refresh, so the
        // user can switch providers mid-flight (#873). We fetch this provider's ids, then re-check on
        // resume that it's still the live one, and merge against THIS same snapshot, so the guard and
        // the merge always use one consistent provider, never a stale/mixed list for the wrong one.
        let capturedProvider = provider

        do {
            let ids: [String]
            #if DEBUG
            if let override = fetchModelsOverride {
                ids = try await override(capturedProvider, key)
            } else {
                ids = try await capturedProvider.client.fetchModels(key: key, session: session)
            }
            #else
            ids = try await capturedProvider.client.fetchModels(key: key, session: session)
            #endif

            // The user switched providers while we were awaiting, so these ids belong to the old one.
            // Drop them rather than write a list for a provider that's no longer selected.
            guard provider == capturedProvider else { return }

            guard !ids.isEmpty else {
                errorText = AICoachError.decode.errorDescription
                return
            }

            // Merge: keep the captured provider's built-in options on top, append any newly-discovered
            // ids (sorted), and preserve a current custom selection if it isn't otherwise present.
            let builtin = capturedProvider.modelOptions
            let discovered = Set(ids).subtracting(builtin).sorted()
            var merged = builtin + discovered
            if !merged.contains(model) { merged.insert(model, at: 0) }
            availableModels = merged
        } catch {
            // A switch mid-flight makes any error moot for the old provider, so don't surface it.
            guard provider == capturedProvider else { return }
            errorText = AICoachError.network(error.localizedDescription).errorDescription
            return
        }
    }

    // MARK: Sending

    /// Hard rolling cap on the STORED transcript. The network payload is separately windowed by
    /// `windowedMessages()` (`maxHistoryMessages`); this bounds the in-memory `messages` array — and the
    /// SwiftUI transcript rendered from it — so a long-lived session can't grow it without bound. `coach`
    /// is a single app-lifetime instance on `AppModel`, so before this an active chat grew `messages`
    /// until the process was killed: the "gets laggy the longer the app runs, reopening fixes it, feels
    /// like RAM" report. Cap >> the wire window, so it never changes what's sent. (parity with Android)
    private static let maxStoredMessages = 40
    private func appendMessage(_ message: ChatMessage) {
        messages.append(message)
        if messages.count > Self.maxStoredMessages {
            messages.removeFirst(messages.count - Self.maxStoredMessages)
        }
    }

    /// Send a question: append it, build the metrics context, call the chosen provider with the
    /// system prompt + context + running history, parse the reply, append it. Never throws/crashes;
    /// failures land in `errorText`.
    func send(_ userText: String) async {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { errorText = AICoachError.emptyQuestion.errorDescription; return }
        guard let key = resolvedKey else { errorText = AICoachError.noKey.errorDescription; return }

        // A transcript from an earlier local day is retired before the new turn is appended (#1542,
        // Kotlin twin merged first). `messages` outlives a night — the engine is held for the app's
        // lifetime — so without this the coach answers TODAY's question inside YESTERDAY's
        // conversation. The DATA was never stale: buildFullContext() re-reads on every send. It is the
        // assistant's own earlier turns stating yesterday's figures, and the model staying consistent
        // with them, which reads as "the coach only talks about my imported data" after a night of
        // fresh strap data.
        //
        // Placed AFTER the guards on purpose: a send that never happens must not wipe a transcript.
        let today = Self.localEpochDay()
        if Self.isStaleConversation(lastEpochDay: conversationDay, todayEpochDay: today) {
            messages = []
        }
        conversationDay = today

        errorText = nil
        appendMessage(ChatMessage(role: .user, text: trimmed))
        sending = true
        defer { sending = false }

        // Build the data context once and prepend it to the FIRST user turn we send. We send the
        // full running history so follow-ups stay coherent; the context only needs to ride the
        // earliest user message.
        // Include the user's data ONLY with explicit consent; otherwise send a note instead of numbers.
        let context = dataConsent ? await buildFullContext() : noConsentNote
        let wire = wireMessages(context: context)

        do {
            let reply = try await callProvider(key: key, messages: wire)
            let clean = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            appendMessage(ChatMessage(role: .assistant, text: clean.isEmpty ? "(no reply)" : clean,
                                      generatedByModel: lastAnsweringModel,
                                      cameFromFallback: lastTimeoutFallbackModel != nil))
        } catch let e as AICoachError {
            errorText = e.errorDescription
        } catch {
            errorText = AICoachError.network(error.localizedDescription).errorDescription
        }
    }

    /// Proactively generate "Today's brief" the first time the Coach opens, readiness + a training
    /// prescription + one recovery tip, without the user typing. Requires a key + data consent.
    func startBriefIfNeeded() async {
        guard isConfigured, dataConsent, messages.isEmpty, !sending else { return }
        guard let key = resolvedKey else { return }
        errorText = nil
        sending = true
        defer { sending = false }

        let context = await buildFullContext()
        let instruction = """
        Based on the data above, give me TODAY'S coaching brief in three short parts: \
        (1) my readiness in one line, citing charge, HRV and rest; \
        (2) exactly what training to do today and what to avoid; \
        (3) one specific thing to improve my charge. Be punchy and motivating.
        """
        let wire: [(role: ChatMessage.Role, content: String)] = [(.user, context + "\n\n---\n\n" + instruction)]
        do {
            let reply = try await callProvider(key: key, messages: wire)
            let clean = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                appendMessage(ChatMessage(role: .assistant, text: "Today's brief\n\n" + clean,
                                          generatedByModel: lastAnsweringModel,
                                          cameFromFallback: lastTimeoutFallbackModel != nil))
            }
        } catch let e as AICoachError {
            errorText = e.errorDescription
        } catch {
            errorText = AICoachError.network(error.localizedDescription).errorDescription
        }
    }

    // MARK: - Today's synthesis (coach-written)

    /// The coach-generated Today synthesis — one short paragraph reading the day, regenerated on every
    /// app open (both platforms' scenePhase-active handlers call `refreshSynthesis`). Nil until the
    /// first generation lands, and whenever the provider is unconfigured or data consent is off — the
    /// Today card falls back to the rule-based read in every such case, so this only ever adds.
    /// Deliberately NEVER appended to `messages`: the chat transcript is the user's own conversation,
    /// and a per-open generation would bury it.
    @Published var synthesisText: String?
    /// The model that wrote the current `synthesisText`, whichever it was. Nil only before the first
    /// generation.
    @Published private(set) var synthesisModel: String?

    /// Whether the current `synthesisText` came from the one-shot fallback rather than the selected
    /// model. The model name alone does not say a substitution happened — that only reads as unusual
    /// if you remember what you had picked — so the card labels it explicitly.
    @Published private(set) var synthesisCameFromFallback = false

    /// When `synthesisText` was generated. The Today card treats a text from a previous local day as
    /// absent (`synthesisIsCurrent`), so a provider that stops answering degrades to the rule-based
    /// read by the next morning rather than pinning yesterday's narrative to today's numbers.
    @Published var synthesisGeneratedAt: Date?
    /// True while a generation is running — drives the refresh button's spinner on the Today cards.
    @Published var synthesisRefreshing = false
    private var synthesisInFlight = false

    /// Whether a generation stamped `generatedAt` may still be shown at `now`: same LOCAL calendar day.
    /// Pure and static so the day-rollover fallback is pinnable without a provider or a store;
    /// `nonisolated` because the engine's @MainActor isolation would otherwise ride along and there is
    /// no state here to isolate.
    nonisolated static func synthesisIsCurrent(generatedAt: Date?, now: Date = Date()) -> Bool {
        guard let generatedAt else { return false }
        return Calendar.current.isDate(generatedAt, inSameDayAs: now)
    }

    /// Regenerate the Today synthesis from the configured provider. Same gates as `startBriefIfNeeded`
    /// (configured + consent + key) minus the empty-transcript one. Silent on failure — Today is a
    /// glanceable surface, so provider errors stay on the Coach screen (`errorText` is untouched here)
    /// and the rule-based synthesis simply remains. Re-entry: one generation at a time, and a text
    /// under a minute old is kept — a foreground flap (notification shade, app switcher) re-fires
    /// `.active` within seconds, and burning a provider call per flap buys nothing.
    /// - Parameter force: skip the one-minute freshness keep. The Today cards' refresh button passes
    ///   true — a deliberate tap is a request for a NEW paragraph, not a flap to be absorbed.
    func refreshSynthesis(force: Bool = false) async {
        guard isConfigured, dataConsent, !synthesisInFlight else { return }
        guard let key = resolvedKey else { return }
        // Drop a previous day's text BEFORE generating, so a failed call falls back to the rule-based
        // read rather than yesterday's narrative.
        if !Self.synthesisIsCurrent(generatedAt: synthesisGeneratedAt) {
            synthesisText = nil
            synthesisGeneratedAt = nil
        }
        if !force, let at = synthesisGeneratedAt, synthesisText != nil,
           Date().timeIntervalSince(at) < 60 { return }
        synthesisInFlight = true
        synthesisRefreshing = true
        defer {
            synthesisInFlight = false
            synthesisRefreshing = false
        }

        // The scenePhase-active trigger fires at LAUNCH too, before the repository's merged cache has
        // loaded — and an empty `repo.days` makes `buildContext` emit its honest "no wearable data yet"
        // note, which the model dutifully turns into a generic no-access paragraph that then sits on
        // Today all day. Wait (bounded) for the cache to land; if there is genuinely no data after the
        // wait — a fresh install — generate nothing and leave the rule-based read, which handles the
        // cold start honestly.
        for _ in 0..<20 where repo.days.isEmpty {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard !repo.days.isEmpty else { return }

        let context = await buildFullContext()
        // Read fresh (see `synthesisPrompt`), so an edit in the settings applies to this refresh.
        let instruction = synthesisPrompt
        let wire: [(role: ChatMessage.Role, content: String)] = [(.user, context + "\n\n---\n\n" + instruction)]
        do {
            let reply = try await callProvider(key: key, messages: wire)
            let clean = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                synthesisText = clean
                synthesisGeneratedAt = Date()
                // Which model wrote it — ALWAYS, not only when a fallback did. Showing the name only
                // for the retry made its absence carry the hidden meaning "your chosen model", which
                // is legible only to someone who already knows the rule.
                synthesisModel = lastAnsweringModel
                synthesisCameFromFallback = lastTimeoutFallbackModel != nil
                lastSynthesisError = nil   // a good generation clears the previous failure
            }
        } catch {
            // Today's card stays clean — the stale-day drop above already ran, so a failure here shows
            // the rule-based read, never a previous day's paragraph. But it is no longer silent
            // EVERYWHERE: swallowing the reason is why "the heavy model produces no synthesis" could
            // not be diagnosed from inside the app at all, by the user or by anyone reading the code.
            // The reason is recorded for the Coach screen to surface, where an error banner already
            // exists and belongs.
            lastSynthesisError = (error as? AICoachError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Why the last Today-synthesis generation failed, or nil if the last one succeeded (or none has
    /// run). Surfaced in the Coach screen rather than on Today: the Today card's contract is to always
    /// show something useful, and a provider error is not that — but "synthesis is blank and I cannot
    /// tell why" is exactly the question the Coach screen should answer.
    @Published private(set) var lastSynthesisError: String?

    /// Full data context = the metrics summary + recent workouts (+ an OPT-IN on-device-signals summary
    /// when the second consent is on). Used when the user has granted data access.
    func buildFullContext() async -> String {
        var ctx = buildContext()
        ctx += "\n\n" + (await recentWorkoutsBlock())
        // Derived stress: a single Baevsky Stress Index summary line over today's R-R, computed the same
        // way StressView does. Gated here under `dataConsent` (the caller only reaches buildFullContext()
        // with consent on), so it rides the SAME consent + text-only channel as the HRV/RHR summary, a
        // derived number, never raw R-R egress. Omitted when there aren't enough clean beats yet.
        if let line = await stressIndexLine() { ctx += "\n\n" + line }
        // Third opt-in: deterministic roll-ups (training load, sleep debt, baseline deviations) over the
        // SAME `repo.days` rows the summary above is built from. Pure and store-free, so it adds no read
        // and no egress surface — only resolution on data already in the context.
        if includeDerivedTrends {
            let trends = Self.derivedTrendsBlock(days: repo.days)
            if !trends.isEmpty { ctx += "\n\n" + trends }
        }
        // The three-pillar targets — the SAME deterministic numbers the Lock-Screen card prints, so the
        // synthesis and the card can never disagree about today's prescription. The "right now" HR is a
        // two-minute mean over already-persisted samples (summary-only, same egress posture as the rest).
        let targets = repo.cachedLiveTargets()
        let anchor = repo.cachedWidgetAnchor()
        let nowSec = Int(Date().timeIntervalSince1970)
        let recentHr = await repo.hrSamples(from: nowSec - 120, to: nowSec, limit: 200)
        let currentBpm: Int? = recentHr.isEmpty ? nil
            : Int((Double(recentHr.reduce(0) { $0 + $1.bpm }) / Double(recentHr.count)).rounded())
        let targetsBlock = Self.dailyTargetsBlock(
            targets: targets,
            charge: anchor?.recovery.map { Int($0.rounded()) },
            effortToday: anchor?.strain.map { Int($0.rounded()) },
            currentBpm: currentBpm,
            breatheNow: currentBreathe?() ?? nil,
            midsleepSec: await repo.habitualMidsleepSec(),
            typicalSleepHours: BatteryEstimator.typicalSleepHours(
                nightlyHours: repo.days.compactMap { $0.totalSleepMin.map { $0 / 60.0 } }),
            effortScale: EffortScale(rawValue: UserDefaults.standard.string(
                forKey: UnitPrefs.effortScaleKey) ?? "") ?? .hundred)
        if !targetsBlock.isEmpty { ctx += "\n\n" + targetsBlock }
        if includeOnDeviceSignals {
            let block = await onDeviceSignalsBlock()
            if !block.isEmpty { ctx += "\n\n" + block }
        }
        return ctx
    }

    /// One derived stress line for the coach context: the Baevsky Stress Index over TODAY's R-R, read
    /// via the same device-aware repository R-R union as `StressView`,
    /// then summarised to a single number with `StressIndex.stressIndex(rr:)`. Returns nil when the
    /// store is unavailable or there are too few clean beats (the histogram needs >= 20), so the line is
    /// simply absent, never a fabricated value. Summary-only: the raw R-R never leaves the device.
    func stressIndexLine() async -> String? {
        let cal = Calendar.current
        let from = Int(cal.startOfDay(for: Date()).timeIntervalSince1970)
        let to = Int(Date().timeIntervalSince1970)
        let rr = await repo.rrIntervals(from: from, to: to, limit: 200_000)
        guard let si = StressIndex.stressIndex(rr: rr) else { return nil }
        return Self.stressIndexSummary(si: si)
    }

    /// Pure formatter for the derived stress line, kept separate so it is unit-testable without a store.
    /// One summary number, labelled, with a plain-English note that it's an autonomic-balance proxy.
    static func stressIndexSummary(si: Double) -> String {
        "Stress (SI): \(Int(si.rounded())) (Baevsky Stress Index over today's R-R; higher means more sympathetic / under load; an autonomic-balance proxy, not a clinical figure)."
    }

    /// A SUMMARY-ONLY block of the new on-device signals, the user's strongest n-of-1 correlations
    /// (lag-aware EffectRanker) and a one-line roll-up of their Lab Book markers. Plain sentences, never
    /// raw readings: this rides the same text channel as the metrics summary, so the no-raw-egress posture
    /// holds. Gated by the caller on the second opt-in; returns "" when there's nothing worth adding.
    func onDeviceSignalsBlock() async -> String {
        var lines: [String] = []

        // 1. Strongest behaviour→outcome associations (EffectRanker over the journal × Charge).
        let entries = await repo.journalEntries()
        // Yes days and NO days, kept apart. A day with no journal row for the question lands in
        // neither, so an unanswered day is never counted as a No (BehaviorInsights.effect).
        var byBehaviour: [String: Set<String>] = [:]
        var controls: [String: Set<String>] = [:]
        for e in entries {
            if e.answeredYes { byBehaviour[e.question, default: []].insert(e.day) }
            else { controls[e.question, default: []].insert(e.day) }
        }
        if !byBehaviour.isEmpty {
            let outcomeByDay = Dictionary(
                repo.days.compactMap { d in d.recovery.map { (d.day, $0) } },
                uniquingKeysWith: { _, last in last })
            let ranked = EffectRanker.rank(behaviors: byBehaviour, controls: controls,
                                           outcomeByDay: outcomeByDay, outcome: "Charge")
                .filter { $0.effect.significant }
                .prefix(3)
            if !ranked.isEmpty {
                lines.append("STRONGEST PERSONAL PATTERNS (the user's own data — association, not cause):")
                for r in ranked { lines.append("  • " + r.sentence()) }
            }
        }

        // 2. Lab Book markers roll-up (count + latest of a few, never the full history).
        if let store = await repo.storeHandle() {
            var markerSummaries: [String] = []
            for category in LabMarkerCategory.allCases {
                let rows = (try? await store.labMarkers(deviceId: repo.deviceId, category: category.rawValue)) ?? []
                let byKey = Dictionary(grouping: rows, by: { $0.markerKey })
                for (key, kRows) in byKey {
                    guard let latest = kRows.sorted(by: { $0.takenAt < $1.takenAt }).last else { continue }
                    let name = MarkerCatalog.definition(for: key)?.displayName ?? key
                    let value = latest.value.map { "\(LabBookFormat.value($0, key: key)) \(latest.unit)" } ?? latest.valueText ?? "—"
                    markerSummaries.append("\(name) \(value)")
                }
            }
            if !markerSummaries.isEmpty {
                lines.append("")
                lines.append("LAB BOOK (the user's own logged health numbers — not medical advice; do not interpret as clinical findings):")
                lines.append("  " + markerSummaries.prefix(8).joined(separator: ", "))
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Dispatch to the user's chosen provider client, with ONE fallback retry on a timeout.
    ///
    /// A timed-out request is the one failure worth re-spending on automatically: the key is good, the
    /// endpoint is right, and the request simply did not finish in time — usually because a large model
    /// was asked for a long answer over a mobile link. Retrying on the provider's cheapest (and so
    /// fastest) model converts that into an answer often enough to be worth a single extra request.
    ///
    /// Exactly one retry, and only on `.timedOut`. Every other failure — a rejected key, a rate limit,
    /// a 4xx — would fail identically on a smaller model, so retrying would double the latency of an
    /// error the user still has to read. Anything more than one retry would stack timeouts on top of a
    /// request that is already too slow.
    ///
    /// Already on the cheapest model (or on Custom, where there is no cheaper id to pick — see
    /// `cheapestModel`), the retry is SKIPPED rather than re-sending the identical request. Repeating a
    /// request that just exhausted the full timeout budget on the same model mostly buys the user a
    /// second long wait before the same error — the first attempt already proved the deadline is the
    /// binding constraint, not luck. Reporting promptly is the better outcome.
    ///
    /// The retry never mutates `model`. The user's chosen model is theirs; a rescued answer must not
    /// silently re-point the picker at a smaller model for every request that follows.
    private func callProvider(key: String,
                              messages: [(role: ChatMessage.Role, content: String)]) async throws -> String {
        let attempted = model
        do {
            let reply = try await provider.client.send(
                key: key,
                model: attempted,
                systemPrompt: systemPrompt,
                messages: messages,
                session: session
            )
            lastTimeoutFallbackModel = nil
            lastAnsweringModel = attempted
            lastAttemptTrace = nil   // a clean success needs no explanation
            return reply
        } catch let failure as AICoachError where failure.deservesLighterModelRetry {
            // Only worth a second request if it is a genuinely DIFFERENT, lighter one. Same model ⇒
            // rethrow immediately rather than repeat a request that already failed exactly this way.
            guard let fallback = provider.cheapestModel, fallback != model else {
                lastTimeoutFallbackModel = nil
                lastAttemptTrace = "\(attempted) failed (\(failure.shortLabel)); no lighter model to "
                    + "fall back to, so no retry was attempted."
                throw failure
            }
            lastTimeoutFallbackModel = fallback
            do {
                let reply = try await provider.client.send(
                    key: key,
                    model: fallback,
                    systemPrompt: systemPrompt,
                    messages: messages,
                    session: session
                )
                lastAnsweringModel = fallback
                lastAttemptTrace = "\(attempted) failed (\(failure.shortLabel)) — this answer came from "
                    + "\(fallback) instead."
                return reply
            } catch let retryFailure {
                let retryLabel = (retryFailure as? AICoachError)?.shortLabel
                    ?? retryFailure.localizedDescription
                lastAttemptTrace = "\(attempted) failed (\(failure.shortLabel)), and the retry on "
                    + "\(fallback) also failed (\(retryLabel))."
                throw retryFailure
            }
        } catch {
            // Not retry-worthy: record WHY there was no second attempt, so "the retry didn't run" is
            // an answerable question rather than a guess.
            lastTimeoutFallbackModel = nil
            let label = (error as? AICoachError)?.shortLabel ?? error.localizedDescription
            lastAttemptTrace = "\(attempted) failed (\(label)). That kind of failure is not retried — a "
                + "lighter model would fail the same way."
            throw error
        }
    }

    /// The model the last retry fell back to, or nil if no retry has happened. Set even when the retry
    /// itself fails, so the surfaced error can say a fallback was already tried rather than implying
    /// the user's first choice was the only attempt.
    ///
    /// `@Published` because it is displayed. It was neither published nor read by any view, which meant
    /// the retry was completely unobservable: a user seeing no synthesis could not tell whether the
    /// fallback ran and failed, or never ran at all — and neither could anyone reading the code. That
    /// ambiguity is what made "the retry doesn't work" impossible to diagnose from the outside.
    @Published private(set) var lastTimeoutFallbackModel: String?

    /// The model that actually produced the last successful reply — the selected one, or the fallback
    /// when the retry rescued it. Always set on success, unlike `lastTimeoutFallbackModel`, which is
    /// nil precisely when nothing went wrong and so cannot answer "which model wrote this?".
    @Published private(set) var lastAnsweringModel: String?

    /// A human-readable trace of what the last generation actually did — which model was tried, whether
    /// a fallback was attempted, and how it ended. Surfaced in the Coach screen.
    ///
    /// Deliberately records SUCCESS as well as failure. A retry that silently rescues the request is
    /// just as confusing as one that silently does nothing: the answer arrives from a model the picker
    /// does not name, and the user is left believing their chosen model produced it.
    @Published private(set) var lastAttemptTrace: String?

    /// Sliding window over the chat: the FIRST user turn (it carries the metrics context) plus the most
    /// recent `maxHistoryMessages`, dropping the middle. Sending the whole growing history crowds out the
    /// reply on small-context local servers (Ollama defaults to a 2048-token window, the Custom
    /// provider's main use case) and balloons token cost/latency on cloud providers. (parity with Android)
    /// True when a transcript last written on `lastEpochDay` should be retired before a question asked
    /// on `todayEpochDay` — i.e. the conversation crossed into a new local day.
    ///
    /// STRICTLY forward (`>`, never `!=`): a clock that moves BACKWARDS — the user flying west, a
    /// timezone change, an NTP correction — must not wipe a conversation they are in the middle of.
    /// Only real elapsed days retire a transcript. A nil `lastEpochDay` (nothing sent yet) is never
    /// stale. Kotlin twin: `CoachViewModel.isStaleConversation`.
    ///
    /// `nonisolated` because it is a pure function of its arguments. AICoachEngine is @MainActor, so
    /// without this the rule inherits that isolation and cannot be called from a synchronous test —
    /// which is exactly how the first attempt at this twin failed to compile. Isolating a function
    /// that touches no state buys nothing and costs its testability.
    nonisolated static func isStaleConversation(lastEpochDay: Int?, todayEpochDay: Int) -> Bool {
        guard let lastEpochDay else { return false }
        return todayEpochDay > lastEpochDay
    }

    /// Days since the epoch in the LOCAL calendar — the twin of Kotlin's `LocalDate.now().toEpochDay()`.
    ///
    /// Counted with calendar day arithmetic from `startOfDay`, not by dividing an interval by 86,400:
    /// a day is not always 86,400 seconds (DST), and the rule only needs a value that increments
    /// exactly once per local midnight and orders correctly. Injectable so the tests never depend on
    /// the machine's clock or zone.
    nonisolated static func localEpochDay(_ date: Date = Date(), calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: date)
        let epoch = Date(timeIntervalSince1970: 0)
        return calendar.dateComponents([.day], from: epoch, to: start).day ?? 0
    }

    private static let maxHistoryMessages = 10
    private func windowedMessages() -> [ChatMessage] {
        guard messages.count > Self.maxHistoryMessages + 1,
              let firstUser = messages.firstIndex(where: { $0.role == .user }) else { return messages }
        let recentStart = messages.count - Self.maxHistoryMessages
        // If the first user turn already falls inside the recent window, that window covers it.
        if firstUser >= recentStart { return Array(messages.suffix(Self.maxHistoryMessages)) }
        return [messages[firstUser]] + Array(messages[recentStart...])
    }

    /// The chat as `(role, content)` pairs, with the metrics context prepended to the first user turn.
    private func wireMessages(context: String) -> [(role: ChatMessage.Role, content: String)] {
        var out: [(role: ChatMessage.Role, content: String)] = []
        var contextInjected = false
        for m in windowedMessages() {
            if m.role == .user && !contextInjected {
                contextInjected = true
                out.append((.user, context + "\n\n---\n\nQuestion: " + m.text))
            } else {
                out.append((m.role, m.text))
            }
        }
        return out
    }

    // MARK: - Context builder

    /// Build a compact plain-text summary of the user's recent data: last ~14 days of
    /// recovery/strain/sleep-hours/HRV/restingHR where present, plus 30-day averages, plus a few
    /// recent workouts. Kept well under ~1500 tokens. If there's no data, it says so.
    func buildContext() -> String {
        let days = repo.days // oldest → newest
        var lines: [String] = ["USER BIOMETRIC SUMMARY (the user's own wearable data):"]

        guard !days.isEmpty else {
            return """
            USER BIOMETRIC SUMMARY:
            No wearable data is available yet. Acknowledge this and give general, encouraging guidance \
            while inviting the user to sync their device so future advice can reference real numbers.
            """
        }

        // Last ~14 days, newest first for readability.
        let recent = Array(days.suffix(14)).reversed()
        lines.append("")
        lines.append(includeDerivedTrends
            ? "Recent days (newest first) — charge(0-100), effort(0-100), rest/sleep(h), HRV(RMSSD, ms), RHR(bpm), deep/REM sleep(min), eff(sleep efficiency %), wakes(disturbances), SDNN(broad HRV, ms), skin(skin temperature — labelled either absolute °C or a signed deviation vs baseline). Fields are omitted on nights that didn't record them:"
            : "Recent days (newest first) — charge(0-100), effort(0-100), rest/sleep(h), HRV(ms), RHR(bpm):")
        for d in recent {
            lines.append("  " + dayLine(d))
        }

        // 30-day averages.
        let last30 = Array(days.suffix(30))
        lines.append("")
        lines.append("30-day averages:")
        lines.append("  charge: \(avgInt(last30.compactMap { $0.recovery }))"
                     + ", effort: \(avgOne(last30.compactMap { $0.strain }))"
                     + ", sleep: \(avgSleepHours(last30))h"
                     + ", HRV: \(avgInt(last30.compactMap { $0.avgHrv })) ms"
                     + ", RHR: \(avgInt(last30.compactMap { $0.restingHr.map(Double.init) })) bpm")
        // Additional vitals when present (#124, the coach used to see only recovery/strain/sleep/HRV/RHR).
        lines.append("  SpO2: \(avgInt(last30.compactMap { $0.spo2Pct }))%"
                     + ", respiration: \(avgOne(last30.compactMap { $0.respRateBpm }))/min"
                     + ", skin-temp deviation: \(avgOne(last30.compactMap { $0.skinTempDevC }))°C"
                     + ", steps: \(avgInt(last30.compactMap { $0.steps.map(Double.init) }))/day"
                     + ", active energy: \(avgInt(last30.compactMap { $0.activeKcalEst }))kcal/day")

        return lines.joined(separator: "\n")
    }

    /// Append recent workouts to an existing context string. Async (workouts are read from the store),
    /// so callers that want workouts in the context can await this and feed the result to `send`'s
    /// flow via the chat, kept separate so `buildContext()` stays synchronous per the spec.
    func recentWorkoutsBlock(limit: Int = 6) async -> String {
        let rows = await repo.workoutRows(days: 30) // newest first
        guard !rows.isEmpty else { return "Recent workouts: none recorded in the last 30 days." }
        var lines = ["Recent workouts (newest first):"]
        for w in rows.prefix(limit) {
            var parts = ["  \(dateString(w.startTs)) \(w.sport)"]
            if let dur = w.durationS { parts.append("\(Int((dur / 60).rounded())) min") }
            if let s = w.strain { parts.append("effort \(String(format: "%.1f", s))") }
            if let hr = w.avgHr { parts.append("avg HR \(hr)") }
            if let kcal = w.energyKcal { parts.append("\(Int(kcal.rounded())) kcal") }
            if let dist = w.distanceM { parts.append("\(String(format: "%.1f", dist / 1000)) km") }
            lines.append(parts.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Derived trends (third opt-in)

    /// A block of DETERMINISTIC roll-ups over the same `repo.days` rows the core summary is built from:
    /// training load (CTL/ATL/TSB), the sleep-debt ledger, personal baseline deviations, and a data-density
    /// note. Pure — no store reads, no network, no new consent surface beyond the caller's gate.
    ///
    /// Why these and not more raw days: the context targets a small token budget, and one computed sentence
    /// ("acute load is above chronic") carries more usable signal per token than ten additional day rows the
    /// model would have to trend-fit itself — badly, and unstated. Every figure here is one the app already
    /// computes for its own screens, so the coach stops disagreeing with the UI the user is looking at.
    ///
    /// Each sub-block is INDEPENDENTLY nil-guarded: a user with 6 nights gets the sleep-debt line and no
    /// training-load line, rather than a fabricated ratio. Returns "" when nothing qualifies.
    nonisolated static func derivedTrendsBlock(days: [DailyMetric]) -> String {
        guard !days.isEmpty else { return "" }
        var lines: [String] = []

        // 1. Training load — CTL (chronic), ATL (acute), TSB (form). The engine reports its OWN state, so
        //    a still-calibrating model is labelled as such instead of being read as established.
        let loads = days.map { TrainingLoadEngine.DailyLoad(day: $0.day, load: $0.strain) }
        let tl = TrainingLoadEngine.evaluate(days: loads)
        if tl.isAvailable, let ctl = tl.ctl, let atl = tl.atl, let tsb = tl.tsb {
            let qualifier = tl.state == .building ? " (still calibrating — treat as directional)" : ""
            let direction: String
            if tsb < -5 { direction = "acute load is running ABOVE chronic — accumulating fatigue" }
            else if tsb > 5 { direction = "acute load is BELOW chronic — freshening / detraining" }
            else { direction = "acute and chronic load are balanced" }
            lines.append(String(format:
                "Training load: chronic (42d) %.1f, acute (7d) %.1f, balance %+.1f — %@%@",
                ctl, atl, tsb, direction, qualifier))
        }

        // 2. Sleep debt — a running balance vs need over the ledger window. Far more actionable than the
        //    per-night durations alone, which the model would otherwise have to sum by eye.
        let ledger = SleepDebt.ledger(series: days.map { (day: $0.day, totalSleepMin: $0.totalSleepMin) })
        if ledger.nightCount > 0 {
            let hours = ledger.magnitudeMin / 60.0
            if ledger.magnitudeMin < SleepDebt.onTargetBandMin {
                lines.append(String(format:
                    "Sleep debt: balanced over the last %d nights (within %.0f min of a %.1fh nightly need).",
                    ledger.nightCount, SleepDebt.onTargetBandMin, ledger.needMin / 60.0))
            } else {
                lines.append(String(format:
                    "Sleep debt: %.1fh %@ over the last %d nights, against a %.1fh nightly need.",
                    hours, ledger.isDebt ? "SHORT" : "surplus", ledger.nightCount, ledger.needMin / 60.0))
            }
        }

        // 3. Personal baselines — the single biggest interpretive win. Absolutes ("HRV 42ms") tell the model
        //    nothing without knowing what is normal FOR THIS USER; a z turns every vital into a deviation.
        //    Only `usable` baselines are emitted, so a cold-start never ships a confident-looking z.
        var deviations: [String] = []
        func deviationLine(_ label: String, values: [Double?], cfgKey: String, latest: Double?, unit: String) {
            guard let latest, let cfg = Baselines.metricCfg[cfgKey] else { return }
            let state = Baselines.foldHistory(values, cfg: cfg)
            guard state.usable else { return }
            let dev = Baselines.deviation(latest, state: state)
            let tag = state.status == .provisional ? ", provisional baseline" : ""
            deviations.append(String(format: "%@ %.0f%@ vs personal baseline %.0f%@ (z %+.1f%@)",
                                     label, latest, unit, state.baseline, unit, dev.z, tag))
        }
        let newest = days.last
        deviationLine("HRV", values: days.map { $0.avgHrv }, cfgKey: "hrv",
                      latest: newest?.avgHrv, unit: "ms")
        deviationLine("Resting HR", values: days.map { $0.restingHr.map(Double.init) }, cfgKey: "resting_hr",
                      latest: newest?.restingHr.map(Double.init), unit: "bpm")
        deviationLine("Respiration", values: days.map { $0.respRateBpm }, cfgKey: "resp",
                      latest: newest?.respRateBpm, unit: "/min")
        if !deviations.isEmpty {
            lines.append("Latest night vs personal baseline (z = SDs from this user's own norm; |z| <= 1 is typical):")
            for d in deviations { lines.append("  • " + d) }
        }

        // 4. Data density — so thin history is hedged rather than over-read as a real trend.
        let scored = days.filter { $0.recovery != nil }.count
        lines.append("Data density: \(scored) scored days of \(days.count) in history"
                     + (scored < 14 ? " — thin history, so state trends cautiously and avoid strong claims." : "."))

        guard !lines.isEmpty else { return "" }
        return (["DERIVED TRENDS (computed on-device from the days above — deterministic, not model estimates):"]
                + lines).joined(separator: "\n")
    }

    /// The THREE-PILLAR targets block: the same deterministic numbers the Live Activity card prints
    /// (`LiveTargets` / `DailyTargets`), stated to the coach so the synthesis cites the
    /// figures the user is already looking at instead of inventing parallel ones. Pure and
    /// independently nil-guarded like `derivedTrendsBlock`: a cold-start field is simply absent,
    /// never fabricated. Returns "" when nothing qualifies.
    nonisolated static func dailyTargetsBlock(targets: LiveTargets,
                                              charge: Int?,
                                              effortToday: Int?,
                                              currentBpm: Int?,
                                              breatheNow: Bool?,
                                              midsleepSec: Int?,
                                              typicalSleepHours: Double?,
                                              effortScale: EffortScale = .hundred) -> String {
        var lines: [String] = []

        // Pillar 2 — breathing & heart rate: the live autonomic read behind the card's # marker.
        // No ceiling, no threshold (both retired 260830): the verdict is the body's own — fast
        // RMSSD against the rolling baseline, exercise-gated — and a minute it cannot judge is said
        // plainly, never guessed.
        if let bpm = currentBpm {
            var line = "Heart right now: \(bpm) bpm; autonomic read: "
            switch breatheNow {
            case .some(true):
                line += "STRESSED — beat-to-beat variability has dipped well below the rolling "
                        + "baseline while at rest; the card is showing the # breathe marker, and a "
                        + "short breathing or meditation break is the prescription."
            case .some(false):
                line += "calm (variability in its normal range, or the elevation is exercise doing "
                        + "its job)."
            case .none:
                line += "not judgeable this minute (too few clean beats) — no claim either way."
            }
            lines.append(line)
        }

        // Pillar 3 — activity & exercise: the prescribed session and the effort/calorie targets
        // priced FROM it, vs today so far. Effort figures render on the USER'S chosen display scale
        // — they said "optimal effort is around 10" meaning the 0–21 axis, and a 0–100 figure under
        // the same label reads as a different (and absurdly large) prescription.
        let scaleMax = UnitFormatter.effortScaleMax(effortScale)
        let effortTargetText = targets.effortTarget.map {
            UnitFormatter.effortDisplay(Double($0), scale: effortScale)
        }
        let todayEffortText = UnitFormatter.effortDisplay(Double(effortToday ?? 0), scale: effortScale)
        if targets.restDay {
            lines.append("Today's prescription: REST — the body's readiness read says recover, so "
                         + "there is no session and no calorie ask; the effort target is simply to "
                         + "hold near \(effortTargetText ?? todayEffortText) of \(scaleMax).")
        } else if let minutes = targets.sessionMinutes {
            let hrText = targets.sessionHrBpm.map { " at ~\($0) bpm" } ?? ""
            var line = "Today's prescribed session: \(minutes) min\(hrText) (from today's charge "
                       + "band + the multi-signal readiness read + last night's Rest — the body's "
                       + "state, never past habits)."
            if let targetText = effortTargetText {
                line += " Completing it lands the day at effort \(targetText) of \(scaleMax) "
                        + "(so far today: \(todayEffortText))."
            }
            if let kcal = targets.kcalTargetKcal {
                line += " Exercise-calorie target: \(kcal) kcal (that session through the app's own "
                        + "Keytel model); exercise calories so far today: "
                        + "\(targets.exerciseKcalToday.map(String.init) ?? "0") kcal (above resting "
                        + "burn — resting metabolism is deliberately excluded from both sides)."
            }
            lines.append(line)
        }

        // Pillar 1 — rest & sleep: tonight's target and the precise bedtime that achieves it.
        if let need = targets.sleepNeedTonightMin {
            lines.append(sleepPlanLine(needTonightMin: need, midsleepSec: midsleepSec,
                                       typicalSleepHours: typicalSleepHours))
        }

        guard !lines.isEmpty else { return "" }
        return (["TODAY'S TARGETS (deterministic, computed on-device from the user's own history — the "
                 + "SAME numbers the Lock-Screen card shows; cite these, do not invent alternatives):"]
                + lines.map { "  • " + $0 }).joined(separator: "\n")
    }

    /// Tonight's sleep prescription as one sentence: the target duration, plus the precise "asleep by"
    /// time derived from the learned sleep model (#547 — habitual wake = midsleep + half the typical
    /// night, the same circular arithmetic as `BatteryEstimator.bedtimeAlert`). Cold-start (no learned
    /// midsleep or duration yet) states only the duration — a fixed-clock bedtime would be wrong for
    /// exactly the shift/late sleepers the learner exists for.
    nonisolated static func sleepPlanLine(needTonightMin: Int, midsleepSec: Int?,
                                          typicalSleepHours: Double?) -> String {
        let target = String(format: "%dh%02d", needTonightMin / 60, needTonightMin % 60)
        guard let midsleep = midsleepSec, (0..<86_400).contains(midsleep),
              let typical = typicalSleepHours, typical > 0 else {
            return "Sleep tonight: target \(target) asleep."
        }
        func hhmm(_ secOfDay: Int) -> String {
            let s = ((secOfDay % 86_400) + 86_400) % 86_400
            return String(format: "%02d:%02d", s / 3600, (s % 3600) / 60)
        }
        let wakeSec = midsleep + Int((typical * 1800).rounded())
        let bedSec = wakeSec - needTonightMin * 60
        return "Sleep tonight: target \(target) asleep — aim to be asleep by \(hhmm(bedSec)) "
               + "against the learned habitual wake of about \(hhmm(wakeSec))."
    }

    // MARK: Formatting helpers

    private func dayLine(_ d: DailyMetric) -> String {
        Self.dayLine(d, wide: includeDerivedTrends)
    }

    /// Pure per-day formatter, kept static so it is unit-testable without a store or a live engine.
    ///
    /// `wide` appends the sleep-architecture / autonomic columns that already ride the SAME `DailyMetric`
    /// row the narrow line is built from — deep/REM, efficiency, disturbances, SDNN and ABSOLUTE skin
    /// temperature. None of these is a new read: the coach has held them all along and used five columns.
    ///
    /// Skin temperature comes from `skinTempDevC`, which is BIMODAL: strap nights store a deviation from
    /// baseline, while CSV/Apple imports write an absolute wrist °C into the same column. They are told
    /// apart by magnitude (`VitalBands.isAbsoluteSkinTemp`) and LABELLED accordingly, so the model is
    /// never handed a "+31.2" that it reads as a deviation. Emitting one fixed meaning for both would
    /// misreport every row of whichever kind lost the coin toss.
    ///
    /// Every field is optional and simply ABSENT when nil — never a placeholder that could be read as a
    /// measured zero.
    nonisolated static func dayLine(_ d: DailyMetric, wide: Bool) -> String {
        var parts: [String] = [d.day + ":"]
        parts.append("charge " + (d.recovery.map { "\(Int($0.rounded()))" } ?? "—"))
        parts.append("effort " + (d.strain.map { String(format: "%.1f", $0) } ?? "—"))
        parts.append("rest " + (d.totalSleepMin.map { String(format: "%.1fh", $0 / 60) } ?? "—"))
        parts.append("HRV " + (d.avgHrv.map { "\(Int($0.rounded()))ms" } ?? "—"))
        parts.append("RHR " + (d.restingHr.map { "\($0)bpm" } ?? "—"))
        guard wide else { return parts.joined(separator: ", ") }

        if let deep = d.deepMin { parts.append("deep \(Int(deep.rounded()))m") }
        if let rem = d.remMin { parts.append("REM \(Int(rem.rounded()))m") }
        if let eff = d.efficiency { parts.append("eff \(Int(eff.rounded()))%") }
        if let dist = d.disturbances { parts.append("wakes \(dist)") }
        if let sdnn = d.avgSdnn { parts.append("SDNN \(Int(sdnn.rounded()))ms") }
        if let skin = d.skinTempDevC {
            parts.append(VitalBands.isAbsoluteSkinTemp(skin)
                ? String(format: "skin %.1f°C", skin)
                : String(format: "skin %+.1f°C vs baseline", skin))
        }
        return parts.joined(separator: ", ")
    }

    private func avgOne(_ xs: [Double]) -> String {
        guard !xs.isEmpty else { return "—" }
        return String(format: "%.1f", xs.reduce(0, +) / Double(xs.count))
    }

    private func avgInt(_ xs: [Double]) -> String {
        guard !xs.isEmpty else { return "—" }
        return "\(Int((xs.reduce(0, +) / Double(xs.count)).rounded()))"
    }

    private func avgSleepHours(_ days: [DailyMetric]) -> String {
        let mins = days.compactMap { $0.totalSleepMin }
        guard !mins.isEmpty else { return "—" }
        return String(format: "%.1f", (mins.reduce(0, +) / Double(mins.count)) / 60)
    }

    private func dateString(_ ts: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
}
