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

    public init(baseUrl: String, controlHost: String, mintBody: @escaping (String) -> Data, sdkVersion: String, budgetSeconds: Double = 12, debug: Bool = false, rang: Bool = false) {
        self.baseUrl = baseUrl
        self.controlHost = controlHost
        self.mintBody = mintBody
        self.sdkVersion = sdkVersion
        self.budgetSeconds = budgetSeconds
        self.debug = debug
        self.rang = rang
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
    /// A control-channel frame — a caption, an action, a component — exactly as it arrived.
    case control(String)
    /// WebRTC cannot carry this call, and nothing has been heard yet: the core carries it on the socket.
    case unreachable(GraineRtcFallback, detail: String)
    /**
     * A gate refused the call itself (`GraineRtcRefusal.codes`: no credit, a
     * monthly cap, the agent off or deleted). The call ends with the server's
     * sentence; the WebSocket would refuse it the same way a second later.
     */
    case refused(code: String, message: String)
    /// The call is over after its media flowed.
    case ended(GraineRtcEnding)
    /// A line for the debug log.
    case log(String)
}

@_spi(GraineRTC) public enum GraineRtcEnding: Equatable {
    /// The agent's side hung up.
    case remote
    /// The media died and could not be brought back.
    case dropped(String)
}

/// The gates' refusals, as the call session's mint names them: these end the call, they never fall back.
@_spi(GraineRTC) public enum GraineRtcRefusal {
    public static let codes: Set<String> = ["insufficient_credits", "parent_out_of_credits", "monthly_cap", "agent_off", "agent_deleted"]
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
}

@_spi(GraineRTC) public extension GraineRtcModule {
    /// A module with nothing to prepare ahead of a call.
    func warmUp(_ request: GraineRtcRequest, log: ((String) -> Void)?) {}
    /// A module without grants: every call takes an id of its own.
    func nextCallId(_ request: GraineRtcRequest) -> String? { nil }
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
 */
enum RtcMintBody {
    static func json(
        publishableKey: String,
        sessionId: String,
        callVariables: [(String, String)],
        variables: [(String, String)],
        identity: IdentityWire.Fields?
    ) -> Data {
        var fields: [(String, WireJSON)] = [
            ("publishableKey", .string(publishableKey)),
            ("session_id", .string(sessionId)),
        ]
        if let metadata = CallWire.ticketVariables(call: callVariables, rest: variables) {
            fields.append(("variables", .object(metadata.map { ($0.0, .string($0.1)) })))
        }
        if let identity = identity { fields += IdentityWire.pairs(identity) }
        return Data(WireJSON.object(fields).text.utf8)
    }
}
