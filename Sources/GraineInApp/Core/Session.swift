import Foundation

/// What the dashboard says about this agent, fetched once per launch from `POST /api/embed/session`.
public struct GraineSessionConfig {
    public let agentId: String
    /// The id calls are placed and filed under. Falls back to `agentId`.
    public let webcallAgentId: String
    /// Embed & Widgets → Appearance, exactly as stored.
    public let appearance: [String: Any]
    /// The agent's default prompt variables.
    public let variables: [String: Any]
    /// The engine page's deployment id — its cache key.
    public let pageVersion: String?
    /// Where the conversation socket lives, for a native call that could not mint a ticket. Nil: `wss://ws.graine.ai`.
    public let wsHost: String?
    /// The in-app actions the dashboard declares for this agent.
    public let declaredActions: Set<String>
    /// The dashboard's friction rules for this agent, as served. Applied under `GraineConfig.friction`.
    public let friction: [String: Any]?
    /**
     * The brand's design, resolved on the server into light and dark tokens.
     * Nil from an older server (or an unreadable one): every surface then draws
     * from `appearance`, exactly as before designs existed.
     */
    public let design: GraineDesign?
    /**
     * The agent's Identity setting: which of the traits `identify` is given
     * names the customer, for memory and for the calls Graine rings. Nil from
     * an older server — then `user_id`, as the dashboard defaults to.
     */
    public let identity: GraineIdentitySettings?
    /// Whether the agent remembers customers between conversations (Agent → Memory). Nil from an older server.
    public let memoryEnabled: Bool?
    /// Whether Graine rings this app (the workspace's push credentials), and the rules for booking calls. Nil from an older server.
    public let calls: GraineHostedCallsSettings?
    /// What the agent checks of the app and the user (APP-IDENTITY.md §2.1): nothing, from an older server.
    let security: SessionSecurity
    /// The parts of the answer a cold start draws from before the network does (SessionCache).
    let cacheable: [String: Any]

    public init(
        agentId: String,
        webcallAgentId: String,
        appearance: [String: Any] = [:],
        variables: [String: Any] = [:],
        pageVersion: String? = nil,
        declaredActions: Set<String> = [],
        friction: [String: Any]? = nil,
        design: GraineDesign? = nil,
        wsHost: String? = nil,
        identity: GraineIdentitySettings? = nil,
        memoryEnabled: Bool? = nil,
        calls: GraineHostedCallsSettings? = nil
    ) {
        self.agentId = agentId
        self.webcallAgentId = webcallAgentId
        self.appearance = appearance
        self.variables = variables
        self.pageVersion = pageVersion
        self.declaredActions = declaredActions
        self.friction = friction
        self.design = design
        self.wsHost = wsHost
        self.identity = identity
        self.memoryEnabled = memoryEnabled
        self.calls = calls
        self.security = .none
        self.cacheable = [:]
    }

    private init(parsed data: [String: Any], agentId: String, declared: Set<String>) {
        self.agentId = agentId
        self.webcallAgentId = JSON.nonEmpty(data["webcallAgentId"]) ?? agentId
        self.appearance = data["appearance"] as? [String: Any] ?? [:]
        self.variables = data["variables"] as? [String: Any] ?? [:]
        self.pageVersion = JSON.nonEmpty(data["pageVersion"])
        self.declaredActions = declared
        self.friction = data["friction"] as? [String: Any]
        self.design = GraineDesign.parse(data["design"])
        self.wsHost = JSON.nonEmpty(data["wsHost"])
        self.identity = GraineIdentitySettings.parse(data["identity"])
        self.memoryEnabled = (JSON.unwrap(data["memory"]) as? [String: Any]).flatMap { JSON.unwrap($0["enabled"]) }.flatMap { JSON.bool($0) }
        self.calls = GraineHostedCallsSettings.parse(data["calls"])
        self.security = SessionSecurity.parse(data["security"])
        var keep: [String: Any] = [:]
        for key in SessionCache.keys {
            if let value = JSON.unwrap(data[key]), !(value is NSNull) { keep[key] = value }
        }
        self.cacheable = keep
    }

    /// The identity setting in force: the session's, else `user_id`.
    var identitySettings: GraineIdentitySettings { identity ?? .standard }

    /// The rules for booking calls (`calls`): no booking, and the defaults, from a server that sends none.
    public var schedulingRules: GraineSchedulingRules { GraineSchedulingRules.from(calls) }

    /// The dashboard's Call audio setting.
    public var preferredTransport: GraineTransport {
        JSON.string(appearance["audioTransport"]) == "rtc" ? .webrtc : .websocket
    }

    /// The dashboard's accent, as stored (with or without its "#").
    public var accent: String? { JSON.nonEmpty(appearance["accent"]) }

    /// Read the session endpoint's JSON. Missing fields are empty, never a crash.
    static func parse(_ data: [String: Any]) -> GraineSessionConfig {
        let agentId = JSON.string(data["agentId"])
        var declared = Set<String>()
        if let actions = data["appActions"] as? [Any] {
            for entry in actions {
                guard let a = entry as? [String: Any] else { continue }
                let name = JSON.nonEmpty(a["tool_name"]) ?? JSON.nonEmpty(a["toolName"]) ?? JSON.nonEmpty(a["name"])
                if let name = name { declared.insert(name) }
            }
        }
        return GraineSessionConfig(parsed: data, agentId: agentId, declared: declared)
    }

    /**
     * The sentence for a refused session, written for whoever has to fix it —
     * or nil for a success. A 403 is almost always the one dashboard step every
     * app integration needs: a native app sends no Origin, so the agent must
     * list `app://` under Allowed domains.
     */
    static func errorMessage(status: Int, body: [String: Any]?) -> String? {
        if (200...299).contains(status) { return nil }
        let serverSaid = JSON.nonEmpty(body?["error"])
        // "Only my apps": not the Allowed domains step — this app is not one of the agent's apps.
        if JSON.nonEmpty(body?["code"]) == GraineErrorCode.appNotAllowed.wire {
            return GraineServiceError.defaultMessage(.appNotAllowed).map { $0 + (serverSaid.map { " (server said: \($0))" } ?? "") }
        }
        switch status {
        case 403:
            return "This agent does not accept connections from a mobile app yet. Add \"app://\" to its "
                + "Allowed domains in the dashboard, under Embed & Widgets. (server said: \(serverSaid ?? "forbidden"))"
        case 401:
            return "Publishable key was rejected. Check it against Embed & Widgets in the dashboard."
        default:
            return serverSaid ?? "Embed rejected (\(status))"
        }
    }
}

/**
 * THE LAST SESSION, KEPT ON THE DEVICE — only what a cold start draws from: the
 * design, the appearance (heading, logo, accent), the calls and identity
 * settings and the agent's ids. A VoIP push can wake an app that has not run
 * since the phone restarted, with the network still coming up; the call screen
 * it opens is then drawn in the brand's design rather than a stranger's, and
 * the call still finds its agent. The dashboard's configuration, never anything
 * about a customer.
 */
final class SessionCache {
    /// `security` too: a ring that wakes a closed app knows, before the network answers, what the agent checks of it.
    static let keys = ["agentId", "webcallAgentId", "appearance", "design", "wsHost", "identity", "memory", "calls", "pageVersion", "security"]

    private let file: URL?
    private let lock = NSLock()
    private var loaded = false
    private var value: GraineSessionConfig?

    /// `directory` nil: Application Support / ai.graine.inapp. `agent`: the default agent keeps `session.json`, another `session-<name>.json`.
    init(directory: URL? = nil, agent: String = GraineAgentRegistry.defaultName) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ai.graine.inapp", isDirectory: true)
        file = base?.appendingPathComponent(SessionCache.fileName(agent: agent))
    }

    /// One file per agent, its name made safe for a file name.
    static func fileName(agent: String) -> String {
        guard agent != GraineAgentRegistry.defaultName else { return "session.json" }
        let safe = String(agent.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? Character($0) : "_" })
        let digest = abs(agent.hashValueStable) % 1_000_000
        return "session-\(safe.prefix(40))-\(digest).json"
    }

    /// The kept session, read once; nil when there is none or it cannot be read.
    func load() -> GraineSessionConfig? {
        lock.lock()
        defer { lock.unlock() }
        if loaded { return value }
        loaded = true
        guard let file = file, let data = try? Data(contentsOf: file), let object = JSON.object(from: data) else { return nil }
        value = GraineSessionConfig.parse(object)
        return value
    }

    /// Keep this one for the next cold start. Written off the caller's thread; a failure only loses the copy.
    func save(_ session: GraineSessionConfig) {
        lock.lock()
        value = session
        loaded = true
        lock.unlock()
        guard let file = file, !session.cacheable.isEmpty, let text = JSON.string(from: session.cacheable, sortedKeys: true) else { return }
        DispatchQueue.global(qos: .utility).async {
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: file, options: [.atomic])
            } catch {
                GraineLog.warning("The session could not be kept for the next launch: \(GraineInApp.describe(error))")
            }
        }
    }
}

extension String {
    /// A hash that is the same on every launch (Swift's own is seeded per process): FNV-1a over the UTF-8.
    var hashValueStable: Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return Int(truncatingIfNeeded: hash & 0x7FFF_FFFF_FFFF_FFFF)
    }
}
