import Foundation

// MARK: - Provider enum

enum AIProvider: String, CaseIterable, Identifiable {
    case openAI
    case anthropic
    case gemini
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI:    return "OpenAI"
        case .anthropic: return "Anthropic"
        case .gemini:    return "Google Gemini"
        case .custom:    return "Custom (OpenAI-compatible)"
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI:    return "gpt-4o-mini"
        case .anthropic: return "claude-sonnet-4-6"
        case .gemini:    return "gemini-flash-latest"   // stable alias → current Flash, no version churn (#400)
        case .custom:    return ""   // the user picks the model their server serves
        }
    }

    /// The cheapest / fastest model this provider offers, used as the one-shot fallback when a request
    /// times out. Cheapest is a proxy for fastest here, which is what actually matters: the retry only
    /// helps if it is likelier to finish inside the same deadline than the attempt that just failed.
    ///
    /// Nil for `.custom`: that provider points at whatever server the user runs, its catalogue is not
    /// known ahead of time, and there is no basis for calling one of its ids cheaper than another —
    /// so a Custom timeout is reported rather than silently re-sent to a model we guessed at.
    var cheapestModel: String? {
        switch self {
        case .openAI:    return "gpt-4.1-nano"
        case .anthropic: return "claude-haiku-4-5-20251001"
        case .gemini:    return "gemini-flash-lite-latest"
        case .custom:    return nil
        }
    }

    /// Models offered in the picker. A "Custom…" path in the UI lets the user pick any id beyond
    /// these, and `refreshModels()` can merge the provider's live list.
    var modelOptions: [String] {
        switch self {
        case .openAI:
            return ["gpt-4o", "gpt-4o-mini", "gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano"]
        case .anthropic:
            return [
                "claude-opus-4-8",
                "claude-sonnet-4-6",
                "claude-haiku-4-5-20251001",
                "claude-3-7-sonnet-latest",
                "claude-3-5-sonnet-latest",
                "claude-3-5-haiku-latest",
                "claude-3-opus-latest"
            ]
        case .gemini:
            // Stable `-latest` ALIASES, not pinned versions (#400): they always resolve to the current
            // stable model in each tier, so Gemini's rapid releases never need a code bump. `refreshModels()`
            // still merges the live `/models` catalogue, so a user with a key can pin a concrete version.
            return [
                "gemini-pro-latest",
                "gemini-flash-latest",
                "gemini-flash-lite-latest"
            ]
        case .custom:
            return []   // populated from the server's /models (refreshModels) or typed in
        }
    }

    var endpoint: URL {
        switch self {
        case .openAI:    return URL(string: "https://api.openai.com/v1/chat/completions")!
        case .anthropic: return URL(string: "https://api.anthropic.com/v1/messages")!
        case .gemini:    return URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!
        case .custom:    return AIProvider.customURL(path: "/chat/completions")
        }
    }

    var modelsEndpoint: URL {
        switch self {
        case .openAI:    return URL(string: "https://api.openai.com/v1/models")!
        case .anthropic: return URL(string: "https://api.anthropic.com/v1/models")!
        case .gemini:    return URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!
        case .custom:    return AIProvider.customURL(path: "/models")
        }
    }

    var client: any AIProviderClient {
        switch self {
        case .openAI:    return OpenAIClient()
        case .anthropic: return AnthropicClient()
        case .gemini:    return GeminiClient()
        case .custom:    return CustomClient()
        }
    }

    // MARK: - Custom (OpenAI-compatible) base URL

    /// UserDefaults key for the Custom provider's base URL (e.g. a local LLM server such as Ollama /
    /// LM Studio / llama.cpp: `http://localhost:11434/v1`). `AICoachEngine` exposes it for editing.
    static let customBaseURLKey = "ai.customBaseURL"
    static let customAuthHeaderKey = "ai.customAuthHeader"

    /// The user-set Custom base URL, normalised. Byte-parity with Android `AiCoach.normalizeCustomBaseUrl`.
    static var customBaseURL: String {
        normalizeCustomBaseURL(UserDefaults.standard.string(forKey: customBaseURLKey) ?? "")
    }

    /// #1074: normalise the Custom base URL so the derived `/chat/completions` and `/models` endpoints
    /// are always well-formed. The user may paste the base (`http://…:11434/v1`) OR the whole chat URL
    /// (`…/v1/chat/completions`) — the latter otherwise made the model scan hit `…/chat/completions/models`
    /// and silently return nothing. Trim, drop trailing slashes, strip one trailing OpenAI-style chat
    /// path, drop trailing slashes again. Pure — unit-tested. Byte-identical to Android normalizeCustomBaseUrl.
    static func normalizeCustomBaseURL(_ url: String) -> String {
        var base = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        for suffix in ["/chat/completions", "/completions"] {
            if base.lowercased().hasSuffix(suffix) {
                base.removeLast(suffix.count)
                while base.hasSuffix("/") { base.removeLast() }
                break
            }
        }
        return base
    }

    static var customAuthHeader: CustomAIAuthHeader {
        let raw = UserDefaults.standard.string(forKey: customAuthHeaderKey)
        return CustomAIAuthHeader(rawValue: raw ?? "") ?? .bearer
    }

    static func applyCustomAuthHeader(_ key: String, to request: inout URLRequest) {
        guard !key.isEmpty else { return }
        switch customAuthHeader {
        case .bearer:
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .xAPIKey:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        }
    }

    /// Build a Custom endpoint by appending `path` to the user's base URL (trailing slashes tolerated).
    /// Falls back to a loopback placeholder when unset — the request then fails with a clear network
    /// error until the user sets a URL.
    static func customURL(path: String) -> URL {
        var base = customBaseURL
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + path) ?? URL(string: "http://localhost" + path)!
    }

    /// #321 gatekeeper for the Custom (local LLM) provider — the byte-parity twin of Android
    /// `AiCoach.guardCustomUrl` (#187), which Swift was previously missing. `https://` is always fine;
    /// plain `http://` is allowed ONLY to a private-network host (loopback / RFC-1918 / link-local /
    /// `*.local`), so a public cleartext endpoint can never egress. Throws `AICoachError.badCustomURL`
    /// with an actionable message on rejection. Called by `CustomClient.send` + `fetchModels`, i.e. on
    /// BOTH Custom network paths (mirrors Kotlin `customChatUrl` / `customModelsUrl`).
    static func guardCustomBaseURL() throws {
        let base = customBaseURL   // already trimmed / trailing-slash-stripped by the accessor
        guard let comps = URLComponents(string: base),
              let host = comps.host, !host.isEmpty,
              let scheme = comps.scheme?.lowercased(), !scheme.isEmpty else {
            throw AICoachError.badCustomURL(
                "That server URL isn't valid. Use http://<host>:<port> for a local server, or https://… for a remote one.")
        }
        if scheme == "https" { return }
        guard scheme == "http" else {
            throw AICoachError.badCustomURL(
                "Unsupported URL scheme \"\(scheme)\". Use http:// for a local server or https:// for a remote one.")
        }
        guard isPrivateLANOrLoopback(host) else {
            throw AICoachError.badCustomURL(
                "Plain http:// is only allowed to a local-network server (localhost, 10.x, 172.16-31.x, "
                + "192.168.x, 169.254.x, or a .local name). Use https:// to reach \"\(host)\".")
        }
    }

    /// True when `host` is on the device's own machine or its private LAN, so plain `http://` to it never
    /// crosses the public internet: loopback (localhost / 127.0.0.0/8 / ::1), RFC-1918 (10/8, 172.16/12,
    /// 192.168/16), link-local (169.254/16 / fe80::/10), fc00::/7 ULA, and any `*.local` mDNS name.
    /// Byte-identical decisions to Android `AiCoach.isPrivateLanOrLoopback`.
    static func isPrivateLANOrLoopback(_ host: String) -> Bool {
        let raw = host.trimmingCharacters(in: .whitespacesAndNewlines)   // match Kotlin String.trim()
        let h = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if h.isEmpty { return false }
        // Only apply the fc/fd/fe80 classification to a real IPv6 LITERAL (bracketed, or contains a colon),
        // so a public NAME like "fclient.evil.com" can't be mistaken for a ULA and allowed cleartext.
        let isIPv6Literal = raw.hasPrefix("[") || h.contains(":")
        if isIPv6Literal {
            if h == "::1" { return true }
            if h.hasPrefix("fc") || h.hasPrefix("fd") || h.hasPrefix("fe80:") { return true }
            return false
        }
        if h == "localhost" || h.hasSuffix(".localhost") { return true }
        if h.hasSuffix(".local") && h.count > ".local".count { return true }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if parts.count != 4 { return false }
        let octets = parts.map { Int($0) ?? -1 }
        if octets.contains(where: { $0 < 0 || $0 > 255 }) { return false }
        let a = octets[0], b = octets[1]
        switch true {
        case a == 127: return true                       // 127.0.0.0/8 loopback
        case a == 10: return true                        // 10.0.0.0/8
        case a == 172 && (16...31).contains(b): return true  // 172.16.0.0/12
        case a == 192 && b == 168: return true           // 192.168.0.0/16
        case a == 169 && b == 254: return true           // 169.254.0.0/16 link-local
        default: return false
        }
    }
}

enum CustomAIAuthHeader: String, CaseIterable, Identifiable {
    case bearer
    case xAPIKey

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bearer: return "Bearer"
        case .xAPIKey: return "x-api-key"
        }
    }
}

// MARK: - Provider protocol

protocol AIProviderClient {
    /// Send a chat turn and return the assistant reply text.
    func send(
        key: String,
        model: String,
        systemPrompt: String,
        messages: [(role: ChatMessage.Role, content: String)],
        session: URLSession
    ) async throws -> String

    /// Fetch the provider's live model list and return plain model ids.
    func fetchModels(key: String, session: URLSession) async throws -> [String]
}

// MARK: - Shared HTTP helpers

/// Execute a request, map HTTP status codes to `AICoachError`, return the decoded JSON object.
func performRequest(_ req: URLRequest, session: URLSession) async throws -> [String: Any] {
    let data: Data
    let response: URLResponse

    do {
        (data, response) = try await session.data(for: req)
    } catch let urlError as URLError where AICoachError.isTimeoutCode(urlError.code) {
        // Distinct from `.network` so the retry path can key off a real signal. Matching on
        // `error.localizedDescription` instead would be a localized-string comparison — it would work
        // in English and silently stop retrying in every other language the app ships.
        throw AICoachError.timedOut
    } catch {
        throw AICoachError.network(error.localizedDescription)
    }

    guard let http = response as? HTTPURLResponse else {
        throw AICoachError.network("no HTTP response")
    }

    switch http.statusCode {
    case 200...299:
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AICoachError.decode
        }

        return obj
    case 401, 403:
        throw AICoachError.badKey
    case 429:
        throw AICoachError.rateLimited
    case 504, 524:
        // Gateway / origin timeout: the request did reach the provider, which then ran out of time on
        // it. Same shape of failure as a client-side timeout from the caller's point of view, and worth
        // the same one retry on a faster model, so it is reported as one rather than as a generic 5xx.
        throw AICoachError.timedOut
    case 500, 502, 503, 529:
        // Transient server-side trouble: 500 internal, 502 bad gateway, 503 unavailable/overloaded,
        // 529 overloaded (Anthropic's). None of these say anything about the request — the key is
        // good, the model id is real, the payload parsed. The provider is simply busy or briefly
        // broken, which is exactly the failure a second attempt exists for.
        //
        // Separate from the `.server` catch-all because that is reported as terminal, and a 503 is
        // not: Gemini returns it routinely when a model is overloaded, and that is what killed a
        // fallback attempt in practice even after the retry had started firing correctly.
        throw AICoachError.transientServer(http.statusCode, providerErrorMessage(from: data))
    default:
        throw AICoachError.server(http.statusCode, providerErrorMessage(from: data))
    }
}

/// Best-effort extraction of a human-readable message from a provider error body.
func providerErrorMessage(from data: Data) -> String {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }

    if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String { return msg }
    if let msg = obj["message"] as? String { return msg }

    return ""
}

/// #1074: the error to throw when a 200 response has no assistant content. Some OpenAI-compatible
/// servers (e.g. a hand-set model they don't offer) return the real error INSIDE the 200 body rather
/// than a 4xx; surface it instead of a blank decode error, so the cause is visible. Byte-parity with
/// Android `AiCoach.emptyReplyMessage`.
func emptyReplyError(_ json: [String: Any]) -> AICoachError {
    if let err = json["error"] as? [String: Any], let msg = err["message"] as? String, !msg.isEmpty {
        return .emptyReply("The provider returned an error: \(msg)")
    }
    return .emptyReply("The provider returned an empty reply. If you set a custom model by hand, check "
        + "that the model name is one the provider actually offers.")
}
