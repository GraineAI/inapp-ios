import Foundation

/// Why Graine refused a request, as the wire says it (WIRE.md "Errors") — a word this build does not know is `unknown`.
public enum GraineErrorCode: Equatable, Hashable, Sendable, CustomStringConvertible {
    case invalidKey
    case originRefused
    /// Too many requests: wait `GraineServiceError.retryAfterSeconds` when the server said how long.
    case rateLimited
    case invalidRequest
    case identityRequired
    case deviceLimit
    case schedulingOff
    case tooSoon
    case tooFar
    case outsideWindow
    case tooManyPending
    case notFound
    case unavailable
    /// `startWorkflow`: no such workflow, "Your app can start this" is off for it, or it isn't published.
    case notAllowed
    /// `startWorkflow`: this device isn't one of the user's signed-in devices, or the agent requires a verified user.
    case notVerified
    /// No answer came back.
    case network
    /**
     * "Only my apps" is on for the agent and this app is not one of its apps
     * (its bundle id or Team ID is not listed). Final: nothing is retried.
     */
    case appNotAllowed
    /**
     * "Require a verified app" is on and this install holds no valid proof
     * that it is your app. The SDK proves it (App Attest) and asks once more
     * before this reaches you; `GraineServiceError.reason` says why
     * (`missing`, `expired`, `invalid`, `debug_token_unknown`, `debug_token_expired`).
     */
    case appNotVerified
    /**
     * "Require verified users" is on and the identity was not proven by an
     * identity token. The SDK asks `identityTokenRefresher` (when set) and
     * tries once more before this reaches you.
     */
    case identityUnverified
    /**
     * The agent requires a server token and none came with the request: set
     * `GraineConfig.tokenProvider`. The SDK has already asked the provider
     * again and sent the request once more. New in 0.14.4.
     */
    case tokenRequired
    /**
     * The server token could not be checked — `GraineServiceError.reason` says
     * why: `malformed`, `signature`, `unknown_key`, `issuer` or
     * `not_yet_valid`. Already asked for again and retried once. New in 0.14.4.
     */
    case tokenInvalid
    /// The server token expired, and a fresh one did not come in time (already asked for again and retried once). New in 0.14.4.
    case tokenExpired
    /**
     * The server token does not allow this — `GraineServiceError.reason`:
     * `agent` (it is another agent's), `user` (another user's) or `scope` (it
     * lacks the scope this needs). Never retried. New in 0.14.4.
     */
    case tokenScope
    /// This publishable key was revoked: ship the agent's new key (Agent → Embed & Widgets → Keys). Never retried. New in 0.14.4.
    case keyRevoked
    /// A website's bot check did not pass. Apps never see it: it applies only to websites. New in 0.14.4.
    case botCheckFailed
    case unknown(String)

    private static let words: [(GraineErrorCode, String)] = [
        (.invalidKey, "invalid_key"), (.originRefused, "origin_refused"), (.rateLimited, "rate_limited"),
        (.invalidRequest, "invalid_request"), (.identityRequired, "identity_required"), (.deviceLimit, "device_limit"),
        (.schedulingOff, "scheduling_off"), (.tooSoon, "too_soon"), (.tooFar, "too_far"), (.outsideWindow, "outside_window"),
        (.tooManyPending, "too_many_pending"), (.notFound, "not_found"), (.unavailable, "unavailable"),
        (.notAllowed, "not_allowed"), (.notVerified, "not_verified"), (.network, "network"),
        (.appNotAllowed, "app_not_allowed"), (.appNotVerified, "app_not_verified"), (.identityUnverified, "identity_unverified"),
        (.tokenRequired, "token_required"), (.tokenInvalid, "token_invalid"), (.tokenExpired, "token_expired"),
        (.tokenScope, "token_scope"), (.keyRevoked, "key_revoked"), (.botCheckFailed, "bot_check_failed"),
    ]

    public init(wire: String) {
        let word = wire.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self = GraineErrorCode.words.first { $0.1 == word }?.0 ?? .unknown(wire)
    }

    /// The word on the wire: `too_soon`, …; an unknown code's own.
    public var wire: String {
        if case .unknown(let raw) = self { return raw }
        return GraineErrorCode.words.first { $0.0 == self }?.1 ?? ""
    }

    public var description: String { wire }
}

/**
 * A REFUSAL FROM GRAINE, or a request that never got an answer: the route's
 * `{error, code, reason?}` (WIRE.md "Errors"), its HTTP status, and — for
 * `rateLimited` — how long the server asked to wait. `code` is the stable
 * part: branch on it; `message` is a sentence fit to show; `reason`, the
 * server's one word beside the code when it gave one.
 */
public struct GraineServiceError: LocalizedError, Equatable, Sendable {
    public let code: GraineErrorCode
    public let message: String
    /// For `rateLimited`: the seconds the server asked to wait (`Retry-After`), when it said.
    public let retryAfterSeconds: Int?
    /// The HTTP status; 0 when no answer came back.
    public let status: Int
    /**
     * The server's one-word reason beside the code, when it gave one — for
     * `appNotVerified`, why (`missing`, `expired`, `invalid`,
     * `debug_token_unknown`…); for a server token, which part failed (`scope`,
     * `user`, `agent`, `signature`, `unknown_key`, …); nil otherwise.
     */
    public let reason: String?

    public var errorDescription: String? { message }

    public init(code: GraineErrorCode, message: String, status: Int = 0, retryAfterSeconds: Int? = nil, reason: String? = nil) {
        self.code = code
        self.message = message
        self.status = status
        self.retryAfterSeconds = retryAfterSeconds
        self.reason = reason
    }

    /// The answer's `reason` — one word beside the code (`scope`, `signature`, …) — or nil.
    static func reason(_ body: [String: Any]?) -> String? {
        guard let raw = JSON.unwrap(body?["reason"]) as? String else { return nil }
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return word.isEmpty ? nil : word
    }

    /// The error for an answer that was not a success: the body's words when it has them.
    static func from(status: Int, body: [String: Any]?, headers: [String: String] = [:], now: Date = Date()) -> GraineServiceError {
        let said = JSON.nonEmpty(body?["error"])
        if status == 0 {
            return GraineServiceError(code: .network, message: said ?? "Graine could not be reached. Check the connection and try again.")
        }
        // The one rule every SDK follows (sdk/contract/http-status.json): a body's non-blank string code wins, trimmed.
        let sent = (JSON.unwrap(body?["code"]) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let code = !sent.isEmpty ? GraineErrorCode(wire: sent) : GraineServiceError.code(status: status)
        return GraineServiceError(
            code: code,
            message: said ?? defaultMessage(code) ?? "Graine refused the request (\(status)).",
            status: status,
            retryAfterSeconds: retryAfter(headers["retry-after"], body: body, now: now),
            reason: reason(body)
        )
    }

    /**
     * A refusal's code when its body names none — the one rule on every SDK
     * (sdk/contract/http-status.json): 502, 503, 504 and the CDN's 520–524 —
     * a gateway that could not reach Graine or gave up waiting, Graine itself
     * down — are `unavailable`; a bare 500 and every status the rule does not
     * name are `unknown("http_<status>")`.
     */
    static func code(status: Int) -> GraineErrorCode {
        switch status {
        case 400, 422: return .invalidRequest
        case 401: return .invalidKey
        case 403: return .originRefused
        case 404: return .notFound
        case 429: return .rateLimited
        case 502, 503, 504, 520...524: return .unavailable
        default: return .unknown("http_\(status)")
        }
    }

    /// The sentence for a refusal whose answer had none of its own: what to change, for the developer who reads it.
    static func defaultMessage(_ code: GraineErrorCode) -> String? {
        switch code {
        case .appNotAllowed:
            return "This app is not one of the agent's apps. Add its bundle id and Team ID under Embed & Widgets → Install → Your apps, or turn off \"Only my apps\"."
        case .appNotVerified:
            return "The agent requires a verified app, and this install could not prove it is your app."
        case .identityUnverified:
            return "The agent requires verified users, and the identity was not proven by an identity token."
        default:
            // A refusal for the server token, the key or the bot check: the SDK's own sentence, which says what to do.
            return ClientTokenRules.refusalCodes.contains(code.wire) ? ClientTokenRules.sentence(code.wire) : nil
        }
    }

    /// `Retry-After` as seconds (a number, or an HTTP date from now), else the body's `retryAfterSeconds`.
    static func retryAfter(_ header: String?, body: [String: Any]?, now: Date) -> Int? {
        if let raw = header?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            if let seconds = Double(raw), seconds.isFinite, seconds >= 0 { return Int(seconds.rounded(.up)) }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: raw) { return max(0, Int(date.timeIntervalSince(now).rounded(.up))) }
        }
        for key in ["retryAfterSeconds", "retryAfter"] {
            if let v = JSON.unwrap(body?[key]), let n = JSON.number(v), n.doubleValue.isFinite, n.doubleValue >= 0 {
                return Int(n.doubleValue.rounded(.up))
            }
        }
        return nil
    }
}

/**
 * THE SDK'S OWN REQUESTS to Graine's embed routes: JSON in, JSON out, the
 * publishable key in every body (as the session and ticket routes take it),
 * no `Origin` (an app is `app://` on the agent's Allowed domains, or one of
 * its apps). Every body leaves through `EmbedSeal.seal` — the app's
 * declaration, and the identity's proof inside `identity` (APP-IDENTITY.md
 * §1) — once the Team ID has been read, and, with server tokens in play,
 * carries the newest token inside that door (ClientTokenWire: a refusal a
 * fresh token can lift is sent once more with one). An answer's
 * `verification` is kept (§2.2); a refusal the SDK can cure —
 * `app_not_verified` (prove the app), `identity_unverified` (a fresh identity
 * token) — is cured and the request sent once more. The network is the calls'
 * seam, so tests answer for it.
 */
final class EmbedRequests {
    let baseUrl: String
    let publishableKey: String
    private let network: CallNetwork
    /// The app's and the user's proofs; nil sends the fields as they are (tests of older behaviour, the preview).
    weak var security: AppVerification?
    /// This agent's server tokens; nil, or none in play, sends none.
    private let tokens: ClientTokens?

    init(baseUrl: String, publishableKey: String, network: CallNetwork, security: AppVerification? = nil, tokens: ClientTokens? = nil) {
        self.baseUrl = GraineProtocol.trimTrailingSlashes(baseUrl)
        self.publishableKey = publishableKey
        self.network = network
        self.security = security
        self.tokens = tokens
    }

    /// The body: the key first, then the fields, in order; sealed — `declaration` in place of the current one when given.
    func body(_ fields: [(String, WireJSON)], declaration: AppDeclaration? = nil) -> Data {
        var all = EmbedSeal.seal([("publishableKey", .string(publishableKey))] + fields, security)
        if let declaration = declaration {
            all.removeAll { $0.0 == "app" }
            all.append(("app", declaration.wire))
        }
        return Data(WireJSON.object(all).text.utf8)
    }

    /**
     * POST `path` once, sealed: the status (0 when no answer came back), the
     * JSON body and the headers. The answer's `verification` is kept here.
     * Inside the seal, the agent's server token (ClientTokenWire): a
     * `newConnection` — the session, a ticket — waits for a usable one, and a
     * refusal a fresh one can lift is sent once more with it; `completion`
     * hears the last answer.
     */
    func send(
        _ path: String,
        _ fields: [(String, WireJSON)],
        declaration: AppDeclaration? = nil,
        patient: Bool = false,
        newConnection: Bool = false,
        completion: @escaping (Int, [String: Any]?, [String: String]) -> Void
    ) {
        guard let url = URL(string: baseUrl + path) else {
            completion(-1, nil, [:])
            return
        }
        let go = { [weak self] in
            guard let self = self else { return }
            let security = self.security
            let answered: (Int, Data?, [String: String]) -> Void = { status, data, headers in
                let parsed = JSON.object(from: data)
                security?.heard(status: status, body: parsed, identityValue: EmbedSeal.identityValue(fields))
                completion(status, parsed, headers)
            }
            let body = self.body(fields, declaration: declaration)
            let network = self.network
            ClientTokenWire.post(self.tokens, body: body, newConnection: newConnection, send: { json, answer in
                if patient {
                    network.postPatiently(url, body: json, completion: answer)
                } else {
                    network.postWithHeaders(url, body: json, completion: answer)
                }
            }, done: answered)
        }
        // The declaration carries the Team ID: read once per launch, off the main thread, before the first request.
        if let security = security { security.whenDeclarationReady(go) } else { go() }
    }

    /**
     * POST `path`; a 2xx answers its JSON object (an empty one for no body),
     * anything else a GraineServiceError. `cure`: an `app_not_verified` or
     * `identity_unverified` refusal is cured (the app proven, the identity
     * token refreshed) and the request sent once more, sealed again.
     */
    func post(
        _ path: String,
        _ fields: [(String, WireJSON)],
        cure: Bool = true,
        declaration: AppDeclaration? = nil,
        completion: @escaping (Result<[String: Any], GraineServiceError>) -> Void
    ) {
        guard URL(string: baseUrl + path) != nil else {
            completion(.failure(GraineServiceError(code: .invalidRequest, message: "baseUrl \"\(baseUrl)\" is not a URL.")))
            return
        }
        func once(_ done: @escaping (Result<[String: Any], GraineServiceError>) -> Void) {
            send(path, fields, declaration: declaration) { status, body, headers in
                if (200...299).contains(status) {
                    done(.success(body ?? [:]))
                } else {
                    done(.failure(GraineServiceError.from(status: max(0, status), body: body, headers: headers)))
                }
            }
        }
        once { [weak self] result in
            guard cure, case .failure(let error) = result, error.code == .appNotVerified || error.code == .identityUnverified,
                  let security = self?.security else { return completion(result) }
            security.cure(error) { retry in
                guard retry else { return completion(result) }
                once(completion)
            }
        }
    }

    func post(_ path: String, _ fields: [(String, WireJSON)], cure: Bool = true) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            post(path, fields, cure: cure) { result in continuation.resume(with: result) }
        }
    }
}
