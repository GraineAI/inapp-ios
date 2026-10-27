import Foundation

/*
 * ONE NATIVE CALL'S CONVERSATION, ON WHICHEVER ROAD CARRIES IT.
 *
 * GraineCalls drives this exactly as it drives the voice socket's engine
 * (start, the audio when CallKit hands it over, mute, the screen, hang-up)
 * and hears the same events. Underneath:
 *
 *   the choice      WebRTC when the opt-in module is in the app, the app asked
 *                   for it (`auto` does) and the dashboard has not turned it
 *                   off; the voice socket (CallEngine) otherwise
 *   the fallback    anything that stops WebRTC before the audio flows — the
 *                   mint, the registration, a dial nobody answers, a media path
 *                   that never connects, the 12 s budget — starts the voice
 *                   socket in the same system call: no second ring, the
 *                   customer sees "Connecting…" a moment longer. The reason is
 *                   kept for the call screen and the log
 *   after media     never: a call that dropped has dropped. While WebRTC
 *                   brings a lost media path back, the call is `reconnecting`
 *                   (the voice socket never is: one socket, the whole call)
 *
 * On WebRTC the audio is RTP; captions, the agent's actions and the screen
 * travel the control channel as the voice socket's own frames, and are
 * handled here the same way, so the call screen and the app cannot tell the
 * transports apart. Either road's analytics rows come up as `row` events, for
 * the call's connection report. Foundation only: a Mac proves it with a fake
 * module.
 */
final class CallConversation {
    private let setup: CallEngine.Setup
    private let audio: CallAudioIO
    private let network: CallNetwork
    private let scheduler: CallScheduler
    private let requested: GraineCallTransport
    private let rtcModule: () -> GraineRtcModule?
    /// The leg prepared while the call rang (by its id), when it was minted with what this call carries (its mint body).
    private let takePrepared: (String?, Data) -> GraineRtcCall?
    private let onTransport: (CallTransportReport) -> Void
    private let onEvent: (CallEngine.Event) -> Void
    private let debug: Bool

    private enum Phase {
        case idle
        case choosing
        case rtc
        case socket
        case ended
    }

    // Everything below is touched on the scheduler's context only.
    private var phase = Phase.idle
    private var socketEngine: CallEngine?
    private var rtc: GraineRtcCall?
    private var rtcConnected = false
    private var audioActive = false
    private var muted = false
    /// The audio watch before the INVITE: CallKit's audio, or a direct start, or the call fails.
    private var rtcAudioWatch: CallAudioWatch?
    private var spokenTurn = ""
    private var speaking = false
    private var reconnecting = false
    private var timers: [Int: CallTimer] = [:]
    private var nextTimerId = 0
    /// When the customer tapped (or answered), on the scheduler's clock: the analytics rows count from it.
    private var tapAt: Double?

    init(
        setup: CallEngine.Setup,
        audio: CallAudioIO,
        network: CallNetwork,
        scheduler: CallScheduler,
        transport: GraineCallTransport = .auto,
        debug: Bool = false,
        rtcModule: @escaping () -> GraineRtcModule? = { GraineRtcRegistry.module },
        takePrepared: @escaping (String?, Data) -> GraineRtcCall? = { RingPreparation.shared.take($0, mint: $1) },
        onTransport: @escaping (CallTransportReport) -> Void = { _ in },
        onEvent: @escaping (CallEngine.Event) -> Void
    ) {
        self.setup = setup
        self.audio = audio
        self.network = network
        self.scheduler = scheduler
        self.requested = transport
        self.debug = debug
        self.rtcModule = rtcModule
        self.takePrepared = takePrepared
        self.onTransport = onTransport
        self.onEvent = onEvent
    }

    /// What the module needs to place this call: where to mint, the control host, the mint's body (its id among the rest).
    static func rtcRequest(setup: CallEngine.Setup, session: GraineSessionConfig, debug: Bool) -> GraineRtcRequest {
        let key = setup.publishableKey
        let callVariables = setup.callVariables
        let variables = setup.variables
        let identity = setup.identity
        let security = setup.security
        var request = GraineRtcRequest(
            baseUrl: setup.baseUrl,
            controlHost: controlHost(session),
            mintBody: { sessionId in
                RtcMintBody.json(publishableKey: key, sessionId: sessionId, callVariables: callVariables, variables: variables,
                                 identity: identity, credentials: security)
            },
            sdkVersion: GraineVersion.name,
            debug: debug,
            // The mint carries the agent's server token; checked only here, never once the call is up.
            clientTokens: setup.tokens.map { GraineRtcTokens($0) }
        )
        request.guarded(by: security, identityValue: identity?.value)
        return request
    }

    /// The control channel's host: the agent's socket host, without a trailing slash.
    static func controlHost(_ session: GraineSessionConfig) -> String {
        var host = session.wsHost.flatMap { $0.isEmpty ? nil : $0 } ?? CallWire.defaultWsHost
        while host.hasSuffix("/") { host.removeLast() }
        return host
    }

    // MARK: - Driving it (CallEngine's surface)

    /// Choose the road, and start on it. The audio starts separately, when the system hands it over.
    func start() {
        scheduler.run { [self] in
            guard phase == .idle else { return }
            phase = .choosing
            tapAt = scheduler.now
            setup.session { [weak self] session in
                self?.scheduler.run { self?.chose(session) }
            }
        }
    }

    /**
     * The audio is the call's: without `done`, CallKit activated it; with it,
     * this is the direct start the audio watch makes when CallKit never did,
     * and `done` hears whether the audio runs.
     */
    func startAudio(_ done: ((Bool) -> Void)? = nil) {
        scheduler.run { [self] in
            switch phase {
            case .ended:
                done?(false)
            case .idle, .choosing:
                if done == nil { audioActive = true }
                done?(true)
            case .socket:
                if done == nil { audioActive = true }
                socketEngine?.startAudio(done)
            case .rtc:
                guard let call = rtc else { return done?(false) ?? () }
                if let done = done {
                    call.startAudioDirectly { [weak self] started in
                        self?.scheduler.run {
                            if started { self?.audioActive = true }
                            done(started)
                        }
                    }
                } else {
                    audioActive = true
                    call.audioActivated()
                    rtcAudioWatch?.audioStarted()
                }
            }
        }
    }

    /// The system took the audio back (CallKit's `didDeactivate`).
    func stopAudio() {
        scheduler.run { [self] in
            audioActive = false
            switch phase {
            case .socket: socketEngine?.stopAudio()
            case .rtc: rtc?.audioDeactivated()
            default: break
            }
        }
    }

    /**
     * Who or what ended the call — its `ended` row, on the channel that is
     * still up (the voice socket, or WebRTC's control channel), just before a
     * hang-up. Nothing once the call is over: a channel already closed carries
     * nothing.
     */
    func sendEnded(_ cause: GraineCallEndCause) {
        scheduler.run { [self] in
            switch phase {
            case .socket: socketEngine?.sendEnded(cause: cause.rawValue)
            case .rtc: rtc?.sendEnded(cause: cause.rawValue)
            default: break
            }
        }
    }

    func hangUp() {
        scheduler.run { [self] in
            switch phase {
            case .ended:
                return
            case .socket:
                phase = .ended
                // The socket's engine says `.ended(.local)` itself.
                socketEngine?.hangUp()
            default:
                finish(.local)
            }
        }
    }

    func setMuted(_ value: Bool) {
        scheduler.run { [self] in
            muted = value
            socketEngine?.setMuted(value)
            rtc?.setMuted(value)
        }
    }

    /// The screen changed during the call.
    func sendContext(_ frame: [String: Any]) {
        scheduler.run { [self] in
            switch phase {
            case .socket:
                socketEngine?.sendContext(frame)
            case .rtc:
                if let text = CallWire.appContextFrame(frame) { rtc?.sendControl(text, kind: "app_context") }
            default:
                break
            }
        }
    }

    // MARK: - The choice

    private func chose(_ session: GraineSessionConfig?) {
        guard phase == .choosing else { return }
        let module = rtcModule().flatMap { $0.isSupported ? $0 : nil }
        let choice = CallTransportChoice.decide(requested: requested, dashboard: session?.calls?.audioTransport, rtcAvailable: module != nil)
        if requested == .webrtc, module == nil {
            GraineLog.warning("callTransport is .webrtc, but the GraineInAppRTC module is not in this app; the call runs on the WebSocket.")
        }
        guard choice == .webrtc, let module = module, let session = session,
              !(session.webcallAgentId.isEmpty && session.agentId.isEmpty) else {
            startSocket(CallTransportReport(transport: .websocket), skipped: Self.skippedReason(requested: requested, session: session, rtcAvailable: module != nil))
            return
        }
        startRtc(module, session: session)
    }

    /**
     * Why a call the app wanted on WebRTC (`auto` or `webrtc`) starts on the
     * WebSocket without trying it — for its transport row only; the call
     * screen shows no fallback for it. The dashboard's switch is Standard, or
     * this build or device cannot run WebRTC. Asked for the WebSocket: no
     * reason, nothing fell back.
     */
    static func skippedReason(requested: GraineCallTransport, session: GraineSessionConfig?, rtcAvailable: Bool) -> String? {
        guard requested != .websocket else { return nil }
        if session?.calls?.audioTransport == .websocket { return "dashboard" }
        return rtcAvailable ? nil : "unavailable"
    }

    private func startSocket(_ report: CallTransportReport, skipped: String? = nil) {
        phase = .socket
        // Its analytics rows count from the tap, a WebRTC attempt's included, and say why it is not WebRTC, if it could have been.
        let telemetry = CallEngine.Telemetry(
            tapAt: tapAt ?? scheduler.now,
            transportFrame: GraineCallTelemetry.transportFrame(carried: .websocket, requested: requested, fallbackReason: report.reason ?? skipped)
        )
        let engine = CallEngine(setup: setup, audio: audio, network: network, scheduler: scheduler, telemetry: telemetry) { [weak self] event in
            self?.socketEvent(event)
        }
        socketEngine = engine
        onTransport(report)
        engine.setMuted(muted)
        engine.start()
        if audioActive { engine.startAudio() }
    }

    private func socketEvent(_ event: CallEngine.Event) {
        guard phase == .socket || phase == .ended else { return }
        if case .ended = event { phase = .ended }
        onEvent(event)
    }

    // MARK: - WebRTC

    private func startRtc(_ module: GraineRtcModule, session: GraineSessionConfig) {
        phase = .rtc
        let request = Self.rtcRequest(setup: setup, session: session, debug: debug)
        // Prepared while it rang with exactly what this call carries; otherwise (the customer became known meanwhile) minted again.
        let prepared = takePrepared(setup.identity?.callId, request.mintBody(""))
        let call = prepared ?? module.makeCall(request)
        // Its analytics rows: how it was made — ahead of the tap (prepareCall, or as it rang), or at it — and
        // the transport row it sends at media, which only this side can write (what the app asked for).
        if prepared != nil { call.preparedAhead = true }
        call.transportRow = GraineCallTelemetry.transportFrame(carried: .webrtc, requested: requested, fallbackReason: nil)
        rtc = call
        call.onEvent = { [weak self, weak call] event in
            self?.scheduler.run {
                guard let self = self, let call = call, self.rtc === call, self.phase == .rtc else { return }
                self.rtcEvent(event)
            }
        }
        if prepared == nil { call.prepare() }
        call.setMuted(muted)
        // The screen the customer is on, for the agent's first line: queued until the channel joins.
        if let frame = setup.contextFrame(), let text = CallWire.appContextFrame(frame) { call.sendControl(text, kind: "app_context") }
        call.begin()
        if audioActive { call.audioActivated() }
        if debug { GraineLog.trace("call: trying WebRTC\(prepared == nil ? "" : " (prepared while it rang)")") }
    }

    private func rtcEvent(_ event: GraineRtcEvent) {
        switch event {
        case .ready:
            // Everything but the INVITE is done; without the audio it waits — not for ever.
            guard !audioActive, rtcAudioWatch == nil else { return }
            let watch = CallAudioWatch(schedule: { [weak self] seconds, fire in
                guard let self = self else { return {} }
                let id = self.schedule(after: seconds, fire)
                return { [weak self] in self?.cancelTimer(id) }
            }, act: { [weak self] step in self?.rtcAudioStep(step) })
            rtcAudioWatch = watch
            watch.opened(audioRunning: false)

        case .connected:
            rtcConnected = true
            rtcAudioWatch?.cancel()
            onTransport(CallTransportReport(transport: .webrtc))
            onEvent(.opened(.webrtc))

        case .speaking(let value):
            setSpeaking(value)

        case .reconnecting(let value):
            // Only after media: a path that never connected falls back to the socket instead.
            guard rtcConnected else { return }
            setReconnecting(value)

        case .level(let value):
            guard rtcConnected else { return }
            onEvent(.level(value))

        case .row(let frame):
            // The leg's analytics rows — a media row before a fallback included: the socket's own rows replace it.
            onEvent(.row(frame))

        case let .audio(loss, jitterAvg, jitterMax, rtt):
            guard rtcConnected else { return }
            onEvent(.audio(lossPct: loss, jitterAvgMs: jitterAvg, jitterMaxMs: jitterMax, rttAvgMs: rtt))

        case .control(let text):
            control(text)

        case let .unreachable(reason, detail):
            rtcAudioWatch?.cancel()
            rtcAudioWatch = nil
            let call = rtc
            rtc = nil
            call?.onEvent = nil
            call?.hangUp()
            closeSpokenTurn()
            if rtcConnected {
                // Never after media: a live call is not moved.
                return finish(.dropped(detail))
            }
            GraineLog.warning("The call could not be carried on WebRTC (\(reason.rawValue)): \(detail). It continues on the WebSocket.")
            startSocket(CallTransportReport(transport: .websocket, requested: .webrtc, reason: reason.rawValue))

        case let .refused(code, message):
            // The same failure, with the same words, the voice socket's close would bring a second later. Refused for the
            // server token or the key without a sentence: the SDK's own, after the code.
            let words = message.isEmpty && ClientTokenRules.refusalCodes.contains(code) ? ClientTokenRules.sentence(code) : message
            GraineLog.warning("The call was refused (\(code)): \(words)")
            finish(.couldNotOpen(words.isEmpty ? code : "\(code): \(words)"))

        case .ended(let ending):
            switch ending {
            case .remote:
                finish(rtcConnected ? .remote : .couldNotOpen("The call ended before it connected."))
            case .dropped(let detail):
                finish(rtcConnected ? .dropped(detail) : .couldNotOpen(detail))
            }

        case .playoutFailed(let detail):
            // Audio arrives and none of it reaches the speaker, even started again: nobody can hear this call. GraineCalls
            // ends it as its audio watch ends one — the cause `audio_watch`, said on the channel before the hang-up.
            guard rtcConnected else { return }
            GraineLog.warning("Calls: \(CallAudioWatch.failure) \(detail): the call ends (audio_watch).")
            onEvent(.audioFailed(CallAudioWatch.failure))

        case .log(let line):
            GraineLog.trace(line)
        }
    }

    /// What the audio watch decided before the INVITE (Calls/CallAudioWatch.swift).
    private func rtcAudioStep(_ step: CallAudioWatch.Step) {
        guard phase == .rtc, let call = rtc else { return }
        switch step {
        case .connect:
            break
        case .retry:
            GraineLog.warning("Calls: CallKit has not activated the call's audio \(Int(CallAudioWatch.graceSeconds)) s after the call could start; activating it directly.")
            call.startAudioDirectly { [weak self] started in
                self?.scheduler.run {
                    guard let self = self, self.rtc === call else { return }
                    if started {
                        GraineLog.info("Calls: the call's audio started directly (WebRTC): the call is dialled.")
                        self.audioActive = true
                        self.rtcAudioWatch?.audioStarted()
                        // This call's audio runs, though CallKit never said so: the call is connected once its media is up.
                        self.onEvent(.audioStartedDirectly)
                    } else {
                        GraineLog.warning("Calls: the call's audio could not be started directly (WebRTC) — the audio session's error is in the log above.")
                        self.rtcAudioWatch?.retryFailed()
                    }
                }
            }
        case .fail:
            GraineLog.warning("Calls: \(CallAudioWatch.failure) CallKit never activated it and the direct start did not run: the call ends (audio_watch).")
            finish(.couldNotOpen(CallAudioWatch.failure))
        }
    }

    // MARK: - The control channel's frames: the voice socket's own, handled as CallEngine handles them

    private func control(_ text: String) {
        guard let object = JSON.object(from: text), let type = object["type"] as? String else { return }
        switch type {
        case "text":
            let chunk = CallWire.readAgentChunk(JSON.text(object["data"]) ?? "")
            if !chunk.text.isEmpty {
                spokenTurn += CallWire.spokenJoinGap(spokenTurn, chunk.text) + chunk.text
                onEvent(.caption(GraineCaption(role: .agent, text: spokenTurn, live: true)))
            }
            if chunk.endsTurn { closeSpokenTurn() }
        case "transcript", "interim_transcript_received":
            // The control channel's captions carry `content`; the voice socket's carry `data`.
            let data = object["data"] as? [String: Any]
            let words = JSON.text(object["content"]) ?? data.flatMap { JSON.text($0["content"]) } ?? JSON.text(object["data"]) ?? ""
            onEvent(.caption(GraineCaption(role: .customer, text: words, live: type != "transcript")))
        case "end_of_stream", "beginning_of_stream", "clear", "interruption":
            closeSpokenTurn()
        case "app_action":
            if case let .appAction(id, name, arguments)? = CallInbound.parse(text) {
                runAction(id: id, name: name, arguments: arguments)
            }
        default:
            // Components (`widget`, `widget_pending`) are drawn by neither engine; the rest is the channel's own.
            break
        }
    }

    /// Answered within six seconds on every path: the agent is waiting on it.
    private func runAction(id: String, name: String, arguments: [String: Any]) {
        var answered = false
        let answer: (GraineActionResult) -> Void = { [weak self] result in
            guard let self = self, !answered else { return }
            answered = true
            self.rtc?.sendControl(CallWire.actionResultFrame(actionId: id, result: result), kind: nil)
        }
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

    private func setSpeaking(_ value: Bool) {
        guard speaking != value else { return }
        speaking = value
        onEvent(.speaking(value))
    }

    private func setReconnecting(_ value: Bool) {
        guard reconnecting != value else { return }
        reconnecting = value
        onEvent(.reconnecting(value))
    }

    private func closeSpokenTurn() {
        if !spokenTurn.isEmpty {
            onEvent(.caption(GraineCaption(role: .agent, text: spokenTurn, live: false)))
        }
        spokenTurn = ""
    }

    // MARK: - Ending

    private func finish(_ ending: CallEngine.Ending) {
        guard phase != .ended else { return }
        phase = .ended
        rtcAudioWatch?.cancel()
        rtcAudioWatch = nil
        for timer in timers.values { timer.cancel() }
        timers = [:]
        if let call = rtc {
            rtc = nil
            call.onEvent = nil
            call.hangUp()
        }
        setSpeaking(false)
        // A call that ends while reconnecting is reconnecting no more: said before its end.
        setReconnecting(false)
        closeSpokenTurn()
        onEvent(.ended(ending))
    }

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
}
