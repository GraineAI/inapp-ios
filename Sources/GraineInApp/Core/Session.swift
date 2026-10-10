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

    public init(
        agentId: String,
        webcallAgentId: String,
        appearance: [String: Any] = [:],
        variables: [String: Any] = [:],
        pageVersion: String? = nil,
        declaredActions: Set<String> = [],
        friction: [String: Any]? = nil,
        design: GraineDesign? = nil,
        wsHost: String? = nil
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
    }

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
        return GraineSessionConfig(
            agentId: agentId,
            webcallAgentId: JSON.nonEmpty(data["webcallAgentId"]) ?? agentId,
            appearance: data["appearance"] as? [String: Any] ?? [:],
            variables: data["variables"] as? [String: Any] ?? [:],
            pageVersion: JSON.nonEmpty(data["pageVersion"]),
            declaredActions: declared,
            friction: data["friction"] as? [String: Any],
            design: GraineDesign.parse(data["design"]),
            wsHost: JSON.nonEmpty(data["wsHost"])
        )
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
