import Foundation

/*
 * THE CHAT'S WIRE AND ITS TRANSCRIPT — the React Native SDK's text path
 * (client.ts `openSocket` / `onFrame` / `say` / `submitWidget` /
 * `reportEvent`), spoken by this SDK itself. The socket is the same one the
 * native call uses, opened as text: a `text` ticket (or `?text_chat=1` on the
 * direct socket), `call_type: "text_chat"` in the variables, and no audio.
 * Pure: Foundation only, so a Mac proves every frame and every turn.
 */

enum ChatWire {
    /// The ticket's mode, and the variables' call type, for a typed conversation.
    static let ticketMode = "text"
    static let callType = "text_chat"
    /// Silence before a reply is no longer "typing…".
    static let replyWaitSeconds = 30.0
    /// The reconnect ladder after a drop: each wait, then the chat is offline until a send or a retry.
    static let reconnectDelays: [Double] = [1, 2, 4, 8, 15, 15]
    /// Messages typed while offline, kept to be sent; older ones beyond this are not sent.
    static let queueLimit = 20
    /**
     * With no window showing it, the chat stays connected until nothing has
     * been said either way for this long — the idle window Graine's server
     * applies — then hangs up (DESIGN.md "How long a conversation lasts").
     */
    static let idleSeconds = 300.0
    /// The close codes with which Graine ends a conversation itself: idle (4408, `idle_timeout`) and the session's time limit (4410).
    static let endedByGraine: Set<Int> = [4408, 4410]

    /// A customer turn.
    static func textFrame(_ text: String) -> String {
        WireJSON.object([("type", .string("text")), ("data", .string(text))]).text
    }

    /// The structured answer to a component; the sentence goes as its own `text` turn.
    static func widgetResultFrame(widgetId: String, data: [String: Any]) -> String {
        WireJSON.object([
            ("type", .string("widget_result")),
            ("widget_id", .string(widgetId)),
            ("data", WireJSON.from(data)),
        ]).text
    }

    /// Keys of an app event the runtime reads at the event's own level; anything else rides in `data`.
    private static let eventKeys: Set<String> = ["cooldown_seconds", "max_per_session", "quiet", "data"]

    /**
     * `{type: "app_event", event: {name, detail?, cooldown_seconds?, max_per_session?, quiet?, data?}}` —
     * from the shape `GraineVoice.reportEvent` takes (name, detail, a data map that may carry those keys).
     */
    static func appEventFrame(name: String, detail: String?, data: [String: Any]) -> String {
        var fields: [(String, WireJSON)] = [("name", .string(name))]
        if let detail = detail, !detail.isEmpty { fields.append(("detail", .string(detail))) }
        var rest: [String: Any] = [:]
        for key in data.keys.sorted() {
            guard let value = data[key] else { continue }
            if eventKeys.contains(key), key != "data" {
                fields.append((key, WireJSON.from(value)))
            } else if key != "data" {
                rest[key] = value
            }
        }
        var inner = (JSON.normalize(data["data"]) as? [String: Any]) ?? [:]
        for (k, v) in rest where inner[k] == nil { inner[k] = v }
        if !inner.isEmpty { fields.append(("data", WireJSON.from(inner))) }
        return WireJSON.object([("type", .string("app_event")), ("event", .object(fields))]).text
    }
}

/// One frame from the chat socket, typed. Anything this build does not use is `.ignored`.
enum ChatInbound {
    case text(String)
    case beginningOfStream
    case endOfStream
    case widget([String: Any])
    case widgetPending([String: Any])
    case appAction(id: String, name: String, arguments: [String: Any])
    /// The earlier conversation, restored (contract §2.6): the turns, oldest first — possibly none.
    case history([GraineChatTurn])
    /// Replies the agent suggests for the turn it just sent, cleaned (DESIGN.md "Chat window v2"); none takes them away.
    case quickReplies([GraineQuickReply])
    /// The agent ended the conversation: the open turn closes, typing stops, the replies go, the rating may be asked for.
    case conversationEnd
    /// `{"type":"session","id","at"}`, once as a connection starts: its session — nil for an id that is not a non-empty string.
    case session(String?)
    case ignored(String)

    static func parse(_ raw: String) -> ChatInbound? {
        guard let o = JSON.object(from: raw), let type = o["type"] as? String else { return nil }
        switch type {
        case "widget":
            guard let widget = o["widget"] as? [String: Any] else { return .ignored(type) }
            return .widget(widget)
        case "widget_pending":
            // The agent asked for a component and its content is loading: draw the loader, not nothing.
            return .widgetPending(o["widget"] as? [String: Any] ?? [:])
        case "history":
            // A history whose turns are not a list restores nothing, never an error — but it still says the
            // server continued the conversation (no new-conversation marker for this connection).
            return .history(ChatHistory.read(o) ?? [])
        case "quick_replies":
            // Replies that are not a list are not a frame this build can draw: ignored.
            guard let replies = QuickReplies.read(o) else { return .ignored(type) }
            return .quickReplies(replies)
        case "conversation_end":
            return .conversationEnd
        case "session":
            // history.json `sessionFrame`: an id that is not a non-empty string is no session.
            return .session((o["id"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        default:
            break
        }
        switch CallInbound.parse(raw) {
        case .text(let data)?: return .text(data)
        case .beginningOfStream?: return .beginningOfStream
        case .endOfStream?: return .endOfStream
        case let .appAction(id, name, arguments)?: return .appAction(id: id, name: name, arguments: arguments)
        case nil: return nil
        default: return .ignored(type)
        }
    }
}

// MARK: - The connection's state

/// Where the chat's connection is.
public enum GraineChatStatus: Equatable, Sendable {
    /// Not in the chat: never opened, left, or the app is in the background — or the agent ended the conversation (`ended`); a message starts another.
    case idle
    case connecting
    case online
    /// The connection dropped and is being made again; `attempt` of six.
    case reconnecting(attempt: Int)
    /// It could not reconnect, or the server closed the conversation (with `disconnected` when Graine ended it itself). A message, or `retry()`, connects again.
    case offline

    /// Connecting, or reconnecting: draw "Connecting…".
    public var isConnecting: Bool {
        switch self {
        case .connecting, .reconnecting: return true
        default: return false
        }
    }
}

// MARK: - The transcript

/// Where a message was said: typed in the chat, or spoken on a call (only an earlier conversation's turn is).
public enum GraineChatChannel: String, Sendable {
    case chat
    case voice
}

/// One message in the chat.
public struct GraineChatTurn: Identifiable, Equatable {
    /// Where a customer's message is (an agent's turn is always `sent`).
    public enum Delivery: String, Sendable {
        /// Waiting for the connection: typed while the chat was not connected, sent when it is.
        case sending
        /// On its way to the agent.
        case sent
        /// The chat could not reconnect to send it. `GraineChat.retry()` tries again.
        case failed
    }

    /// Stable for the life of the transcript: `t1`, `t2`, …
    public let id: String
    public let role: GraineRole
    public internal(set) var text: String
    /// The agent's words still arriving: draw them as provisional.
    public internal(set) var live: Bool
    public internal(set) var delivery: Delivery
    public let at: Date
    /// The agent said this without being asked: its turn did not follow one of the customer's.
    public let proactive: Bool
    /**
     * From an earlier conversation, restored when the chat opened (the customer
     * came back): delivered, with the time it was said and Graine's id, not
     * said just now.
     */
    public let restored: Bool
    /// Where it was said. A chat window draws a run of `.voice` turns as one "Voice call" row, never their words.
    public let channel: GraineChatChannel
    /**
     * The id of the session it was said in — a chat connection's run, or a
     * call's id for a turn said on one — as Execution Logs shows it: a live
     * turn carries the chat's `sessionId` of the connection that carried it.
     * Nil for turns kept before sessions were recorded, with a server that
     * sends none, and for a line still waiting for its connection.
     */
    public internal(set) var session: String?

    init(
        id: String, role: GraineRole, text: String, live: Bool, delivery: Delivery, at: Date, proactive: Bool,
        restored: Bool = false, channel: GraineChatChannel = .chat, session: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.live = live
        self.delivery = delivery
        self.at = at
        self.proactive = proactive
        self.restored = restored
        self.channel = channel
        self.session = session
    }
}

/**
 * THE CONVERSATION CONTINUES (contract §2.6, vectors sdk/contract/history.json).
 *
 * An identified customer who comes back finds the chat where they left it: a
 * chat that passes the memory gate opens with ONE frame, before any agent
 * message (and no welcome — the customer types next),
 *
 *     {"type":"history","turns":[{id, role: "user"|"assistant", text,
 *       at: ISO-8601 UTC, channel: "chat"|"voice"}, …oldest first],"continued":true}
 *
 * read here as the React Native SDK reads it (protocol.ts readHistoryFrame).
 */
enum ChatHistory {
    /**
     * The turns a history frame restores, oldest first, or nil when its `turns`
     * is not a list. A turn that cannot be read is skipped: not an object, a
     * role other than user/assistant, text that is not a string or is blank, no
     * ISO-8601 `at` string. A channel other than "voice" is the chat; a missing
     * or repeated id becomes "h<index>".
     */
    static func read(_ frame: [String: Any]) -> [GraineChatTurn]? {
        guard let list = frame["turns"] as? [Any] else { return nil }
        var out: [GraineChatTurn] = []
        var used = Set<String>()
        for (index, raw) in list.enumerated() {
            guard let o = raw as? [String: Any] else { continue }
            let role: GraineRole
            switch o["role"] as? String {
            case "user": role = .customer
            case "assistant": role = .agent
            default: continue
            }
            // A number is neither a message nor a time: JSONSerialization hands both back as NSNumber, never String.
            guard let text = o["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let atText = o["at"] as? String, let at = ChatHistory.time(atText) else { continue }
            var id = "h\(index)"
            if let wire = o["id"] as? String, !wire.isEmpty, !used.contains(wire) { id = wire }
            used.insert(id)
            out.append(GraineChatTurn(
                id: id, role: role, text: text, live: false, delivery: .sent, at: at, proactive: false,
                restored: true, channel: (o["channel"] as? String) == "voice" ? .voice : .chat,
                // The session it was said in, as Graine kept it: a string that is not empty, else none.
                session: (o["session"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ))
        }
        return out
    }

    /// ISO-8601 with a zone, fractions or not — the server writes UTC with a Z. A time with no zone is not one.
    static func time(_ raw: String) -> Date? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard s.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:?\d{2})$"#, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        // The short forms are ISO too ("T09:30Z", "+0530"); the system's reader takes only the long ones.
        s = s.replacingOccurrences(of: #"^(.{10}T\d{2}:\d{2})(?=[Zz+-])"#, with: "$1:00", options: .regularExpression)
        s = s.replacingOccurrences(of: #"([+-]\d{2})(\d{2})$"#, with: "$1:$2", options: .regularExpression)
        return Scheduling.date(s)
    }
}

/**
 * HOW TURNS ARE ASSEMBLED — one bubble per agent turn. A turn's words stream
 * in chunks that carry their own spaces (unlike speech) and are appended as
 * they come; the turn closes on its end marker, when the customer speaks, or
 * when the connection goes. The next words then start a new bubble — the bug
 * this replaces merged every reply after the first into one bubble that never
 * settled. An agent turn that does not follow the customer's is proactive.
 *
 * A NEW CONVERSATION UNDER EARLIER LINES (DESIGN.md, history.json → `fresh`):
 * a connection whose server could not continue the conversation sends no
 * history, and its agent greets again. Instead of a second welcome stacked
 * under the first, the earlier lines either give way (an opening nobody
 * answered) or are closed by a "Disconnected · new conversation" marker —
 * kept here as the ids of the turns a marker is drawn before, never as turns.
 */
struct ChatTranscript: Equatable {
    static let cap = 200

    private(set) var turns: [GraineChatTurn] = []
    private var nextId = 1
    /// The ids that were settled when the connection last opened — what a history replaces. Nil before any open.
    private var settledAtOpen: Set<String>?
    /// The turns a "Disconnected · new conversation" row is drawn before: the window's own rows, not turns.
    private(set) var marks: Set<String> = []
    /// A marker owed to the next turn: the new conversation began before anything was said in it.
    private var markNext = false
    /// The connection opened, and neither a history nor the agent has come since: the agent's first act says which conversation this is.
    private var opening = false
    /**
     * The chat's current session: this connection's, from the server's
     * session frame (`sessionStarted`); nil from a connection's open until the
     * frame arrives, and with a server that sends none.
     */
    private(set) var session: String?
    /// Between a connection's open and its session frame: the turns it carries meanwhile are stamped when the frame comes.
    private var stamping = false
    /// Those turns, by id: the lines waiting at the open, and every turn said before the frame.
    private var unstamped = Set<String>()

    /// Agent words. Returns the turn they belong to, and whether they began it.
    @discardableResult
    mutating func agentChunk(_ text: String, now: Date) -> (turn: GraineChatTurn, began: Bool) {
        if let last = turns.last, last.role == .agent, last.live {
            turns[turns.count - 1].text += text
            return (turns[turns.count - 1], false)
        }
        agentBegan()
        let proactive = turns.last?.role != .customer
        let turn = GraineChatTurn(id: take(), role: .agent, text: text, live: true, delivery: .sent, at: now, proactive: proactive, session: session)
        append(turn)
        return (turn, true)
    }

    /// The agent's turn is complete. Returns it, settled — nil when nothing was open.
    @discardableResult
    mutating func agentTurnEnded() -> GraineChatTurn? {
        guard let last = turns.last, last.role == .agent, last.live else { return nil }
        turns[turns.count - 1].live = false
        return turns[turns.count - 1]
    }

    /// The customer said something: whatever the agent was saying is over.
    mutating func customerSaid(_ text: String, delivery: GraineChatTurn.Delivery, now: Date) -> GraineChatTurn {
        closeLive()
        // Said on the connection: its session. Waiting for one: the session of the connection that sends it.
        let turn = GraineChatTurn(
            id: take(), role: .customer, text: text, live: false, delivery: delivery, at: now, proactive: false,
            session: delivery == .sent ? session : nil
        )
        append(turn)
        return turn
    }

    mutating func setDelivery(_ id: String, _ delivery: GraineChatTurn.Delivery) {
        guard let i = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[i].delivery = delivery
    }

    /// The connection went: an open agent turn will not get its end marker now.
    mutating func closeLive() {
        if let last = turns.last, last.live { turns[turns.count - 1].live = false }
    }

    /// Empty: the turns, and the markers between them. The session is the connection's: it stays.
    mutating func clear() {
        turns = []
        settledAtOpen = nil
        marks = []
        markNext = false
        opening = false
        unstamped = []
    }

    /**
     * WHO A CHAT BELONGS TO (DESIGN.md): the identity changed, and what was
     * said belonged to the one before. Every turn goes — what a history
     * restored, the marker rows — but the customer's lines that have not gone
     * out, still sending or failed: they stay, in order, all waiting for the
     * next connection. Returns them, oldest first.
     */
    mutating func keepUnsent() -> [(id: String, text: String)] {
        turns = turns.filter { $0.role == .customer && $0.delivery != .sent }
        for i in turns.indices {
            turns[i].delivery = .sending
            // Said in the session of the connection that sends them, not the identity before's.
            turns[i].session = nil
        }
        settledAtOpen = nil
        marks = []
        markNext = false
        opening = false
        session = nil
        stamping = false
        unstamped = []
        return turns.map { ($0.id, $0.text) }
    }

    /**
     * The connection opened, before what was waiting goes out: what is settled
     * now is what the next history replaces. A message still waiting goes out
     * right after this, and stays.
     */
    mutating func opened() {
        settledAtOpen = Set(turns.filter { $0.delivery == .sent && !$0.live }.map(\.id))
        opening = true
        // A new connection: its session is its own, unknown until its frame comes. What waited goes on it.
        session = nil
        stamping = true
        unstamped = Set(turns.filter { $0.role == .customer && $0.delivery != .sent && $0.session == nil }.map(\.id))
    }

    /**
     * THE SESSION FRAME (history.json `sessionFrame`): this connection's
     * session — nil for an id that is not a non-empty string. Every turn the
     * connection carried before it — the lines waiting at its open, and
     * whatever was said meanwhile — takes it; never a stray session with no id.
     */
    mutating func sessionStarted(_ id: String?) {
        session = id
        stamping = false
        if let id = id {
            for i in turns.indices where unstamped.contains(turns[i].id) && turns[i].session == nil { turns[i].session = id }
        }
        unstamped = []
    }

    /**
     * The agent began — a turn's start marker, words that begin a turn, or a
     * component. Its first since the connection opened, with no history before
     * it, means the server began a NEW conversation. The current one — the
     * turns settled at that open after the last marker — then gives way when
     * the customer said none of them (the new opening replaces the old; a
     * marker before them moves on to what comes next), else is closed by a
     * marker before what came after it: what went out once the connection
     * opened belongs to the new conversation. True when the turns or markers
     * changed.
     */
    @discardableResult
    mutating func agentBegan() -> Bool {
        guard opening else { return false }
        opening = false
        // A marker still owed is the last one, after every turn: nothing settled comes after it.
        guard let settled = settledAtOpen, !markNext else { return false }
        let start = turns.lastIndex(where: { marks.contains($0.id) }) ?? 0
        let current = turns.indices.filter { $0 >= start && settled.contains(turns[$0].id) }
        guard !current.isEmpty else { return false }
        // The customer answered when any line of theirs follows the last marker — sent, or still to go.
        if turns[start...].contains(where: { $0.role == .customer }) {
            // A marker before the first turn after the last marker that was not settled at the open — or before
            // the next turn, when none came yet.
            if let first = turns.indices.first(where: { $0 >= start && !settled.contains(turns[$0].id) }) {
                marks.insert(turns[first].id)
            } else { markNext = true }
            return true
        }
        // An opening nobody answered gives way; a marker before it now goes before what follows.
        let gone = Set(current.map { turns[$0].id })
        let first = turns[start].id
        if marks.contains(first) && gone.contains(first) {
            marks.remove(first)
            if let next = turns[start...].first(where: { !gone.contains($0.id) }) { marks.insert(next.id) } else { markNext = true }
        }
        turns.removeAll { gone.contains($0.id) }
        return true
    }

    /**
     * An earlier conversation, restored: its turns, then every turn the history
     * cannot hold yet — still sending or failed, or said since the connection
     * opened — in order. A reconnect's history holds what the last one did and
     * what was said since, so it replaces both, and nothing shows twice. With
     * no open yet, only the turns still to go are kept. A marker before a turn
     * it replaced goes with that turn. False when there was nothing to restore.
     */
    @discardableResult
    mutating func restore(_ restored: [GraineChatTurn]) -> Bool {
        // A history before the agent's first words: the conversation continues, whatever the agent says next.
        opening = false
        guard !restored.isEmpty else { return false }
        let kept = turns.filter { turn in
            if turn.restored { return false }
            if let settled = settledAtOpen { return !settled.contains(turn.id) }
            return turn.delivery != .sent
        }
        turns = restored + kept
        marks.formIntersection(kept.map(\.id))
        markNext = false
        trim()
        return true
    }

    private mutating func take() -> String {
        defer { nextId += 1 }
        return "t\(nextId)"
    }

    private mutating func append(_ turn: GraineChatTurn) {
        turns.append(turn)
        if markNext {
            marks.insert(turn.id)
            markNext = false
        }
        // Said on this connection before its session frame: stamped when the frame comes.
        if stamping && turn.session == nil && !turn.restored { unstamped.insert(turn.id) }
        trim()
    }

    /// At most `cap` turns: the oldest go, and any marker before them.
    private mutating func trim() {
        guard turns.count > ChatTranscript.cap else { return }
        let gone = turns.prefix(turns.count - ChatTranscript.cap)
        for turn in gone {
            marks.remove(turn.id)
            unstamped.remove(turn.id)
        }
        turns.removeFirst(gone.count)
    }
}

// MARK: - Which conversation

/// A conversation is a call or a chat at any moment — never both at once.
public enum GraineSurface: String, Sendable {
    case voice
    case chat
}

/**
 * WHAT THE DASHBOARD OFFERS, AND WHAT OPENS FIRST — protocol.ts
 * `resolveSurface`. `appearance.mode` says which surfaces exist (`voice`,
 * `chat`, absent or anything else meaning both); `appearance.start` which opens
 * first. The app's preference (a parameter, or the surface the customer last
 * switched to) picks among the allowed ones and can never add one the brand
 * withheld: an app must not put a microphone in front of the customers of a
 * business that chose chat only.
 */
struct SurfacePolicy: Equatable {
    let allowed: [GraineSurface]
    let start: GraineSurface
    var canSwitch: Bool { allowed.count > 1 }

    static func resolve(appearance: [String: Any]?, prefer: GraineSurface?) -> SurfacePolicy {
        // Trimmed, as this SDK has always read `mode`: a padded value is the same choice, not "both".
        let mode = JSON.jsString(appearance?["mode"] ?? "both").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed: [GraineSurface] = mode == "voice" ? [.voice] : mode == "chat" ? [.chat] : [.voice, .chat]
        let configured = JSON.jsStringOrEmpty(appearance?["start"]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let start: GraineSurface
        if let prefer = prefer, allowed.contains(prefer) {
            start = prefer
        } else if let wanted = GraineSurface(rawValue: configured) {
            start = allowed.contains(wanted) ? wanted : allowed[0]
        } else {
            start = allowed[0]
        }
        return SurfacePolicy(allowed: allowed, start: start)
    }
}
