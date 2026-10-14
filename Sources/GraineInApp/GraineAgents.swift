import Foundation

/**
 * SEVERAL AGENTS IN ONE APP (MULTI-AGENT.md) — each its own publishable key,
 * chosen per screen or use case: a support agent in Help, a sales agent on
 * Plans. Every agent configured with `GraineInApp.configure(_:name:)` is kept
 * here, in the order it was configured.
 *
 * What one app, one person and one device have once is shared by every agent:
 * the install id, who is signed in (`identify` on any agent identifies them for
 * all; `identify(nil)` signs out everywhere), the memory choice, and the screen
 * (the current screen is the app's; each agent hears it while it has a live
 * conversation). Everything else — the session and its design, the chat, the
 * voice bar, the actions, the scheduling and memory requests — is the agent's
 * own. One conversation at a time across all of them.
 *
 * The process has one registry; tests make their own. Thread-safe.
 */
final class GraineAgentRegistry {
    static let process = GraineAgentRegistry()
    static let defaultName = "default"

    private let lock = NSLock()
    private var ordered: [GraineInApp] = []
    /// The last `identify` (traits, memory), for an agent configured after it.
    private var identified: (traits: [String: Any?]?, memory: Bool?)?
    /// The last explicit memory choice (`identify(…, memory:)` or `setMemory`).
    private var memoryChoice: Bool?
    /// The app's current screen, for an agent configured after it was set.
    private var screen: GraineScreen?
    private var installId: String?

    /// A name as it is kept: trimmed; empty is the default.
    static func normalise(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultName : trimmed
    }

    /// The agent under `name`, or the one `make` creates and adds — once, however many threads ask.
    func agent(named name: String, make: () -> GraineInApp) -> (agent: GraineInApp, created: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if let existing = ordered.first(where: { $0.name == name }) { return (existing, false) }
        let made = make()
        ordered.append(made)
        return (made, true)
    }

    /// Add an agent built elsewhere (tests).
    func add(_ agent: GraineInApp) {
        lock.lock()
        defer { lock.unlock() }
        if !ordered.contains(where: { $0 === agent }) { ordered.append(agent) }
    }

    func named(_ name: String) -> GraineInApp? {
        lock.lock()
        defer { lock.unlock() }
        return ordered.first { $0.name == name }
    }

    var all: [String: GraineInApp] {
        lock.lock()
        defer { lock.unlock() }
        var out: [String: GraineInApp] = [:]
        for agent in ordered { out[agent.name] = agent }
        return out
    }

    /// The default agent, else the first configured.
    var primary: GraineInApp? {
        lock.lock()
        defer { lock.unlock() }
        return ordered.first { $0.name == GraineAgentRegistry.defaultName } ?? ordered.first
    }

    /// Every agent, `agent` among them even when it was never added.
    func members(including agent: GraineInApp) -> [GraineInApp] {
        lock.lock()
        defer { lock.unlock() }
        return ordered.contains(where: { $0 === agent }) ? ordered : ordered + [agent]
    }

    /**
     * The agent a hosted ring belongs to: the one whose session (or the last
     * one kept) has the push's `agent_id` as its agent id or its web-call
     * twin's. Nil when no agent has it — the caller then uses the default.
     */
    func agent(forAgentId id: String) -> GraineInApp? {
        let wanted = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        for agent in members() {
            guard let session = agent.sessionOrCached else { continue }
            if session.agentId == wanted || session.webcallAgentId == wanted { return agent }
        }
        return nil
    }

    func members() -> [GraineInApp] {
        lock.lock()
        defer { lock.unlock() }
        return ordered
    }

    // MARK: - Shared by every agent

    func rememberIdentify(_ traits: [String: Any?]?, memory: Bool?) {
        lock.lock()
        identified = (traits, memory)
        if let memory = memory { memoryChoice = memory }
        lock.unlock()
    }

    func rememberMemory(_ enabled: Bool) {
        lock.lock()
        memoryChoice = enabled
        lock.unlock()
    }

    func rememberScreen(_ next: GraineScreen?) {
        lock.lock()
        screen = next
        lock.unlock()
    }

    /// What a newly configured agent takes on: who is signed in, their memory choice, the current screen.
    func shared() -> (identified: (traits: [String: Any?]?, memory: Bool?)?, memory: Bool?, screen: GraineScreen?) {
        lock.lock()
        defer { lock.unlock() }
        return (identified, memoryChoice, screen)
    }

    /// The install id, resolved once for every agent (one device, one id).
    func installId(resolving store: InstallIdStore) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let known = installId { return known }
        let made = InstallId.resolve(store)
        if !made.kept { GraineLog.warning("The install id could not be kept in the Keychain; this launch uses a new one.") }
        installId = made.id
        return made.id
    }
}
