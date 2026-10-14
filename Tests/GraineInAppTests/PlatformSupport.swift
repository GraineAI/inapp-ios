import Foundation
import Testing
@testable import GraineInApp

/*
 * What the identity, memory, scheduling, hosted-call and chat tests stand on:
 * a network that answers each route as the test says (and records every body),
 * a UserDefaults suite and a folder of their own, and an instance built on
 * them — never the Keychain, the real defaults, the disk or a real host.
 */

/// Answers each path as told; records every POST; opens fake sockets.
final class RoutedNetwork: CallNetwork {
    private(set) var posts: [(path: String, body: [String: Any], raw: String)] = []
    private(set) var sockets: [FakeSocket] = []
    /// path → (status, body). Anything else: 200 and `{}`.
    var replies: [String: (Int, String?)] = [:]
    /// What the ticket route answers when no reply is set: a ticket and its socket.
    var ticket: (Int, String?) = (200, #"{"ticket":"tkt-1","wsUrl":"wss://ws.graine.ai/v1/embed"}"#)

    /// path → response headers (names lower-cased), for `Retry-After`.
    var headers: [String: [String: String]] = [:]

    func post(_ url: URL, body: Data, completion: @escaping (Int, Data?) -> Void) {
        postWithHeaders(url, body: body) { status, data, _ in completion(status, data) }
    }

    func postWithHeaders(_ url: URL, body: Data, completion: @escaping (Int, Data?, [String: String]) -> Void) {
        let raw = String(decoding: body, as: UTF8.self)
        posts.append((url.path, JSON.object(from: body) ?? [:], raw))
        let reply = replies[url.path] ?? (url.path == "/api/embed/ticket" ? ticket : (200, "{}"))
        completion(reply.0, reply.1.map { Data($0.utf8) }, headers[url.path] ?? [:])
    }

    func openSocket(_ url: URL, protocols: [String], events: CallSocketEvents) -> CallSocket {
        let socket = FakeSocket(url: url, protocols: protocols, events: events)
        sockets.append(socket)
        return socket
    }

    var socket: FakeSocket? { sockets.last }

    func bodies(_ path: String) -> [[String: Any]] {
        posts.filter { $0.path == path }.map { $0.body }
    }
}

/// A defaults suite and a folder of the test's own, removed by `clean()`.
final class Sandbox {
    let suite = "ai.graine.inapp.tests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let folder: URL

    init() {
        defaults = UserDefaults(suiteName: suite)!
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("graine-tests-\(UUID().uuidString)", isDirectory: true)
    }

    func clean() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }
}

/// An instance on fakes: the install id in memory, the defaults and the cache in the sandbox, the network routed.
struct PlatformRig {
    let sandbox = Sandbox()
    let network = RoutedNetwork()
    let scheduler = ManualScheduler()
    let installs = MemoryInstallIdStore("3f2504e0-4f89-11d3-9a0c-0305e82c3301")
    let graine: GraineInApp

    init(variables: [String: Any] = [:]) {
        graine = GraineInApp(
            config: GraineConfig(baseUrl: "https://www.graine.ai", publishableKey: "pk_test_rig", variables: variables),
            installIds: installs,
            defaults: sandbox.defaults,
            sessionCache: SessionCache(directory: sandbox.folder),
            network: network,
            chatScheduler: scheduler
        )
    }

    /// Deliver the session the server would send, as the network would.
    func session(_ json: [String: Any] = [:]) {
        var body: [String: Any] = ["agentId": "agent-1", "webcallAgentId": "web-1"]
        for (k, v) in json { body[k] = v }
        graine.finishSession(.success(GraineSessionConfig.parse(body)))
    }
}

/// Collects what a listener hears.
final class HeardListener: GraineListener {
    var widgets: [[String: Any]] = []
    var pending: [[String: Any]] = []
    var messages: [GraineChatTurn] = []

    func onWidget(_ widget: [String: Any]) { widgets.append(widget) }
    func onWidgetPending(_ hint: [String: Any]) { pending.append(hint) }
    func onChatMessage(_ turn: GraineChatTurn) { messages.append(turn) }
}
