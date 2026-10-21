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
 * ended it, the workspace is out of credit, the agent was turned off, or
 * Graine let it go — idle, 4408, or at the session's time limit, 4410, when
 * the header says "Disconnected") is not dialled again on its own: the next
 * message does it, so a refused agent is not hammered and a customer who comes
 * back still gets an answer.
 *
 * HOW LONG A CONVERSATION LASTS (DESIGN.md): closing the chat window does not
 * end it at once. With no window showing it (`shown(false)`), the chat stays
 * connected — a window back in time continues the same conversation, nothing
 * on screen changes — for the close delay (15 seconds unless the app sets
 * another, 0–300) after the later of the moment the last window left and the
 * last message either way; then it hangs up, as `close` does. (It was five
 * minutes of quiet in 0.14.0–0.14.1.)
 *
 * WHO A CHAT BELONGS TO (DESIGN.md): a connection belongs to whoever was
 * identified when its ticket was asked for — nobody, before `identify()`.
 * Another identity while it is connected or connecting, and it is made again
 * for that one (`identityChanged`).
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
        /// The customer rated the conversation the agent ended (taken once: one answer per conversation).
        case rated(GraineChatRating)
        /// The connection went, with why (nil for a close we asked for).
        case closed(String?)
        /// No window showed the chat for the close delay, and nothing was said either way meanwhile: it hung up, as `close` does.
        case letGo
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
    /**
     * The replies the agent suggests for its latest turn (a `quick_replies`
     * frame). Gone once the customer sends anything, the agent starts another
     * turn, an earlier conversation is restored, or the conversation ends —
     * protocol.ts `foldChat`, pinned by chat-window.json → `fold`.
     */
    private(set) var quickReplies: [GraineQuickReply] = []
    /// The agent ended the conversation (`conversation_end`): the window may ask for a rating. The customer speaking again starts over.
    private(set) var ended = false
    /// The customer's answer to that rating: one per conversation, only after the end.
    private(set) var rating: GraineChatRating?
    /// The socket opened at least once since the customer came into the chat: a drop now is a reconnect, not a first connect.
    private(set) var wasOnline = false
    /**
     * Graine ended the conversation itself — idle (4408) or at the session's
     * time limit (4410): it is not dialled again on its own, and the header
     * says "Disconnected" until the chat connects again.
     */
    private(set) var disconnected = false

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
    /// No window shows the chat: it is let go once the close delay has passed since it left the last one, and since the last message.
    private var unseen = false
    /// When the last window left — the scheduler's clock.
    private var unseenSince = 0.0
    /// When something was last said either way, or the customer came into the chat — the scheduler's clock.
    private var lastActivity = 0.0
    /// How long a chat no window shows is kept, in seconds: 0 (it closes as the last window leaves) to 300.
    private var closeDelay: Double
    private var idleTimer: CallTimer?
    /// Who the connection up (or being made) was asked for: the identity value its ticket was asked with (nil: nobody).
    private var owner: String?
    /// A ticket was asked for at least once, so `owner` says whose the connection is.
    private var ownerKnown = false

    init(
        setup: Setup,
        network: CallNetwork,
        scheduler: CallScheduler,
        closeDelaySeconds: Int = ChatWire.closeDelaySeconds,
        onEvent: @escaping (Event) -> Void
    ) {
        self.setup = setup
        self.network = network
        self.scheduler = scheduler
        self.closeDelay = Double(ChatWire.closeDelay(closeDelaySeconds))
        self.onEvent = onEvent
    }

    /// Typing indicator: the agent is working on a reply.
    var typing: Bool { awaitingReply || agentTyping }

    /// The id of the chat's current session: this connection's, from the server's session frame; nil until it arrives.
    var sessionId: String? { transcript.session }

    // MARK: - Driving it

    /// The customer is in the chat: connect, and stay connected.
    func open() {
        scheduler.run { [self] in
            wanted = true
            noteActivity()
            guard !paused else { return }
            if phase == .idle && retryTimer == nil {
                attempt = 0
                connect()
            }
        }
    }

    /// The customer left the chat: hang up, and do not come back on our own. The transcript stays.
    func close() {
        scheduler.run { [self] in hangUp() }
    }

    /**
     * Whether a chat window shows the chat. Unseen, the conversation stays up
     * — a window back in time continues it — for the close delay after the
     * later of the moment it left the last window and the last message either
     * way; then it hangs up as `close` does, and `letGo` says so. A window
     * showing it again calls the close off.
     */
    func shown(_ visible: Bool) {
        scheduler.run { [self] in
            if !visible && !unseen { unseenSince = scheduler.now }
            unseen = !visible
            watchIdle()
        }
    }

    /**
     * The close delay, in seconds (clamped to 0–300). A close already waiting
     * waits again with it: from the same moments, the new length — at once
     * when that is already past.
     */
    func setCloseDelay(_ seconds: Int) {
        scheduler.run { [self] in
            closeDelay = Double(ChatWire.closeDelay(seconds))
            if unseen && wanted { watchIdle() }
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
                // Held past its close delay with no window showing it (the app away a while): let go, not dialled again.
                if unseen && scheduler.now - max(unseenSince, lastActivity) >= closeDelay {
                    letGo()
                    return
                }
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
            noteActivity()
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
            noteActivity()
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
            noteActivity()
            onEvent(.changed)
        }
    }

    /**
     * WHO A CHAT BELONGS TO (DESIGN.md): the identity is now `current`. The
     * chat's lines are whoever its last ticket was for; when that is someone
     * else — nobody → a customer, a customer → another, a customer → nobody:
     *
     *   1. a connection up or being made is closed normally (no
     *      "Disconnected", no reconnect banner);
     *   2. the turns go, with what a history restored and the marker rows;
     *   3. the customer's lines that have not gone out — still sending, or
     *      failed — stay, and go on the next connection;
     *   4. a chat that was connected or connecting, while the customer is in
     *      it (a window shows it, the app opened it, or they wrote), connects
     *      again at once with a ticket for `current`; one that was not, or
     *      nobody is in, connects at the next open or message — never
     *      "Disconnected", never offline.
     *
     * The same identity changes nothing (other traits and the memory choice
     * apply from the next connection), and neither does anything before the
     * chat's first ticket: it holds nobody's lines but those still to send.
     */
    func identityChanged(to current: String?) {
        scheduler.run { [self] in
            guard ownerKnown, owner != current else { return }
            belongsToAnother(current)
        }
    }

    /// Forget what was said (a new customer signed in): the screen starts empty.
    func clearTranscript() {
        scheduler.run { [self] in
            transcript.clear()
            queue = []
            freshConversation()
            onEvent(.changed)
        }
    }

    /**
     * Empty the screen only (the app's `GraineChat.clear()`): the turns and the
     * typing indicator go; the connection, and the messages still waiting for
     * it, stay — those are sent when it is up, off the screen.
     */
    func clearScreen() {
        scheduler.run { [self] in
            transcript.clear()
            stopAwaiting()
            agentTyping = false
            freshConversation()
            onEvent(.changed)
        }
    }

    /**
     * The customer's end-of-chat rating. Taken once, and only for a
     * conversation the agent ended: then it goes on the conversation as a
     * quiet app event (recorded, never a nudge) while the socket is still open
     * — the server keeps it a short while for this — and the app hears it.
     */
    func rate(style: GraineChatRating.Style, value: Int) {
        scheduler.run { [self] in
            guard ended, rating == nil else { return }
            let answer = ChatRatings.make(style: style.rawValue, value: value)
            rating = answer
            write(ChatRatings.frame(answer))
            // The state first, so an app reading `chat.rating` from its `onRated` sees the answer.
            onEvent(.changed)
            onEvent(.rated(answer))
        }
    }

    /// What belongs to one conversation on screen: the replies offered, its end, its rating.
    private func freshConversation() {
        quickReplies = []
        ended = false
        rating = nil
    }

    // MARK: - Opening

    private func connect() {
        guard phase == .idle else { return }
        generation += 1
        let mine = generation
        phase = .preparing
        transport = nil
        disconnected = false
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
        let identity = setup.identity()
        // Whose this connection is: the identity its ticket is asked with (DESIGN.md "Who a chat belongs to").
        owner = identity?.value
        ownerKnown = true
        let body = CallWire.ticketRequest(
            publishableKey: setup.publishableKey,
            metadata: CallWire.ticketMetadata(variables.map { ($0.0, $0.1 as Any?) }),
            mode: ChatWire.ticketMode,
            identity: identity
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
            closed: { [weak self] byServer, detail, code in
                self?.scheduler.run { self?.socketClosed(byServer: byServer, detail: detail, code: code, mine: mine) }
            }
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
        wasOnline = true
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

    private func socketClosed(byServer: Bool, detail: String?, code: Int?, mine: Int) {
        guard mine == generation else { return }
        switch phase {
        case .idle:
            return
        case .preparing:
            failedToOpen(detail ?? "The conversation could not be opened.")
        case .open:
            teardown(sendStop: false, reason: detail ?? "The connection was lost.")
            // Graine let the conversation go (idle, or its time limit) — by its code, however the socket reported it.
            let graineEnded = code.map { ChatWire.endedByGraine.contains($0) } ?? false
            if byServer || graineEnded {
                // The other side ended this conversation. The next message starts another. When it was the agent that
                // ended it (`conversation_end`), the chat is over rather than offline: idle, as every SDK says it.
                disconnected = graineEnded
                setStatus(wanted && !paused && !ended ? .offline : .idle)
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

    /**
     * The chat's lines were another identity's (`identityChanged`). A first
     * connect for `current` follows — "Connecting…", never "Disconnected" or
     * the reconnect banner.
     */
    private func belongsToAnother(_ current: String?) {
        let live = phase != .idle || retryTimer != nil
        let again = live && wanted && !unseen && !paused
        if again {
            // Closed normally: the stop frame, then the socket.
            teardown(sendStop: true, reason: nil)
        } else if live {
            // Nobody is in the chat: closed as `close` closes it; the next open or message connects.
            hangUp()
        }
        // Whose the chat is now: the same change heard again changes nothing.
        owner = current
        attempt = 0
        disconnected = false
        wasOnline = false
        var waiting = transcript.keepUnsent()
        if waiting.count > ChatWire.queueLimit {
            for dropped in waiting.prefix(waiting.count - ChatWire.queueLimit) { transcript.setDelivery(dropped.id, .failed) }
            waiting.removeFirst(waiting.count - ChatWire.queueLimit)
        }
        queue = waiting
        freshConversation()
        if again {
            connect()
        } else {
            setStatus(.idle)
            if live { onEvent(.letGo) }
        }
        onEvent(.changed)
    }

    /// Hang up and stay down: the stop frame, no reconnect, nothing left waiting to close it. The transcript stays.
    private func hangUp() {
        wanted = false
        idleTimer?.cancel()
        idleTimer = nil
        teardown(sendStop: true, reason: nil)
        wasOnline = false
        setStatus(.idle)
    }

    // MARK: - How long it lasts

    /// Something was said either way, or the customer came into the chat: a close waiting for an unseen chat waits again from now.
    private func noteActivity() {
        lastActivity = scheduler.now
        // Unseen with nothing watching (it let the chat go, or no window has shown it since): watched again.
        if unseen && idleTimer == nil { watchIdle() }
    }

    /**
     * Unseen and wanted: let go once the close delay has passed since the
     * later of the moment the last window left and the last activity.
     * Activity meanwhile only moves the deadline — the timer reads it when it
     * fires and waits out what is left.
     */
    private func watchIdle() {
        idleTimer?.cancel()
        idleTimer = nil
        guard unseen, wanted else { return }
        let left = max(unseenSince, lastActivity) + closeDelay - scheduler.now
        // Within a millisecond is over: what a clock rounds away must not wait again, and again.
        guard left > 0.001 else {
            letGo()
            return
        }
        idleTimer = scheduler.after(left) { [weak self] in self?.watchIdle() }
    }

    /// No window showed it for the close delay: hung up as `close` does. The lines stay; the next open or message connects again.
    private func letGo() {
        hangUp()
        onEvent(.letGo)
    }

    // MARK: - What the agent sends

    private func received(_ raw: String, mine: Int) {
        guard mine == generation, phase == .open, let frame = ChatInbound.parse(raw) else { return }
        if case .ignored = frame { return }
        if case .session(let id) = frame {
            // This connection's session (history.json `sessionFrame`): what it carried so far takes it. Nothing said.
            transcript.sessionStarted(id)
            onEvent(.changed)
            return
        }
        // The agent said something: a close waiting for an unseen chat waits again from now.
        noteActivity()
        switch frame {
        case .text(let data):
            let chunk = CallWire.readAgentChunk(data)
            // A start marker begins the agent's next turn: one still open without its end marker is over, and the
            // replies suggested for the turn before are spent.
            if chunk.startsTurn { agentTurnStarts() }
            if !chunk.text.isEmpty {
                if transcript.agentChunk(chunk.text, now: setup.now()).began { quickReplies = [] }
                agentTyping = false
                stopAwaiting()
            } else if chunk.startsTurn {
                agentTyping = true
            }
            if chunk.endsTurn { endAgentTurn() }
            onEvent(.changed)
        case .beginningOfStream:
            agentTurnStarts()
            agentTyping = true
            onEvent(.changed)
        case .endOfStream:
            endAgentTurn()
            onEvent(.changed)
        case .widget(let widget):
            // A component can be the agent's first act on a connection: it says which conversation this is, as words do.
            transcript.agentBegan()
            stopAwaiting()
            onEvent(.changed)
            onEvent(.widget(widget))
        case .widgetPending(let hint):
            if transcript.agentBegan() { onEvent(.changed) }
            onEvent(.widgetPending(hint))
        case let .appAction(id, name, arguments):
            runAction(id: id, name: name, arguments: arguments)
        case .history(let turns):
            // The conversation continues: the earlier turns, before any agent message. Never announced as new ones.
            if transcript.restore(turns) {
                quickReplies = []
                onEvent(.changed)
            }
        case .quickReplies(let replies):
            // An empty list takes them away; offered after the conversation ended, they are nobody's to tap.
            if replies.isEmpty {
                guard !quickReplies.isEmpty else { return }
                quickReplies = []
            } else {
                guard !ended else { return }
                quickReplies = replies
            }
            onEvent(.changed)
        case .conversationEnd:
            // The open turn closes, typing stops, the replies go. The socket stays open a short while for a rating.
            if let done = transcript.agentTurnEnded() { onEvent(.agentTurnEnded(done)) }
            agentTyping = false
            stopAwaiting()
            quickReplies = []
            ended = true
            onEvent(.changed)
        case .session, .ignored:
            break
        }
    }

    /// The agent's next turn begins: the one still open is over, and the replies offered for it go.
    private func agentTurnStarts() {
        quickReplies = []
        if let done = transcript.agentTurnEnded() { onEvent(.agentTurnEnded(done)) }
        transcript.agentBegan()
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
        // The customer has moved on — past the replies the agent suggested, and past a conversation that had ended.
        freshConversation()
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
