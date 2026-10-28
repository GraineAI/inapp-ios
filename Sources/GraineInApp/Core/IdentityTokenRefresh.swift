import Foundation

/**
 * THE APP'S IDENTITY-TOKEN REFRESHER, ASKED AS APP-IDENTITY.md §1.3 SAYS —
 * one for the app, since who the customer is is the app's (every agent
 * shares it):
 *
 *   never two at once   a caller while one is on its way hears its answer
 *   once per 30 s       a caller sooner than that hears "nothing new" at once —
 *                       per person: another person, or nobody (`personChanged`),
 *                       starts the 30 s afresh
 *   only for whom       the token is applied only while the identity is the
 *                       one it was asked for (an account change meanwhile
 *                       drops it, never attaches it to the next person); the
 *                       last person's request on its way is let go of — its
 *                       callers hear "nothing new" at once, the next person's
 *                       first caller asks anew
 *   waited out once     a request someone already waited for in vain
 *                       (`timedOut`) is not waited for again: later callers
 *                       hear "nothing new" at once until it answers or its
 *                       place is freed
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
    /// Someone's wait for `round` ran out before it answered: later callers do not wait for it.
    private var overdue = false
    private var lastStart: Double?
    /// Moves on with every change of person: an answer asked for the one before is never applied.
    private var person = 0
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
     * there is no refresher, it was asked less than 30 s ago for this person,
     * the request on its way already ran out someone's wait, it answered nil,
     * or the identity changed meanwhile. Returns the request joined or
     * started; nil when nothing was asked (`done(false)` has been heard).
     */
    @discardableResult
    func refresh(capture: () -> (String) -> Bool, done: @escaping (Bool) -> Void) -> UUID? {
        lock.lock()
        guard let refresher = refresherValue else {
            lock.unlock()
            done(false)
            return nil
        }
        if let current = round {
            // Waited for in vain once already: not waited for again — nothing new, at once.
            guard !overdue else {
                lock.unlock()
                done(false)
                return nil
            }
            waiters.append(done)
            lock.unlock()
            return current
        }
        let now = clock()
        if let last = lastStart, now - last < IdentityTokenRefresh.minInterval {
            lock.unlock()
            done(false)
            return nil
        }
        lastStart = now
        let mine = UUID()
        let askedFor = person
        round = mine
        waiters = [done]
        lock.unlock()
        let apply = capture()
        // Its place is freed after `patience` whatever happens; an answer after that is still applied, under the same rule.
        after(IdentityTokenRefresh.patience) { [weak self] in self?.release(mine, changed: false) }
        Task { [weak self] in
            let token = await refresher()
            guard let self = self else { return }
            // Asked for the person before: never applied (the identity's own generation refuses it too).
            let changed = self.isPerson(askedFor) ? (token.flatMap { IdentityTokenRules.usable($0) }.map(apply) ?? false) : false
            self.release(mine, changed: changed)
        }
        return mine
    }

    /// A caller's wait for `which` ran out before it answered: until it answers or its place is freed, later callers do not wait for it.
    func timedOut(_ which: UUID) {
        lock.lock()
        if round == which { overdue = true }
        lock.unlock()
    }

    /**
     * Another person, or nobody (`identify`): the request on its way was the
     * last person's — its callers hear "nothing new" now, and its answer is
     * never applied — and the 30 s limit starts over, so the new person's
     * first conversation asks for their token at once.
     */
    func personChanged() {
        lock.lock()
        person += 1
        let dropped = waiters
        round = nil
        waiters = []
        overdue = false
        lastStart = nil
        lock.unlock()
        dropped.forEach { $0(false) }
    }

    private func isPerson(_ askedFor: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return person == askedFor
    }

    private func release(_ which: UUID, changed: Bool) {
        lock.lock()
        guard round == which else {
            lock.unlock()
            return
        }
        round = nil
        overdue = false
        let ready = waiters
        waiters = []
        lock.unlock()
        ready.forEach { $0(changed) }
    }
}
