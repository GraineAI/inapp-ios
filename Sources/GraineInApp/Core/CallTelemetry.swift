import Foundation

/*
 * CALL ANALYTICS ROWS (v1): how each native call connected and how it went,
 * on the call's own conversation, so the call's record shows it — the same
 * rows from every engine. The contract is defined once, in
 * sdk/inapp/protocol.ts (`callAnalyticsEvent`); this is its Swift builder,
 * held to sdk/contract/call-analytics.json byte for byte by the tests.
 *
 *   transport  once, when the call is connected on whichever road carries it,
 *              and why it is not WebRTC when it could have been
 *   connect    once, at media: prepared or cold, and where the tap's wait went
 *   voice      once, when the agent's voice is first heard
 *   recovery   each time the connection heals (a redial, an ICE restart, a socket replaced)
 *   quality    once, at the end of a call that had media: loss, jitter, round trip
 *   media      the call was answered and no audio could flow
 *
 * Each row is an app event — `{"type":"app_event","event":{name, detail,
 * quiet: true, telemetry: true, data}}` — on the WebRTC control channel, or on
 * the voice socket for a call the WebSocket carries. One pure function makes
 * it from a row's name and what was measured: only that row's keys, in the
 * contract's order; a key that is absent, null or does not fit its type left
 * out (a numeric string, a boolean for a number, a number for a boolean, a
 * negative, NaN, infinity); integers rounded half up and held at their
 * ceilings; an enumerated key only with a value from its list, so a string can
 * never carry a name or a number; the detail written from what survived. At
 * most twelve keys; never an id, an identity or anything personal.
 *
 * Rounding is spelled out because four languages must write the same digits:
 * an integer is floor(x + 0.5), a percentage keeps two decimals the same way,
 * and seconds in a detail are tenths = floor((ms + 50) / 100), written with a
 * '.' whatever the device's locale.
 *
 * A row waits for its channel to open and is dropped if it never does: rows
 * never delay a call or its hang-up.
 */
@_spi(GraineRTC) public enum GraineCallTelemetry {
    static let version = 1
    /// The most keys one row may carry. `connect` uses all twelve.
    public static let maxKeys = 12

    /**
     * THE ROWS, each with its keys in the order they are sent and the type of
     * each value, in the contract's own words:
     *   ms       integer milliseconds, ≥ 0, at most `limits["ms"]`
     *   seconds  whole seconds, ≥ 0, at most `limits["seconds"]`
     *   count    a whole count, ≥ 0, at most `limits["count"]`
     *   percent  0–100, two decimals
     *   bool     true or false — never 1 or 0
     *   codec    a name from `enums["codec"]`, written the SDP way
     *   enum:X   one value of `enums[X]`, exactly as written there
     */
    static let rows: [String: [(key: String, type: String)]] = [
        "transport": [("transport", "enum:transport"), ("requested", "enum:requested"), ("fallback_reason", "enum:fallback_reason")],
        "connect": [
            ("mode", "enum:mode"), ("warm", "bool"), ("total_ms", "ms"), ("setup_ms", "ms"), ("dial_ms", "ms"),
            ("mint_ms", "ms"), ("mint_route", "enum:mint_route"), ("gather_ms", "ms"), ("register_ms", "ms"),
            ("redials", "count"), ("prepared_age_s", "seconds"), ("ice_ms", "ms"),
        ],
        "voice": [("tap_to_voice_ms", "ms"), ("answer_to_voice_ms", "ms"), ("first_audio_ms", "ms"), ("codec", "codec"), ("candidate", "enum:candidate")],
        "recovery": [("what", "enum:recovery"), ("after_ms", "ms")],
        "quality": [("duration_s", "seconds"), ("loss_pct", "percent"), ("jitter_avg_ms", "ms"), ("jitter_max_ms", "ms"), ("rtt_avg_ms", "ms")],
        "media": [("reason", "enum:media_reason"), ("transport", "enum:transport")],
    ]

    /// Every closed list a row's value may come from, by name.
    static let enums: [String: [String]] = [
        "transport": ["rtc", "ws"],
        "requested": ["rtc", "ws", "auto"],
        "fallback_reason": [
            "mint_failed", "register_failed", "no_response", "no_answer",
            "ice_timeout", "ice_failed", "ice_disconnected", "media", "stalled", "screen_channel",
            "not_configured", "unreachable", "dashboard", "unavailable", "error",
        ],
        "mode": ["prepared", "cold"],
        "mint_route": ["direct", "web"],
        "candidate": ["host", "srflx", "prflx", "relay"],
        "recovery": ["redial", "ice_restart", "socket_replaced"],
        "media_reason": ["ice_failed", "ice_disconnected", "ice_timeout"],
        "codec": ["opus", "PCMU", "PCMA", "G722", "G729", "iLBC", "ISAC", "L16"],
    ]

    /// The ceilings: a value above one is held AT it. Ten minutes; a day; twenty redials (a loop, not a recovery); 100%.
    static let limits: [String: Double] = ["ms": 600_000, "seconds": 86_400, "count": 20, "percent": 100]

    // MARK: - The builder

    /// The row's event, `{name, detail, quiet, telemetry, data}`, as JSON text — nil for a name that is not a row: a report nobody can read is not sent.
    public static func event(_ name: String, _ data: [String: Any?]) -> String? {
        eventValue(name, data)?.text
    }

    /// The frame the row travels in on the call's channel: `{"type":"app_event","event":…}`.
    public static func frame(_ name: String, _ data: [String: Any?]) -> String? {
        guard let event = eventValue(name, data) else { return nil }
        return WireJSON.object([("type", .string("app_event")), ("event", event)]).text
    }

    private static func eventValue(_ name: String, _ data: [String: Any?]) -> WireJSON? {
        guard let keys = rows[name] else { return nil }
        let clean = cleanData(keys, data)
        return .object([
            ("name", .string(name)),
            ("detail", .string(detail(name, Dictionary(clean, uniquingKeysWith: { first, _ in first })))),
            ("quiet", .bool(true)),
            ("telemetry", .bool(true)),
            ("data", .object(clean)),
        ])
    }

    /// Only the row's keys, in its order; anything that does not fit left out.
    private static func cleanData(_ keys: [(key: String, type: String)], _ data: [String: Any?]) -> [(String, WireJSON)] {
        var out: [(String, WireJSON)] = []
        for (key, type) in keys {
            guard let raw = data[key], let value = clean(type, raw) else { continue }
            out.append((key, value))
            if out.count >= maxKeys { break }
        }
        return out
    }

    /// One value, as its type allows it, or nil when it does not fit.
    static func clean(_ type: String, _ raw: Any?) -> WireJSON? {
        guard let value = JSON.unwrap(raw), !(value is NSNull) else { return nil }
        switch type {
        case "ms", "seconds", "count":
            return number(value, ceiling: limits[type] ?? 0, scale: 1).map { .int(Int($0)) }
        case "percent":
            return number(value, ceiling: limits[type] ?? 0, scale: 100).map { .double($0) }
        case "bool":
            return JSON.bool(value).map { .bool($0) }
        case "codec":
            return codec(value).map { .string($0) }
        default:
            // enum:X — the value exactly as the list writes it, compared unit for unit as JavaScript compares.
            let list = String(type.dropFirst(5))
            guard type.hasPrefix("enum:"), let allowed = enums[list] ?? aheadEnums[list], let word = value as? String,
                  allowed.contains(where: { $0.utf16.elementsEqual(word.utf16) }) else { return nil }
            return .string(word)
        }
    }

    /// A real number — never a boolean or a numeric string — finite and not negative; rounded half up at `scale` and held at the ceiling.
    private static func number(_ value: Any, ceiling: Double, scale: Double) -> Double? {
        guard let n = JSON.number(value) else { return nil }
        let x = n.doubleValue
        guard x.isFinite, !(x < 0) else { return nil }
        return min(roundHalfUp(x * scale) / scale, ceiling)
    }

    /// floor(x + 0.5): the one rounding every implementation uses (JavaScript's Math.round for what a row holds).
    static func roundHalfUp(_ x: Double) -> Double {
        (x + 0.5).rounded(.down)
    }

    /**
     * A codec the SDP way: one of `enums["codec"]`, matched without case after
     * an optional "audio/", then "/<clock rate>" when 4–6 digits follow; a
     * channel count is dropped. "audio/OPUS" → "opus", "opus/48000/2" →
     * "opus/48000", "pcmu/8000" → "PCMU/8000". Read in UTF-16 units and ASCII
     * classes, exactly as the contract's expression reads it.
     */
    static func codec(_ value: Any) -> String? {
        guard let text = value as? String else { return nil }
        let units = Array(text.trimmingCharacters(in: javaScriptSpace).utf16)
        func lower(_ u: UInt16) -> UInt16 { (65...90).contains(u) ? u + 32 : u }
        func isDigit(_ u: UInt16) -> Bool { (48...57).contains(u) }
        func isAlphanumeric(_ u: UInt16) -> Bool { isDigit(u) || (65...90).contains(u) || (97...122).contains(u) }
        func digits(from start: Int) -> Int {
            var end = start
            while end < units.count, isDigit(units[end]) { end += 1 }
            return end - start
        }
        let slash: UInt16 = 47
        var i = 0
        let prefix = Array("audio/".utf16)
        if units.count >= prefix.count, zip(units.prefix(prefix.count), prefix).allSatisfy({ lower($0) == $1 }) {
            i = prefix.count
        }
        let nameStart = i
        while i < units.count, isAlphanumeric(units[i]) { i += 1 }
        guard (2...8).contains(i - nameStart) else { return nil }
        let name = Array(units[nameStart..<i])
        var rate: [UInt16] = []
        if i < units.count {
            // "/<rate>" or "/<channels>" to the end, or "/<rate>/<channels>".
            guard units[i] == slash else { return nil }
            let first = digits(from: i + 1)
            let afterFirst = i + 1 + first
            if afterFirst == units.count {
                if (4...6).contains(first) {
                    rate = Array(units[(i + 1)..<afterFirst])
                } else if !(1...2).contains(first) {
                    return nil
                }
            } else {
                guard (4...6).contains(first), units[afterFirst] == slash else { return nil }
                let second = digits(from: afterFirst + 1)
                guard (1...2).contains(second), afterFirst + 1 + second == units.count else { return nil }
                rate = Array(units[(i + 1)..<afterFirst])
            }
        }
        guard let known = enums["codec"]?.first(where: { $0.utf16.map(lower).elementsEqual(name.map(lower)) }) else { return nil }
        return rate.isEmpty ? known : known + "/" + String(decoding: rate, as: UTF16.self)
    }

    /// What JavaScript's trim() removes — its white space and line terminators. Not quite Foundation's set: U+FEFF is in it, U+0085 is not.
    private static let javaScriptSpace: CharacterSet = {
        var set = CharacterSet(charactersIn: "\u{09}\u{0A}\u{0B}\u{0C}\u{0D}\u{20}\u{A0}\u{1680}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")
        set.insert(charactersIn: "\u{2000}"..."\u{200A}")
        return set
    }()

    // MARK: - The detail

    /**
     * THE DETAIL, the one line a row reads as wherever a raw timeline is shown:
     *   transport  "WebRTC" · "WebSocket" · "WebSocket (fallback: no_answer)"
     *   connect    "prepared · 0.2s (setup 0.0s, answer 0.2s)"
     *   voice      "agent's voice 0.9s after the tap (0.7s after the answer)"
     *   recovery   "redial after 1.2s"
     *   quality    "64s · loss 0.3% · jitter 12 ms"
     *   media      "no audio path (ice_timeout)"
     * Built from the CLEANED data, so it never says what the data does not.
     */
    private static func detail(_ name: String, _ d: [String: WireJSON]) -> String {
        func word(_ key: String) -> String? {
            if case .string(let s)? = d[key] { return s }
            return nil
        }
        func whole(_ key: String) -> Int? {
            if case .int(let i)? = d[key] { return i }
            return nil
        }
        switch name {
        case "transport":
            let reason = word("fallback_reason")
            switch word("transport") {
            case "rtc"?: return "WebRTC"
            case "ws"?: return reason.map { "WebSocket (fallback: \($0))" } ?? "WebSocket"
            default: return reason.map { "fallback: \($0)" } ?? "transport"
            }
        case "connect":
            var mode = "connected"
            if let m = word("mode") {
                mode = m
            } else if case .bool(let warm)? = d["warm"] {
                mode = warm ? "prepared" : "cold"
            }
            let parts = [whole("setup_ms").map { "setup \(seconds($0))" }, whole("dial_ms").map { "answer \(seconds($0))" }].compactMap { $0 }
            return mode + (whole("total_ms").map { " · \(seconds($0))" } ?? "") + (parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))")
        case "voice":
            let tap = whole("tap_to_voice_ms"), answer = whole("answer_to_voice_ms")
            if let tap = tap {
                return "agent's voice \(seconds(tap)) after the tap" + (answer.map { " (\(seconds($0)) after the answer)" } ?? "")
            }
            if let answer = answer { return "agent's voice \(seconds(answer)) after the answer" }
            return "agent's voice heard"
        case "recovery":
            let what: String
            switch word("what") {
            case "redial"?: what = "redial"
            case "ice_restart"?: what = "ice restart"
            case "socket_replaced"?: what = "socket replaced"
            default: what = "recovered"
            }
            return what + (whole("after_ms").map { " after \(seconds($0))" } ?? "")
        case "quality":
            var parts: [String] = []
            if let duration = whole("duration_s") { parts.append("\(duration)s") }
            if case .double(let loss)? = d["loss_pct"] { parts.append("loss \(percent(loss))") }
            if let jitter = whole("jitter_avg_ms") { parts.append("jitter \(jitter) ms") }
            return parts.isEmpty ? "call quality" : parts.joined(separator: " · ")
        case "media":
            return word("reason").map { "no audio path (\($0))" } ?? "no audio path"
        case "ended":
            let what: String
            switch word("cause") {
            case "local_end"?: what = "hung up on this side"
            case "remote_bye"?: what = "the far side hung up"
            case "media_drop"?: what = "the audio path dropped"
            case "audio_watch"?: what = "nothing arrived: ended on this side"
            case "provider_reset"?: what = "the system reset the call"
            case "failed"?: what = "failed"
            default: what = "ended"
            }
            var heard = ""
            if case .bool(let voice)? = d["voice_heard"] { heard = voice ? ", the agent heard" : ", the agent not heard" }
            return what + (whole("after_ms").map { " after \(seconds($0))" } ?? "") + heard
        case "audio":
            let what: String
            switch word("event") {
            case "ready"?: what = "audio playing"
            case "rescued"?: what = "audio started directly"
            case "deactivated_live"?: what = "audio taken back by the system"
            case "playout_restarted"?: what = "audio arrived, nothing played: restarted"
            case "failed"?: what = "audio never played: the call ends"
            case "route_changed"?: what = "audio moved" + (word("route").map { " to \($0)" } ?? "")
            default: what = "audio"
            }
            var via = ""
            switch word("via") {
            case "callkit"?: via = ", activated by the system"
            case "direct"?: via = ", started directly"
            case "none"?: via = ", never activated"
            default: break
            }
            return what + (whole("after_ms").map { " after \(seconds($0))" } ?? "") + via + (word("reason").map { " (\($0))" } ?? "")
        default:
            return name
        }
    }

    /// Milliseconds as a detail writes them: tenths = floor((ms + 50) / 100), "<tenths / 10>.<tenths % 10>s" — "0.2s", "12.5s".
    static func seconds(_ milliseconds: Int) -> String {
        let tenths = (max(0, milliseconds) + 50) / 100
        return "\(tenths / 10).\(tenths % 10)s"
    }

    /// A percentage as a detail writes it: tenths = floor((round(pct × 100) + 5) / 10) — "0.3%", "100.0%".
    static func percent(_ pct: Double) -> String {
        let hundredths = Int(min(max(0, roundHalfUp(pct * 100)), 1_000_000))
        let tenths = (hundredths + 5) / 10
        return "\(tenths / 10).\(tenths % 10)%"
    }

    // MARK: - For the engines

    /**
     * Whole milliseconds from `from` to `to` (seconds, on one clock), rounded
     * as every row rounds and held at the ceiling; nil when either moment is
     * unknown or time ran backwards. An engine adds these (total = setup +
     * dial) so its sums come out exact.
     */
    public static func milliseconds(from: Double?, to: Double?) -> Int? {
        guard let from = from, let to = to else { return nil }
        let ms = (to - from) * 1000
        guard ms.isFinite, ms >= 0 else { return nil }
        return Int(min(roundHalfUp(ms), limits["ms"] ?? 0))
    }

    /// The transport's word on the wire: `rtc`, `ws` or `auto`.
    static func word(_ transport: GraineCallTransport) -> String {
        switch transport {
        case .webrtc: return "rtc"
        case .websocket: return "ws"
        case .auto: return "auto"
        }
    }

    /// The `transport` row's frame: the road that carries the call, what the app asked for, and why it is not WebRTC (only on a fallback).
    static func transportFrame(carried: GraineCallTransport, requested: GraineCallTransport, fallbackReason: String?) -> String {
        frame("transport", [
            "transport": word(carried),
            "requested": word(requested),
            "fallback_reason": fallbackReason,
        ]) ?? ""
    }

    /**
     * ROWS SENT AHEAD OF THE CONTRACT (Android's CallAnalytics.AHEAD, key for
     * key): built by the same rules as `rows`, kept apart from them, so
     * `frame` — the contract's builder — never makes one. They join
     * protocol.ts's rows there; until then a server files them like any
     * telemetry row, and a raw timeline shows their detail.
     *   ended  once, as the call ends: `cause` (GraineCallEndCause's word),
     *          `transport`, `after_ms` (how long the call had its audio) and
     *          `voice_heard` (whether the agent's voice reached the phone)
     *   audio  the phone's own audio, when it matters — iOS's, where CallKit
     *          owns it: `event` (`ready`: the audio activated and the agent's
     *          audio reaching the speaker, once; `rescued`: started directly,
     *          the system never activated it or took it back mid-call;
     *          `deactivated_live`: the system took it back while the call
     *          went on; `playout_restarted`: audio arrived and nothing played,
     *          so it was started again; `failed`: still nothing, the call
     *          ends; `route_changed`: the output moved — a headset or car
     *          kit connected or left, the speaker toggled), `transport`,
     *          `via` (how the audio was activated by then), `route` (the
     *          output's kind, never a device's name), `reason` (what the SDK
     *          saw) and `after_ms` (from the tap)
     */
    static let ahead: [String: [(key: String, type: String)]] = [
        "ended": [("cause", "enum:end_cause"), ("transport", "enum:transport"), ("after_ms", "ms"), ("voice_heard", "bool")],
        "audio": [("event", "enum:audio_event"), ("transport", "enum:transport"), ("via", "enum:audio_via"), ("route", "enum:audio_route"), ("reason", "enum:audio_reason"), ("after_ms", "ms")],
    ]

    /// Their closed lists. `provider_reset` is iOS's own: Android has no CallKit to reset.
    static let aheadEnums: [String: [String]] = [
        "end_cause": ["local_end", "remote_bye", "media_drop", "audio_watch", "provider_reset", "failed"],
        "audio_event": ["ready", "rescued", "deactivated_live", "playout_restarted", "failed", "route_changed"],
        "audio_via": ["callkit", "direct", "none"],
        "audio_route": ["speaker", "receiver", "bluetooth", "wired", "airplay", "car"],
        "audio_reason": ["no_activation", "deactivated", "interrupted", "unit_failed", "disabled", "inactive", "no_playout"],
    ]

    /// The causes an `ended` row may carry: GraineCallEndCause's words.
    static var endCauses: Set<String> { Set(aheadEnums["end_cause"] ?? []) }

    /**
     * THE `ended` ROW — who or what ended the call, sent once on its channel
     * just before it closes (when one is still open), as Android sends it:
     * `{name: "ended", detail, quiet, telemetry, data: {cause, transport?,
     * after_ms?, voice_heard?}}`, the detail one line — "hung up on this side
     * after 12.5s, the agent heard". Nil for a cause that is not one of
     * `endCauses`. Never an id or anything personal.
     */
    public static func endedFrame(cause: String, transport: String? = nil, afterMs: Int? = nil, voiceHeard: Bool? = nil) -> String? {
        guard endCauses.contains(cause), let keys = ahead["ended"] else { return nil }
        return aheadFrame("ended", cleanData(keys, ["cause": cause, "transport": transport, "after_ms": afterMs, "voice_heard": voiceHeard]))
    }

    /**
     * THE `audio` ROW — the phone's audio when it matters, on the call's
     * channel as it happens (kept until the channel joins, like every row):
     * `{name: "audio", detail, quiet, telemetry, data: {event, transport?,
     * via?, reason?, after_ms?}}`, the detail one line — "audio arrived,
     * nothing played: restarted after 2.4s, activated by the system
     * (interrupted)". Nil for an event that is not one of `audio_event`. A
     * healthy call sends one (`ready`); everything else is the exception.
     * Never an id or anything personal.
     */
    public static func audioFrame(event: String, transport: String? = nil, via: String? = nil, reason: String? = nil, afterMs: Int? = nil, route: String? = nil) -> String? {
        guard aheadEnums["audio_event"]?.contains(event) == true, let keys = ahead["audio"] else { return nil }
        return aheadFrame("audio", cleanData(keys, ["event": event, "transport": transport, "via": via, "route": route, "reason": reason, "after_ms": afterMs]))
    }

    /// A row sent ahead of the contract, from its cleaned data: the same event and frame `frame` builds.
    private static func aheadFrame(_ name: String, _ clean: [(String, WireJSON)]) -> String {
        let event = WireJSON.object([
            ("name", .string(name)),
            ("detail", .string(detail(name, Dictionary(clean, uniquingKeysWith: { first, _ in first })))),
            ("quiet", .bool(true)),
            ("telemetry", .bool(true)),
            ("data", .object(clean)),
        ])
        return WireJSON.object([("type", .string("app_event")), ("event", event)]).text
    }
}
