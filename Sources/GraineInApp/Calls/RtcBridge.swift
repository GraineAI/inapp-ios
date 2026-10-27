import Foundation

/*
 * THE DOOR THE OPT-IN WEBRTC MODULE COMES IN THROUGH.
 *
 * The native calls carry their audio on the voice socket (CallEngine) unless
 * the app also links `GraineInAppRTC`, which carries it on WebRTC. This SDK
 * never imports that module — every app would then pay for libwebrtc — so the
 * module comes to it: it registers here (`GraineRTC.install()`), or is found
 * at runtime by its Objective-C class name, `GraineInAppRTCModule`. An app
 * that adds the product changes nothing else.
 *
 * Everything here is SPI (`@_spi(GraineRTC)`): the module sees it, an app
 * does not. The calls' own logic stays in this SDK (CallConversation): which
 * transport, the fallback to the socket, the captions and the actions. The
 * module only moves audio and frames.
 */

/// Why a call that tried WebRTC continues on the WebSocket — the voice bar's own words.
@_spi(GraineRTC) public enum GraineRtcFallback: String, Sendable {
    /// The call session could not be minted (refused, rate-limited, unreachable).
    case mintFailed = "mint_failed"
    /// The SBC refused the registration, or never answered it.
    case registerFailed = "register_failed"
    /// The INVITE got no reply at all.
    case noResponse = "no_response"
    /// Replies came, the answer did not.
    case noAnswer = "no_answer"
    /// Answered, but the media path never connected.
    case iceTimeout = "ice_timeout"
    /// Anything else before the audio flowed.
    case error
}

/// What the core hands the module for one call.
@_spi(GraineRTC) public struct GraineRtcRequest {
    /// "https://www.graine.ai" unless self-hosted: where the call session is minted.
    public var baseUrl: String
    /// The agent's socket host (`wss://ws.graine.ai`): the control channel lives beside it.
    public var controlHost: String
    /// The mint's JSON body for a session id: the key, the call's variables and who the customer is.
    public var mintBody: (_ sessionId: String) -> Data
    /// The SDK's version, for the SIP User-Agent.
    public var sdkVersion: String
    /// The whole WebRTC attempt — mint to media — within this, or it falls back.
    public var budgetSeconds: Double
    /// Trace each step to the debug log.
    public var debug: Bool
    /**
     * This call rang (Graine or the app's server rang it). The answer to its
     * mint brings a grant for its id, kept for a later mint of the same call —
     * a redial, a leg made again at the answer; only when it brings none is
     * one asked for on its own, so a ring costs the web route one request.
     */
    public var rang: Bool
    /**
     * Before each request to the call-session route — a call's mint, a
     * grant's renewal — what must be ready first is made ready (APP-IDENTITY.md
     * §2.1, §1.3: a proof of the app the agent requires, an identity token
     * about to expire), then `go`: within ten seconds, on any thread. Nil: at
     * once. `mintBody` is read after it, so the body carries what it brought.
     */
    public var beforeMint: ((_ go: @escaping () -> Void) -> Void)?
    /// Every answer of the call-session route — its status and body — for what it says about the app and the user (`verification`).
    public var mintAnswered: ((_ status: Int, _ body: Data?) -> Void)?
    /**
     * A refusal of a call's mint the core may cure — `app_not_verified`
     * (prove the app), `identity_unverified` (a fresh identity token):
     * `retry(true)` once it is cured, and the mint is made once more with a
     * body read again; `retry(false)` and the refusal stands.
     */
    public var cure: ((_ code: String, _ retry: @escaping (Bool) -> Void) -> Void)?

    /**
     * The agent's server tokens (CLIENT-TOKENS.md §2.2): the mint and a grant
     * request to the web route carry the newest one, and a refusal a fresh
     * token can lift is sent once more with one. Never in `mintBody` — what a
     * call was prepared with is compared by it, and a refreshed token is not
     * another call. Nil: no token is in play.
     */
    public var clientTokens: GraineRtcTokens?

    public init(
        baseUrl: String,
        controlHost: String,
        mintBody: @escaping (String) -> Data,
        sdkVersion: String,
        budgetSeconds: Double = 12,
        debug: Bool = false,
        rang: Bool = false,
        beforeMint: ((@escaping () -> Void) -> Void)? = nil,
        mintAnswered: ((Int, Data?) -> Void)? = nil,
        cure: ((String, @escaping (Bool) -> Void) -> Void)? = nil,
        clientTokens: GraineRtcTokens? = nil
    ) {
        self.baseUrl = baseUrl
        self.controlHost = controlHost
        self.mintBody = mintBody
        self.sdkVersion = sdkVersion
        self.budgetSeconds = budgetSeconds
        self.debug = debug
        self.rang = rang
        self.beforeMint = beforeMint
        self.mintAnswered = mintAnswered
        self.cure = cure
        self.clientTokens = clientTokens
    }
}

/**
 * ONE AGENT'S SERVER TOKENS, FOR THE MODULE'S OWN REQUESTS TO THE WEB ROUTE —
 * the call's mint and a grant request (CLIENT-TOKENS.md §2.2). The rules —
 * when to ask, one question at a time, the waits — stay in the core.
 */
@_spi(GraineRTC) public final class GraineRtcTokens {
    let tokens: ClientTokens

    init(_ tokens: ClientTokens) {
        self.tokens = tokens
    }

    /**
     * One request: `send` posts the body it is handed and answers. The body
     * carries the newest token as `clientToken` — a new connection's, so it
     * waits for a usable one first (at most 10 s) — and an answer `refreshable`
     * says a fresh token can lift is sent once more with the token a refresh
     * brought, never with the same one. `done` hears the last answer. Any thread.
     */
    public func send<Answer>(
        _ body: Data,
        refreshable: @escaping (Answer) -> Bool,
        send: @escaping (Data, @escaping (Answer) -> Void) -> Void,
        done: @escaping (Answer) -> Void
    ) {
        ClientTokenWire.exchange(tokens, body: body, newConnection: true, refreshable: refreshable, send: send, done: done)
    }

    /// A refusal's code a fresh server token can lift: `token_required`, `token_invalid`, `token_expired`.
    public static func refreshable(_ code: String?) -> Bool {
        guard let word = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        return ClientTokenRules.refreshableCodes.contains(word)
    }
}

/// What a call prepared ahead of its dial reports while nobody listens to it (`GraineRtcCall.onPrepared`).
@_spi(GraineRTC) public enum GraineRtcPreparedState: Equatable {
    /// Minted, registered and its offer gathered: how long that took, and whether its credential came from the telephony gateway.
    case ready(milliseconds: Int, direct: Bool)
    /// It can no longer carry a call: its mint refused, its registration or its socket lost.
    case lost
}

/// What the module reports about a call, on its own queue.
@_spi(GraineRTC) public enum GraineRtcEvent {
    /// Minted, registered and the offer gathered: the INVITE leaves as soon as the audio runs.
    case ready
    /// Answered, and the media path is up: the call is on WebRTC.
    case connected
    /// The agent's voice is (or stopped being) audible, from the incoming audio level.
    case speaking(Bool)
    /**
     * The media path, up before, was lost and is being brought back (true) —
     * the call screen's "Reconnecting" — or it is back (false). Never before
     * the media flowed; false again before the call's end.
     */
    case reconnecting(Bool)
    /// The agent's voice level, 0–1 — what the receiver plays out — five times a second while the call is live.
    case level(Double)
    /**
     * An analytics row (GraineCallTelemetry's frame), exactly as the call sent
     * it on its control channel — or would have, had the channel joined: the
     * call's connection report is read from these.
     */
    case row(String)
    /**
     * The audio as received so far — the running figures the call's quality
     * row will carry at its end: packets lost (percent), jitter's average and
     * peak and the round trip (milliseconds); nil where nothing was measured.
     * About once a second while the call is live.
     */
    case audio(lossPct: Double?, jitterAvgMs: Double?, jitterMaxMs: Double?, rttAvgMs: Double?)
    /// A control-channel frame — a caption, an action, a component — exactly as it arrived.
    case control(String)
    /// WebRTC cannot carry this call, and nothing has been heard yet: the core carries it on the socket.
    case unreachable(GraineRtcFallback, detail: String)
    /**
     * A gate refused the call itself (`GraineRtcRefusal.codes`: no credit, a
     * monthly cap, the agent off or deleted), or the web route refused it for
     * the server token or the key (`GraineRtcRefusal.tokenCodes`). The call
     * ends with the server's sentence; the WebSocket would refuse it the same way.
     */
    case refused(code: String, message: String)
    /// The call is over after its media flowed.
    case ended(GraineRtcEnding)
    /**
     * The call cannot be heard: the agent's audio arrives and none of it
     * reaches the speaker, even after the leg started the phone's audio
     * again (its playout watch). The core ends the call as its audio watch
     * ends one (`CallAudioWatch.failure`, cause `audio_watch`).
     */
    case playoutFailed(String)
    /// A line for the debug log.
    case log(String)
}

/**
 * THE PHONE'S WORD THAT THE CALL'S AUDIO IS PLAYING. Every WebRTC mint says
 * the phone will send it (`audio_ready_signal: true`, RtcMintBody), so the
 * agent's greeting waits for it — a few seconds at most — instead of being
 * played into a phone whose audio has not started. The leg sends it once per
 * call on its control channel, once the audio was activated (by CallKit, or
 * started by the SDK itself) and the phone's playout is seen running.
 */
@_spi(GraineRTC) public enum GraineRtcSignal {
    /// `{"type":"audio","state":"ready"}`, exactly.
    public static let audioReady = #"{"type":"audio","state":"ready"}"#
}

@_spi(GraineRTC) public enum GraineRtcEnding: Equatable {
    /// The agent's side hung up.
    case remote
    /// The media died and could not be brought back.
    case dropped(String)
}

/// The gates' refusals, as the call session's mint names them: these end the call, they never fall back.
@_spi(GraineRTC) public enum GraineRtcRefusal {
    /**
     * Credit, the agent's status — and the agent's refusal of this app
     * (`app_not_allowed`, and `app_not_verified` once the core could not cure
     * it, APP-IDENTITY.md §2.3): the WebSocket's ticket would be refused the
     * same way a second later.
     */
    public static let codes: Set<String> = [
        "insufficient_credits", "parent_out_of_credits", "monthly_cap", "agent_off", "agent_deleted",
        "app_not_allowed", "app_not_verified",
    ]
    /// The refusals the core may cure once (`GraineRtcRequest.cure`) before they end the call.
    public static let curable: Set<String> = ["app_not_verified", "identity_unverified"]
    /**
     * Refusals for the server token, the publishable key or the bot check
     * (CLIENT-TOKENS.md §5): final for the call — the WebSocket's ticket would
     * meet the same answer, so it ends with the code as its reason.
     */
    public static let tokenCodes: Set<String> = ClientTokenRules.refusalCodes

    /// A mint's refusal that ends the call: a gate's, this app's, or one for the token, the key or the bot check.
    public static func ends(_ code: String?) -> Bool {
        guard let word = code?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return codes.contains(word) || tokenCodes.contains(word.lowercased())
    }
}

/// One call's WebRTC leg. Every method may be called from any thread.
@_spi(GraineRTC) public protocol GraineRtcCall: AnyObject {
    /**
     * Where events go. Settable, so a leg prepared while a call rings can be
     * handed to the call that answers it; events from before one is set are
     * kept and delivered, in order, when it is.
     */
    var onEvent: ((GraineRtcEvent) -> Void)? { get set }
    /// Everything that needs no audio: the mint, the registration, the peer and its candidates.
    func prepare()
    /// The call is wanted now: the control channel opens and the attempt's budget starts.
    func begin()
    /// CallKit activated the audio session (`didActivate`): enable the audio, then dial.
    func audioActivated()
    /// CallKit never did: start the audio without it, once. `done` says whether it runs.
    func startAudioDirectly(_ done: @escaping (Bool) -> Void)
    /// CallKit took the audio back (`didDeactivate`).
    func audioDeactivated()
    func setMuted(_ muted: Bool)
    /// A frame for the control channel; `kind` replaces a queued frame of the same kind (the screen).
    func sendControl(_ frame: String, kind: String?)
    /**
     * Who or what ended the call (GraineCallEndCause's word): the leg's
     * `ended` row on the control channel — with how long the call had its
     * audio and whether the agent's voice was heard — once, before the BYE.
     */
    func sendEnded(cause: String)
    /// Hang up and release everything. Nothing is reported after it.
    func hangUp()
    /**
     * While the call is prepared ahead of its dial and nobody listens: told
     * when it is ready and when it is lost, without taking the events kept for
     * whoever listens later. Any thread.
     */
    var onPrepared: ((GraineRtcPreparedState) -> Void)? { get set }
    /**
     * The call being dialled was prepared ahead of the tap — by `prepareCall`,
     * or as it rang — rather than at it: its `connect` row says `prepared`
     * when it was also ready by then. Set before `begin()`.
     */
    var preparedAhead: Bool { get set }
    /**
     * The call's `transport` row (GraineCallTelemetry), written by whoever
     * dials it — only it knows what the app asked for. Sent on the control
     * channel at media, just before the `connect` row; never if the call
     * does not get there. Set before `begin()`.
     */
    var transportRow: String? { get set }
}

@_spi(GraineRTC) public extension GraineRtcCall {
    /// A call that reports nothing ahead of its listener.
    var onPrepared: ((GraineRtcPreparedState) -> Void)? {
        get { nil }
        set {}
    }

    /// A call that does not tell prepared from cold.
    var preparedAhead: Bool {
        get { false }
        set {}
    }

    /// A call that sends no analytics rows.
    var transportRow: String? {
        get { nil }
        set {}
    }

    /// A leg that keeps no timings: the cause alone.
    func sendEnded(cause: String) {
        if let frame = GraineCallTelemetry.endedFrame(cause: cause, transport: "rtc") { sendControl(frame, kind: nil) }
    }
}

/// The module itself.
@_spi(GraineRTC) public protocol GraineRtcModule: AnyObject {
    /// Whether this device can carry a call on it.
    var isSupported: Bool { get }
    func makeCall(_ request: GraineRtcRequest) -> GraineRtcCall
    /**
     * Ahead of a call: whatever lets it start sooner — a grant for the direct
     * mint, the gateway asked whether it takes one. `request.mintBody` carries
     * who the customer is and, for a call that is ringing, its id: a grant
     * names exactly one call. Without an id, it is for the next call the
     * customer places (`nextCallId` hands that call its id); the session
     * arrived, the customer changed, the app came back. In the background; it
     * never touches the microphone, never waits and never fails anything, and
     * sends nothing while what it prepared still holds. `log` hears what
     * happened when the app runs with debug on.
     */
    func warmUp(_ request: GraineRtcRequest, log: ((String) -> Void)?)
    /**
     * The id for the call the customer is placing now: the one the next
     * call's grant was asked for, while that grant is usable for who
     * `request.mintBody` names — so the call mints at the telephony gateway
     * and carries its own id there. Taken once; the next call's grant follows
     * this call's mint. Nil: the call takes an id of its own and mints on the
     * web route. Answers at once.
     */
    func nextCallId(_ request: GraineRtcRequest) -> String?
    /**
     * CallKit took the call's audio session back (`didDeactivate`) with no leg
     * left to tell — the call it was for is over. The module's view of the
     * session must follow, or the next call's start believes a session active
     * that is not. Main thread.
     */
    func audioSessionDeactivated()
}

@_spi(GraineRTC) public extension GraineRtcModule {
    /// A module with nothing to prepare ahead of a call.
    func warmUp(_ request: GraineRtcRequest, log: ((String) -> Void)?) {}
    /// A module without grants: every call takes an id of its own.
    func nextCallId(_ request: GraineRtcRequest) -> String? { nil }
    /// A module that keeps no view of the audio session.
    func audioSessionDeactivated() {}
}

/// Where the core finds the module: installed explicitly, or looked up once by its class name.
@_spi(GraineRTC) public enum GraineRtcRegistry {
    /// The module's stable Objective-C name.
    public static let className = "GraineInAppRTCModule"

    private static let lock = NSLock()
    private static var installed: GraineRtcModule?
    private static var lookedUp = false

    /// `GraineRTC.install()` calls this; so does the runtime lookup.
    public static func install(_ module: GraineRtcModule) {
        lock.lock()
        installed = module
        lock.unlock()
    }

    /// The module, or nil when the app does not include it.
    static var module: GraineRtcModule? {
        lock.lock()
        defer { lock.unlock() }
        if installed == nil && !lookedUp {
            lookedUp = true
            if let type = NSClassFromString(className) as? NSObject.Type, let found = type.init() as? GraineRtcModule {
                installed = found
            }
        }
        return installed
    }

    /// Tests only: forget what was installed (and whether it was looked up).
    static func reset(_ module: GraineRtcModule? = nil) {
        lock.lock()
        installed = module
        lookedUp = module != nil
        lock.unlock()
    }
}

/**
 * THE MINT'S BODY: the publishable key, this call's session id, the call's
 * variables and the same identity fields the ticket request carries — who the
 * customer is, the install (without it the agent's memory stays off), the
 * memory choice, the time zone, and the id of a call Graine rang. The
 * variables are exactly the ticket's (`CallWire.ticketVariables`: the call's
 * own first, then the SDK's, at most twelve, 200 characters each, a kilobyte
 * in all), so a call reaches the agent with the same prompt on either road.
 * Last, `audio_ready_signal: true`: this phone says when the call's audio
 * plays (GraineRtcSignal.audioReady), and the greeting waits for it.
 */
enum RtcMintBody {
    /// The mint's body, sealed with `credentials` (APP-IDENTITY.md §1: the app's declaration; the token and pass inside `identity`).
    static func json(
        publishableKey: String,
        sessionId: String,
        callVariables: [(String, String)],
        variables: [(String, String)],
        identity: IdentityWire.Fields?,
        credentials: EmbedCredentials? = nil
    ) -> Data {
        var fields: [(String, WireJSON)] = [
            ("publishableKey", .string(publishableKey)),
            ("session_id", .string(sessionId)),
        ]
        if let metadata = CallWire.ticketVariables(call: callVariables, rest: variables) {
            fields.append(("variables", .object(metadata.map { ($0.0, .string($0.1)) })))
        }
        if let identity = identity { fields += IdentityWire.pairs(identity) }
        fields.append(("audio_ready_signal", .bool(true)))
        return Data(WireJSON.object(EmbedSeal.seal(fields, credentials)).text.utf8)
    }

    /**
     * What makes two mints the same call: the body without what renews on
     * its own — the app's declaration (its pass is renewed daily) and the
     * user pass (hourly). Who is calling, the identity token included, stays:
     * a call prepared with another token is not the call placed now.
     */
    static func stable(_ body: Data) -> Data {
        guard var object = JSON.object(from: body) else { return body }
        object.removeValue(forKey: "app")
        if var identity = object["identity"] as? [String: Any] {
            identity.removeValue(forKey: "pass")
            object["identity"] = identity
        }
        return JSON.string(from: object, sortedKeys: true).map { Data($0.utf8) } ?? body
    }

    /// Two mint bodies place the same call (`stable`).
    static func sameCall(_ a: Data, _ b: Data) -> Bool {
        stable(a) == stable(b)
    }
}

extension GraineRtcRequest {
    /**
     * The call session asked as APP-IDENTITY.md says: before each mint (and
     * grant renewal) what is worth waiting for is waited for, every answer's
     * `verification` is kept, and a curable refusal is cured once.
     */
    mutating func guarded(by security: EmbedProof?, identityValue: String?) {
        guard let security = security else { return }
        beforeMint = { go in security.beforeConversation(go) }
        mintAnswered = { status, data in
            security.heard(status: status, body: JSON.object(from: data), identityValue: identityValue)
        }
        cure = { code, retry in
            security.cure(GraineServiceError(code: GraineErrorCode(wire: code), message: code, status: 403), retry)
        }
    }
}
