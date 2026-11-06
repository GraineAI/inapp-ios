import Foundation

/*
 * THE AGENT'S FACE ON A NATIVE CALL — one call's face, from its frame to the
 * voice it carries. Foundation only: the Mac proves it with a fake viewer.
 *
 *   the frame     `avatar` off the call's app channel (the control channel on
 *                 WebRTC); read by AvatarWire, folded by AvatarFold
 *   the surface   whether an avatar view is on screen (GraineAvatar): a face
 *                 nobody can see is held — never watched, never given the voice
 *   the viewer    made by the WebRTC module on the call's own media
 *                 (GraineRtcCall.makeAvatarViewer): GET /ice, a complete offer,
 *                 POST /offer, the answer; WebRTC only, never another road. No
 *                 module, or a call on the voice socket: the face is
 *                 `unsupported` and the call stays voice-only
 *   the clock     the service's `clock` answered with `played` once heard;
 *                 `interrupted` drops what is pending and silences the face
 *                 while stale audio drains; a ping every 15 s
 *   the voice     the call's copy silenced only while the fold says `live`, and
 *                 given back at once when it does not — the face stalling 2 s,
 *                 failing, going away, the call ending
 *   patience      the first connection is tried again every 2 s for 20 s; a
 *                 connection lost mid-call (`failed`, or `disconnected` 4 s) is
 *                 made again — a fresh peer and offer, the service holding one
 *                 viewer per face and answering 409 meanwhile — for 40 s, the
 *                 stall rule giving the voice back to the call all the while.
 *                 401/403/404/410 are final. Only then is the face `failed`
 *
 * Every method runs on the scheduler's context.
 */
protocol AvatarHTTP: AnyObject {
    /// One request; `done` hears the status (nil: no answer) and the body.
    func request(_ url: URL, method: String, headers: [String: String], body: Data?, timeout: Double,
                 done: @escaping (_ status: Int?, _ body: Data?) -> Void)
}

/// The face's requests: no cookies, no cache, no referrer — the viewer's token is the only credential.
final class URLSessionAvatarHTTP: AvatarHTTP {
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    func request(_ url: URL, method: String, headers: [String: String], body: Data?, timeout: Double,
                 done: @escaping (Int?, Data?) -> Void) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = body
        session.dataTask(with: request) { data, response, _ in
            done((response as? HTTPURLResponse)?.statusCode, data)
        }.resume()
    }
}

final class AvatarFace {
    struct Hooks {
        /// A viewer on the call's media, or nil when this call cannot show a face.
        var makeViewer: () -> GraineAvatarViewer?
        /// The call's agent voice on the meter scale, before any silencing (nil: unknown).
        var agentLevel: () -> Double?
        /// Silence (false) or restore (true) the call's own copy of the agent's voice.
        var setAgentAudible: (Bool) -> Void
        /// What the app is told.
        var onState: (GraineAvatarState) -> Void
        /// The viewer whose view draws the face while it is on screen (playing, live or stalled); nil otherwise.
        var onViewer: (GraineAvatarViewer?) -> Void
        var log: (String) -> Void = { _ in }
    }

    private let scheduler: CallScheduler
    private let http: AvatarHTTP
    private let wallClock: () -> Double
    private let hooks: Hooks

    private(set) var fold = AvatarFoldState(shown: false)
    private var viewer: GraineAvatarViewer?
    /// Bumped whenever the viewer is replaced or let go: work for an older one is dropped.
    private var generation = 0
    private var clock = AvatarClock()
    /// This call cannot show a face (no module, the voice socket): said once, never connected.
    private var unsupported = false
    /// Until when (scheduler seconds) a connection is still tried for; nil once connected.
    private var deadline: Double?
    private var retry: CallTimer?
    private var connected = false
    /// Frames drawn by connections before this one, so the count the fold reads only grows.
    private var framesBase = 0.0
    private var framesLast = 0.0
    private var sampling: CallTimer?
    private var sampleInFlight = false
    private var ping: CallTimer?
    private var disconnectTimer: CallTimer?
    private var acks: [Int: CallTimer] = [:]
    private var nextAck = 0
    /// After an interruption, the face stays silent until then (scheduler seconds) while stale audio drains.
    private var interruptUntil = 0.0
    private var interruptTimer: CallTimer?
    private var agentAudible = true
    private var faceAudible = false
    private var published: GraineAvatarState?
    private var shownViewer: ObjectIdentifier?
    private var finished = false

    init(scheduler: CallScheduler, http: AvatarHTTP = URLSessionAvatarHTTP(),
         wallClock: @escaping () -> Double = { Date().timeIntervalSince1970 }, hooks: Hooks) {
        self.scheduler = scheduler
        self.http = http
        self.wallClock = wallClock
        self.hooks = hooks
    }

    private var nowMs: Double { scheduler.now * 1000 }

    // MARK: - In

    /// A frame off the call's channel (any JSON object); one that is not an avatar frame changes nothing.
    func frame(_ object: Any?) {
        guard !finished, let read = AvatarWire.read(object) else { return }
        if case .ready = read, unsupported {
            publish()
            return
        }
        step(.frame(read, at: nowMs))
    }

    /// Whether an avatar view is on screen to draw the face.
    func surface(_ shown: Bool) {
        guard !finished else { return }
        step(.surface(shown, at: nowMs))
    }

    /// The call is over: its face goes with it.
    func callEnded() {
        guard !finished else { return }
        step(.callEnded(at: nowMs))
        finished = true
        stopConnection()
        stopSampling()
    }

    // MARK: - The fold, applied

    private func step(_ event: AvatarFoldEvent) {
        let before = fold
        fold = AvatarFold.fold(fold, event)
        if before.phase != fold.phase {
            hooks.log("avatar: \(before.phase.rawValue) → \(fold.phase.rawValue)\(fold.reason.map { " (\($0))" } ?? "")")
        }
        apply(previousSession: before.session)
    }

    private func apply(previousSession: GraineAvatarSession?) {
        if AvatarFold.mounted(fold), let session = fold.session {
            if deadline != nil || viewer != nil, previousSession?.id != session.id { stopConnection() }
            if viewer == nil, deadline == nil, fold.phase == .connecting { begin(session, within: AvatarViewerWire.connectSeconds) }
        } else if viewer != nil || deadline != nil {
            stopConnection()
        }
        setAgent(AvatarFold.agentAudible(fold))
        applyFace()
        if !finished, [.connecting, .waiting, .live, .stalled].contains(fold.phase) { startSampling() } else { stopSampling() }
        publish()
    }

    private func setAgent(_ audible: Bool) {
        guard audible != agentAudible else { return }
        agentAudible = audible
        hooks.setAgentAudible(audible)
    }

    private func applyFace() {
        let audible = AvatarFold.faceAudible(fold) && scheduler.now >= interruptUntil
        guard audible != faceAudible else { return }
        faceAudible = audible
        viewer?.setAudible(audible)
    }

    private func publish() {
        let state = unsupported ? GraineAvatarState(phase: .off, reason: "unsupported") : GraineAvatarState(host: AvatarFold.hostState(fold))
        let drawn = AvatarFold.visible(fold) ? viewer : nil
        let id = drawn.map { ObjectIdentifier($0) }
        if id != shownViewer {
            shownViewer = id
            hooks.onViewer(drawn)
        }
        guard state != published else { return }
        published = state
        hooks.onState(state)
    }

    // MARK: - The connection, patiently

    /// Connect to the face, trying again until `within` seconds have passed.
    private func begin(_ session: GraineAvatarSession, within seconds: Double) {
        deadline = scheduler.now + seconds
        attempt(session)
    }

    /// One attempt: a fresh viewer (its own peer), the ICE servers, the complete offer, the answer.
    private func attempt(_ session: GraineAvatarSession) {
        retry = nil
        guard deadline != nil, AvatarFold.mounted(fold) else { return }
        if AvatarViewerWire.expired(session, now: wallClock()) {
            give(up: "the viewer's token had expired")
            return
        }
        guard let made = hooks.makeViewer() else {
            hooks.log("avatar: this call cannot show a face (no WebRTC viewer): voice only")
            unsupported = true
            deadline = nil
            fold = AvatarFoldState(shown: fold.shown)
            setAgent(true)
            publish()
            return
        }
        dropViewer()
        generation += 1
        let gen = generation
        viewer = made
        clock = AvatarClock()
        faceAudible = false
        made.setAudible(false)
        made.onEvent = { [weak self] event in
            self?.scheduler.run {
                guard let self = self, self.generation == gen else { return }
                self.viewerEvent(event, session: session)
            }
        }
        publish()
        guard let iceURL = AvatarViewerWire.iceURL(session), let offerURL = AvatarViewerWire.offerURL(session) else {
            give(up: "the face's address is not usable")
            return
        }
        let auth = ["Authorization": AvatarViewerWire.authorization(session)]
        http.request(iceURL, method: "GET", headers: auth, body: nil, timeout: AvatarViewerWire.requestSeconds) { [weak self] status, body in
            self?.scheduler.run {
                guard let self = self, self.generation == gen, let viewer = self.viewer else { return }
                guard status == 200 else {
                    self.attemptFailed("ice \(status.map(String.init) ?? "no answer")", final: AvatarViewerWire.isFinal(status), session: session)
                    return
                }
                viewer.offer(iceServers: AvatarViewerWire.iceServers(from: body), gatherSeconds: AvatarViewerWire.gatherSeconds) { sdp, error in
                    self.scheduler.run {
                        guard self.generation == gen else { return }
                        guard let sdp = sdp else {
                            self.attemptFailed("offer: \(error ?? "none")", final: false, session: session)
                            return
                        }
                        self.postOffer(sdp, to: offerURL, auth: auth, gen: gen, session: session)
                    }
                }
            }
        }
    }

    private func postOffer(_ sdp: String, to url: URL, auth: [String: String], gen: Int, session: GraineAvatarSession) {
        var headers = auth
        headers["Content-Type"] = "application/json"
        http.request(url, method: "POST", headers: headers, body: AvatarViewerWire.offerBody(sdp: sdp),
                     timeout: AvatarViewerWire.requestSeconds) { [weak self] status, body in
            self?.scheduler.run {
                guard let self = self, self.generation == gen, let viewer = self.viewer else { return }
                // 409: the service still holds the viewer this one replaces — worth another try, as anything not final is.
                guard status == 200, let answer = AvatarViewerWire.answer(from: body) else {
                    self.attemptFailed("offer \(status.map(String.init) ?? "no answer")", final: AvatarViewerWire.isFinal(status), session: session)
                    return
                }
                viewer.applyAnswer(answer) { error in
                    self.scheduler.run {
                        guard self.generation == gen else { return }
                        if let error = error { self.attemptFailed("answer: \(error)", final: false, session: session) }
                    }
                }
            }
        }
    }

    /// An attempt that did not connect: another in 2 s while there is time, else the face has failed.
    private func attemptFailed(_ why: String, final: Bool, session: GraineAvatarSession) {
        hooks.log("avatar: viewer \(why)")
        dropViewer()
        guard !final, let until = deadline, scheduler.now + AvatarViewerWire.retrySeconds < until else {
            give(up: why)
            return
        }
        retry = scheduler.after(AvatarViewerWire.retrySeconds) { [weak self] in self?.attempt(session) }
        publish()
    }

    /// The face could not be shown, and kept not being shown: voice only for the rest of the call.
    private func give(up why: String) {
        hooks.log("avatar: the face could not be shown (\(why)): voice only")
        stopConnection()
        step(.failed(at: nowMs))
    }

    private func viewerEvent(_ event: GraineAvatarViewerEvent, session: GraineAvatarSession) {
        switch event {
        case .channelOpen:
            viewer?.send(AvatarViewerWire.readyMessage)
            schedulePing()
        case .message(let text):
            guard let step = clock.receive(text) else { return }
            switch step {
            case let .ack(samples, epoch, delayMs):
                nextAck += 1
                let id = nextAck
                acks[id] = scheduler.after(delayMs / 1000) { [weak self] in
                    guard let self = self, self.acks.removeValue(forKey: id) != nil else { return }
                    if self.clock.current(epoch), self.connected {
                        self.viewer?.send(AvatarViewerWire.playedMessage(samples: samples, epoch: epoch))
                    }
                }
            case .interrupted(let muteMs):
                for t in acks.values { t.cancel() }
                acks = [:]
                interruptUntil = scheduler.now + muteMs / 1000
                applyFace()
                interruptTimer?.cancel()
                interruptTimer = scheduler.after(muteMs / 1000 + 0.02) { [weak self] in self?.applyFace() }
            case .failed:
                lost("the face reported an error", session: session)
            }
        case .connection(let state):
            switch state {
            case "connected":
                connected = true
                deadline = nil
                disconnectTimer?.cancel()
                disconnectTimer = nil
                // Native video plays as it arrives, and its sound is never refused: connected is playing.
                step(.playing(at: nowMs))
            case "disconnected":
                guard connected, disconnectTimer == nil else { return }
                disconnectTimer = scheduler.after(AvatarViewerWire.disconnectedSeconds) { [weak self] in
                    guard let self = self else { return }
                    self.disconnectTimer = nil
                    self.lost("disconnected", session: session)
                }
            case "failed", "closed":
                if connected { lost(state, session: session) } else { attemptFailed(state, final: false, session: session) }
            default:
                break
            }
        }
    }

    /// A connection that played is lost: made again for up to 40 s. The stall rule gives the voice back meanwhile.
    private func lost(_ why: String, session: GraineAvatarSession) {
        guard AvatarFold.mounted(fold) else { return }
        hooks.log("avatar: the face's connection was lost (\(why)); connecting it again")
        dropViewer()
        if deadline == nil { deadline = scheduler.now + AvatarViewerWire.reconnectSeconds }
        attempt(session)
    }

    /// Let go of the current viewer (its peer, its timers) — never the fold or the deadline.
    private func dropViewer() {
        generation += 1
        for t in acks.values { t.cancel() }
        acks = [:]
        ping?.cancel()
        ping = nil
        disconnectTimer?.cancel()
        disconnectTimer = nil
        interruptTimer?.cancel()
        interruptTimer = nil
        connected = false
        sampleInFlight = false
        framesBase += framesLast
        framesLast = 0
        guard let v = viewer else { return }
        viewer = nil
        v.onEvent = nil
        v.close()
        faceAudible = false
    }

    /// No connection, and none tried.
    private func stopConnection() {
        retry?.cancel()
        retry = nil
        deadline = nil
        dropViewer()
        publish()
    }

    private func schedulePing() {
        ping?.cancel()
        ping = scheduler.after(AvatarViewerWire.pingSeconds) { [weak self] in
            guard let self = self, self.viewer != nil else { return }
            self.viewer?.send(AvatarViewerWire.pingMessage)
            self.schedulePing()
        }
    }

    // MARK: - Samples, four a second

    private func startSampling() {
        guard sampling == nil else { return }
        sampling = scheduler.after(AvatarFold.sampleMs / 1000) { [weak self] in
            guard let self = self else { return }
            self.sampling = nil
            self.takeSample()
            if !self.finished, [.connecting, .waiting, .live, .stalled].contains(self.fold.phase) { self.startSampling() }
        }
    }

    private func stopSampling() {
        sampling?.cancel()
        sampling = nil
    }

    private func takeSample() {
        let agent = hooks.agentLevel() ?? 0
        guard let viewer = viewer, connected else {
            // No connection now: the frames stand still (the stall rule and the first-frame backstop read that).
            step(.sample(at: nowMs, frames: framesBase + framesLast, face: nil, agent: agent))
            return
        }
        guard !sampleInFlight else { return }
        sampleInFlight = true
        let gen = generation
        viewer.sample { [weak self] frames, face, delay, emitted in
            self?.scheduler.run {
                guard let self = self, self.generation == gen else { return }
                self.sampleInFlight = false
                if let d = delay, let n = emitted, let ms = AvatarViewerWire.playoutDelayMs(jitterBufferDelay: d, emittedCount: n) {
                    self.clock.playoutDelayMs = ms
                }
                if let f = frames { self.framesLast = max(self.framesLast, f) }
                self.step(.sample(at: self.nowMs, frames: frames == nil ? nil : self.framesBase + self.framesLast, face: face, agent: agent))
            }
        }
    }
}
