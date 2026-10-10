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
    /// The socket is gone: `byServer` for a close frame from the other end, false for an error (`detail` says what).
    var closed: (_ byServer: Bool, _ detail: String?) -> Void
}

/// The network a call needs: one POST and one socket.
protocol CallNetwork: AnyObject {
    /// POST JSON. Completes with the HTTP status (0 for a network error) and the body.
    func post(_ url: URL, body: Data, completion: @escaping (Int, Data?) -> Void)
    func openSocket(_ url: URL, protocols: [String], events: CallSocketEvents) -> CallSocket
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
    }

    enum Event {
        case opened(Transport)
        case speaking(Bool)
        case caption(GraineCaption)
        /// What the agent's audio turned out to be, once known.
        case format(AgentAudioFormat)
        case ended(Ending)
    }

    private enum Phase {
        case idle
        case preparing
        case open
        case ended
    }

    private let setup: Setup
    private let audio: CallAudioIO
    private let network: CallNetwork
    private let scheduler: CallScheduler
    private let onEvent: (Event) -> Void

    // Everything below is touched on the scheduler's context only.
    private var phase: Phase = .idle
    private var socket: CallSocket?
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
    private var bargedIn = false
    private var muted = false
    /// The spoken turn's words so far, for joining its phrases.
    private var spokenTurn = ""

    init(setup: Setup, audio: CallAudioIO, network: CallNetwork, scheduler: CallScheduler, onEvent: @escaping (Event) -> Void) {
        self.setup = setup
        self.audio = audio
        self.network = network
        self.scheduler = scheduler
        self.onEvent = onEvent
    }

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

    // MARK: - Driving it

    /// Mint a ticket and open the socket. The audio starts separately (`startAudio`), when the system hands it over.
    func start() {
        scheduler.run { [self] in
            guard phase == .idle else { return }
            phase = .preparing
            setup.session { [weak self] session in
                self?.scheduler.run { self?.sessionArrived(session) }
            }
        }
    }

    /// Start the microphone and the speaker: under CallKit, in `provider(_:didActivate:)`.
    func startAudio() {
        scheduler.run { [self] in
            guard phase == .preparing || phase == .open, !capturing else { return }
            do {
                try audio.startCapture { [weak self] frame in
                    self?.scheduler.run { self?.captured(frame) }
                }
                capturing = true
            } catch {
                finish(phase == .open ? .dropped(Self.describe(error)) : .couldNotOpen(Self.describe(error)), closeSocket: true)
            }
        }
    }

    /// The system took the audio back (CallKit's `didDeactivate`): release it. `startAudio` takes it again.
    func stopAudio() {
        scheduler.run { [self] in
            guard capturing else { return }
            capturing = false
            audio.stop()
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
        let body = CallWire.ticketRequest(
            publishableKey: setup.publishableKey,
            metadata: CallWire.ticketMetadata(setup.variables.map { ($0.0, $0.1 as Any?) })
        )
        guard let url = ticketUrl else {
            connect(session: session, ticket: nil)
            return
        }
        network.post(url, body: body) { [weak self] status, data in
            self?.scheduler.run { self?.ticketArrived(session: session, status: status, data: data) }
        }
    }

    private func ticketArrived(session: GraineSessionConfig, status: Int, data: Data?) {
        guard phase == .preparing else { return }
        // Any non-2xx — 503 is "no gateway here" — or a network error: the direct socket.
        var ticket: (ticket: String, wsUrl: String)?
        if (200...299).contains(status), let body = JSON.object(from: data),
           let t = JSON.nonEmpty(body["ticket"]), let ws = JSON.nonEmpty(body["wsUrl"]) {
            ticket = (t, ws)
        }
        connect(session: session, ticket: ticket)
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
        } else {
            address = CallWire.directUrl(wsHost: session.wsHost, agentId: session.webcallAgentId.isEmpty ? session.agentId : session.webcallAgentId)
            transport = .direct
        }
        address = CallWire.withContextToken(address, token: CallWire.contextToken(setup.variables.map { ($0.0, $0.1 as Any?) }))
        guard let url = URL(string: address) else {
            finish(.couldNotOpen("The conversation address is not a URL."), closeSocket: false)
            return
        }
        let events = CallSocketEvents(
            opened: { [weak self] in self?.scheduler.run { self?.socketOpened(transport) } },
            received: { [weak self] text in self?.scheduler.run { self?.received(text) } },
            closed: { [weak self] byServer, detail in self?.scheduler.run { self?.socketClosed(byServer: byServer, detail: detail) } }
        )
        socket = network.openSocket(url, protocols: protocols, events: events)
        openTimer = scheduler.after(CallWire.socketOpenTimeoutSeconds) { [weak self] in
            guard let self = self, self.phase == .preparing else { return }
            self.finish(.couldNotOpen("The conversation did not open within 15 seconds."), closeSocket: true)
        }
    }

    private func socketOpened(_ transport: Transport) {
        guard phase == .preparing else { return }
        phase = .open
        openTimer?.cancel()
        openTimer = nil
        send(CallWire.initFrame(variables: setup.variables))
        // The screen the customer is on: the whole context for the agent's first line.
        if let frame = setup.contextFrame(), let text = CallWire.appContextFrame(frame) { send(text) }
        schedulePing()
        onEvent(.opened(transport))
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
        audio.play(decoded.pcm16, sampleRate: decoded.sampleRate)
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
        openTimer?.cancel()
        pingTimer?.cancel()
        speakingTimer?.cancel()
        openTimer = nil
        pingTimer = nil
        speakingTimer = nil
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
