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
    /// The last `identify` (traits, memory, the identity token in memory only), for an agent configured after it.
    private var identified: (traits: [String: Any?]?, memory: Bool?, token: String?)?
    /// The last explicit memory choice (`identify(…, memory:)` or `setMemory`).
    private var memoryChoice: Bool?
    /// The traits `memoryChoice` was made for: an agent made later takes it on only for the customer they name.
    private var memoryChoiceFor: [String: Any?]?
    /// The app's current screen, for an agent configured after it was set.
    private var screen: GraineScreen?
    private var installId: String?
    private var debugToken: String?
    /// The app's identity-token refresher, for every agent: one identity, one refresher (APP-IDENTITY.md §1.3).
    let tokenRefresh = IdentityTokenRefresh()
    /// The last server token a calls host pushed; nil before it pushed any. An agent configured later starts with it.
    private var pushedToken: PushedClientToken?
    /// How the calls host asks its wrapper for a token; nil with no host. An agent configured later is given it.
    private var tokenAsk: (() -> Void)?

    /// A server token a calls host pushed: `token` nil is "none" — still a push, which puts tokens in play.
    struct PushedClientToken {
        let token: String?
    }

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

    func rememberIdentify(_ traits: [String: Any?]?, memory: Bool?, token: IdentityState.TokenChange = .keep) {
        lock.lock()
        // The token follows the identity as IdentityState keeps it: another person, or nobody, drops it.
        var kept: String?
        if traits != nil, let before = identified, IdentityState.sameTraits(before.traits, traits) { kept = before.token }
        switch token {
        case .keep: break
        case .set(let given): kept = given
        case .clear: kept = nil
        }
        identified = (traits, memory, traits == nil ? nil : kept)
        if let memory = memory {
            memoryChoice = memory
            memoryChoiceFor = traits
        }
        lock.unlock()
    }

    /// `setIdentityToken`, for an agent configured after it.
    func rememberToken(_ token: String?) {
        lock.lock()
        if let before = identified, before.traits != nil { identified = (before.traits, before.memory, token) }
        lock.unlock()
    }

    func rememberMemory(_ enabled: Bool) {
        lock.lock()
        memoryChoice = enabled
        memoryChoiceFor = identified?.traits ?? nil
        lock.unlock()
    }

    func rememberScreen(_ next: GraineScreen?) {
        lock.lock()
        screen = next
        lock.unlock()
    }

    /// What a newly configured agent takes on: who is signed in (with their identity token), the last memory
    /// choice and whom it was made for, the current screen.
    func shared() -> (identified: (traits: [String: Any?]?, memory: Bool?, token: String?)?, memory: Bool?,
                      memoryFor: [String: Any?]?, screen: GraineScreen?) {
        lock.lock()
        defer { lock.unlock() }
        return (identified, memoryChoice, memoryChoiceFor, screen)
    }

    /// The install's debug token (APP-IDENTITY.md §3.6), resolved once for every agent: one install, one token.
    func debugToken(resolving store: InstallIdStore, random: (Int) -> [UInt8]) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let known = debugToken { return known }
        let made = DebugTokenVault.resolve(store, random: random)
        debugToken = made
        return made
    }

    func rememberClientToken(_ token: String?) {
        lock.lock()
        pushedToken = PushedClientToken(token: token)
        lock.unlock()
    }

    func rememberClientTokenAsk(_ ask: (() -> Void)?) {
        lock.lock()
        tokenAsk = ask
        lock.unlock()
    }

    /// The last token a calls host pushed (CLIENT-TOKENS.md §2.4), for an agent configured after it.
    var pushedClientToken: PushedClientToken? {
        lock.lock()
        defer { lock.unlock() }
        return pushedToken
    }

    /// How a calls host is asked for a token, for an agent configured after it bridged them.
    var clientTokenAsk: (() -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return tokenAsk
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
