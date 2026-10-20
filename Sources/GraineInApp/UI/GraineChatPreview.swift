#if os(iOS)
import SwiftUI

/**
 * FOR GRAINE'S OWN SCREENSHOTS AND DESIGN REVIEWS — not part of the SDK's
 * API (`@_spi(Preview)`), and nothing an app ships with.
 *
 * The real chat window on a connection that never leaves the device: an
 * instance of the SDK built on a network that answers locally, the session
 * (with its design) handed in, and the server's frames delivered by the
 * caller — so a review sees exactly what a customer would, drawn by
 * `GraineChatView`, the chat's fold and its socket, with no server.
 *
 *     let preview = GraineChatPreview(session: ["design": design, "appearance": ["heading": "Aria"]])
 *     preview.deliver(["type": "text", "data": "<beginning_of_stream>Hi, how can I help?<end_of_stream>"])
 *     preview.graine.chat.send("Hello")
 *     preview.screen(takesCalls: true)
 */
@_spi(Preview)
public final class GraineChatPreview {
    public let graine: GraineInApp
    private let network = PreviewNetwork()

    public init(session: [String: Any]) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("graine-preview-\(UUID().uuidString)", isDirectory: true)
        graine = GraineInApp(
            config: GraineConfig(baseUrl: "https://preview.graine.invalid", publishableKey: "pk_preview"),
            installIds: MemoryInstallIdStore("00000000-0000-4000-8000-000000000000"),
            defaults: UserDefaults(suiteName: "ai.graine.inapp.preview") ?? .standard,
            sessionCache: SessionCache(directory: folder),
            network: network
        )
        var body: [String: Any] = ["agentId": "preview-agent", "webcallAgentId": "preview-web"]
        for (key, value) in session { body[key] = value }
        graine.finishSession(.success(GraineSessionConfig.parse(body)))
    }

    /// The server sends a frame on the chat (`text`, `quick_replies`, `conversation_end`, …).
    public func deliver(_ frame: [String: Any]) {
        network.socket?.receive(frame)
    }

    /// The connection drops and does not come back (the window's reconnect banner shows while the chat tries again).
    public func loseConnection() {
        network.reachable = false
        network.socket?.drop()
    }

    /// The agent draws a component (a `widget` frame's `widget`).
    public func showComponent(_ widget: [String: Any]) {
        graine.componentArrived(widget)
    }

    /// The chat screen, as `GraineChatView` draws it; `takesCalls` shows the call button and microphone where the design puts them.
    public func screen(takesCalls: Bool) -> some View {
        GraineChatView(graine: graine, previewCall: takesCalls ? {} : nil)
    }
}

/// A network that answers on the device: a ticket for the chat, `{}` for anything else, and a socket the preview drives.
private final class PreviewNetwork: CallNetwork {
    private(set) var socket: PreviewSocket?
    /// Off: new sockets never open.
    var reachable = true

    func post(_ url: URL, body: Data, completion: @escaping (Int, Data?) -> Void) {
        let reply = url.path.hasSuffix("/api/embed/ticket") ? #"{"ticket":"preview","wsUrl":"wss://preview.graine.invalid/v1/embed"}"# : "{}"
        DispatchQueue.main.async { completion(200, Data(reply.utf8)) }
    }

    func openSocket(_ url: URL, protocols: [String], events: CallSocketEvents) -> CallSocket {
        let opened = PreviewSocket(events: events)
        socket = opened
        if reachable { DispatchQueue.main.async { events.opened() } }
        return opened
    }
}

private final class PreviewSocket: CallSocket {
    private let events: CallSocketEvents

    init(events: CallSocketEvents) {
        self.events = events
    }

    func send(_ text: String) {}
    func close() {}

    func receive(_ frame: [String: Any]) {
        events.received(JSON.string(from: frame) ?? "{}")
    }

    func drop() {
        events.closed(false, "The connection was lost.")
    }
}
#endif
