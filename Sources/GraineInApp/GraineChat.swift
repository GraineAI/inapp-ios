import Combine
import Foundation

/**
 * THE CHAT — a typed conversation with the agent, on its own connection.
 *
 *     let chat = GraineInApp.shared.chat
 *     chat.open()                 // connect; it stays connected while the customer is in the chat
 *     chat.send("Why was my card declined?")
 *     chat.close()                // they left
 *
 * The agent sees the screen you describe and runs your actions, as on a call,
 * and the components it draws arrive in the same views (`GraineWidgetView`,
 * the bar). A message typed while the chat is not connected is shown at once
 * and sent when it is; a dropped connection is made again on its own
 * (1, 2, 4, 8, 15 and 15 seconds apart, then `offline` until the customer sends
 * something or you call `retry()`). Each agent reply is its own message.
 *
 * One conversation at a time, across every agent the app configured: opening
 * the chat ends any call an assistant bar holds and closes another agent's
 * chat, starting a call closes it, and a native call (`calls`) holds every chat
 * down until it is over. With the app in the background the chat
 * hangs up (when `GraineConfig.endOnBackground`), and comes back with the app.
 *
 * `ObservableObject`: `GraineChatView` draws it whole; draw your own from
 * `turns`, `status` and `typing` — and `quickReplies`, `ended` and `rating`.
 * Main thread.
 *
 * What the chat window draws beside the conversation is yours to give:
 *
 *     chat.pin(GraineChatPin(title: "Your plan", subtitle: "Renews on 14 Nov"))  // what it is about
 *     chat.onAttach = { presentPicker() }       // the paperclip, where the design draws one
 *     chat.onRated = { rating in log(rating) }  // the end-of-chat rating
 */
public final class GraineChat: ObservableObject {
    /// What has been said, oldest first: the customer's messages and the agent's replies, one bubble each.
    @Published public private(set) var turns: [GraineChatTurn] = []
    @Published public private(set) var status: GraineChatStatus = .idle
    /// The agent is working on a reply: from the customer's message until its first words.
    @Published public private(set) var typing = false

    /**
     * The replies the agent suggests for its latest turn, drawn as chips by
     * `GraineChatView` — for a chat of your own, draw them and send one with
     * `sendQuickReply(_:)`. Gone once the customer sends anything, the agent
     * starts another turn, or the conversation ends.
     */
    @Published public private(set) var quickReplies: [GraineQuickReply] = []

    /**
     * The agent ended the conversation. The chat window asks for a rating
     * where the design does; your own UI can call `rate(style:value:)`. The
     * customer sending another message starts the conversation over (and
     * this goes back to false).
     */
    @Published public private(set) var ended = false

    /// The customer's end-of-chat rating, once given (one per conversation). `onRated` hears it as it happens.
    @Published public private(set) var rating: GraineChatRating?

    /// What the conversation is about, as your app pinned it (`pin(_:)`); nil when nothing is pinned.
    @Published public private(set) var pinned: GraineChatPin?

    /// The customer rated the chat (in the window, or through `rate(style:value:)`). Main thread.
    public var onRated: ((GraineChatRating) -> Void)?

    /**
     * Your app handles attachments: set this and the chat window draws the
     * paperclip where the design asks for one; a tap calls it. The SDK sends
     * nothing itself — upload what the customer picks and describe it to the
     * agent as you would anything else. Nil (the default): no paperclip. Main thread.
     */
    public var onAttach: (() -> Void)? {
        didSet { objectWillChange.send() }
    }

    /// The chat lost a connection it had and is making it again (the window's calm "Reconnecting…" banner).
    @Published private(set) var wasOnline = false

    /**
     * This customer's calls still to come (`scheduledCalls()`), soonest first,
     * at most three — the chat window's "Upcoming calls" card. Fetched when the
     * chat opens and after the agent finishes a reply (it may have just booked
     * one), only where Graine rings this app. Cancel one with `cancelUpcomingCall(id:)`.
     */
    @Published public private(set) var upcomingCalls: [GraineScheduledCall] = []
    /// Calls being cancelled from the card, and those whose cancel failed (tap to retry).
    @Published private(set) var cancelling: Set<String> = []
    @Published private(set) var cancelFailed: Set<String> = []

    /// Connected: a message goes now.
    public var online: Bool { status == .online }

    /**
     * The customer has said nothing yet in this conversation, and it is not one
     * that continues (no turn was restored): the brand's starters are offered.
     */
    public var awaitingFirstMessage: Bool { ChatRows.offersStarters(turns) }

    /// The customer is in the chat (`open` was called and `close` was not).
    public private(set) var isOpen = false

    /**
     * The size this open asked for (`open(size:)`), until `close()`; nil
     * follows `GraineConfig.chatSize`, then the dashboard's. The bar draws the
     * chat at it — and switching to the call and back keeps it.
     */
    @Published public private(set) var openedSize: GraineChatSize?
    /// Counts the app's opens, so a mounted bar moves to the chat when the app opens it.
    @Published private(set) var appOpens = 0

    private unowned let graine: GraineInApp
    private var connection: ChatConnection!
    private var unwatch: [() -> Void] = []

    static let holdBackground = "background"
    static let holdNativeCall = "native-call"

    init(graine: GraineInApp, network: CallNetwork, scheduler: CallScheduler) {
        self.graine = graine
        let setup = ChatConnection.Setup(
            publishableKey: graine.config.publishableKey,
            baseUrl: graine.config.baseUrl,
            variables: { [weak graine] in graine?.variables.orderedForTicket() ?? [] },
            identity: { [weak graine] in graine?.identityFields(callId: nil) },
            contextFrame: { [weak graine] in graine?.currentContextFrame() },
            session: { [weak graine] done in
                guard let graine = graine else { return done(nil) }
                graine.loadSessionOrCached(done)
            },
            runAction: CallEngine.actionRunner(graine)
        )
        connection = ChatConnection(setup: setup, network: network, scheduler: scheduler) { [weak self] event in
            self?.event(event)
        }
        graine.onMain { [weak self] in self?.watch() }
    }

    deinit {
        unwatch.forEach { $0() }
    }

    // MARK: - Driving it

    /**
     * The customer is in the chat: connect, and keep connected. Ends a call the
     * assistant bar holds. A mounted `GraineAgentBar` moves to the chat (where
     * the agent offers one) and draws it at `size` — this open's own, until
     * `close()`; nil follows `GraineConfig.chatSize`, then the dashboard's.
     */
    public func open(size: GraineChatSize? = nil) {
        graine.onMain {
            self.openedSize = size
            self.appOpens += 1
            self.connectOpen()
        }
    }

    /// The customer left: the chat hangs up and stays down. What was said stays on screen.
    public func close() {
        graine.onMain {
            self.openedSize = nil
            self.closeConnection()
        }
    }

    /// Connect for the SDK's own views — the bar moving to the chat, a chat screen appearing — keeping the open's size.
    func connectOpen() {
        // One conversation at a time, across every agent.
        graine.takeConversation(for: .chat)
        isOpen = true
        connection.open()
        fetchUpcoming(force: true)
    }

    /// Hang up for the SDK's own views — the bar moving to the call — keeping the open's size for its way back.
    func closeConnection() {
        isOpen = false
        connection.close()
    }

    /// Send a message. Shown at once; sent now, or as soon as the chat is connected (connecting it if it is not).
    public func send(_ text: String) {
        graine.onMain {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if !self.isOpen {
                self.graine.takeConversation(for: .chat)
                self.isOpen = true
            }
            self.graine.noteInteraction()
            self.connection.send(text)
        }
    }

    /**
     * Send one of the agent's quick replies: its `text`, as the customer's own
     * message — a real turn, exactly as if typed.
     */
    public func sendQuickReply(_ reply: GraineQuickReply) {
        send(reply.text)
    }

    /**
     * Rate the conversation the agent ended, from a UI of your own (the chat
     * window draws its own rating card): thumbs `1` up or `0` down, stars and
     * emoji `1`–`5`. Taken once, only after the conversation ended; it goes
     * on the conversation and to `onRated`.
     */
    public func rate(style: GraineChatRating.Style, value: Int) {
        graine.onMain { self.connection.rate(style: style, value: value) }
    }

    /**
     * Pin what the conversation is about — drawn under the chat's header or
     * atop its thread, where the design puts it — or `nil` to take it away.
     * Never sent to the agent.
     */
    public func pin(_ pin: GraineChatPin?) {
        graine.onMain { self.pinned = pin.flatMap { $0.title.isEmpty ? nil : $0 } }
    }

    /// Connect now, and send what could not be sent.
    public func retry() {
        graine.onMain {
            self.isOpen = true
            self.connection.retry()
        }
    }

    /**
     * Empty the chat on screen — a new topic, a tidy screen. Only the screen:
     * the conversation goes on, a message still waiting for the connection is
     * still sent, and nothing Graine keeps — the conversation that continues,
     * what the agent remembers — is touched. `newConversation()` starts over.
     */
    public func clear() {
        graine.onMain { self.connection.clearScreen() }
    }

    /**
     * START A NEW CONVERSATION — a fresh thread, as a support chat offers one.
     *
     * The chat hangs up, Graine lets go of the conversation it kept for this
     * agent and customer (so the next chat does not continue it), the chat on
     * screen clears, and — when the customer was in the chat — a fresh chat
     * opens, with the welcome and the starters. What the agent remembers about
     * the customer (memories) is untouched. Nobody identified: nothing was
     * kept, so only the screen clears. `GraineChatView`'s header offers it
     * while it shows an earlier conversation.
     *
     * Throws `GraineServiceError` when Graine refused (`deviceLimit`,
     * `network`, …); the chat is then as it was, connected again.
     */
    public func newConversation() async throws {
        var wasOpen = false
        await onMainAndWait {
            wasOpen = self.isOpen
            // Hung up first: the conversation being let go of must not write another turn after it.
            if wasOpen { self.connection.close() }
        }
        do {
            try await graine.letGoOfConversation()
        } catch {
            // Nothing was let go of: back to the conversation as it was.
            await onMainAndWait { if wasOpen && self.isOpen { self.connection.open() } }
            throw error
        }
        await onMainAndWait {
            self.connection.clearTranscript()
            if wasOpen && self.isOpen { self.connection.open() }
        }
    }

    /// Run on the main thread, and wait for it.
    private func onMainAndWait(_ block: @escaping () -> Void) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            graine.onMain {
                block()
                done.resume()
            }
        }
    }

    /// Fetch the upcoming calls again (the card refreshes itself; call this after booking one elsewhere).
    public func refreshUpcomingCalls() {
        graine.onMain { self.fetchUpcoming(force: true) }
    }

    /**
     * Cancel one of the card's calls. Its row says "Cancelling…" until the
     * server has it, then goes; a failure leaves it saying so, to try again.
     */
    public func cancelUpcomingCall(id: String) {
        graine.onMain { self.startCancelling(id) }
    }

    /// Main thread.
    private func startCancelling(_ id: String) {
        guard !cancelling.contains(id) else { return }
        cancelling.insert(id)
        cancelFailed.remove(id)
        graine.cancelScheduledCall(id: id) { [weak self] result in
            let failed: Bool
            if case .failure = result { failed = true } else { failed = false }
            DispatchQueue.main.async { self?.cancelled(id, failed: failed) }
        }
    }

    private func cancelled(_ id: String, failed: Bool) {
        cancelling.remove(id)
        if failed {
            cancelFailed.insert(id)
        } else {
            upcomingCalls.removeAll { $0.id == id }
        }
    }

    /// Fetch at most every ten seconds, unless asked; only where Graine rings this app.
    private func fetchUpcoming(force: Bool) {
        guard graine.sessionOrCached?.calls?.ringsThisPlatform == true else { return }
        let now = Date()
        if !force, let last = lastUpcomingFetch, now.timeIntervalSince(last) < 10 { return }
        lastUpcomingFetch = now
        graine.listScheduledCalls { [weak self] result in
            guard case .success(let calls) = result else { return }
            let shown = UpcomingCalls.shown(calls)
            DispatchQueue.main.async {
                guard let self = self, self.upcomingCalls != shown else { return }
                self.upcomingCalls = shown
            }
        }
    }

    private var lastUpcomingFetch: Date?

    // MARK: - For the SDK's own views and routing

    /// The chat is the conversation a component's answer and an app event belong to.
    var carriesConversation: Bool { isOpen && status != .idle }

    func submitWidget(widgetId: String, data: [String: Any], summary: String) {
        connection.submitWidget(widgetId: widgetId, data: data, summary: summary)
    }

    func reportEvent(_ name: String, detail: String?, data: [String: Any]) {
        connection.sendEvent(name: name, detail: detail, data: data)
    }

    func hold(_ reason: String) {
        connection.hold(reason)
    }

    func release(_ reason: String) {
        connection.release(reason)
    }

    /// A different customer signed in on this phone, or the customer's memory was forgotten: the conversation leaves the screen.
    func forgetTranscript() {
        connection.clearTranscript()
    }

    // MARK: - Internals

    private func watch() {
        unwatch = [
            graine.onContext { [weak self] frame in self?.connection.sendContext(frame) },
            // Who is signed in decides whether the window offers "Book a call": redraw it.
            graine.onIdentity { [weak self] in self?.objectWillChange.send() },
            graine.onForegroundChange { [weak self] foreground in
                guard let self = self, self.graine.config.endOnBackground else { return }
                if foreground { self.connection.release(GraineChat.holdBackground) } else { self.connection.hold(GraineChat.holdBackground) }
            },
        ]
    }

    private func event(_ event: ChatConnection.Event) {
        switch event {
        case .changed:
            if turns != connection.transcript.turns { turns = connection.transcript.turns }
            if status != connection.status { status = connection.status }
            if typing != connection.typing { typing = connection.typing }
            if quickReplies != connection.quickReplies { quickReplies = connection.quickReplies }
            if ended != connection.ended { ended = connection.ended }
            if rating != connection.rating { rating = connection.rating }
            if wasOnline != connection.wasOnline { wasOnline = connection.wasOnline }
        case .rated(let answer):
            onRated?(answer)
        case .opened:
            graine.conversationLive(chat: true)
        case .closed:
            graine.conversationLive(chat: false)
        case .widget(let widget):
            graine.componentArrived(widget)
        case .widgetPending(let hint):
            graine.notifyListeners { $0.onWidgetPending(hint) }
        case .agentTurnEnded(let turn):
            graine.notifyListeners { $0.onChatMessage(turn) }
            // The agent may have just booked a call for the customer.
            fetchUpcoming(force: false)
        }
    }
}
