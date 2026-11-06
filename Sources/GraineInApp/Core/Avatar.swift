import Foundation

/*
 * THE AGENT'S FACE (avatar) — the wire and the rules, Foundation only.
 *
 * When an agent has a face, the runtime says so on the call's app channel
 * (the WebRTC call's control channel, or the voice socket):
 *
 *   {"type":"avatar","state":"ready","session":{"id","url","token","expires_at"}}
 *   {"type":"avatar","state":"unavailable","reason":"busy"|"error"|"off"}
 *
 * `session` is the VIEWER's descriptor only: where the face is served, which
 * session, and the viewer's own short-lived token. The face's video carries
 * the agent's voice in sync with its lips, so while the face is on screen and
 * playing, the call's own copy of the voice is silenced — and given back the
 * moment the face stops. Exactly one voice is ever heard.
 *
 * Three pieces, each held to the vectors the web engine is held to:
 *   AvatarWire    the frame's reader and the host messages (contract/avatar.json)
 *   AvatarFold    who carries the voice, step by step (contract/avatar-voice.json)
 *   AvatarViewerWire  the face's viewer protocol: its ICE servers, the offer
 *                 and answer, and its clock on the data channel
 */

/// The viewer's descriptor: enough to watch one face, nothing that could drive it. Never logged whole.
@_spi(GraineRTC) public struct GraineAvatarSession: Equatable {
    public let id: String
    /// Where the face is served: https (http only on this machine), no trailing slash, no query.
    public let url: String
    /// The viewer's own short-lived token, sent only to `url`.
    public let token: String
    /// When the token stops working, seconds since 1970; nil when the frame did not say.
    public let expiresAt: Double?
}

/// An `avatar` frame, read.
enum AvatarFrame: Equatable {
    case ready(GraineAvatarSession)
    case unavailable(String)
    case ended
}

enum AvatarWire {
    static let frameType = "avatar"
    static let reasons = ["busy", "error", "off"]
    static let sessionIdMax = 128
    static let urlMax = 2048
    static let tokenMax = 4096
    /// page → host: `{type: "graine:avatar", state: available|live|off, reason?}`.
    static let hostState = "graine:avatar"
    /// host → page: `{type: "graine:avatar-surface", shown}`.
    static let surface = "graine:avatar-surface"
    static let hostStates = ["available", "live", "off"]

    private static let localHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    /// Where a face is served, cleaned — or nil (sdk/inapp protocol.ts `avatarServiceUrl`).
    static func serviceUrl(_ raw: Any?) -> String? {
        guard let text = JSON.unwrap(raw) as? String, !text.isEmpty, text.count <= urlMax,
              text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let parts = URLComponents(string: text),
              let scheme = parts.scheme?.lowercased(),
              let rawHost = parts.host, !rawHost.isEmpty,
              parts.user == nil, parts.password == nil
        else { return nil }
        let bare = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        let local = localHosts.contains(bare)
        guard scheme == "https" || (scheme == "http" && local) else { return nil }
        let host = bare.contains(":") ? "[\(bare)]" : bare
        var port = ""
        if let p = parts.port, !(scheme == "https" && p == 443), !(scheme == "http" && p == 80) { port = ":\(p)" }
        var path = parts.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        return "\(scheme)://\(host)\(port)\(path)"
    }

    /// An `avatar` frame, read — or nil when it is not one, or names a session nobody could watch. Never throws.
    static func read(_ frame: Any?) -> AvatarFrame? {
        guard let f = JSON.unwrap(frame) as? [String: Any], (JSON.unwrap(f["type"]) as? String) == frameType else { return nil }
        let state = JSON.unwrap(f["state"]) as? String
        if state == "unavailable" {
            let reason = JSON.unwrap(f["reason"]) as? String
            return .unavailable(reason.flatMap { reasons.contains($0) ? $0 : nil } ?? "error")
        }
        if state == "ended" { return .ended }
        guard state == "ready", let s = JSON.unwrap(f["session"]) as? [String: Any] else { return nil }
        if let transport = JSON.unwrap(s["transport"]), !(transport is NSNull), (transport as? String) != "webrtc" { return nil }
        let id = JSON.unwrap(s["id"]) as? String ?? ""
        guard !id.isEmpty, id.count <= sessionIdMax, id.unicodeScalars.allSatisfy(isIdScalar) else { return nil }
        guard let url = serviceUrl(s["url"]) else { return nil }
        let token = JSON.unwrap(s["token"]) as? String ?? ""
        guard !token.isEmpty, token.count <= tokenMax,
              !token.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.value < 0x20 || $0.value == 0x7F })
        else { return nil }
        var expiresAt: Double?
        if let raw = JSON.unwrap(s["expires_at"]), let n = JSON.number(raw), n.doubleValue.isFinite, n.doubleValue > 0 {
            expiresAt = n.doubleValue
        }
        return .ready(GraineAvatarSession(id: id, url: url, token: token, expiresAt: expiresAt))
    }

    private static func isIdScalar(_ c: Unicode.Scalar) -> Bool {
        switch c {
        case "A"..."Z", "a"..."z", "0"..."9", ".", "_", ":", "-": return true
        default: return false
        }
    }

    /// The message a host is told, or nil for a state it is not told about (protocol.ts `avatarHostMessage`).
    static func hostMessage(state: String, reason: String?) -> [String: Any]? {
        guard hostStates.contains(state) else { return nil }
        var message: [String: Any] = ["type": hostState, "state": state]
        if state == "off", let r = reason, r.range(of: "^[a-z_]{1,24}$", options: .regularExpression) != nil { message["reason"] = r }
        return message
    }

    /// A page's `graine:avatar`, read: (state, reason) — nil when it is not one.
    static func readHostMessage(_ message: Any?) -> (state: String, reason: String?)? {
        guard let m = JSON.unwrap(message) as? [String: Any], (JSON.unwrap(m["type"]) as? String) == hostState,
              let state = JSON.unwrap(m["state"]) as? String, hostStates.contains(state) else { return nil }
        let reason = JSON.unwrap(m["reason"]) as? String
        return (state, state == "off" && reason?.range(of: "^[a-z_]{1,24}$", options: .regularExpression) != nil ? reason : nil)
    }

    /// A host's `graine:avatar-surface`, read: whether the face is on screen — nil when it is not one.
    static func readSurface(_ message: Any?) -> Bool? {
        guard let m = JSON.unwrap(message) as? [String: Any], (JSON.unwrap(m["type"]) as? String) == surface,
              let shown = JSON.unwrap(m["shown"]), let value = JSON.bool(shown) else { return nil }
        return value
    }

    /// What the host posts into the page: the engine's view is (or is no longer) on screen as the face.
    static func surfaceMessage(shown: Bool) -> [String: Any] { ["type": surface, "shown": shown] }

    /// The app's view of the face, for a bridge: `{"phase":"off"|"available"|"live","reason":"…"|null}`.
    static func stateJSON(_ state: GraineAvatarState) -> String {
        let reason = state.reason.flatMap { $0.range(of: "^[a-z_]{1,24}$", options: .regularExpression) != nil ? "\"\($0)\"" : nil } ?? "null"
        return #"{"phase":"\#(state.phase.rawValue)","reason":\#(reason)}"#
    }
}

// MARK: - Who carries the voice (lib/avatar-state.ts, line for line)

enum AvatarPhase: String {
    /// No face on this call (yet, or any more).
    case off
    /// A face is ready but cannot be seen here: not watched, the voice stays the call's.
    case held
    /// Watching it: connecting, no frame yet. The voice is the call's.
    case connecting
    /// On screen and playing, silent, waiting for a gap to take the voice.
    case waiting
    /// On screen and carrying the voice; the call's own copy is silenced.
    case live
    /// Frames stopped. The voice is the call's again, the face silent.
    case stalled
    /// The face will not play aloud. The voice is the call's.
    case blocked
}

struct AvatarFoldState: Equatable {
    var phase: AvatarPhase = .off
    var session: GraineAvatarSession?
    var reason: String?
    var shown: Bool
    var since: Double = 0
    var frames: Double = 0
    var lastFrameAt: Double = 0
    var flowingSince: Double = 0
    var stalls = 0
    var quiet = 0
    var heard: [[Bool]] = []

    init(shown: Bool) { self.shown = shown }
}

enum AvatarFoldEvent {
    case frame(AvatarFrame, at: Double)
    case surface(Bool, at: Double)
    case playing(at: Double)
    case blocked(at: Double)
    case failed(at: Double)
    /// Times in milliseconds. `frames`: decoded so far (nil: unknown). `face`: the face's level (nil: unknown). `agent`: the call's, on the meter scale, before any mute.
    case sample(at: Double, frames: Double?, face: Double?, agent: Double)
    case callEnded(at: Double)
}

enum AvatarFold {
    static let sampleMs = 250.0
    static let stallMs = 2_000.0
    static let firstFrameMs = 25_000.0
    static let resumeMs = 1_000.0
    static let stalledMaxMs = 45_000.0
    static let maxStalls = 3
    static let quietSamples = 2
    static let quietLevel = 0.08
    static let speechLevel = 0.15
    static let faceQuiet = 0.01
    static let faceHeard = 0.02
    static let voiceWindow = 12
    static let voiceSpeechMin = 8

    private static let mountedPhases: Set<AvatarPhase> = [.connecting, .waiting, .live, .stalled, .blocked]

    static func mounted(_ s: AvatarFoldState) -> Bool { mountedPhases.contains(s.phase) }
    static func visible(_ s: AvatarFoldState) -> Bool { s.phase == .waiting || s.phase == .live || s.phase == .stalled }
    static func agentAudible(_ s: AvatarFoldState) -> Bool { s.phase != .live }
    static func faceAudible(_ s: AvatarFoldState) -> Bool { s.phase == .live }

    /// What a host is told: a face to show, a face on screen carrying the voice, or none.
    static func hostState(_ s: AvatarFoldState) -> (state: String, reason: String?) {
        switch s.phase {
        case .off: return ("off", s.reason)
        case .live: return ("live", nil)
        case .blocked: return ("off", "blocked")
        default: return ("available", nil)
        }
    }

    private static func off(_ s: AvatarFoldState, _ reason: String?, _ at: Double) -> AvatarFoldState {
        var n = AvatarFoldState(shown: s.shown)
        n.reason = reason
        n.since = at
        return n
    }

    private static func watching(_ s: AvatarFoldState, _ session: GraineAvatarSession, _ at: Double) -> AvatarFoldState {
        var n = AvatarFoldState(shown: s.shown)
        n.phase = s.shown ? .connecting : .held
        n.session = session
        n.since = at
        return n
    }

    static func fold(_ s: AvatarFoldState, _ e: AvatarFoldEvent) -> AvatarFoldState {
        switch e {
        case let .frame(frame, at):
            switch frame {
            case .ready(let session):
                if let current = s.session, current.id == session.id, s.phase != .off { return s }
                return watching(s, session, at)
            case .unavailable(let reason):
                return off(s, reason, at)
            case .ended:
                return off(s, "ended", at)
            }
        case let .surface(shown, at):
            if shown == s.shown { return s }
            var next = s
            next.shown = shown
            if shown, s.phase == .held, let session = s.session { return watching(next, session, at) }
            if !shown, mounted(s), let session = s.session {
                var held = AvatarFoldState(shown: false)
                held.phase = .held
                held.session = session
                held.since = at
                return held
            }
            return next
        case .playing(let at):
            guard s.phase == .connecting || s.phase == .blocked else { return s }
            var n = s
            n.phase = .waiting
            n.since = at
            n.lastFrameAt = at
            n.quiet = 0
            return n
        case .blocked(let at):
            guard mounted(s), s.phase != .blocked else { return s }
            var n = s
            n.phase = .blocked
            n.since = at
            n.quiet = 0
            n.heard = []
            return n
        case .failed(let at):
            return mounted(s) ? off(s, "failed", at) : s
        case .callEnded(let at):
            // Clean for the next call — the reason too.
            return s.phase == .off && s.session == nil && s.reason == nil ? s : off(s, nil, at)
        case let .sample(at, frames, face, agent):
            return sample(s, at: at, frames: frames, face: face, agent: agent)
        }
    }

    private static func sample(_ s: AvatarFoldState, at: Double, frames: Double?, face: Double?, agent: Double) -> AvatarFoldState {
        if s.phase == .connecting {
            return at - s.since >= firstFrameMs ? off(s, "failed", at) : s
        }
        guard s.phase == .waiting || s.phase == .live || s.phase == .stalled else { return s }

        let moved = frames.map { $0 > s.frames } ?? false
        var next = s
        if moved, let f = frames {
            next.frames = f
            next.lastFrameAt = at
        }

        if s.phase == .stalled {
            if at - s.since >= stalledMaxMs { return off(s, "stalled", at) }
            if !moved {
                if next.flowingSince != 0 { next.flowingSince = 0 }
                return next
            }
            let flowingSince = next.flowingSince != 0 ? next.flowingSince : at
            if at - flowingSince >= resumeMs {
                next.phase = .waiting
                next.since = at
                next.flowingSince = 0
                next.quiet = 0
                next.heard = []
                return next
            }
            next.flowingSince = flowingSince
            return next
        }

        if at - next.lastFrameAt >= stallMs {
            let stalls = next.stalls + 1
            if stalls >= maxStalls { return off(s, "stalled", at) }
            next.phase = .stalled
            next.since = at
            next.stalls = stalls
            next.flowingSince = 0
            next.quiet = 0
            next.heard = []
            return next
        }

        let agentLevel = agent.isFinite ? agent : 0

        if s.phase == .waiting {
            let gap = agentLevel < quietLevel && (face == nil || face! < faceQuiet)
            let quiet = gap ? next.quiet + 1 : 0
            if quiet >= quietSamples {
                next.phase = .live
                next.since = at
                next.quiet = 0
                next.heard = []
                return next
            }
            next.quiet = quiet
            return next
        }

        guard let faceLevel = face else { return next }
        var heard = next.heard + [[agentLevel >= speechLevel, faceLevel >= faceHeard]]
        if heard.count > voiceWindow { heard.removeFirst(heard.count - voiceWindow) }
        if heard.count == voiceWindow {
            let speaking = heard.filter { $0[0] }.count
            let faceWasHeard = heard.contains { $0[1] }
            if speaking >= voiceSpeechMin && !faceWasHeard { return off(s, "no_voice", at) }
        }
        next.heard = heard
        return next
    }

    /// The meter scale the rules are written on (the web engine's `meterLevel`): from the mean absolute sample, 0–1.
    static func meterLevel(meanAbs: Double) -> Double {
        let x = meanAbs.isFinite ? max(0, meanAbs) : 0
        return (min(1, (x / 0.25).squareRoot()) * 100).rounded() / 100
    }
}

// MARK: - The face's viewer protocol

/// One ICE server as the face's /ice route names it.
@_spi(GraineRTC) public struct GraineAvatarIceServer: Equatable {
    public let urls: [String]
    public let username: String?
    public let credential: String?
}

/// One step the viewer's clock asks for.
enum AvatarClockStep: Equatable {
    /// Say `{type: played, samples, epoch}` after `delayMs`, if the epoch is still current then.
    case ack(samples: Double, epoch: Double, delayMs: Double)
    /// The agent was interrupted: drop pending acks, silence the face for `muteMs` while stale audio drains.
    case interrupted(muteMs: Double)
    /// The service reported an error: the viewer has failed.
    case failed
}

/**
 * THE VIEWER PROTOCOL (the avatar service's browser playback, implemented
 * natively): GET {url}/v1/sessions/{id}/ice and POST …/offer with the viewer's
 * bearer token; the offer is complete (the service never trickles); one data
 * channel carries the service's clock, which the viewer answers with what it
 * has played — the service paces the face by it.
 */
enum AvatarViewerWire {
    /// How long the face's address may take to answer each request.
    static let requestSeconds = 8.0
    /// How long to gather network paths before offering what there is.
    static let gatherSeconds = 5.0
    /// The service closes an idle viewer; this keeps it from looking idle.
    static let pingSeconds = 15.0
    /// The data channel's label.
    static let channelLabel = "playback"
    /// The first connection: tried again (every `retrySeconds`) until this long has passed.
    static let connectSeconds = 20.0
    /**
     * A connection lost mid-call: made again (a fresh peer and offer) until this
     * long has passed — the service can hold a dead viewer for up to ~30 s and
     * answers 409 meanwhile, so this outlasts that.
     */
    static let reconnectSeconds = 40.0
    static let retrySeconds = 2.0
    /// `disconnected` this long is a lost connection.
    static let disconnectedSeconds = 4.0

    /// A refusal no retry can change: the token expired, or the face is gone.
    static func isFinal(_ status: Int?) -> Bool {
        guard let s = status else { return false }
        return [401, 403, 404, 410].contains(s)
    }

    static func base(_ s: GraineAvatarSession) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        let id = s.id.addingPercentEncoding(withAllowedCharacters: allowed) ?? s.id
        return "\(s.url)/v1/sessions/\(id)"
    }

    static func iceURL(_ s: GraineAvatarSession) -> URL? { URL(string: base(s) + "/ice") }
    static func offerURL(_ s: GraineAvatarSession) -> URL? { URL(string: base(s) + "/offer") }
    static func authorization(_ s: GraineAvatarSession) -> String { "Bearer \(s.token)" }

    /// Whether the token has expired at `now` (seconds since 1970).
    static func expired(_ s: GraineAvatarSession, now: Double) -> Bool {
        guard let at = s.expiresAt else { return false }
        return now > at
    }

    /// The ICE servers the /ice route answers, kept only when they look like ICE servers (at most 8).
    static func iceServers(from body: Data?) -> [GraineAvatarIceServer] {
        guard let o = JSON.object(from: body), let list = o["iceServers"] as? [Any] else { return [] }
        var out: [GraineAvatarIceServer] = []
        for item in list.prefix(8) {
            guard let s = item as? [String: Any] else { continue }
            let urls: [String]
            if let one = s["urls"] as? String { urls = [one] } else if let many = s["urls"] as? [Any], !many.isEmpty, many.allSatisfy({ $0 is String }) {
                urls = many.compactMap { $0 as? String }
            } else { continue }
            guard urls.allSatisfy(isIceUrl) else { continue }
            out.append(GraineAvatarIceServer(urls: urls, username: s["username"] as? String, credential: s["credential"] as? String))
        }
        return out
    }

    private static func isIceUrl(_ u: String) -> Bool {
        u.range(of: "^(stuns?|turns?):", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The offer's body: `{"sdp": …, "type": "offer"}`.
    static func offerBody(sdp: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["sdp": sdp, "type": "offer"], options: [.sortedKeys])) ?? Data()
    }

    /// The answer's SDP, or nil when the body is not an answer.
    static func answer(from body: Data?) -> String? {
        guard let o = JSON.object(from: body), (o["type"] as? String) == "answer", let sdp = o["sdp"] as? String, !sdp.isEmpty else { return nil }
        return sdp
    }

    static let readyMessage = #"{"type":"ready"}"#
    static let pingMessage = #"{"type":"ping"}"#

    static func playedMessage(samples: Double, epoch: Double) -> String {
        #"{"type":"played","samples":\#(number(samples)),"epoch":\#(number(epoch))}"#
    }

    private static func number(_ x: Double) -> String {
        x == x.rounded() && abs(x) < 1e15 ? String(Int64(x)) : String(x)
    }

    /// How far behind the clock the face is heard, from its jitter buffer (ms), 60–500.
    static func playoutDelayMs(jitterBufferDelay: Double, emittedCount: Double) -> Double? {
        guard emittedCount > 0, jitterBufferDelay.isFinite else { return nil }
        return min(500, max(60, 1000 * jitterBufferDelay / emittedCount + 40))
    }
}

/// The viewer's clock on the data channel: what each service message asks of it.
struct AvatarClock {
    private(set) var epoch: Double = 0
    private var lastSamples: Double = -1
    /// When to say a sample was played, from the jitter buffer; 150 ms until measured.
    var playoutDelayMs: Double = 150

    mutating func reset() { lastSamples = -1 }

    mutating func receive(_ text: String) -> AvatarClockStep? {
        guard let ev = JSON.object(from: text) else { return nil }
        if let e = ev["epoch"], let n = JSON.number(e) { epoch = n.doubleValue }
        switch ev["type"] as? String {
        case "clock":
            guard let raw = ev["samples"], let n = JSON.number(raw) else { return nil }
            let samples = n.doubleValue
            guard samples != lastSamples else { return nil }
            lastSamples = samples
            return .ack(samples: samples, epoch: epoch, delayMs: playoutDelayMs)
        case "interrupted":
            lastSamples = -1
            return .interrupted(muteMs: playoutDelayMs + 60)
        case "error":
            return .failed
        default:
            return nil
        }
    }

    func current(_ e: Double) -> Bool { e == epoch }
}

// MARK: - What an app sees

/**
 * THE AGENT'S FACE, AS THE APP SEES IT — `GraineAvatar.shared.state`.
 *
 * `off` — no face on this call (or no call). `reason` says why when a call has
 * an agent with a face that is not shown: `busy` (every face is in use),
 * `error`, `off` (the agent has none), `ended`, `failed` (it could not
 * connect), `stalled`, `no_voice`, `blocked`, `hidden` (no avatar view on
 * screen), `unsupported` (this call cannot show one — see the README).
 * `available` — a face is ready: show your avatar view. `live` — the face is
 * on screen and carries the agent's voice.
 */
public struct GraineAvatarState: Equatable {
    public enum Phase: String {
        case off
        case available
        case live
    }

    public let phase: Phase
    public let reason: String?

    public init(phase: Phase, reason: String? = nil) {
        self.phase = phase
        self.reason = phase == .off ? reason : nil
    }

    public static let off = GraineAvatarState(phase: .off)

    /// A face to draw: available or live.
    public var showsFace: Bool { phase != .off }

    init(host: (state: String, reason: String?)) {
        self.init(phase: Phase(rawValue: host.state) ?? .off, reason: host.reason)
    }
}
