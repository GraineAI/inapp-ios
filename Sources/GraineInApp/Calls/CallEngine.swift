import Foundation

/*
 * THE NATIVE CALL'S CONVERSATION — the voice socket, spoken by the app's own
 * process: the customer's microphone up, the agent's voice down, the agent's
 * actions answered. No web view, so a CallKit call (which gives the microphone
 * to the app's process) and a call with the screen off both just work.
 *
 * Foundation only: the same engine runs under CallKit on a phone and under
 * `swift test` on a Mac, where the live end-to-end test speaks to production
 * through it. Everything platform-specific is behind three seams:
 *
 *   CallAudioIO    the microphone and the speaker (AVAudioEngine on iOS; a fake in tests)
 *   CallNetwork    the ticket request and the WebSocket (URLSession; a fake in tests)
 *   CallScheduler  the clock, the timers and the one queue the engine runs on
 *
 * The wire protocol is sdk/NATIVE-CALLS.md, verified against production.
 *
 * One socket carries the whole call: a close or a failure once it is open
 * ends the call (`dropped`), and nothing reconnects inside it — so this
 * engine never reports `reconnecting`; that moment is WebRTC's alone
 * (CallConversation). The agent's voice level is measured here, from the
 * audio decoded for the speaker (HeardLevels), and reported as it is heard.
 */

/// The microphone and the speaker, for one call.
protocol CallAudioIO: AnyObject {
    /// Start the microphone (and the speaker). `onFrame` gets 20 ms of 16 kHz mono PCM16 little-endian (640 bytes), on any thread.
    func startCapture(_ onFrame: @escaping (Data) -> Void) throws
    /// Queue agent speech. Called before `startCapture` too: hold it until the audio is running.
    func play(_ pcm: [Int16], sampleRate: Int)
    /// Drop everything queued and unplayed — the customer interrupted.
    func clear()
    /// Seconds of agent audio not yet heard; exactly zero once it has all played.
    func bufferedSeconds() -> Double
    /// Release the microphone and the speaker.
    func stop()
    /**
     * The system took the audio back while the call goes on (CallKit's `didDeactivate`): release the microphone and
     * the speaker, but keep the agent's audio not yet heard — from where it stopped — to play when `startCapture`
     * runs again, as audio that arrives before the start is kept.
     */
    func suspend()
}

extension CallAudioIO {
    /// An implementation that keeps nothing across a deactivation releases everything.
    func suspend() { stop() }
}

/// A WebSocket. Every callback may arrive on any thread.
protocol CallSocket: AnyObject {
    func send(_ text: String)
    func close()
}

/// What a socket reports.
struct CallSocketEvents {
    var opened: () -> Void
    var received: (String) -> Void
    /**
     * The socket is gone: `byServer` for a close frame from the other end,
     * false for an error (`detail` says what). `code` is the close frame's
     * code whenever one arrived — an error can follow it — else nil.
     */
    var closed: (_ byServer: Bool, _ detail: String?, _ code: Int?) -> Void
}

/// The network a call needs: one POST and one socket.
protocol CallNetwork: AnyObject {
    /// POST JSON. Completes with the HTTP status (0 for a network error) and the body.
    func post(_ url: URL, body: Data, completion: @escaping (Int, Data?) -> Void)
    /// The same POST, with the answer's headers (names lower-cased) — for `Retry-After`. None by default.
    func postWithHeaders(_ url: URL, body: Data, completion: @escaping (Int, Data?, [String: String]) -> Void)
    /// The same, for a request a slow network may take longer over than a call's (the agent's settings: up to 30 s).
    func postPatiently(_ url: URL, body: Data, completion: @escaping (Int, Data?, [String: String]) -> Void)
    func openSocket(_ url: URL, protocols: [String], events: CallSocketEvents) -> CallSocket
}

extension CallNetwork {
    func postWithHeaders(_ url: URL, body: Data, completion: @escaping (Int, Data?, [String: String]) -> Void) {
        post(url, body: body) { status, data in completion(status, data, [:]) }
    }

    func postPatiently(_ url: URL, body: Data, completion: @escaping (Int, Data?, [String: String]) -> Void) {
        postWithHeaders(url, body: body, completion: completion)
    }
}

/// A timer that can be cancelled.
protocol CallTimer {
    func cancel()
}

extension DispatchWorkItem: CallTimer {}

/// The engine's clock and its one serial context.
protocol CallScheduler: AnyObject {
    /// Seconds on a clock that never jumps.
    var now: Double { get }
    /// Run on the engine's context, after the current work.
    func run(_ block: @escaping () -> Void)
    /// Run on the engine's context after `seconds`.
    func after(_ seconds: Double, _ block: @escaping () -> Void) -> CallTimer
}

/// The production scheduler: a serial queue and the uptime clock.
final class DispatchCallScheduler: CallScheduler {
    let queue: DispatchQueue

    init(queue: DispatchQueue = DispatchQueue(label: "ai.graine.calls.engine", qos: .userInitiated)) {
        self.queue = queue
    }

    var now: Double { ProcessInfo.processInfo.systemUptime }

    func run(_ block: @escaping () -> Void) {
        queue.async(execute: block)
    }

    func after(_ seconds: Double, _ block: @escaping () -> Void) -> CallTimer {
        let item = DispatchWorkItem(block: block)
        queue.asyncAfter(deadline: .now() + max(0, seconds), execute: item)
        return item
    }
}

/// One call's conversation. Create it when a call is answered or placed; it is spent once it ends.
final class CallEngine {
    /// What the engine needs from the SDK, handed in so tests can stand in for it.
    struct Setup {
        var publishableKey: String
        var baseUrl: String
        /// Every variable the agent receives, the call's own first and winning (see `CallEngine.variables`).
        var variables: [(String, String)]
        /// The screen as `currentContextFrame()` builds it, read when the socket opens.
        var contextFrame: () -> [String: Any]?
        /// The agent's configuration (the SDK's cached session). May call back on any thread.
        var session: (@escaping (GraineSessionConfig?) -> Void) -> Void
        /// Runs one app action and answers — the SDK's action runner. May call back on any thread.
        var runAction: (_ name: String, _ arguments: [String: Any], _ answer: @escaping (GraineActionResult) -> Void) -> Void
        /// The call's own variables (`who_called`, `call_reason`, the push's or startCall's), which the ticket keeps before any of the SDK's.
        var callVariables: [(String, String)] = []
        /// Who the customer is for memory, the install, their memory choice, the time zone and the call's id — on the ticket only.
        var identity: IdentityWire.Fields? = nil
        /// The app's and the user's proofs on the ticket and the call session (APP-IDENTITY.md): sealed in, waited for, cured once.
        var security: EmbedProof? = nil
        /// The call's agent's server tokens: the ticket (and a WebRTC mint) carries one when they are in play (CLIENT-TOKENS.md); nil sends none.
        var tokens: ClientTokens? = nil
    }

    /// How a call's conversation ended.
    enum Ending: Equatable {
        /// We hung up.
        case local
        /// The agent's side closed the socket.
        case remote
        /// The socket failed mid-call.
        case dropped(String)
        /// It never opened.
        case couldNotOpen(String)
    }

    enum Transport: String {
        /// Through the embed gateway, on a single-use ticket.
        case gateway
        /// Straight to the conversation host (no ticket could be minted).
        case direct
        /// On WebRTC, through the opt-in module (CallConversation).
        case webrtc
    }

    enum Event {
        case opened(Transport)
        case speaking(Bool)
        /**
         * The call's media path, up before, is being brought back (true) or is
         * back (false). WebRTC's only (CallConversation): this engine's socket
         * is never reconnected inside a call.
         */
        case reconnecting(Bool)
        /// The agent's voice level, 0–1, as it is heard: about ten a second while it plays, 0 once it has played out.
        case level(Double)
        case caption(GraineCaption)
        /// What the agent's audio turned out to be, once known.
        case format(AgentAudioFormat)
        /// An analytics row the call sent (GraineCallTelemetry's frame): its connection report is read from these (CallConnectionFold).
        case row(String)
        /// The audio as received so far, on WebRTC (GraineRtcEvent.audio): the report's audio until the quality row.
        case audio(lossPct: Double?, jitterAvgMs: Double?, jitterMaxMs: Double?, rttAvgMs: Double?)
        /// The WebRTC leg started the call's audio itself before its dial — CallKit had not activated it: this call's audio runs (CallConversation).
        case audioStartedDirectly
        /// The call cannot be heard (the WebRTC leg's playout watch, GraineRtcEvent.playoutFailed): it ends with this.
        case audioFailed(String)
        case ended(Ending)
    }

    private enum Phase {
        case idle
        case preparing
        case open
        case ended
    }

    /**
     * Everything before the socket — the session, the ticket and the open —
     * within this, or the call has failed. One deadline, armed in `start()`:
     * each step's own timeout (15 s for the session, 10 s for the ticket, 15 s
     * for the open) could otherwise add up to most of a minute on "Connecting".
     */
    static let connectDeadlineSeconds = 20.0

    /**
     * What the call's analytics rows (GraineCallTelemetry) need from whoever
     * opened it — the conversation: when the customer tapped or answered, on
     * this engine's clock, and the call's `transport` row (the road, what the
     * app asked for, why it fell back). Without it, no rows.
     */
    struct Telemetry {
        var tapAt: Double
        var transportFrame: String
    }

    private let setup: Setup
    private let audio: CallAudioIO
    private let network: CallNetwork
    private let scheduler: CallScheduler
    private let telemetry: Telemetry?
    private let onEvent: (Event) -> Void

    // Everything below is touched on the scheduler's context only.
    private var phase: Phase = .idle
    private var socket: CallSocket?
    private var connectTimer: CallTimer?
    private var openTimer: CallTimer?
    private var pingTimer: CallTimer?
    private var speakingTimer: CallTimer?
    private var timers: [Int: CallTimer] = [:]
    private var nextTimerId = 0
    private var capturing = false

    private var latched: AgentAudioFormat?
    private var echo = EchoGuard<Data>()
    private var lastAudioAt: Double?
    /// When the agent audio received so far is due to have been heard (AgentSpeech.audible).
    private var audibleUntil: Double?
    private var speaking = false
    /// The agent's voice level as it will be heard — each window of decoded audio, due when it plays.
    private var heard = HeardLevels()
    private var levelTimer: CallTimer?
    /// The level last reported; 0 is reported once when the voice has played out.
    private var levelShown = 0.0
    private var bargedIn = false
    private var muted = false
    /// The spoken turn's words so far, for joining its phrases.
    private var spokenTurn = ""
    /// When each step began, for the analytics rows: the ticket asked for and back (and whether it came), the socket asked for and open.
    private var ticketAskedAt: Double?
    private var ticketAt: Double?
    private var ticketCame = false
    private var connectAt: Double?
    private var openedAt: Double?
    private var voiceRowSent = false
    /// The `ended` row went: once per call.
    private var endedSent = false
    /// How this call's audio was activated, for its `audio` rows: by CallKit (`startAudio()`), started directly, or not yet.
    private var audioVia = "none"
    /// The system took the audio back while the conversation was open, and has not given it back: a direct start now is that deactivation's rescue.
    private var deactivatedOpen = false

    init(setup: Setup, audio: CallAudioIO, network: CallNetwork, scheduler: CallScheduler, telemetry: Telemetry? = nil, onEvent: @escaping (Event) -> Void) {
        self.setup = setup
        self.audio = audio
        self.network = network
        self.scheduler = scheduler
        self.telemetry = telemetry
        self.onEvent = onEvent
    }

    /**
     * Who the agent hears called, for an answered ring (contract §3.4):
     * "scheduled" for a call Graine rang at a booked time (the push says
     * `hosted: "1"`), "agent" for a ring from the app's own server. A call the
     * customer places is "customer". The push's own `who_called` never wins.
     */
    static func whoCalled(hosted: Bool) -> String { hosted ? "scheduled" : "agent" }

    /**
     * Every variable the agent should have, in the order the ticket keeps
     * them (it keeps twelve): `who_called`, `call_reason`, the call's own,
     * then the SDK's (`currentVariables()`). The call's own win over the
     * SDK's; `call_reason` over a variable of that name; `who_called` over all.
     */
    static func variables(
        sdk: [String: String],
        whoCalled: String,
        reason: String?,
        own: [String: String]
    ) -> [(String, String)] {
        var merged = sdk
        for (k, v) in own where !k.isEmpty { merged[k] = v }
        if let reason = reason, !reason.isEmpty { merged["call_reason"] = reason }
        merged["who_called"] = whoCalled
        var seen = Set<String>()
        var out: [(String, String)] = []
        for key in ["who_called", "call_reason"] + own.keys.sorted() + sdk.keys.sorted() {
            guard let value = merged[key], seen.insert(key).inserted else { continue }
            out.append((key, value))
        }
        return out
    }

    /**
     * The SDK's own action runner (the handlers `registerAction` holds), with
     * the native call's deadline: answered inside the runtime's six seconds,
     * and a late handler is "did not finish in time".
     */
    static func actionRunner(
        _ graine: GraineInApp,
        deadlineMs: Int = CallWire.actionAnswerMs
    ) -> (String, [String: Any], @escaping (GraineActionResult) -> Void) -> Void {
        return { [weak graine] name, arguments, answer in
            guard let graine = graine else {
                answer(.error("\"\(name)\" failed: the app is shutting down."))
                return
            }
            graine.executeAction(
                name: name,
                arguments: arguments,
                deadlineMs: deadlineMs,
                timeoutMessage: "\"\(name)\" did not finish in time.",
                answer: answer
            )
        }
    }

    /**
     * WHERE A CALL'S SESSION COMES FROM (`Setup.session`). The session in
     * memory, else the one kept on the device, starts the call at once — and
     * the network refreshes it behind the call. Only with neither does the
     * call wait for the network (0.3–1.2 s on a good day; up to its 15 s
     * timeout on a bad one), the kept session still answering if that fails.
     *
     * A kept session starts a call only when it says where the agent's socket
     * lives (`wsHost`): without it, the direct socket would guess Graine's
     * default host, wrong for an install that runs its own.
     */
    static func sessionLoader(_ graine: GraineInApp) -> (@escaping (GraineSessionConfig?) -> Void) -> Void {
        sessionLoader(
            live: { [weak graine] in graine?.session },
            kept: { [weak graine] in graine?.sessionOrCached },
            refresh: { [weak graine] in graine?.loadSession { _ in } },
            // A push can wake the app before the network is up: the last session still finds the agent.
            load: { [weak graine] done in
                guard let graine = graine else { return done(nil) }
                graine.loadSessionOrCached(done)
            }
        )
    }

    /// `sessionLoader(_:)`'s rule, with its sources handed in.
    static func sessionLoader(
        live: @escaping () -> GraineSessionConfig?,
        kept: @escaping () -> GraineSessionConfig?,
        refresh: @escaping () -> Void,
        load: @escaping (@escaping (GraineSessionConfig?) -> Void) -> Void
    ) -> (@escaping (GraineSessionConfig?) -> Void) -> Void {
        return { done in
            if let session = live() {
                done(session)
                return
            }
            if let session = kept(), let host = session.wsHost, !host.isEmpty {
                done(session)
                // Behind the call: this launch's session, for the next call and every screen.
                refresh()
                return
            }
            load(done)
        }
    }

    // MARK: - Driving it

    /// Mint a ticket and open the socket. The audio starts separately (`startAudio`), when the system hands it over.
    func start() {
        scheduler.run { [self] in
            guard phase == .idle else { return }
            phase = .preparing
            connectTimer = scheduler.after(Self.connectDeadlineSeconds) { [weak self] in
                guard let self = self, self.phase == .preparing else { return }
                self.finish(.couldNotOpen("The call could not connect within \(Int(Self.connectDeadlineSeconds)) seconds."), closeSocket: true)
            }
            setup.session { [weak self] session in
                self?.scheduler.run { self?.sessionArrived(session) }
            }
        }
    }

    /**
     * Start the microphone and the speaker: under CallKit, in
     * `provider(_:didActivate:)`. Without `done`, audio that cannot start ends
     * the call. With it, `done` hears whether the audio runs (on the engine's
     * context) and the call is the caller's to end — the audio watch's direct
     * start, when CallKit never activated the session.
     */
    func startAudio(_ done: ((Bool) -> Void)? = nil) {
        scheduler.run { [self] in
            guard phase == .preparing || phase == .open else {
                done?(false)
                return
            }
            if capturing {
                done?(true)
                return
            }
            do {
                try audio.startCapture { [weak self] frame in
                    self?.scheduler.run { self?.captured(frame) }
                }
                capturing = true
                if done == nil {
                    audioVia = "callkit"
                } else {
                    // Started directly — CallKit never activated it, or took it back mid-call: said on the open socket.
                    sendAudioRow("rescued", reason: deactivatedOpen ? "deactivated" : "no_activation", via: "direct")
                    audioVia = "direct"
                }
                deactivatedOpen = false
                done?(true)
            } catch {
                if let done = done {
                    done(false)
                } else {
                    finish(phase == .open ? .dropped(Self.describe(error)) : .couldNotOpen(Self.describe(error)), closeSocket: true)
                }
            }
        }
    }

    /**
     * The system took the audio back (CallKit's `didDeactivate`): release it,
     * keeping what the agent said that was not heard yet (`suspend`) — a late
     * deactivation on a redial within a second must not cut the greeting.
     * `startAudio` takes it again and plays on from where it stopped. While the
     * conversation is open it is an interruption, not the end — said in an
     * `audio` row; GraineCalls starts the audio again if CallKit does not give
     * it back. Only the call's end drops what was queued (`finish`).
     */
    func stopAudio() {
        scheduler.run { [self] in
            guard capturing else { return }
            capturing = false
            audio.suspend()
            guard phase == .open else { return }
            deactivatedOpen = true
            sendAudioRow("deactivated_live", reason: nil)
        }
    }

    /**
     * The call's `ended` row (GraineCallTelemetry.endedFrame), once, on the
     * socket while it is open — just before a hang-up: who or what ended it,
     * how long the conversation had been open, and whether the agent's voice
     * was heard.
     */
    func sendEnded(cause: String) {
        scheduler.run { [self] in
            guard phase == .open, !endedSent else { return }
            let frame = GraineCallTelemetry.endedFrame(
                cause: cause,
                transport: "ws",
                afterMs: GraineCallTelemetry.milliseconds(from: openedAt, to: scheduler.now),
                voiceHeard: voiceRowSent
            )
            guard let row = frame else { return }
            endedSent = true
            send(row)
        }
    }

    /// Hang up: the stop frame, then the socket ~200 ms later.
    func hangUp() {
        scheduler.run { [self] in
            guard phase != .ended else { return }
            finish(.local, closeSocket: true)
        }
    }

    /// Muted frames are dropped before sending; the microphone keeps running.
    func setMuted(_ value: Bool) {
        scheduler.run { [self] in muted = value }
    }

    /// The screen changed during the call.
    func sendContext(_ frame: [String: Any]) {
        scheduler.run { [self] in
            guard phase == .open, let text = CallWire.appContextFrame(frame) else { return }
            send(text)
        }
    }

    // MARK: - Opening

    private func sessionArrived(_ session: GraineSessionConfig?) {
        guard phase == .preparing else { return }
        guard let session = session, !(session.webcallAgentId.isEmpty && session.agentId.isEmpty) else {
            finish(.couldNotOpen("The agent's configuration could not be loaded."), closeSocket: false)
            return
        }
        let ticketUrl = URL(string: GraineProtocol.trimTrailingSlashes(setup.baseUrl) + "/api/embed/ticket")
        let fields = CallWire.ticketFields(
            publishableKey: setup.publishableKey,
            metadata: CallWire.ticketVariables(call: setup.callVariables, rest: setup.variables),
            identity: setup.identity
        )
        guard let url = ticketUrl else {
            connect(session: session, ticket: nil)
            return
        }
        ticketAskedAt = scheduler.now
        ConversationTicket.ask(url: url, fields: { fields }, security: setup.security, tokens: setup.tokens, network: network) { [weak self] outcome in
            self?.scheduler.run { self?.ticketArrived(session: session, outcome: outcome) }
        }
    }

    private func ticketArrived(session: GraineSessionConfig, outcome: ConversationTicket.Outcome) {
        guard phase == .preparing else { return }
        ticketAt = scheduler.now
        switch outcome {
        case let .ticket(ticket, wsUrl):
            ticketCame = true
            connect(session: session, ticket: (ticket, wsUrl))
        case .direct:
            // Any other non-2xx — 503 is "no gateway here" — or a network error: the direct socket.
            ticketCame = false
            connect(session: session, ticket: nil)
        case .refused(let error):
            // The agent refused this app or this user, or Graine the server token or the key: the call does not open, on either road.
            ticketCame = false
            GraineLog.warning("The call was refused (\(error.code.wire)): \(error.message)")
            finish(.couldNotOpen(ClientTokenRules.callError(error)), closeSocket: false)
        }
    }

    private func connect(session: GraineSessionConfig, ticket: (ticket: String, wsUrl: String)?) {
        let transport: Transport
        var address: String
        var protocols: [String] = []
        if let ticket = ticket {
            address = ticket.wsUrl
            // In the subprotocol, never the query: a query lands in every access log on the way.
            protocols = [CallWire.subprotocol, ticket.ticket]
            transport = .gateway
            // No variables on this URL: the gateway builds the call's context from the ticket's signed
            // claims and reads nothing else, so a token here would only reach the access logs.
        } else {
            address = CallWire.directUrl(wsHost: session.wsHost, agentId: session.webcallAgentId.isEmpty ? session.agentId : session.webcallAgentId)
            transport = .direct
            // The direct socket reads the variables off its URL.
            address = CallWire.withContextToken(address, token: CallWire.contextToken(setup.variables.map { ($0.0, $0.1 as Any?) }))
        }
        guard let url = URL(string: address) else {
            finish(.couldNotOpen("The conversation address is not a URL."), closeSocket: false)
            return
        }
        let events = CallSocketEvents(
            opened: { [weak self] in self?.scheduler.run { self?.socketOpened(transport) } },
            received: { [weak self] text in self?.scheduler.run { self?.received(text) } },
            closed: { [weak self] byServer, detail, _ in self?.scheduler.run { self?.socketClosed(byServer: byServer, detail: detail) } }
        )
        connectAt = scheduler.now
        socket = network.openSocket(url, protocols: protocols, events: events)
        openTimer = scheduler.after(CallWire.socketOpenTimeoutSeconds) { [weak self] in
            guard let self = self, self.phase == .preparing else { return }
            self.finish(.couldNotOpen("The conversation did not open within 15 seconds."), closeSocket: true)
        }
    }

    private func socketOpened(_ transport: Transport) {
        guard phase == .preparing else { return }
        phase = .open
        connectTimer?.cancel()
        connectTimer = nil
        openTimer?.cancel()
        openTimer = nil
        send(CallWire.initFrame(variables: setup.variables))
        // The screen the customer is on: the whole context for the agent's first line.
        if let frame = setup.contextFrame(), let text = CallWire.appContextFrame(frame) { send(text) }
        sendOpenRows()
        schedulePing()
        onEvent(.opened(transport))
    }

    /**
     * The analytics rows once the conversation starts — the contract's
     * "media" on this road: the road it took, then where the tap's wait went.
     * A socket's call is never prepared. Setup is the tap to the socket asked
     * for (a WebRTC attempt that fell back, the ticket), the dial the socket's
     * own opening; the mint is the ticket, when one came back from the web app.
     */
    private func sendOpenRows() {
        guard let telemetry = telemetry else { return }
        let now = scheduler.now
        openedAt = now
        sendRow(telemetry.transportFrame)
        let setup = GraineCallTelemetry.milliseconds(from: telemetry.tapAt, to: connectAt)
        let dial = GraineCallTelemetry.milliseconds(from: connectAt, to: now)
        let row = GraineCallTelemetry.frame("connect", [
            "mode": "cold",
            "warm": false,
            "total_ms": Self.sum(setup, dial) ?? GraineCallTelemetry.milliseconds(from: telemetry.tapAt, to: now),
            "setup_ms": setup,
            "dial_ms": dial,
            "mint_ms": ticketCame ? GraineCallTelemetry.milliseconds(from: ticketAskedAt, to: ticketAt) : nil,
            "mint_route": ticketCame ? "web" : nil,
        ])
        if let row = row { sendRow(row) }
    }

    /// An analytics row: on the socket, and to whoever reads the call's connection report.
    private func sendRow(_ row: String) {
        send(row)
        onEvent(.row(row))
    }

    /// The call's `audio` row (GraineCallTelemetry.audioFrame), on the open socket: the exceptions only — this road plays its own audio.
    private func sendAudioRow(_ event: String, reason: String?, via: String? = nil) {
        guard let telemetry = telemetry, phase == .open else { return }
        let afterMs = GraineCallTelemetry.milliseconds(from: telemetry.tapAt, to: scheduler.now)
        if let row = GraineCallTelemetry.audioFrame(event: event, transport: "ws", via: via ?? audioVia, reason: reason, afterMs: afterMs) { sendRow(row) }
    }

    /// The analytics row for the agent's first audio on the socket — its voice, heard: once.
    private func sendVoiceRow(_ format: AgentAudioFormat) {
        guard let telemetry = telemetry, !voiceRowSent, let opened = openedAt else { return }
        voiceRowSent = true
        let now = scheduler.now
        let row = GraineCallTelemetry.frame("voice", [
            "tap_to_voice_ms": GraineCallTelemetry.milliseconds(from: telemetry.tapAt, to: now),
            "answer_to_voice_ms": GraineCallTelemetry.milliseconds(from: opened, to: now),
            "first_audio_ms": GraineCallTelemetry.milliseconds(from: opened, to: now),
            "codec": format.kind == .mulaw ? "PCMU/\(format.sampleRate)" : "L16/\(format.sampleRate)",
        ])
        if let row = row { sendRow(row) }
    }

    /// Two whole durations added, so a total is exactly its parts; nil unless both are known.
    static func sum(_ a: Int?, _ b: Int?) -> Int? {
        guard let a = a, let b = b else { return nil }
        return a + b
    }

    private func schedulePing() {
        pingTimer = scheduler.after(CallWire.pingSeconds) { [weak self] in
            guard let self = self, self.phase == .open else { return }
            self.send(CallWire.pingFrame)
            self.schedulePing()
        }
    }

    private func socketClosed(byServer: Bool, detail: String?) {
        switch phase {
        case .preparing:
            finish(.couldNotOpen(detail ?? "The conversation could not be opened."), closeSocket: false)
        case .open:
            finish(byServer ? .remote : .dropped(detail ?? "The connection was lost."), closeSocket: false)
        case .idle, .ended:
            break
        }
    }

    // MARK: - What the agent sends

    private func received(_ raw: String) {
        guard phase == .open, let frame = CallInbound.parse(raw) else { return }
        switch frame {
        case let .audio(data, format, rate):
            agentAudio(data: data, format: format, rate: rate)

        case .mark(let name):
            // When the audio queued before it has been heard: the runtime reads the ack as
            // "playback ended" — it clears "agent speaking" and records the welcome as played.
            let delay = MarkAck.delay(bufferedSeconds: audio.bufferedSeconds())
            let ack = CallWire.markFrame(name: name)
            if delay <= 0 {
                send(ack)
            } else {
                schedule(after: delay) { [weak self] in self?.send(ack) }
            }

        case .beginningOfStream, .endOfStream:
            // Never sent on this path today; if they come, they bound a caption turn — speech follows the audio.
            closeSpokenTurn()

        case .clear:
            audio.clear()
            levelsCleared()
            speakingTimer?.cancel()
            speakingTimer = nil
            setSpeaking(false)
            closeSpokenTurn()

        case .text(let raw):
            let chunk = CallWire.readAgentChunk(raw)
            if !chunk.text.isEmpty {
                let words = CallWire.spokenJoinGap(spokenTurn, chunk.text) + chunk.text
                spokenTurn += words
                onEvent(.caption(GraineCaption(role: .agent, text: spokenTurn, live: true)))
            }
            if chunk.endsTurn { closeSpokenTurn() }

        case let .transcript(text, final):
            onEvent(.caption(GraineCaption(role: .customer, text: text, live: !final)))

        case let .appAction(id, name, arguments):
            runAction(id: id, name: name, arguments: arguments)

        case .ignored:
            break
        }
    }

    private func agentAudio(data: String, format: String?, rate: Int?) {
        // Speech follows the audio: true on the first frame, false once it has been heard.
        lastAudioAt = scheduler.now
        setSpeaking(true)
        armSpeakingCheck(after: AgentSpeech.tailSeconds)

        guard let bytes = CallWire.base64Bytes(data),
              let decoded = AgentAudio.decode(bytes, declaredFormat: format, declaredRate: rate, latched: latched) else { return }
        if latched == nil, let latch = decoded.latch {
            latched = latch
            onEvent(.format(latch))
        }
        // It starts to be heard when what the speaker already holds has played. Digital silence is
        // silent whatever it was decoded as (mu-law reads it as a full-scale DC step, which is not heard).
        let startsAt = scheduler.now + audio.bufferedSeconds()
        audio.play(decoded.pcm16, sampleRate: decoded.sampleRate)
        heard.add(decoded.pcm16, sampleRate: decoded.sampleRate, startsAt: startsAt, silent: !bytes.contains { $0 != 0 })
        levelsDue()
        sendVoiceRow(AgentAudioFormat(kind: decoded.kind, sampleRate: decoded.sampleRate))
        audibleUntil = scheduler.now + audio.bufferedSeconds()
    }

    private func armSpeakingCheck(after seconds: Double) {
        speakingTimer?.cancel()
        speakingTimer = scheduler.after(seconds) { [weak self] in
            guard let self = self, self.speaking else { return }
            self.speakingTimer = nil
            if let next = AgentSpeech.recheck(
                now: self.scheduler.now,
                lastAudioAt: self.lastAudioAt ?? -.infinity,
                bufferedSeconds: self.audio.bufferedSeconds()
            ) {
                self.armSpeakingCheck(after: next)
            } else {
                self.setSpeaking(false)
            }
        }
    }

    private func setSpeaking(_ value: Bool) {
        guard speaking != value else { return }
        speaking = value
        // A new agent turn may be barged into once.
        if !value { bargedIn = false }
        onEvent(.speaking(value))
    }

    /**
     * THE VOICE LEVEL, AS IT IS HEARD: every HeardLevels.windowSeconds while
     * any is queued, the level of the window playing now; once the voice has
     * played out, 0, and the ticks stop — a quiet call schedules nothing.
     */
    private func levelsDue() {
        guard levelTimer == nil else { return }
        levelTimer = scheduler.after(0) { [weak self] in self?.levelTick() }
    }

    private func levelTick() {
        levelTimer = nil
        guard phase == .open else { return }
        let due = heard.due(scheduler.now)
        // Silence while silent says nothing new: no report.
        if let level = due, level > 0 || levelShown > 0 {
            reportLevel(level)
        } else if due == nil, heard.isEmpty, levelShown > 0 {
            reportLevel(0)
        }
        if !heard.isEmpty || levelShown > 0 {
            levelTimer = scheduler.after(HeardLevels.windowSeconds) { [weak self] in self?.levelTick() }
        }
    }

    /// What was queued will not be heard (the customer interrupted): its levels go, and the voice is silent now.
    private func levelsCleared() {
        heard.clear()
        if levelShown > 0 { reportLevel(0) }
    }

    private func reportLevel(_ level: Double) {
        levelShown = level
        onEvent(.level(level))
    }

    /// The spoken turn is over: its caption settles and the next phrase starts a new one.
    private func closeSpokenTurn() {
        if !spokenTurn.isEmpty {
            onEvent(.caption(GraineCaption(role: .agent, text: spokenTurn, live: false)))
        }
        spokenTurn = ""
    }

    // MARK: - The agent asks the app to act

    /// Answered within six seconds on every path: the runtime is blocked on it.
    private func runAction(id: String, name: String, arguments: [String: Any]) {
        var answered = false
        let answer: (GraineActionResult) -> Void = { [weak self] result in
            guard let self = self, !answered else { return }
            answered = true
            self.send(CallWire.actionResultFrame(actionId: id, result: result))
        }
        // A backstop on this queue, for a handler that holds the main thread past the runner's own deadline.
        let backstop = schedule(after: Double(CallWire.actionAnswerMs) / 1000 + 0.1) {
            answer(.error("\"\(name)\" did not finish in time."))
        }
        setup.runAction(name, arguments) { [weak self] result in
            self?.scheduler.run {
                self?.cancelTimer(backstop)
                answer(result)
            }
        }
    }

    // MARK: - The customer's microphone

    private func captured(_ frame: Data) {
        guard capturing, phase == .preparing || phase == .open else { return }
        let pcm = AgentAudio.decodePcm16([UInt8](frame))
        let frameMs = Double(pcm.count) / Double(CallWire.captureRate) * 1000
        let audible = AgentSpeech.audible(
            now: scheduler.now, lastAudioAt: lastAudioAt, audibleUntil: audibleUntil,
            bufferedSeconds: audio.bufferedSeconds(), speaking: speaking
        )
        for released in echo.filter(frame, pcm: pcm, agentAudible: audible, frameMs: frameMs) {
            sendMicrophone(released)
        }
    }

    private func sendMicrophone(_ frame: Data) {
        guard phase == .open, !muted else { return }
        // The first frame the guard lets through while the agent is audible interrupts it — once per turn.
        if speaking && !bargedIn {
            bargedIn = true
            send(CallWire.bargeInFrame)
        } else if !speaking {
            bargedIn = false
        }
        send(CallWire.audioFrame(base64: frame.base64EncodedString()))
    }

    // MARK: - Ending

    private func finish(_ ending: Ending, closeSocket: Bool) {
        guard phase != .ended else { return }
        let wasOpen = phase == .open
        phase = .ended
        connectTimer?.cancel()
        openTimer?.cancel()
        pingTimer?.cancel()
        speakingTimer?.cancel()
        levelTimer?.cancel()
        connectTimer = nil
        openTimer = nil
        pingTimer = nil
        speakingTimer = nil
        levelTimer = nil
        heard.clear()
        for timer in timers.values { timer.cancel() }
        timers = [:]
        if closeSocket, let sock = socket {
            if wasOpen && ending == .local {
                // A hangup, not a vanished customer: the stop frame leaves before the socket goes.
                sock.send(CallWire.stopFrame)
                _ = scheduler.after(CallWire.closeGraceSeconds) { sock.close() }
            } else {
                sock.close()
            }
        }
        socket = nil
        if capturing { capturing = false }
        audio.stop()
        if speaking {
            speaking = false
            onEvent(.speaking(false))
        }
        closeSpokenTurn()
        onEvent(.ended(ending))
    }

    // MARK: - Helpers

    private func send(_ text: String) {
        guard phase == .open else { return }
        socket?.send(text)
    }

    /// A timer the end cancels. Returns its id, for `cancelTimer`.
    @discardableResult
    private func schedule(after seconds: Double, _ block: @escaping () -> Void) -> Int {
        nextTimerId += 1
        let id = nextTimerId
        timers[id] = scheduler.after(seconds) { [weak self] in
            guard self?.timers.removeValue(forKey: id) != nil else { return }
            block()
        }
        return id
    }

    private func cancelTimer(_ id: Int) {
        timers.removeValue(forKey: id)?.cancel()
    }

    static func describe(_ error: Error) -> String {
        GraineInApp.describe(error)
    }
}
