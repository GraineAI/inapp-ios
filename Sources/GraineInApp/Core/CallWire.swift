import Foundation

/*
 * THE NATIVE CALL'S WIRE — the voice socket's frames, spoken by this SDK
 * itself rather than by the hosted page.
 *
 * Exactly what the React Native client sends and reads (sdk/NATIVE-CALLS.md),
 * held to contract/native-calls.json: the variables on the URL (`contextToken`)
 * and on the ticket (`ticketMetadata`), the frames, the turn markers and the
 * spacing of spoken phrases. Pure: Foundation only, proven by `swift test`.
 */

enum CallWire {
    // MARK: - Constants (contract/native-calls.json "frames")

    /// Rides the WebSocket subprotocol header with the ticket, never the query.
    static let subprotocol = "graine.embed.v1"
    /// Who is on the socket, in the init frame.
    static let client = "graine-ios-sdk"
    static let pingSeconds = 25.0
    /// A socket that has not opened by then has failed.
    static let socketOpenTimeoutSeconds = 15.0
    /// The runtime waits this long for an app action's answer, then tells the model it did not happen.
    static let actionDeadlineMs = 6_000
    /// The SDK's own action deadline: inside the runtime's, so the agent hears a real answer.
    static let actionAnswerMs = 5_500
    static let defaultWsHost = "wss://ws.graine.ai"
    /// The microphone: 16 kHz mono PCM16, 20 ms frames.
    static let captureRate = 16_000
    static let captureFrameSamples = 320
    /// A mark is acknowledged when the audio before it has been heard, but never later than this.
    static let markAckCapSeconds = 10.0
    /// The stop frame leaves this long before the socket is closed.
    static let closeGraceSeconds = 0.2

    // MARK: - Frames out

    static let pingFrame = #"{"type":"ping"}"#
    static let bargeInFrame = #"{"type":"barge_in"}"#
    static let stopFrame = #"{"type":"stop","event":"stop","data":"client_hangup"}"#

    /// The first frame: a start, with who is on the call (the runtime logs it; it reads the token and ticket).
    static func initFrame(variables: [(String, String)]) -> String {
        WireJSON.object([
            ("type", .string("init")),
            ("event", .string("start")),
            ("meta_data", .object([
                ("client", .string(client)),
                ("context_data", .object(variables.map { ($0.0, .string($0.1)) })),
            ])),
        ]).text
    }

    /// One microphone frame: 16 kHz mono PCM16 little-endian, base64.
    static func audioFrame(base64: String) -> String {
        WireJSON.object([
            ("type", .string("audio")),
            ("data", .string(base64)),
            ("meta_info", .object([
                ("format", .string("pcm")),
                ("sample_rate", .int(captureRate)),
                ("encoding", .string("base64")),
            ])),
        ]).text
    }

    /// The agent's mark, echoed back — at playout, never on arrival.
    static func markFrame(name: Any) -> String {
        WireJSON.object([("type", .string("mark")), ("name", WireJSON.from(name))]).text
    }

    /// The answer to an app action. `message` and `data` only when there is one.
    static func actionResultFrame(actionId: String, result: GraineActionResult) -> String {
        var fields: [(String, WireJSON)] = [
            ("type", .string("app_action_result")),
            ("action_id", .string(actionId)),
            ("status", .string(result.status.rawValue)),
        ]
        if !result.message.isEmpty { fields.append(("message", .string(result.message))) }
        if !result.data.isEmpty { fields.append(("data", WireJSON.from(result.data))) }
        return WireJSON.object(fields).text
    }

    /**
     * The screen, as the socket takes it: `currentContextFrame()`'s
     * `context` / `availableActions` / `seq`, with the socket's key names. An
     * absent `availableActions` stays absent ("everything the dashboard
     * declared"); an empty one is sent empty ("nothing here").
     */
    static func appContextFrame(_ frame: [String: Any]) -> String? {
        guard let context = frame["context"] as? [String: Any] else { return nil }
        var fields: [(String, WireJSON)] = [("type", .string("app_context")), ("context", WireJSON.from(context))]
        if let actions = frame["availableActions"] as? [String] {
            fields.append(("available_actions", .array(actions.map { .string($0) })))
        }
        if let seq = frame["seq"] { fields.append(("seq", WireJSON.from(seq))) }
        return WireJSON.object(fields).text
    }

    /// The ticket request: a voice ticket, the variables on it when they fit.
    static func ticketRequest(publishableKey: String, metadata: [(String, String)]?) -> Data {
        var fields: [(String, WireJSON)] = [
            ("publishableKey", .string(publishableKey)),
            ("mode", .string("voice")),
        ]
        if let metadata = metadata { fields.append(("metadata", .object(metadata.map { ($0.0, .string($0.1)) }))) }
        return Data(WireJSON.object(fields).text.utf8)
    }

    // MARK: - URLs

    /// The direct socket, used when no ticket could be minted: `{wsHost}/chat/v1/{agentId}?webcall=1`.
    static func directUrl(wsHost: String?, agentId: String) -> String {
        var host = wsHost.flatMap { $0.isEmpty ? nil : $0 } ?? defaultWsHost
        if host.hasSuffix("/") { host.removeLast() }
        return host + "/chat/v1/" + GraineProtocol.encode(agentId) + "?webcall=1"
    }

    /// `context_token` on whichever URL was chosen.
    static func withContextToken(_ url: String, token: String?) -> String {
        guard let token = token else { return url }
        return url + (url.contains("?") ? "&" : "?") + "context_token=" + GraineProtocol.encode(token)
    }

    // MARK: - Variables

    /**
     * THE VARIABLES THE AGENT'S PROMPT READS, on the URL: base64 of the UTF-8
     * JSON `{ ...vals, call_type, recipient_data: { ...vals, call_type } }`,
     * where `vals` are the values with nulls and objects dropped and every
     * scalar stringified. Nil when there is nothing to say. Keys keep their
     * order, as a JavaScript object does — the vectors compare bytes.
     */
    static func contextToken(_ variables: [(String, Any?)], callType: String = "webcall") -> String? {
        var vals = OrderedFields()
        for (rawKey, value) in variables {
            guard let text = scalarText(value) else { continue }
            let key = jsTrim(rawKey)
            if key.isEmpty { continue }
            vals.set(key, .string(text))
        }
        if vals.isEmpty { return nil }
        var recipient = vals
        recipient.set("call_type", .string(callType))
        var payload = vals
        payload.set("call_type", .string(callType))
        payload.set("recipient_data", .object(recipient.pairs))
        return Data(WireJSON.object(payload.pairs).text.utf8).base64EncodedString()
    }

    /// The ticket's limits: what the server keeps, since the ticket rides a WebSocket header.
    static let ticketKeyLimit = 12
    static let ticketKeyLength = 40
    static let ticketValueLength = 200
    static let ticketTotalBytes = 1_024

    /**
     * The variables on the ticket: the gateway builds the call's context from
     * the ticket's signed claims and ignores the URL. At most 12 keys (the
     * first twelve usable ones, in order), keys cut to 40 and values to 200
     * UTF-16 units, and nothing at all over 1 KB.
     */
    static func ticketMetadata(_ variables: [(String, Any?)]) -> [(String, String)]? {
        var out = OrderedFields()
        var n = 0
        for (rawKey, value) in variables {
            if n >= ticketKeyLimit { break }
            guard let text = scalarText(value) else { continue }
            let key = utf16Prefix(rawKey, ticketKeyLength)
            let cut = utf16Prefix(text, ticketValueLength)
            if key.isEmpty || cut.isEmpty { continue }
            out.set(key, .string(cut))
            n += 1
        }
        if n == 0 { return nil }
        let pairs: [(String, String)] = out.pairs.map { pair in
            if case let .string(s) = pair.1 { return (pair.0, s) }
            return (pair.0, "")
        }
        var bytes = 2
        for (k, v) in pairs { bytes += k.utf8.count + v.utf8.count + 6 }
        return bytes > ticketTotalBytes ? nil : pairs
    }

    /**
     * The ticket's variables, as many as it holds. `ticketMetadata` keeps the
     * first twelve and nothing at all over a kilobyte, so the whole list, handed
     * over at once, could lose exactly the keys a call exists to carry
     * (`who_called`, `call_reason`) behind one long app variable. The call's own
     * go first and always win; the rest are added one at a time while the
     * ticket still accepts them — the rule Android's `ticketVariables` follows.
     */
    static func ticketVariables(call: [(String, String)], rest: [(String, String)]) -> [(String, String)]? {
        func fit(_ list: [(String, String)]) -> [(String, String)]? {
            ticketMetadata(list.map { ($0.0, $0.1 as Any?) })
        }
        var best = fit(call)
        if best == nil && !call.isEmpty { return nil }
        var candidate = call
        let taken = Set(call.map { $0.0 })
        for pair in rest where !taken.contains(pair.0) {
            candidate.append(pair)
            if let next = fit(candidate), next.count > (best?.count ?? 0) {
                best = next
            } else {
                candidate.removeLast()
            }
        }
        return best
    }

    /// A prompt variable's text: strings as they are, numbers and booleans as JavaScript writes them; nil for null, objects, arrays.
    static func scalarText(_ value: Any?) -> String? {
        guard let v = JSON.unwrap(value), !(v is NSNull) else { return nil }
        if v is [Any] || v is [AnyHashable: Any] { return nil }
        return JSON.text(v) ?? String(describing: v)
    }

    // MARK: - The agent's words

    static let streamStart = "<beginning_of_stream>"
    static let streamEnd = "<end_of_stream>"

    /// One `text` frame: the words to show, and whether it opened or closed a turn.
    struct AgentChunk: Equatable {
        var text: String
        var startsTurn: Bool
        var endsTurn: Bool
    }

    /// The React Native SDK's readAgentChunk: markers removed (any case), nothing else touched — no trimming.
    static func readAgentChunk(_ raw: String) -> AgentChunk {
        if raw.isEmpty || !raw.contains("<") { return AgentChunk(text: raw, startsTurn: false, endsTurn: false) }
        let lower = raw.lowercased()
        let starts = lower.contains(streamStart)
        let ends = lower.contains(streamEnd)
        if !starts && !ends { return AgentChunk(text: raw, startsTurn: false, endsTurn: false) }
        let text = raw
            .replacingOccurrences(of: streamStart, with: "", options: .caseInsensitive)
            .replacingOccurrences(of: streamEnd, with: "", options: .caseInsensitive)
        return AgentChunk(text: text, startsTurn: starts, endsTurn: ends)
    }

    /**
     * SPOKEN TEXT ARRIVES IN PHRASES, WITHOUT THE SPACES BETWEEN THEM ("Sure! I
     * can", "help you", "settings,"). The gap to put before `next`: one space,
     * unless either side is empty or already has one, `next` opens with closing
     * punctuation, or `soFar` ends with an opening bracket. The React Native
     * SDK's spokenJoinGap; vectors "spokenJoin".
     */
    static func spokenJoinGap(_ soFar: String, _ next: String) -> String {
        guard let last = soFar.unicodeScalars.last, let first = next.unicodeScalars.first else { return "" }
        if isJsWhitespace(last) || isJsWhitespace(first) { return "" }
        if closingPunctuation.contains(first) { return "" }
        if openingPunctuation.contains(last) { return "" }
        return " "
    }

    private static let closingPunctuation: Set<Unicode.Scalar> = Set(",.;:!?)]}…%'’”»।॥".unicodeScalars)
    private static let openingPunctuation: Set<Unicode.Scalar> = Set("([{“‘«/-".unicodeScalars)

    /// base64 → bytes, as leniently as the React Native SDK reads it: anything outside the alphabet ignored, padding optional.
    static func base64Bytes(_ text: String) -> [UInt8]? {
        var clean = String(text.unicodeScalars.filter { base64Alphabet.contains($0) })
        let rest = clean.count % 4
        if rest == 1 { clean.removeLast() }
        if rest == 2 || rest == 3 { clean += String(repeating: "=", count: 4 - rest) }
        return Data(base64Encoded: clean).map { [UInt8]($0) }
    }

    private static let base64Alphabet: Set<Unicode.Scalar> =
        Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".unicodeScalars)

    /// JavaScript's `\s`.
    static func isJsWhitespace(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            return true
        default:
            return false
        }
    }

    /// JavaScript's `String.prototype.trim()`.
    static func jsTrim(_ s: String) -> String {
        let scalars = s.unicodeScalars
        guard let start = scalars.firstIndex(where: { !isJsWhitespace($0) }),
              let end = scalars.lastIndex(where: { !isJsWhitespace($0) }) else { return "" }
        return String(scalars[start...end])
    }

    /// `slice(0, n)` in UTF-16 units — without splitting a surrogate pair.
    static func utf16Prefix(_ s: String, _ n: Int) -> String {
        if s.utf16.count <= n { return s }
        var units = Array(s.utf16.prefix(n))
        if let last = units.last, UTF16.isLeadSurrogate(last) { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }
}

// MARK: - Frames in

/// One frame from the voice socket, typed. Anything this build does not use is `.ignored`.
enum CallInbound {
    case audio(data: String, format: String?, sampleRate: Int?)
    case mark(name: Any)
    case beginningOfStream
    case endOfStream
    /// `clear` or `interruption`: the customer talked over the agent.
    case clear
    case text(String)
    case transcript(String, final: Bool)
    case appAction(id: String, name: String, arguments: [String: Any])
    case ignored(String)

    static func parse(_ raw: String) -> CallInbound? {
        guard let o = JSON.object(from: raw), let type = o["type"] as? String else { return nil }
        switch type {
        case "audio":
            let meta = o["meta_info"] as? [String: Any]
            return .audio(
                data: JSON.string(o["data"]),
                format: JSON.nonEmpty(meta?["format"]),
                sampleRate: meta.flatMap { rate($0["sample_rate"]) }
            )
        case "mark":
            // JavaScript's `if (!name)`: absent, null, "" and 0 are not names.
            guard let name = JSON.unwrap(o["name"]), JSON.truthy(name) else { return .ignored(type) }
            return .mark(name: name)
        case "beginning_of_stream":
            return .beginningOfStream
        case "end_of_stream":
            return .endOfStream
        case "clear", "interruption":
            return .clear
        case "text":
            return .text(JSON.text(o["data"]) ?? "")
        case "transcript":
            return .transcript(JSON.text(o["data"]) ?? "", final: true)
        case "interim_transcript_received":
            return .transcript(JSON.text(o["data"]) ?? "", final: false)
        case "app_action":
            guard let a = o["action"] as? [String: Any] else { return .ignored(type) }
            return .appAction(
                id: JSON.string(a["action_id"]),
                name: JSON.string(a["name"]),
                arguments: a["arguments"] as? [String: Any] ?? [:]
            )
        default:
            return .ignored(type)
        }
    }

    /// A sample rate as the server wrote it: a number or a numeric string. Nil otherwise.
    private static func rate(_ value: Any?) -> Int? {
        guard let v = JSON.unwrap(value), !(v is NSNull) else { return nil }
        if let n = JSON.number(v) {
            let d = n.doubleValue
            return d.isFinite && d > 0 ? Int(d) : nil
        }
        if let s = v as? String, let d = Double(s.trimmingCharacters(in: .whitespaces)), d.isFinite, d > 0 { return Int(d) }
        return nil
    }
}

// MARK: - JSON, written the way JSON.stringify writes it

/**
 * An ordered JSON value. Foundation's writer orders keys at random and escapes
 * "/"; the context token is compared byte for byte with what the React Native
 * SDK produces, so frames and tokens are written here, keys in order, escaped
 * exactly as JSON.stringify escapes.
 */
indirect enum WireJSON {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([WireJSON])
    case object([(String, WireJSON)])

    var text: String {
        var out = ""
        write(into: &out)
        return out
    }

    private func write(into out: inout String) {
        switch self {
        case .string(let s): WireJSON.quote(s, into: &out)
        case .int(let i): out += String(i)
        case .double(let d): out += d.isFinite ? JSON.jsNumberText(d) : "null"
        case .bool(let b): out += b ? "true" : "false"
        case .null: out += "null"
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                item.write(into: &out)
            }
            out += "]"
        case .object(let fields):
            out += "{"
            for (i, field) in fields.enumerated() {
                if i > 0 { out += "," }
                WireJSON.quote(field.0, into: &out)
                out += ":"
                field.1.write(into: &out)
            }
            out += "}"
        }
    }

    /// JSON.stringify's string escaping: quote, backslash and control characters; nothing else.
    static func quote(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    /// Any Foundation/Swift JSON value. Dictionary keys are sorted, so the same value always writes the same text.
    static func from(_ value: Any?) -> WireJSON {
        let v = JSON.normalize(value)
        if v is NSNull { return .null }
        if let s = v as? String { return .string(s) }
        if let b = JSON.bool(v) { return .bool(b) }
        if let n = JSON.number(v) {
            if isIntegerType(n) { return .int(n.intValue) }
            let d = n.doubleValue
            return d.isFinite ? .double(d) : .null
        }
        if let dict = v as? [String: Any] {
            return .object(dict.keys.sorted().map { ($0, from(dict[$0])) })
        }
        if let list = v as? [Any] { return .array(list.map { from($0) }) }
        return .string(String(describing: v))
    }

    private static let integerTypes: Set<String> = ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q"]

    private static func isIntegerType(_ n: NSNumber) -> Bool {
        integerTypes.contains(String(cString: n.objCType))
    }
}

/// A JavaScript object's key order: a key set again keeps its place and takes the new value.
struct OrderedFields {
    private(set) var pairs: [(String, WireJSON)] = []
    private var index: [String: Int] = [:]

    var isEmpty: Bool { pairs.isEmpty }

    mutating func set(_ key: String, _ value: WireJSON) {
        if let at = index[key] {
            pairs[at].1 = value
        } else {
            index[key] = pairs.count
            pairs.append((key, value))
        }
    }
}
