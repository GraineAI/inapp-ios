import Foundation

/**
 * THE WIRE PROTOCOL — the same one the React Native and Android SDKs speak,
 * byte for byte.
 *
 * The call itself runs in a page Graine hosts, inside a WKWebView this SDK
 * owns. That is deliberate, and it is the whole reason a native app gets every
 * audio-path fix the day it ships: TURN relays, the dead-media watchdog,
 * connection quality, WebSocket fallback — all of it lives in the page, and
 * the page is updated without an app release.
 *
 * What crosses the boundary is small and fixed:
 *
 *   host → page   window.postMessage({type: "graine:…"}, "*")
 *   page → host   window.ReactNativeWebView.postMessage("<json>")
 *
 * The page was written for React Native's WebView, and this SDK installs an
 * object under that same name (forwarding to a WKScriptMessageHandler), so the
 * page needs no idea which platform it is running on. Every message type is
 * listed here once; a type that is not in `PageMessage` is ignored rather than
 * guessed at.
 *
 * Named GraineProtocol, not Protocol: `Protocol` is the Objective-C runtime's
 * class, and shadowing it would break an app that imports both.
 */
public enum GraineProtocol {

    /// Messages this SDK sends into the page.
    public enum Out {
        public static let startCall = "graine:start-call"
        public static let endCall = "graine:end-call"
        public static let setMuted = "graine:set-muted"
        public static let warm = "graine:warm"
        public static let variables = "graine:variables"
        public static let appContext = "graine:app-context"
        public static let appActionResult = "graine:app-action-result"
        public static let appEvent = "graine:app-event"
        public static let widgetResult = "graine:widget-result"
    }

    /// Messages the page sends out.
    public enum In {
        public static let ready = "graine:ready"
        public static let call = "graine:call"
        public static let muted = "graine:muted"
        public static let caption = "graine:caption"
        public static let widget = "graine:widget"
        public static let widgetPending = "graine:widget-pending"
        public static let appAction = "graine:app-action"
        public static let ended = "graine:ended"
        public static let micDenied = "graine:mic-denied"
        public static let transport = "graine:transport"
        public static let quality = "graine:quality"
        public static let network = "graine:network"
        public static let reconnecting = "graine:reconnecting"
        /// Where a connect is: registering · dialling · retrying · switching · failed (contract/DESIGN.md "Connecting").
        public static let progress = "graine:progress"
    }

    /**
     * The name the page looks for. It was written against React Native's
     * WebView bridge; installing the same name is what lets one page serve
     * every platform.
     */
    public static let bridgeName = "ReactNativeWebView"

    /// The WKScriptMessageHandler the bridge object forwards to.
    public static let messageHandlerName = "graine"

    /// How long an action handler may take before the agent is told it was not done.
    public static let actionDeadlineMs = 6_000

    /**
     * The engine page's URL. Identical to the React Native launcher's, because
     * a difference here is a different agent, a different transport, or a
     * cache that never refreshes.
     *
     * - Parameters:
     *   - voiceAgentId: the WEB-CALL agent id. Calling the primary id works,
     *     sounds right, and files every transcript under an agent nobody watches.
     *   - cacheKey: the deployment id from the session — so a new deploy is a
     *     new URL, and the same deploy is served from the nearest edge. A
     *     per-launch timestamp here is an origin round trip on every launch.
     *   - idle: load the page without registering anything, so a later tap
     *     costs one registration and an INVITE instead of a whole page load.
     *
     * Values are encoded exactly as JavaScript's encodeURIComponent does —
     * the React Native SDK built the fixtures this is tested against.
     */
    public static func engineUrl(
        baseUrl: String,
        voiceAgentId: String,
        transport: GraineTransport,
        cacheKey: String,
        idle: Bool,
        publishableKey: String,
        accent: String?
    ) -> String {
        var url = trimTrailingSlashes(baseUrl)
        url += "/embed/" + encode(voiceAgentId)
        url += "?mode=voice&branding=0&embed=1"
        url += "&transport=" + transport.wire
        url += "&b=" + encode(cacheKey)
        if idle { url += "&idle=1" }
        url += "&pk=" + encode(publishableKey)
        if var hex = accent?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if hex.hasPrefix("#") { hex.removeFirst() }
            if !hex.isEmpty { url += "&accent=" + encode(hex) }
        }
        return url
    }

    /**
     * The JavaScript that delivers one message into the page. Nil when the
     * message cannot be serialised — dropped, never a crash.
     *
     * `true;` at the end so the statement's value is always serialisable.
     * U+2028/U+2029 are escaped: JSON allows them raw inside a string, and an
     * older JavaScript engine reads them as a line break inside a literal.
     */
    public static func deliver(_ message: [String: Any]) -> String? {
        guard let json = JSON.string(from: message) else { return nil }
        let safe = json
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return "window.postMessage(\(safe), \"*\"); true;"
    }

    /**
     * What the debug log shows for a message going into the page: its type and
     * enough to recognise it, never a customer's values. Variables are logged as
     * their keys only; a context frame as its screen's name only.
     */
    static func redactForLog(_ message: [String: Any]) -> String {
        switch JSON.string(message["type"]) {
        case Out.variables:
            let keys = (message["variables"] as? [String: Any])?.keys.sorted() ?? []
            return "{" + keys.joined(separator: ", ") + "}"
        case Out.appContext:
            let context = message["context"] as? [String: Any]
            return "screen=" + JSON.string(context?["screen"])
        default:
            return String((JSON.string(from: message) ?? "").prefix(300))
        }
    }

    /// One outgoing message: its type, and its fields as JSON values.
    public static func out(_ type: String, _ fields: [String: Any?] = [:]) -> [String: Any] {
        var message: [String: Any] = ["type": type]
        for (key, value) in fields { message[key] = JSON.normalize(value) }
        return message
    }

    /// Parse one message from the page. Nil for anything that is not ours.
    public static func parse(_ raw: String?) -> PageMessage? {
        guard let o = JSON.object(from: raw), let type = o["type"] as? String else { return nil }
        switch type {
        case In.ready:
            return .ready
        case In.call:
            return .call(connected: JSON.flag(o["connected"]), connecting: JSON.flag(o["connecting"]))
        case In.muted:
            return .muted(JSON.flag(o["muted"]))
        case In.caption:
            let role: GraineRole = JSON.string(o["role"]) == "agent" ? .agent : .customer
            return .caption(role: role, text: JSON.string(o["text"]), live: JSON.flag(o["live"]))
        case In.widget:
            return .widget(o["widget"] as? [String: Any] ?? [:])
        case In.widgetPending:
            return .widgetPending(o["widget"] as? [String: Any] ?? [:])
        case In.appAction:
            guard let a = o["action"] as? [String: Any] else { return nil }
            return .appAction(
                actionId: JSON.string(a["action_id"]),
                name: JSON.string(a["name"]),
                arguments: a["arguments"] as? [String: Any] ?? [:]
            )
        case In.ended:
            return .ended
        case In.micDenied:
            return .micDenied(reason: JSON.nonEmpty(o["reason"]) ?? "NotAllowedError")
        case In.transport:
            return .transport(
                transport: GraineTransport.from(o["transport"] as? String),
                requested: GraineTransport.from(o["requested"] as? String),
                reason: JSON.nonEmpty(o["reason"]),
                message: JSON.nonEmpty(o["message"])
            )
        case In.quality:
            let sample = o["sample"] as? [String: Any] ?? [:]
            return .quality(
                rttMs: qualityNumber(sample["rtt"]),
                jitterMs: qualityNumber(sample["jitter"]),
                loss: qualityNumber(sample["loss"])
            )
        case In.network:
            return .network(online: JSON.flag(o["online"]))
        case In.reconnecting:
            return .reconnecting(active: JSON.flag(o["active"]))
        case In.progress:
            // A stage this build does not know is ignored, not stored: the engine may name more later.
            return GraineConnectProgress.from(o["stage"] as? String).map { .progress($0) }
        default:
            return nil
        }
    }

    /**
     * A measurement, or nothing — the React Native SDK's `num()`. A missing,
     * null, negative or non-numeric value is ABSENT, not zero: zero would read
     * as a perfect line, and absent is not perfect.
     */
    static func qualityNumber(_ value: Any?) -> Double? {
        guard let v = JSON.unwrap(value), let n = JSON.number(v) else { return nil }
        let d = n.doubleValue
        return d.isFinite && d >= 0 ? d : nil
    }

    // MARK: - Encoding

    private static let unreserved: Set<UInt8> =
        Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()".utf8)

    /// JavaScript's encodeURIComponent: UTF-8 bytes, upper-case hex, space as %20.
    static func encode(_ s: String) -> String {
        var out = ""
        for byte in s.utf8 {
            if unreserved.contains(byte) {
                out.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    static func trimTrailingSlashes(_ s: String) -> String {
        var out = s
        while out.hasSuffix("/") { out.removeLast() }
        return out
    }
}

/// How the call's audio travels.
public enum GraineTransport: String {
    /// Raw PCM on the conversation socket. Works everywhere; a lossy network sounds lossy.
    case websocket = "ws"
    /// Opus over WebRTC with a jitter buffer and the device's echo canceller. Falls back to `.websocket`.
    case webrtc = "rtc"

    /// The value on the wire and in the engine URL.
    public var wire: String { rawValue }

    /// Anything that is not "rtc" is the WebSocket — the transport that always works.
    public static func from(_ s: String?) -> GraineTransport {
        s == "rtc" ? .webrtc : .websocket
    }
}

/// Who said a caption line.
public enum GraineRole: String {
    case agent
    case customer
}

/// Everything the page can say, typed.
public enum PageMessage {
    case ready
    case call(connected: Bool, connecting: Bool)
    case muted(Bool)
    case caption(role: GraineRole, text: String, live: Bool)
    case widget([String: Any])
    case widgetPending([String: Any])
    case appAction(actionId: String, name: String, arguments: [String: Any])
    case ended
    case micDenied(reason: String)
    case transport(transport: GraineTransport, requested: GraineTransport, reason: String?, message: String?)
    case quality(rttMs: Double?, jitterMs: Double?, loss: Double?)
    case network(online: Bool)
    case reconnecting(active: Bool)
    case progress(GraineConnectProgress)
}

/**
 * The connection, in one word — the way LiveKit reports it.
 *
 * Same thresholds as the React Native SDK, Android and the website (the
 * classic VoIP edges: 150ms / 30ms / 2% leaves "excellent", 400ms / 80ms / 8%
 * is "poor"), so every surface means the same thing by "weak connection".
 * The raw values are the wire words.
 */
public enum GraineConnectionQuality: String {
    case excellent
    case good
    case poor
    case lost
    case unknown

    public static func classify(rttMs: Double?, jitterMs: Double?, loss: Double?) -> GraineConnectionQuality {
        if rttMs == nil && jitterMs == nil && loss == nil { return .unknown }
        let r = rttMs ?? 0
        let j = jitterMs ?? 0
        let l = loss ?? 0
        // Any one of these alone is enough to ruin a call, so the worst wins.
        if r >= 400 || j >= 80 || l >= 0.08 { return .poor }
        if r >= 150 || j >= 30 || l >= 0.02 { return .good }
        return .excellent
    }

    /// One sample object as the page sends it (`{rtt, jitter, loss}`), the React Native `classifyQuality`.
    public static func classify(sample: [String: Any]?) -> GraineConnectionQuality {
        guard let s = sample else { return .unknown }
        return classify(
            rttMs: GraineProtocol.qualityNumber(s["rtt"]),
            jitterMs: GraineProtocol.qualityNumber(s["jitter"]),
            loss: GraineProtocol.qualityNumber(s["loss"])
        )
    }
}
