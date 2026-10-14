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
    }
}

/// Hears the chat change — its turns, its status or the typing indicator. Main thread. Held weakly.
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
        ]
    }

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

    /// `idle`, `connecting`, `online`, `reconnecting` or `offline`.
    @objc public var status: String { objcOnMainSync { ObjCBridge.chatStatus(self.graine.chat.status).word } }

    /// While reconnecting, which attempt this is (of six); 0 otherwise.
    @objc public var reconnectAttempt: Int { objcOnMainSync { ObjCBridge.chatStatus(self.graine.chat.status).attempt } }

    /// The agent is working on a reply.
    @objc public var typing: Bool { objcOnMainSync { self.graine.chat.typing } }

    /// The user is in the chat.
    @objc public var isOpen: Bool { objcOnMainSync { self.graine.chat.isOpen } }

    /// The whole chat as JSON, for a bridge: `{turns: [{id, role, text, live, delivery, at, proactive, restored, channel}], status, attempt, typing, open}`.
    @objc public var snapshotJSON: String {
        objcOnMainSync {
            let chat = self.graine.chat
            let status = ObjCBridge.chatStatus(chat.status)
            return ObjCBridge.text([
                "turns": chat.turns.map { ObjCBridge.turn($0) },
                "status": status.word,
                "attempt": status.attempt,
                "typing": chat.typing,
                "open": chat.isOpen,
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

    /// Send a message: shown at once, sent now or when the chat connects.
    @objc(send:)
    public func send(_ text: String) { graine.chat.send(text) }

    /// Connect now, and send what could not be sent.
    @objc(retry)
    public func retry() { graine.chat.retry() }

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

/// Run on the main thread and return what it returns: the chat and the calls are main-thread state.
func objcOnMainSync<T>(_ block: () -> T) -> T {
    if Thread.isMainThread { return block() }
    return DispatchQueue.main.sync(execute: block)
}
