import Foundation

/**
 * THE CHAT'S CONNECTION — a typed conversation with the agent on its own
 * socket, kept up while the customer is in the chat.
 *
 * The React Native SDK's text path, with the three things it lacked: it
 * reconnects after a drop (1, 2, 4, 8, 15, 15 seconds, then offline until the
 * customer sends something or asks to retry), a message typed while it is not
 * connected waits and goes when it is (never shown and silently lost), and an
 * agent turn ends on its end marker, so each reply is its own bubble.
 *
 * Each connect is a new conversation for the agent — a fresh ticket and
 * `init`, the screen and the identity as they are now — while the transcript
 * on screen stays. A server that closes the conversation itself (the agent
 * ended it, the workspace is out of credit, the agent was turned off) is not
 * dialled again on its own: the next message does it, so a refused agent is
 * not hammered and a customer who comes back still gets an answer.
 *
 * Foundation only, behind the calls' seams (CallNetwork, CallScheduler): the
 * same code runs on the main queue in an app and on a hand-moved clock in
 * `swift test`. Every method may be called from any thread; the work runs on
 * the scheduler's context, and so do the events.
 */
final class ChatConnection {
    struct Setup {
        var publishableKey: String
        var baseUrl: String
        /// Every variable the agent receives, read at each connect.
        var variables: () -> [(String, String)]
        /// The identity fields, read at each connect: a change applies to the next conversation.
        var identity: () -> IdentityWire.Fields?
        /// The screen as `currentContextFrame()` builds it, read when the socket opens.
        var contextFrame: () -> [String: Any]?
        /// The agent's configuration (the SDK's cached session). May call back on any thread.
        var session: (@escaping (GraineSessionConfig?) -> Void) -> Void
        /// Runs one app action and answers — the SDK's action runner. May call back on any thread.
        var runAction: (_ name: String, _ arguments: [String: Any], _ answer: @escaping (GraineActionResult) -> Void) -> Void
        var now: () -> Date = Date.init
    }

    typealias Status = GraineChatStatus

    enum Event {
        /// The status, the transcript or the typing indicator changed: read them.
        case changed
        case opened(CallEngine.Transport)
        case widget([String: Any])
        case widgetPending([String: Any])
        /// An agent turn finished (settled), with its words.
        case agentTurnEnded(GraineChatTurn)
        /// The connection went, with why (nil for a close we asked for).
        case closed(String?)
    }

    private enum Phase {
        case idle
        case preparing
        case open
    }

    private let setup: Setup
    private let network: CallNetwork
    private let scheduler: CallScheduler
    private let onEvent: (Event) -> Void

    // Everything below is touched on the scheduler's context only.
    private(set) var status: Status = .idle
    private(set) var transcript = ChatTranscript()
    /// The customer sent a turn and no reply has started yet.
    private(set) var awaitingReply = false
    /// The agent opened a turn (its start marker) and no words have arrived yet.
    private(set) var agentTyping = false
    private(set) var transport: CallEngine.Transport?

    private var phase: Phase = .idle
    private var wanted = false
    /// Why the chat is held down (the app in the background, a native call): it comes back when none is left.
    private var holds = Set<String>()
    private var paused: Bool { !holds.isEmpty }
    private var socket: CallSocket?
    private var generation = 0
    private var attempt = 0
    private var openTimer: CallTimer?
    private var pingTimer: CallTimer?
    private var retryTimer: CallTimer?
    private var replyTimer: CallTimer?
    private var queue: [(id: String, text: String)] = []
    private var timers: [Int: CallTimer] = [:]
    private var nextTimerId = 0

    init(setup: Setup, network: CallNetwork, scheduler: CallScheduler, onEvent: @escaping (Event) -> Void) {
        self.setup = setup
        self.network = network
        self.scheduler = scheduler
        self.onEvent = onEvent
    }

    /// Typing indicator: the agent is working on a reply.
    var typing: Bool { awaitingReply || agentTyping }

    // MARK: - Driving it

    /// The customer is in the chat: connect, and stay connected.
    func open() {
        scheduler.run { [self] in
            wanted = true
            guard !paused else { return }
            if phase == .idle && retryTimer == nil {
                attempt = 0
                connect()
            }
        }
    }

    /// The customer left the chat: hang up, and do not come back on our own. The transcript stays.
    func close() {
        scheduler.run { [self] in
            wanted = false
            teardown(sendStop: true, reason: nil)
            setStatus(.idle)
        }
    }

    /**
     * Held down — the app went to the background, or a native call took the
     * conversation: hang up like `close`, but come back once nothing holds it,
     * if the customer was still in the chat.
     */
    func hold(_ reason: String) {
        scheduler.run { [self] in
            guard holds.insert(reason).inserted else { return }
            teardown(sendStop: true, reason: nil)
            setStatus(.idle)
        }
    }

    func release(_ reason: String) {
        scheduler.run { [self] in
            guard holds.remove(reason) != nil, holds.isEmpty else { return }
            if wanted && phase == .idle {
                attempt = 0
                connect()
            }
        }
    }

    /// Try again now: what could not be sent goes back in the queue, and the connection is made.
    func retry() {
        scheduler.run { [self] in
            for turn in transcript.turns where turn.role == .customer && turn.delivery == .failed {
                transcript.setDelivery(turn.id, .sending)
                queue.append((turn.id, turn.text))
            }
            wanted = true
            retryTimer?.cancel()
            retryTimer = nil
            attempt = 0
            if phase == .idle && !paused { connect() }
            onEvent(.changed)
        }
    }

    /// A customer turn. Shown at once; sent now, or as soon as the chat is connected.
    func send(_ text: String) {
        scheduler.run { [self] in
            let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else { return }
            say(words)
            onEvent(.changed)
        }
    }

    /// The screen changed while the chat is open.
    func sendContext(_ frame: [String: Any]) {
        scheduler.run { [self] in
            guard phase == .open, let text = CallWire.appContextFrame(frame) else { return }
            socket?.send(text)
        }
    }

    /// Something happened the agent may speak up about — only on a live chat: queued, it would open the next one.
    func sendEvent(name: String, detail: String?, data: [String: Any]) {
        scheduler.run { [self] in
            guard phase == .open else { return }
            socket?.send(ChatWire.appEventFrame(name: name, detail: detail, data: data))
        }
    }

    /**
     * The customer answered a component: the structured answer and the
     * sentence, as the web chat sends them — the first is for the record, the
     * second moves the conversation. Offline, the sentence waits like any message.
     */
    func submitWidget(widgetId: String, data: [String: Any], summary: String) {
        scheduler.run { [self] in
            if phase == .open { socket?.send(ChatWire.widgetResultFrame(widgetId: widgetId, data: data)) }
            let words = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !words.isEmpty { say(words) }
            onEvent(.changed)
        }
    }

    /// Forget what was said (a new customer signed in): the screen starts empty.
    func clearTranscript() {
        scheduler.run { [self] in
            transcript.clear()
            queue = []
            onEvent(.changed)
        }
    }

    // MARK: - Opening

    private func connect() {
        guard phase == .idle else { return }
        generation += 1
        let mine = generation
        phase = .preparing
        transport = nil
        setStatus(attempt == 0 ? .connecting : .reconnecting(attempt: attempt))
        setup.session { [weak self] session in
            self?.scheduler.run { self?.sessionArrived(session, mine) }
        }
    }

    private func sessionArrived(_ session: GraineSessionConfig?, _ mine: Int) {
        guard mine == generation, phase == .preparing else { return }
        guard let session = session, !(session.webcallAgentId.isEmpty && session.agentId.isEmpty) else {
            failedToOpen("The agent's configuration could not be loaded.")
            return
        }
        let variables = setup.variables()
        let body = CallWire.ticketRequest(
            publishableKey: setup.publishableKey,
            metadata: CallWire.ticketMetadata(variables.map { ($0.0, $0.1 as Any?) }),
            mode: ChatWire.ticketMode,
            identity: setup.identity()
        )
        guard let url = URL(string: GraineProtocol.trimTrailingSlashes(setup.baseUrl) + "/api/embed/ticket") else {
            openSocket(session: session, ticket: nil, variables: variables, mine: mine)
            return
        }
        network.post(url, body: body) { [weak self] status, data in
            self?.scheduler.run {
                guard let self = self, mine == self.generation, self.phase == .preparing else { return }
                var ticket: (ticket: String, wsUrl: String)?
                // Any non-2xx — a 503 says tickets are not offered here — or a network error: the direct socket.
                if (200...299).contains(status), let body = JSON.object(from: data),
                   let t = JSON.nonEmpty(body["ticket"]), let ws = JSON.nonEmpty(body["wsUrl"]) {
                    ticket = (t, ws)
                }
                self.openSocket(session: session, ticket: ticket, variables: variables, mine: mine)
            }
        }
    }

    private func openSocket(session: GraineSessionConfig, ticket: (ticket: String, wsUrl: String)?, variables: [(String, String)], mine: Int) {
        var address: String
        var protocols: [String] = []
        let via: CallEngine.Transport
        if let ticket = ticket {
            address = ticket.wsUrl
            // In the subprotocol, never the query: a query lands in every access log on the way.
            protocols = [CallWire.subprotocol, ticket.ticket]
            via = .gateway
            // No variables on this URL: the gateway builds the conversation's context from the ticket's
            // signed claims and reads nothing else, so a token here would only reach the access logs.
        } else {
            let agent = session.webcallAgentId.isEmpty ? session.agentId : session.webcallAgentId
            address = CallWire.directUrl(wsHost: session.wsHost, agentId: agent, textChat: true)
            via = .direct
            // The direct socket reads the variables off its URL.
            let token = CallWire.contextToken(variables.map { ($0.0, $0.1 as Any?) }, callType: ChatWire.callType)
            address = CallWire.withContextToken(address, token: token)
        }
        guard let url = URL(string: address) else {
            failedToOpen("The conversation address is not a URL.")
            return
        }
        let events = CallSocketEvents(
            opened: { [weak self] in self?.scheduler.run { self?.socketOpened(via, variables: variables, mine: mine) } },
            received: { [weak self] text in self?.scheduler.run { self?.received(text, mine: mine) } },
            closed: { [weak self] byServer, detail in self?.scheduler.run { self?.socketClosed(byServer: byServer, detail: detail, mine: mine) } }
        )
        socket = network.openSocket(url, protocols: protocols, events: events)
        openTimer = scheduler.after(CallWire.socketOpenTimeoutSeconds) { [weak self] in
            guard let self = self, mine == self.generation, self.phase == .preparing else { return }
            self.failedToOpen("The conversation did not open within 15 seconds.")
        }
    }

    private func socketOpened(_ via: CallEngine.Transport, variables: [(String, String)], mine: Int) {
        guard mine == generation, phase == .preparing else { return }
        phase = .open
        // What a history on this connection replaces: what is settled now, before the waiting messages go.
        transcript.opened()
        openTimer?.cancel()
        openTimer = nil
        attempt = 0
        transport = via
        write(CallWire.initFrame(variables: variables))
        // A screen set before the chat opened is the whole context for the agent's first words.
        if let frame = setup.contextFrame(), let text = CallWire.appContextFrame(frame) { write(text) }
        schedulePing()
        setStatus(.online)
        onEvent(.opened(via))
        flushQueue()
    }

    private func schedulePing() {
        pingTimer = scheduler.after(CallWire.pingSeconds) { [weak self] in
            guard let self = self, self.phase == .open else { return }
            self.write(CallWire.pingFrame)
            self.schedulePing()
        }
    }

    // MARK: - Closing

    private func socketClosed(byServer: Bool, detail: String?, mine: Int) {
        guard mine == generation else { return }
        switch phase {
        case .idle:
            return
        case .preparing:
            failedToOpen(detail ?? "The conversation could not be opened.")
        case .open:
            teardown(sendStop: false, reason: detail ?? "The connection was lost.")
            if byServer {
                // The other side ended this conversation. The next message starts another.
                setStatus(wanted && !paused ? .offline : .idle)
                failQueued()
            } else {
                reconnectOrGiveUp()
            }
        }
    }

    private func failedToOpen(_ why: String) {
        teardown(sendStop: false, reason: why)
        reconnectOrGiveUp()
    }

    private func reconnectOrGiveUp() {
        guard wanted, !paused else {
            setStatus(.idle)
            return
        }
        guard attempt < ChatWire.reconnectDelays.count else {
            attempt = 0
            setStatus(.offline)
            failQueued()
            return
        }
        let delay = ChatWire.reconnectDelays[attempt]
        attempt += 1
        setStatus(.reconnecting(attempt: attempt))
        retryTimer = scheduler.after(delay) { [weak self] in
            guard let self = self else { return }
            self.retryTimer = nil
            guard self.wanted, !self.paused, self.phase == .idle else { return }
            self.connect()
        }
    }

    /// Drop the socket and everything tied to it. The transcript stays; its open turn settles.
    private func teardown(sendStop: Bool, reason: String?) {
        let wasLive = phase != .idle || socket != nil
        generation += 1
        let wasOpen = phase == .open
        phase = .idle
        for timer in [openTimer, pingTimer, retryTimer, replyTimer] { timer?.cancel() }
        openTimer = nil
        pingTimer = nil
        retryTimer = nil
        replyTimer = nil
        for timer in timers.values { timer.cancel() }
        timers = [:]
        if let sock = socket {
            if wasOpen && sendStop {
                // A hangup, not a vanished customer: the stop frame leaves before the socket goes.
                sock.send(CallWire.stopFrame)
                _ = scheduler.after(CallWire.closeGraceSeconds) { sock.close() }
            } else {
                sock.close()
            }
        }
        socket = nil
        transport = nil
        transcript.closeLive()
        awaitingReply = false
        agentTyping = false
        if wasLive { onEvent(.closed(reason)) }
    }

    // MARK: - What the agent sends

    private func received(_ raw: String, mine: Int) {
        guard mine == generation, phase == .open, let frame = ChatInbound.parse(raw) else { return }
        switch frame {
        case .text(let data):
            let chunk = CallWire.readAgentChunk(data)
            if !chunk.text.isEmpty {
                transcript.agentChunk(chunk.text, now: setup.now())
                agentTyping = false
                stopAwaiting()
            } else if chunk.startsTurn {
                agentTyping = true
            }
            if chunk.endsTurn { endAgentTurn() }
            onEvent(.changed)
        case .beginningOfStream:
            agentTyping = true
            onEvent(.changed)
        case .endOfStream:
            endAgentTurn()
            onEvent(.changed)
        case .widget(let widget):
            stopAwaiting()
            onEvent(.changed)
            onEvent(.widget(widget))
        case .widgetPending(let hint):
            onEvent(.widgetPending(hint))
        case let .appAction(id, name, arguments):
            runAction(id: id, name: name, arguments: arguments)
        case .history(let turns):
            // The conversation continues: the earlier turns, before any agent message. Never announced as new ones.
            if transcript.restore(turns) { onEvent(.changed) }
        case .ignored:
            break
        }
    }

    private func endAgentTurn() {
        agentTyping = false
        stopAwaiting()
        if let done = transcript.agentTurnEnded() { onEvent(.agentTurnEnded(done)) }
    }

    /// Answered within six seconds on every path: the runtime is blocked on it.
    private func runAction(id: String, name: String, arguments: [String: Any]) {
        var answered = false
        let mine = generation
        let answer: (GraineActionResult) -> Void = { [weak self] result in
            guard let self = self, !answered else { return }
            answered = true
            guard mine == self.generation else { return }
            self.write(CallWire.actionResultFrame(actionId: id, result: result))
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

    // MARK: - What the customer says

    private func say(_ words: String) {
        if phase == .open {
            _ = transcript.customerSaid(words, delivery: .sent, now: setup.now())
            write(ChatWire.textFrame(words))
            startAwaiting()
            return
        }
        let turn = transcript.customerSaid(words, delivery: .sending, now: setup.now())
        queue.append((turn.id, words))
        if queue.count > ChatWire.queueLimit {
            for dropped in queue.prefix(queue.count - ChatWire.queueLimit) { transcript.setDelivery(dropped.id, .failed) }
            queue.removeFirst(queue.count - ChatWire.queueLimit)
        }
        wanted = true
        guard !paused else { return }
        if retryTimer != nil {
            // The customer is waiting on this message: do not sit out the rest of a backoff.
            retryTimer?.cancel()
            retryTimer = nil
            connect()
        } else if phase == .idle {
            attempt = 0
            connect()
        }
    }

    private func flushQueue() {
        guard phase == .open, !queue.isEmpty else { return }
        let waiting = queue
        queue = []
        for item in waiting {
            write(ChatWire.textFrame(item.text))
            transcript.setDelivery(item.id, .sent)
        }
        startAwaiting()
        onEvent(.changed)
    }

    private func failQueued() {
        guard !queue.isEmpty else { return }
        for item in queue { transcript.setDelivery(item.id, .failed) }
        queue = []
        onEvent(.changed)
    }

    private func startAwaiting() {
        awaitingReply = true
        replyTimer?.cancel()
        replyTimer = scheduler.after(ChatWire.replyWaitSeconds) { [weak self] in
            guard let self = self, self.awaitingReply else { return }
            self.awaitingReply = false
            self.onEvent(.changed)
        }
    }

    private func stopAwaiting() {
        replyTimer?.cancel()
        replyTimer = nil
        awaitingReply = false
    }

    // MARK: - Helpers

    private func setStatus(_ next: Status) {
        guard status != next else { return }
        status = next
        onEvent(.changed)
    }

    /// One frame onto the open socket.
    private func write(_ text: String) {
        guard phase == .open else { return }
        socket?.send(text)
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
