import Foundation

/*
 * PAST SESSIONS (0.14.3; sdk/contract/PUBLIC-STATE.md "Past sessions", the
 * wire and its vectors in sdk/contract/past-sessions.json): the identified
 * customer's earlier sessions with this agent, newest first — as the
 * dashboard's Execution History lists them — and each one's transcript. Only
 * for the customer `identify` names, from a device bound to them; never
 * anyone else's. `GraineChat.pastSessions` holds the list.
 *
 * Pure: Foundation only, so `swift test` proves it on a Mac.
 */

/// Where a past session happened (`GraineSessionSummary.channel`).
public enum GraineSessionChannel: String, Equatable, Sendable {
    /// Typed, in the chat.
    case chat
    /// Talked with the agent in the app.
    case voice
    /// A call with the agent — `direction` says who rang whom.
    case call
}

/// Who started a past call or talk (`GraineSessionSummary.direction`).
public enum GraineSessionDirection: String, Equatable, Sendable {
    /// The customer reached the agent.
    case inbound
    /// The agent reached the customer.
    case outbound
}

/**
 * ONE OF THE CUSTOMER'S EARLIER SESSIONS with this agent, as
 * `GraineChat.pastSessions` lists them — newest first. `id` is the session's
 * execution id, the one Execution History shows; open its chat history with
 * `GraineChat.sessionTranscript(id:)`.
 */
public struct GraineSessionSummary: Equatable, Sendable, Identifiable {
    /// The session's id — the id Execution History shows; pass it to `sessionTranscript(id:)`.
    public let id: String
    /// When it started.
    public let startedAt: Date
    /// When it ended; nil when Graine did not say.
    public let endedAt: Date?
    /// How long it lasted, in whole seconds; nil when Graine did not say.
    public let durationSeconds: Int?
    /// Typed (`.chat`), talked in the app (`.voice`) or a call (`.call`).
    public let channel: GraineSessionChannel
    /// Who started a call or a talk; nil for a chat, and when Graine did not say.
    public let direction: GraineSessionDirection?
    /// How it ended, in plain words — `completed`, `missed`, `failed`, … — as Graine says it; "" when it did not.
    public let status: String
    /// How many messages it holds.
    public let turns: Int
    /// The customer's first line, at most 120 characters; "" when there is none.
    public let preview: String

    public init(
        id: String,
        startedAt: Date,
        endedAt: Date? = nil,
        durationSeconds: Int? = nil,
        channel: GraineSessionChannel = .chat,
        direction: GraineSessionDirection? = nil,
        status: String = "",
        turns: Int = 0,
        preview: String = ""
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.channel = channel
        self.direction = direction
        self.status = status
        self.turns = turns
        self.preview = preview
    }
}

/// One message of a past session's transcript: who said it, what, and when.
public struct GraineSessionTurn: Equatable, Sendable {
    /// `.customer` or `.agent`.
    public let role: GraineRole
    /// What was said.
    public let text: String
    /// When it was said.
    public let at: Date

    public init(role: GraineRole, text: String, at: Date) {
        self.role = role
        self.text = text
        self.at = at
    }
}

/**
 * A PAST SESSION'S CHAT HISTORY, oldest first — what
 * `GraineChat.sessionTranscript(id:)` answers: the session as the list
 * describes it, and every message said in it.
 */
public struct GraineSessionTranscript: Equatable, Sendable, Identifiable {
    /// The session's id.
    public let id: String
    /// When it started; nil when Graine did not say.
    public let startedAt: Date?
    /// When it ended; nil when Graine did not say.
    public let endedAt: Date?
    /// How long it lasted, in whole seconds; nil when Graine did not say.
    public let durationSeconds: Int?
    /// Typed (`.chat`), talked in the app (`.voice`) or a call (`.call`).
    public let channel: GraineSessionChannel
    /// Who started a call or a talk; nil for a chat, and when Graine did not say.
    public let direction: GraineSessionDirection?
    /// How it ended, in plain words, as Graine says it; "" when it did not.
    public let status: String
    /// What was said, oldest first.
    public let turns: [GraineSessionTurn]

    public init(
        id: String,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        durationSeconds: Int? = nil,
        channel: GraineSessionChannel = .chat,
        direction: GraineSessionDirection? = nil,
        status: String = "",
        turns: [GraineSessionTurn] = []
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.channel = channel
        self.direction = direction
        self.status = status
        self.turns = turns
    }
}

/**
 * THE CUSTOMER'S PAST SESSIONS, AS STATE — `GraineChat.pastSessions`: the
 * sessions loaded so far (newest first), whether a page is loading, whether
 * there is another, and the last refusal's word.
 */
public struct GrainePastSessions: Equatable, Sendable {
    /// The sessions loaded so far, newest first; empty until `refreshPastSessions()`.
    public let sessions: [GraineSessionSummary]
    /// A page is on its way.
    public let loading: Bool
    /// There is another page: `loadMorePastSessions()` appends it.
    public let hasMore: Bool
    /// Why the last page did not come, as a word — `identity_required`, `device_limit`, `rate_limited`, `unavailable`, `network`, …; nil when it came.
    public let error: String?

    public init(sessions: [GraineSessionSummary] = [], loading: Bool = false, hasMore: Bool = false, error: String? = nil) {
        self.sessions = sessions
        self.loading = loading
        self.hasMore = hasMore
        self.error = error
    }
}

/**
 * THE PAST-SESSIONS WIRE, read and written (sdk/contract/past-sessions.json):
 * `/api/embed/sessions/list` → `{sessions, next}`, `/api/embed/sessions/transcript`
 * → `{id, startedAt, endedAt, durationSeconds, channel, direction, status, turns}`.
 * Every rule of the contract's comment, and nothing else: an item without an
 * id or a readable `startedAt` is skipped; `endedAt` / `durationSeconds`
 * unreadable → nil; a channel other than voice/call is chat; a direction
 * other than inbound/outbound is nil; turns not a whole number ≥ 0 → 0;
 * preview (and status) not a string → ""; a turn without a user/assistant
 * role, a string text or a readable `at` is skipped.
 */
enum PastSessionsWire {
    static let listPath = "/api/embed/sessions/list"
    static let transcriptPath = "/api/embed/sessions/transcript"

    /// A page of the list: its sessions as the SDK keeps them (an id repeated is kept once, first wins), and where the next page starts.
    static func page(_ body: [String: Any]) -> (sessions: [GraineSessionSummary], next: String?) {
        let raw = (JSON.unwrap(body["sessions"]) as? [Any]) ?? []
        var seen = Set<String>()
        var sessions: [GraineSessionSummary] = []
        for entry in raw {
            guard let session = summary(entry), seen.insert(session.id).inserted else { continue }
            sessions.append(session)
        }
        return (sessions, cursor(body["next"]))
    }

    /// `kept`, then the page's sessions whose id is not kept already, in order.
    static func appending(_ page: [GraineSessionSummary], to kept: [GraineSessionSummary]) -> [GraineSessionSummary] {
        var seen = Set(kept.map(\.id))
        return kept + page.filter { seen.insert($0.id).inserted }
    }

    /// One session of a page; nil without an id or a readable `startedAt`.
    static func summary(_ raw: Any?) -> GraineSessionSummary? {
        guard let o = JSON.unwrap(raw) as? [String: Any],
              let id = identifier(o["id"]),
              let startedAt = date(o["startedAt"]) else { return nil }
        return GraineSessionSummary(
            id: id,
            startedAt: startedAt,
            endedAt: date(o["endedAt"]),
            durationSeconds: seconds(o["durationSeconds"]),
            channel: channel(o["channel"]),
            direction: direction(o["direction"]),
            status: words(o["status"]),
            turns: count(o["turns"]),
            preview: words(o["preview"])
        )
    }

    /// A transcript's answer; `asked` is its id when the answer does not say.
    static func transcript(_ body: [String: Any], id asked: String) -> GraineSessionTranscript {
        let raw = (JSON.unwrap(body["turns"]) as? [Any]) ?? []
        return GraineSessionTranscript(
            id: identifier(body["id"]) ?? asked,
            startedAt: date(body["startedAt"]),
            endedAt: date(body["endedAt"]),
            durationSeconds: seconds(body["durationSeconds"]),
            channel: channel(body["channel"]),
            direction: direction(body["direction"]),
            status: words(body["status"]),
            turns: raw.compactMap { turn($0) }
        )
    }

    /// One message: a user/assistant role, a string text and a readable `at`; nil otherwise.
    static func turn(_ raw: Any?) -> GraineSessionTurn? {
        guard let o = JSON.unwrap(raw) as? [String: Any],
              let role = role(o["role"]),
              let text = JSON.unwrap(o["text"]) as? String,
              let at = date(o["at"]) else { return nil }
        return GraineSessionTurn(role: role, text: text, at: at)
    }

    /// The wire's `user` is the customer, its `assistant` the agent; any other role is nobody's.
    static func role(_ raw: Any?) -> GraineRole? {
        switch word(raw) {
        case "user": return .customer
        case "assistant": return .agent
        default: return nil
        }
    }

    static func channel(_ raw: Any?) -> GraineSessionChannel {
        switch word(raw) {
        case "voice": return .voice
        case "call": return .call
        default: return .chat
        }
    }

    static func direction(_ raw: Any?) -> GraineSessionDirection? {
        word(raw).flatMap { GraineSessionDirection(rawValue: $0) }
    }

    /// The cursor of the next page: a string with something in it, as sent; nil at the end.
    static func cursor(_ raw: Any?) -> String? {
        guard let s = JSON.unwrap(raw) as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    /// An id: a string with something in it, as sent.
    static func identifier(_ raw: Any?) -> String? {
        cursor(raw)
    }

    /// Whole seconds: a finite number ≥ 0, rounded; nil for anything else (a string, a boolean).
    static func seconds(_ raw: Any?) -> Int? {
        guard let v = JSON.unwrap(raw), let n = JSON.number(v) else { return nil }
        let d = n.doubleValue
        guard d.isFinite, d >= 0, d.rounded() < Double(Int.max) else { return nil }
        return Int(d.rounded())
    }

    /// A count: a whole number ≥ 0; 0 for anything else.
    static func count(_ raw: Any?) -> Int {
        guard let v = JSON.unwrap(raw), let n = JSON.number(v) else { return 0 }
        let d = n.doubleValue
        guard d.isFinite, d >= 0, d == d.rounded(), d < Double(Int.max) else { return 0 }
        return Int(d)
    }

    /// A string as sent; "" for anything else.
    static func words(_ raw: Any?) -> String {
        (JSON.unwrap(raw) as? String) ?? ""
    }

    private static func word(_ raw: Any?) -> String? {
        (JSON.unwrap(raw) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Times: ISO-8601, as the wire writes them

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// An ISO-8601 time with its zone ("2026-10-21T12:00:05Z", fractions allowed); nil for anything else — a number, "yesterday".
    static func date(_ raw: Any?) -> Date? {
        guard let s = (JSON.unwrap(raw) as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return plain.date(from: s) ?? fractional.date(from: s)
    }

    /// A time as the wire writes it, in UTC: "2026-10-21T12:00:05Z", with milliseconds only when it has them.
    static func iso(_ date: Date) -> String {
        let t = date.timeIntervalSince1970
        return (t == t.rounded(.down) ? plain : fractional).string(from: date)
    }

    // MARK: - Written back, in the wire's own shape (for a bridge)

    /// `{sessions: [{id, startedAt, endedAt, durationSeconds, channel, direction, status, turns, preview}], loading, hasMore, error}`.
    static func json(_ state: GrainePastSessions) -> [String: Any] {
        [
            "sessions": state.sessions.map { json($0) },
            "loading": state.loading,
            "hasMore": state.hasMore,
            "error": state.error.map { $0 as Any } ?? NSNull(),
        ]
    }

    static func json(_ s: GraineSessionSummary) -> [String: Any] {
        [
            "id": s.id,
            "startedAt": iso(s.startedAt),
            "endedAt": s.endedAt.map { iso($0) as Any } ?? NSNull(),
            "durationSeconds": s.durationSeconds.map { $0 as Any } ?? NSNull(),
            "channel": s.channel.rawValue,
            "direction": s.direction.map { $0.rawValue as Any } ?? NSNull(),
            "status": s.status,
            "turns": s.turns,
            "preview": s.preview,
        ]
    }

    /// `{id, startedAt, endedAt, durationSeconds, channel, direction, status, turns: [{role, text, at}]}` — roles in the wire's words, `user` and `assistant`.
    static func json(_ t: GraineSessionTranscript) -> [String: Any] {
        [
            "id": t.id,
            "startedAt": t.startedAt.map { iso($0) as Any } ?? NSNull(),
            "endedAt": t.endedAt.map { iso($0) as Any } ?? NSNull(),
            "durationSeconds": t.durationSeconds.map { $0 as Any } ?? NSNull(),
            "channel": t.channel.rawValue,
            "direction": t.direction.map { $0.rawValue as Any } ?? NSNull(),
            "status": t.status,
            "turns": t.turns.map { turn -> [String: Any] in
                ["role": turn.role == .customer ? "user" : "assistant", "text": turn.text, "at": iso(turn.at)]
            },
        ]
    }
}
