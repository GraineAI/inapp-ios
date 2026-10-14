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
            // A history whose turns are not a list is not one: ignored, never an error.
            guard let turns = ChatHistory.read(o) else { return .ignored(type) }
            return .history(turns)
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
    /// Not in the chat: never opened, left, or the app is in the background.
    case idle
    case connecting
    case online
    /// The connection dropped and is being made again; `attempt` of six.
    case reconnecting(attempt: Int)
    /// It could not reconnect, or the conversation was ended by the other side. A message, or `retry()`, connects again.
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

    init(
        id: String, role: GraineRole, text: String, live: Bool, delivery: Delivery, at: Date, proactive: Bool,
        restored: Bool = false, channel: GraineChatChannel = .chat
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
                restored: true, channel: (o["channel"] as? String) == "voice" ? .voice : .chat
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
 */
struct ChatTranscript: Equatable {
    static let cap = 200

    private(set) var turns: [GraineChatTurn] = []
    private var nextId = 1
    /// The ids that were settled when the connection last opened — what a history replaces. Nil before any open.
    private var settledAtOpen: Set<String>?

    /// Agent words. Returns the turn they belong to, and whether they began it.
    @discardableResult
    mutating func agentChunk(_ text: String, now: Date) -> (turn: GraineChatTurn, began: Bool) {
        if let last = turns.last, last.role == .agent, last.live {
            turns[turns.count - 1].text += text
            return (turns[turns.count - 1], false)
        }
        let proactive = turns.last?.role != .customer
        let turn = GraineChatTurn(id: take(), role: .agent, text: text, live: true, delivery: .sent, at: now, proactive: proactive)
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
        let turn = GraineChatTurn(id: take(), role: .customer, text: text, live: false, delivery: delivery, at: now, proactive: false)
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

    mutating func clear() {
        turns = []
        settledAtOpen = nil
    }

    /**
     * The connection opened, before what was waiting goes out: what is settled
     * now is what the next history replaces. A message still waiting goes out
     * right after this, and stays.
     */
    mutating func opened() {
        settledAtOpen = Set(turns.filter { $0.delivery == .sent && !$0.live }.map(\.id))
    }

    /**
     * An earlier conversation, restored: its turns, then every turn the history
     * cannot hold yet — still sending or failed, or said since the connection
     * opened — in order. A reconnect's history holds what the last one did and
     * what was said since, so it replaces both, and nothing shows twice. With
     * no open yet, only the turns still to go are kept. False when there was
     * nothing to restore.
     */
    @discardableResult
    mutating func restore(_ restored: [GraineChatTurn]) -> Bool {
        guard !restored.isEmpty else { return false }
        let kept = turns.filter { turn in
            if turn.restored { return false }
            if let settled = settledAtOpen { return !settled.contains(turn.id) }
            return turn.delivery != .sent
        }
        turns = restored + kept
        if turns.count > ChatTranscript.cap { turns.removeFirst(turns.count - ChatTranscript.cap) }
        return true
    }

    private mutating func take() -> String {
        defer { nextId += 1 }
        return "t\(nextId)"
    }

    private mutating func append(_ turn: GraineChatTurn) {
        turns.append(turn)
        if turns.count > ChatTranscript.cap { turns.removeFirst(turns.count - ChatTranscript.cap) }
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
