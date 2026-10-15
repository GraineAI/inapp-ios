import Foundation

/**
 * WHICH ROAD A NATIVE CALL'S AUDIO TAKES (`GraineCallsConfig.callTransport`).
 *
 * The WebSocket carries the call's audio as raw PCM: it works everywhere, and
 * a lossy network sounds lossy. WebRTC carries it with a jitter buffer, loss
 * concealment and the platform's echo canceller, and survives a network that
 * drops packets — but it needs the opt-in `GraineInAppRTC` product in the app.
 *
 * Whatever is chosen, a call that cannot be carried on WebRTC before any audio
 * flows continues on the WebSocket inside the same system call: the customer
 * only ever sees "Connecting…" a moment longer.
 */
public enum GraineCallTransport: String, CaseIterable, Sendable {
    /// WebRTC when the app includes GraineInAppRTC (and the dashboard allows it); the WebSocket otherwise. The default.
    case auto
    /// Always the WebSocket.
    case websocket
    /// WebRTC whenever it can carry the call; the WebSocket when it cannot.
    case webrtc

    /// "auto", "websocket" ("ws") or "webrtc" ("rtc"), any case; nil for anything else.
    public static func from(_ text: String?) -> GraineCallTransport? {
        switch text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "auto": return .auto
        case "websocket", "ws": return .websocket
        case "webrtc", "rtc": return .webrtc
        default: return nil
        }
    }
}

/**
 * The transport a call tries first. The dashboard's switch (the session's
 * `calls.audioTransport`) can only turn WebRTC off: "websocket" wins over
 * anything the app asked. `auto` and `webrtc` both mean WebRTC when the module
 * is in the app and runs on this OS.
 */
enum CallTransportChoice {
    static func decide(requested: GraineCallTransport, dashboard: GraineCallTransport?, rtcAvailable: Bool) -> GraineCallTransport {
        if dashboard == .websocket { return .websocket }
        switch requested {
        case .websocket: return .websocket
        case .auto, .webrtc: return rtcAvailable ? .webrtc : .websocket
        }
    }
}

/// What a call ran on, for the call screen and the log: the transport, and why it is not the one asked for.
struct CallTransportReport: Equatable {
    var transport: GraineCallTransport
    /// The transport tried first, when the call fell back from it.
    var requested: GraineCallTransport?
    /// The fallback's reason, in the voice bar's words (`GraineRtcFallback`).
    var reason: String?
}
