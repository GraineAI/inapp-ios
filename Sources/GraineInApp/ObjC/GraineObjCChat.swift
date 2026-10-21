import Combine
import Foundation

/// One message in the chat: the user's, or one reply of the agent's.
@objc(GraineObjCChatTurn)
public final class GraineObjCChatTurn: NSObject {
    /// Stable for the life of the transcript: `t1`, `t2`, …
    @objc public let identifier: String
    /// `user` or `agent`.
    @objc public let role: String
    @objc public let text: String
    /// The agent's words are still arriving.
    @objc public let live: Bool
    /// The user's messages: `sending`, `sent` or `failed`. The agent's: `sent`.
    @objc public let delivery: String
    @objc public let at: Date
    /// The agent spoke up without being asked.
    @objc public let proactive: Bool
    /// From an earlier conversation, restored when the chat opened (the user came back).
    @objc public let restored: Bool
    /// `chat`, or `voice` for a turn said on a call (drawn as one "Voice call" row).
    @objc public let channel: String
    /// The session it was said in (`GraineChatTurn.session`); nil for turns kept before sessions were recorded.
    @objc public let session: String?

    init(_ t: GraineChatTurn) {
        identifier = t.id
        role = t.role == .customer ? "user" : "agent"
        text = t.text
        live = t.live
        delivery = t.delivery.rawValue
        at = t.at
        proactive = t.proactive
        restored = t.restored
        channel = t.channel.rawValue
        session = t.session
    }
}

/// One reply the agent suggests for its latest turn: the words on the chip (`label`), and what a tap sends (`text`).
@objc(GraineObjCQuickReply)
public final class GraineObjCQuickReply: NSObject {
    @objc public let label: String
    @objc public let text: String

    @objc public init(label: String, text: String) {
        self.label = label
        self.text = text
    }

    convenience init(_ r: GraineQuickReply) {
        self.init(label: r.label, text: r.text)
    }
}

/// The user's end-of-chat rating: `thumbs` 1 up / 0 down out of 1, `stars` and `emoji` 1–5 out of 5.
@objc(GraineObjCChatRating)
public final class GraineObjCChatRating: NSObject {
    /// `thumbs`, `stars` or `emoji`.
    @objc public let style: String
    @objc public let value: Int
    @objc public let scale: Int

    init(_ r: GraineChatRating) {
        style = r.style.rawValue
        value = r.value
        scale = r.scale
    }

    /// `{value, scale, style}`, for a bridge.
    @objc public var json: String { ObjCBridge.text(["value": value, "scale": scale, "style": style] as [String: Any]) }
}

/// What the conversation is about, as the app pinned it (`GraineChatPin`).
@objc(GraineObjCChatPin)
public final class GraineObjCChatPin: NSObject {
    @objc public let title: String
    @objc public let subtitle: String?
    @objc public let imageUrl: String?
    @objc public let badge: String?

    init(_ p: GraineChatPin) {
        title = p.title
        subtitle = p.subtitle
        imageUrl = p.imageUrl?.absoluteString
        badge = p.badge
    }
}

/// Hears the chat change — its turns, its status, the typing indicator or the upcoming calls. Main thread. Held weakly.
@objc(GraineObjCChatListener)
public protocol GraineObjCChatListener: AnyObject {
    @objc(graineChatChanged:)
    func graineChatChanged(_ chat: GraineObjCChat)
}

/**
 * THE CHAT, FOR OBJECTIVE-C — `GraineChat`: `open` when the user is in the
 * chat, `send:`, `close` when they leave, and the state (`turns`, `status`,
 * `typing`) read whenever a listener hears a change.
 */
@objc(GraineObjCChat)
public final class GraineObjCChat: NSObject {
    private let graine: GraineInApp
    private let observers = ObjCObservers<GraineObjCChatListener>()
    private var watching: [AnyCancellable] = []
    private var pending = false

    init(graine: GraineInApp) {
        self.graine = graine
        super.init()
        let chat = graine.chat
        // @Published tells before the value changes: one notice per turn of the main loop, read after it.
        watching = [
            chat.$turns.sink { [weak self] _ in self?.changed() },
            chat.$status.sink { [weak self] _ in self?.changed() },
            chat.$typing.sink { [weak self] _ in self?.changed() },
            chat.$upcomingCalls.sink { [weak self] _ in self?.changed() },
            chat.$quickReplies.sink { [weak self] _ in self?.changed() },
            chat.$ended.sink { [weak self] _ in self?.changed() },
            chat.$rating.sink { [weak self] _ in self?.changed() },
            chat.$pinned.sink { [weak self] _ in self?.changed() },
            chat.$disconnected.sink { [weak self] _ in self?.changed() },
            chat.$wasOnline.sink { [weak self] _ in self?.changed() },
            chat.$newConversationBefore.sink { [weak self] _ in self?.changed() },
            chat.$sessionId.sink { [weak self] _ in self?.changed() },
            chat.$sessions.sink { [weak self] _ in self?.changed() },
            chat.$pastSessions.sink { [weak self] _ in self?.changed() },
            // A rating given (in the window or through `rate`), once: its observers hear it.
            chat.$rating.dropFirst().compactMap { $0 }.sink { [weak self] rating in
                self?.rated.notify { $0(GraineObjCChatRating(rating)) }
            },
        ]
    }

    private let rated = ObjCBlocks<(GraineObjCChatRating) -> Void>()

    private func changed() {
        if pending { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.pending = false
            self.observers.notify { $0.graineChatChanged(self) }
        }
    }

    /// What has been said, oldest first. Main thread.
    @objc public var turns: [GraineObjCChatTurn] { objcOnMainSync { self.graine.chat.turns.map { GraineObjCChatTurn($0) } } }

    /**
     * `idle`, `connecting`, `online`, `reconnecting` or `offline` — or
     * `disconnected` while Graine's own end of the conversation stands (idle
     * or its time limit: `disconnected`), until the next open or message.
     */
    @objc public var status: String {
        objcOnMainSync { ObjCBridge.chatStatus(self.graine.chat.status, disconnected: self.graine.chat.disconnected).word }
    }

    /// While reconnecting, which attempt this is (of six); 0 otherwise.
    @objc public var reconnectAttempt: Int { objcOnMainSync { ObjCBridge.chatStatus(self.graine.chat.status).attempt } }

    /**
     * Graine ended the conversation itself (idle, or the session's time limit):
     * the header says "Disconnected"; nothing reconnects until the user opens
     * the chat or writes again (`GraineChat.disconnected`).
     */
    @objc public var disconnected: Bool { objcOnMainSync { self.graine.chat.disconnected } }

    /// The chat was connected since the user came into it: `reconnecting` now is a dropped connection (`GraineChat.wasOnline`).
    @objc public var wasOnline: Bool { objcOnMainSync { self.graine.chat.wasOnline } }

    /**
     * The ids of the turns a "Disconnected · new conversation" row goes before,
     * in the turns' order — Graine began a new conversation under earlier lines
     * (`GraineChat.newConversationBefore`); empty when none.
     */
    @objc public var newConversationBefore: [String] { objcOnMainSync { self.graine.chat.newConversationBefore } }

    /// The agent is working on a reply.
    @objc public var typing: Bool { objcOnMainSync { self.graine.chat.typing } }

    /// The user is in the chat.
    @objc public var isOpen: Bool { objcOnMainSync { self.graine.chat.isOpen } }

    /**
     * How long the conversation stays connected once no screen shows it, in
     * seconds (`GraineChat.closeDelaySeconds`): it closes this long after the
     * later of the moment the last chat screen left and the last message
     * either way. 15 unless configured; 0 closes it as the last screen
     * leaves; at most 300 (clamped). Set while that wait is running, the wait
     * takes the new length, counted from the same moments.
     */
    @objc public var closeDelaySeconds: Int {
        get { objcOnMainSync { self.graine.chat.closeDelaySeconds } }
        set { objcOnMainSync { self.graine.chat.closeDelaySeconds = newValue } }
    }

    /**
     * The user's calls still to come, soonest first, at most three — the chat
     * window's Upcoming calls card (`GraineChat.upcomingCalls`). Main thread.
     */
    @objc public var upcomingCalls: [GraineObjCScheduledCall] {
        objcOnMainSync { self.graine.chat.upcomingCalls.map { GraineObjCScheduledCall($0) } }
    }

    /// The replies the agent suggests for its latest turn (`GraineChat.quickReplies`). Main thread.
    @objc public var quickReplies: [GraineObjCQuickReply] {
        objcOnMainSync { self.graine.chat.quickReplies.map { GraineObjCQuickReply($0) } }
    }

    /// The agent ended the conversation (`GraineChat.ended`): a rating may be asked for.
    @objc public var ended: Bool { objcOnMainSync { self.graine.chat.ended } }

    /// The user's end-of-chat rating, once given; nil before.
    @objc public var rating: GraineObjCChatRating? { objcOnMainSync { self.graine.chat.rating.map { GraineObjCChatRating($0) } } }

    /// What the conversation is about, as the app pinned it; nil when nothing is pinned.
    @objc public var pinned: GraineObjCChatPin? { objcOnMainSync { self.graine.chat.pinned.map { GraineObjCChatPin($0) } } }

    /// The id of the chat's current session (`GraineChat.sessionId`); nil until the server names it. Main thread.
    @objc public var sessionId: String? { objcOnMainSync { self.graine.chat.sessionId } }

    /**
     * The sessions the conversation on screen holds, oldest first
     * (`GraineChat.sessions`), as a JSON array: `[{id, startedAt, endedAt,
     * channel, turns, current}]` — `id` null for a session with no id, the
     * times in milliseconds since the Unix epoch, `channel` `chat` or `voice`.
     * Main thread.
     */
    @objc public var sessionsJSON: String {
        objcOnMainSync { ObjCBridge.text(self.graine.chat.sessions.map { ObjCBridge.session($0) }) }
    }

    /**
     * The user's past sessions with this agent (`GraineChat.pastSessions`),
     * as JSON in the shape Graine's wire carries them: `{sessions: [{id,
     * startedAt, endedAt, durationSeconds, channel, direction, status, turns,
     * preview}], loading, hasMore, error}` — times ISO-8601 in UTC, `channel`
     * `chat`, `voice` or `call`, `direction` `inbound` or `outbound`;
     * `endedAt`, `durationSeconds`, `direction` and `error` null when there is
     * none. Observers hear every change. Main thread.
     */
    @objc public var pastSessionsJSON: String { objcOnMainSync { ObjCBridge.text(PastSessionsWire.json(self.graine.chat.pastSessions)) } }

    /// Load the first page of the past sessions, replacing what was loaded (`GraineChat.refreshPastSessions()`).
    @objc(refreshPastSessions)
    public func refreshPastSessions() { graine.chat.refreshPastSessions() }

    /// Load the next page of the past sessions and append it (`GraineChat.loadMorePastSessions()`).
    @objc(loadMorePastSessions)
    public func loadMorePastSessions() { graine.chat.loadMorePastSessions() }

    /**
     * One past session's chat history (`GraineChat.sessionTranscript(id:)`),
     * on the main thread: the JSON `{id, startedAt, endedAt, durationSeconds,
     * channel, direction, status, turns: [{role, text, at}]}` in the shape
     * Graine's wire carries it — `role` `user` (the user) or `assistant` (the
     * agent), oldest first — or the error (its `userInfo["code"]` the word:
     * `not_found`, `identity_required`, `device_limit`, …).
     */
    @objc(sessionTranscriptJSONWithId:completion:)
    public func sessionTranscriptJSON(id: String, completion: @escaping (String?, NSError?) -> Void) {
        Task { [graine] in
            do {
                let transcript = try await graine.chat.sessionTranscript(id: id)
                let json = ObjCBridge.text(PastSessionsWire.json(transcript))
                await MainActor.run { completion(json, nil) }
            } catch {
                await MainActor.run { completion(nil, ObjCBridge.nsError(error)) }
            }
        }
    }

    /**
     * The whole chat as JSON, for a bridge: `{turns: [{id, role, text, live, delivery, at, proactive, restored, channel, session}],
     * status, attempt, typing, open, upcomingCalls: [{id, at, status, source, reason}], quickReplies: [{label, text}],
     * ended, rating: {value, scale, style} | null, pin: {title, subtitle, imageUrl, badge} | null, disconnected,
     * wasOnline, newConversationBefore: [turn id], sessionId, sessions: [{id, startedAt, endedAt, channel, turns,
     * current}]}` — `status` as the property says it, `disconnected` included; `session` and `sessionId` null when
     * there is none.
     */
    @objc public var snapshotJSON: String {
        objcOnMainSync {
            let chat = self.graine.chat
            let status = ObjCBridge.chatStatus(chat.status, disconnected: chat.disconnected)
            return ObjCBridge.text([
                "disconnected": chat.disconnected,
                "wasOnline": chat.wasOnline,
                "newConversationBefore": chat.newConversationBefore,
                "sessionId": chat.sessionId.map { $0 as Any } ?? NSNull(),
                "sessions": chat.sessions.map { ObjCBridge.session($0) },
                "turns": chat.turns.map { ObjCBridge.turn($0) },
                "status": status.word,
                "attempt": status.attempt,
                "typing": chat.typing,
                "open": chat.isOpen,
                "upcomingCalls": chat.upcomingCalls.map { ObjCBridge.scheduledCall($0) },
                "quickReplies": chat.quickReplies.map { ["label": $0.label, "text": $0.text] },
                "ended": chat.ended,
                "rating": chat.rating.map { ["value": $0.value, "scale": $0.scale, "style": $0.style.rawValue] as Any } ?? NSNull(),
                "pin": chat.pinned.map { p -> Any in
                    [
                        "title": p.title,
                        "subtitle": p.subtitle.map { $0 as Any } ?? NSNull(),
                        "imageUrl": p.imageUrl.map { $0.absoluteString as Any } ?? NSNull(),
                        "badge": p.badge.map { $0 as Any } ?? NSNull(),
                    ] as [String: Any]
                } ?? NSNull(),
            ] as [String: Any])
        }
    }

    /// The user is in the chat: connect, and stay connected.
    @objc(open)
    public func open() { graine.chat.open() }

    /**
     * `open`, at a size for this open: `compact`, `large` or `full`. Nil, or
     * any other word, follows `GraineConfig.chatSize`, then the dashboard's.
     */
    @objc(openWithSize:)
    public func open(size: String?) { graine.chat.open(size: size.flatMap { GraineChatSize(rawValue: $0) }) }

    /// A fresh thread (`GraineChat.newConversation()`): the error is Graine's refusal, the chat then as it was.
    @objc(newConversationWithCompletion:)
    public func newConversation(completion: @escaping (NSError?) -> Void) {
        Task { [graine] in
            do {
                try await graine.chat.newConversation()
                await MainActor.run { completion(nil) }
            } catch {
                await MainActor.run { completion(ObjCBridge.nsError(error)) }
            }
        }
    }

    /// The user left: hang up.
    @objc(close)
    public func close() { graine.chat.close() }

    /**
     * A chat screen of the app's own came on screen (YES) or left it (NO), in
     * pairs (`GraineChat.shown(_:)`): on screen the chat connects; once no
     * screen shows it, the conversation is kept for `closeDelaySeconds` (15
     * seconds unless set), then closed — so a screen back in that time
     * continues it.
     */
    @objc(setShown:)
    public func setShown(_ visible: Bool) { graine.chat.shown(visible) }

    /// Send a message: shown at once, sent now or when the chat connects.
    @objc(send:)
    public func send(_ text: String) { graine.chat.send(text) }

    /// Connect now, and send what could not be sent.
    @objc(retry)
    public func retry() { graine.chat.retry() }

    /// Send one of the agent's quick replies: its text, as the user's own message.
    @objc(sendQuickReply:)
    public func sendQuickReply(_ reply: GraineObjCQuickReply) {
        graine.chat.sendQuickReply(GraineQuickReply(label: reply.label, text: reply.text))
    }

    /**
     * Rate the conversation the agent ended, from a UI of your own: `style`
     * `thumbs` (value 1 up, 0 down), `stars` or `emoji` (1–5); another word is
     * thumbs. Taken once, only after the conversation ended.
     */
    @objc(rateWithStyle:value:)
    public func rate(style: String, value: Int) {
        let r = ChatRatings.make(style: style, value: value)
        graine.chat.rate(style: r.style, value: r.value)
    }

    /**
     * Pin what the conversation is about, drawn under the chat's header or atop
     * its thread where the design puts it (`GraineChatPin`); never sent to the
     * agent. An empty title takes it away.
     */
    @objc(pinWithTitle:subtitle:imageUrl:badge:)
    public func pin(title: String, subtitle: String?, imageUrl: String?, badge: String?) {
        graine.chat.pin(GraineChatPin(title: title, subtitle: subtitle, imageUrl: imageUrl.flatMap { URL(string: $0) }, badge: badge))
    }

    /// Take the pinned context card away.
    @objc(clearPin)
    public func clearPin() { graine.chat.pin(nil) }

    /// The app handles attachments: the chat window draws the paperclip where the design asks for one, and a tap runs this. Nil: none.
    @objc(setAttachHandler:)
    public func setAttachHandler(_ handler: (() -> Void)?) {
        onMain { self.graine.chat.onAttach = handler }
    }

    /// For a bridge: `observer` runs on the main thread each time the user rates the chat, until the registration is stopped.
    @objc(observeRatings:)
    public func observeRatings(_ observer: @escaping (GraineObjCChatRating) -> Void) -> GraineObjCRegistration {
        objcOnMainSync { self.rated.add(observer) }
    }

    /// Empty the chat on screen; the conversation goes on (`GraineChat.clear()`).
    @objc(clear)
    public func clear() { graine.chat.clear() }

    /**
     * Answer a component the agent drew, from a UI of your own
     * (`GraineInApp.answerComponent`), on the conversation that is live:
     * `dataJSON` the structured answer as a JSON object (nil: none),
     * `summary` the sentence that is the user's turn.
     */
    @objc(answerWidgetWithId:dataJSON:summary:)
    public func answerWidget(id: String, dataJSON: String?, summary: String) {
        graine.answerComponent(widgetId: id, data: ObjCBridge.object(dataJSON) ?? [:], summary: summary)
    }

    /**
     * Close a component the agent drew without answering it, from a UI of your
     * own (`GraineInApp.dismissComponent`): the agent is told quietly, and it
     * is kept to be shown again. Nothing for an id that is not the component
     * the agent drew last.
     */
    @objc(dismissWidgetWithId:)
    public func dismissWidget(id: String) {
        graine.dismissComponent(widgetId: id)
    }

    /// Fetch the upcoming calls again (the card refreshes itself; after a booking made elsewhere).
    @objc(refreshUpcomingCalls)
    public func refreshUpcomingCalls() { graine.chat.refreshUpcomingCalls() }

    /// Cancel one of the upcoming calls: it leaves `upcomingCalls` once Graine has called it off.
    @objc(cancelUpcomingCall:)
    public func cancelUpcomingCall(_ callId: String) { graine.chat.cancelUpcomingCall(id: callId) }

    @objc(addListener:)
    public func addListener(_ listener: GraineObjCChatListener) {
        onMain { self.observers.add(listener: listener) }
    }

    @objc(removeListener:)
    public func removeListener(_ listener: GraineObjCChatListener) {
        onMain { self.observers.remove(listener: listener) }
    }

    /// For a bridge: `observer` runs on the main thread after every change, until the registration is stopped.
    @objc(observe:)
    public func observe(_ observer: @escaping () -> Void) -> GraineObjCRegistration {
        objcOnMainSync { self.observers.add(observer) }
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }
}

/// Blocks a bridge registered, each until its registration is stopped. Main thread.
final class ObjCBlocks<Block> {
    private var blocks: [(id: UUID, block: Block)] = []

    func add(_ block: Block) -> GraineObjCRegistration {
        let id = UUID()
        blocks.append((id, block))
        return GraineObjCRegistration { [weak self] in
            let remove: () -> Void = { self?.blocks.removeAll { $0.id == id } }
            if Thread.isMainThread { remove() } else { DispatchQueue.main.async(execute: remove) }
        }
    }

    func notify(_ call: (Block) -> Void) {
        for entry in blocks { call(entry.block) }
    }
}

/// Run on the main thread and return what it returns: the chat and the calls are main-thread state.
func objcOnMainSync<T>(_ block: () -> T) -> T {
    if Thread.isMainThread { return block() }
    return DispatchQueue.main.sync(execute: block)
}
