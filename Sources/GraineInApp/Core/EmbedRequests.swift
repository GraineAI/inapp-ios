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
    /// No answer came back.
    case network
    case unknown(String)

    private static let words: [(GraineErrorCode, String)] = [
        (.invalidKey, "invalid_key"), (.originRefused, "origin_refused"), (.rateLimited, "rate_limited"),
        (.invalidRequest, "invalid_request"), (.identityRequired, "identity_required"), (.deviceLimit, "device_limit"),
        (.schedulingOff, "scheduling_off"), (.tooSoon, "too_soon"), (.tooFar, "too_far"), (.outsideWindow, "outside_window"),
        (.tooManyPending, "too_many_pending"), (.notFound, "not_found"), (.unavailable, "unavailable"), (.network, "network"),
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
 * `{error, code}` (WIRE.md "Errors"), its HTTP status, and — for
 * `rateLimited` — how long the server asked to wait. `code` is the stable
 * part: branch on it; `message` is a sentence fit to show.
 */
public struct GraineServiceError: LocalizedError, Equatable, Sendable {
    public let code: GraineErrorCode
    public let message: String
    /// For `rateLimited`: the seconds the server asked to wait (`Retry-After`), when it said.
    public let retryAfterSeconds: Int?
    /// The HTTP status; 0 when no answer came back.
    public let status: Int

    public var errorDescription: String? { message }

    public init(code: GraineErrorCode, message: String, status: Int = 0, retryAfterSeconds: Int? = nil) {
        self.code = code
        self.message = message
        self.status = status
        self.retryAfterSeconds = retryAfterSeconds
    }

    /// The error for an answer that was not a success: the body's words when it has them.
    static func from(status: Int, body: [String: Any]?, headers: [String: String] = [:], now: Date = Date()) -> GraineServiceError {
        let said = JSON.nonEmpty(body?["error"])
        if status == 0 {
            return GraineServiceError(code: .network, message: said ?? "Graine could not be reached. Check the connection and try again.")
        }
        let code = JSON.nonEmpty(body?["code"]).map { GraineErrorCode(wire: $0) } ?? {
            switch status {
            case 400, 422: return .invalidRequest
            case 401: return .invalidKey
            case 403: return .originRefused
            case 404: return .notFound
            case 429: return .rateLimited
            case 503: return .unavailable
            default: return .unknown("http_\(status)")
            }
        }()
        return GraineServiceError(
            code: code,
            message: said ?? "Graine refused the request (\(status)).",
            status: status,
            retryAfterSeconds: retryAfter(headers["retry-after"], body: body, now: now)
        )
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
 * no `Origin` (an app is `app://` on the agent's Allowed domains). The network
 * is the calls' seam, so tests answer for it.
 */
final class EmbedRequests {
    let baseUrl: String
    let publishableKey: String
    private let network: CallNetwork

    init(baseUrl: String, publishableKey: String, network: CallNetwork) {
        self.baseUrl = GraineProtocol.trimTrailingSlashes(baseUrl)
        self.publishableKey = publishableKey
        self.network = network
    }

    /// The body: the key first, then the fields, in order.
    func body(_ fields: [(String, WireJSON)]) -> Data {
        Data(WireJSON.object([("publishableKey", .string(publishableKey))] + fields).text.utf8)
    }

    /// POST `path`; a 2xx answers its JSON object (an empty one for no body), anything else a GraineServiceError.
    func post(_ path: String, _ fields: [(String, WireJSON)], completion: @escaping (Result<[String: Any], GraineServiceError>) -> Void) {
        guard let url = URL(string: baseUrl + path) else {
            completion(.failure(GraineServiceError(code: .invalidRequest, message: "baseUrl \"\(baseUrl)\" is not a URL.")))
            return
        }
        network.postWithHeaders(url, body: body(fields)) { status, data, headers in
            let parsed = JSON.object(from: data)
            if (200...299).contains(status) {
                completion(.success(parsed ?? [:]))
            } else {
                completion(.failure(GraineServiceError.from(status: status, body: parsed, headers: headers)))
            }
        }
    }

    func post(_ path: String, _ fields: [(String, WireJSON)]) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            post(path, fields) { result in continuation.resume(with: result) }
        }
    }
}
