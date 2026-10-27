import Foundation

/**
 * THE APP'S IDENTITY-TOKEN REFRESHER, ASKED AS APP-IDENTITY.md §1.3 SAYS —
 * one for the app, since who the customer is is the app's (every agent
 * shares it):
 *
 *   never two at once   a caller while one is on its way hears its answer
 *   once per 30 s       a caller sooner than that hears "nothing new" at once
 *   only for whom       the token is applied only while the identity is the
 *                       one it was asked for (an account change meanwhile
 *                       drops it, never attaches it to the next person)
 *   nil changes nothing the token stays as it was
 *
 * A refresher that never answers frees its place after `patience`; a late
 * answer is still applied under the same rule. Thread-safe.
 */
final class IdentityTokenRefresh {
    /// The app's function: a fresh token for the current identity, or nil.
    typealias Refresher = () async -> String?

    static let minInterval = IdentityTokenRules.minRefreshInterval
    /// How long a refresher may take before another may be asked.
    static let patience: TimeInterval = 30

    private let lock = NSLock()
    private var refresherValue: Refresher?
    /// The request on its way, if one is.
    private var round: UUID?
    private var waiters: [(Bool) -> Void] = []
    private var lastStart: Double?
    private let clock: () -> Double
    private let after: (TimeInterval, @escaping () -> Void) -> Void

    init(
        clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
        after: @escaping (TimeInterval, @escaping () -> Void) -> Void = { seconds, block in
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: block)
        }
    ) {
        self.clock = clock
        self.after = after
    }

    var refresher: Refresher? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return refresherValue
        }
        set {
            lock.lock()
            refresherValue = newValue
            lock.unlock()
        }
    }

    var hasRefresher: Bool { refresher != nil }

    /**
     * Ask for a fresh token. `capture` runs only when a new request starts:
     * it binds the answer to the identity as it is now and returns how to
     * apply a token (true when it changed one). `done(changed)` — false when
     * there is no refresher, it was asked less than 30 s ago, it answered nil,
     * or the identity changed meanwhile.
     */
    func refresh(capture: () -> (String) -> Bool, done: @escaping (Bool) -> Void) {
        lock.lock()
        guard let refresher = refresherValue else {
            lock.unlock()
            return done(false)
        }
        if round != nil {
            waiters.append(done)
            lock.unlock()
            return
        }
        let now = clock()
        if let last = lastStart, now - last < IdentityTokenRefresh.minInterval {
            lock.unlock()
            return done(false)
        }
        lastStart = now
        let mine = UUID()
        round = mine
        waiters = [done]
        lock.unlock()
        let apply = capture()
        // Its place is freed after `patience` whatever happens; an answer after that is still applied, under the same rule.
        after(IdentityTokenRefresh.patience) { [weak self] in self?.release(mine, changed: false) }
        Task { [weak self] in
            let token = await refresher()
            let changed = token.flatMap { IdentityTokenRules.usable($0) }.map(apply) ?? false
            self?.release(mine, changed: changed)
        }
    }

    private func release(_ which: UUID, changed: Bool) {
        lock.lock()
        guard round == which else {
            lock.unlock()
            return
        }
        round = nil
        let ready = waiters
        waiters = []
        lock.unlock()
        ready.forEach { $0(changed) }
    }
}
