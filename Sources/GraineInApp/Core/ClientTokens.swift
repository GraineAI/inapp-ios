import Foundation

/*
 * SERVER TOKENS — a short-lived token your server mints for the signed-in user
 * of one agent, which the SDK sends with every request to Graine (contract:
 * CLIENT-TOKENS.md, vectors in client-tokens.json). Once the agent's "Require
 * server tokens" is enforced, the publishable key alone opens nothing: every
 * request without a good token is refused.
 *
 * The SDK never reads a token beyond its `iat` and `exp` — when it was minted
 * and when it lapses, unverified — and only to know when to ask for the next
 * one. It never logs one, never keeps one on the device, and never ends a live
 * chat or call because one expired: tokens are checked when a conversation
 * starts, never while it runs.
 */

/**
 * THE RULES, pure — every number and word the contract fixes, so the vectors in
 * client-tokens.json hold them and every SDK refreshes on the same schedule.
 * Times are in seconds.
 */
enum ClientTokenRules {
    /// The top-level field every request to Graine carries the token in.
    static let field = "clientToken"

    /// A new connection uses the token it holds while it has more than this left.
    static let usableForConnection: Double = 15
    /// Otherwise it waits at most this long for a refresh, then goes with the newest token it has.
    static let connectionWait: Double = 10
    /// A refusal asks for a new token at most once in this long.
    static let forcedMinInterval: Double = 5
    /// A refresh in the background is never sooner than this after the last token arrived.
    static let backgroundMinInterval: Double = 30
    /// How long the calls host waits for its wrapper to push a token it asked for, and the engine page for the SDK.
    static let pushWait: Double = 5
    /// A provider that has not answered in this long has answered nil.
    static let providerTimeout: Double = 15
    /// Each backoff after a failure is varied by up to this share, either way.
    static let backoffJitter = 0.2

    /// Refusals a fresh token can lift: a refresh, then the same request once more.
    static let refreshableCodes: Set<String> = ["token_required", "token_invalid", "token_expired"]
    /**
     * Every refusal for the token, the publishable key or the website bot
     * check: final for the request that met it — a conversation refused with
     * one is never tried another way.
     */
    static let refusalCodes: Set<String> = refreshableCodes.union(["token_scope", "key_revoked", "bot_check_failed"])

    /// What a token says about its own life, unverified: `iat` and `exp` in seconds since 1970; nil when not readable.
    struct Claims: Equatable {
        var iat: Double?
        var exp: Double?
    }

    /// `iat` and `exp` from the token's payload — the middle of its three parts, base64url JSON — or nils. Nothing else is read.
    static func decode(_ token: String?) -> Claims {
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines) else { return Claims() }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, !parts[1].isEmpty, let data = base64url(String(parts[1])),
              let object = JSON.object(from: data) else { return Claims() }
        func seconds(_ key: String) -> Double? {
            guard let raw = JSON.unwrap(object[key]), let number = JSON.number(raw), number.doubleValue.isFinite else { return nil }
            return number.doubleValue
        }
        return Claims(iat: seconds("iat"), exp: seconds("exp"))
    }

    /// base64url, with or without its padding.
    static func base64url(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let rest = s.count % 4
        if rest == 1 { return nil }
        if rest > 0 { s += String(repeating: "=", count: 4 - rest) }
        return Data(base64Encoded: s)
    }

    /**
     * WHEN A TOKEN LAPSES, BY THIS DEVICE'S CLOCK: `min(exp, receivedAt + lifetime)`
     * — a token the app's server cached keeps its real expiry, and a clock that
     * runs behind only refreshes early — or, when that is no more than 15 s
     * after it arrived (a clock far ahead, a stale token), `receivedAt +
     * lifetime`: the token is used and Graine judges it. Nil when the token has
     * no readable `iat` and `exp`, or no life between them: then nothing is
     * refreshed in the background, and only a refusal asks for another.
     */
    static func localExpiry(_ claims: Claims, receivedAt: Double) -> Double? {
        guard let life = lifetime(claims), let exp = claims.exp else { return nil }
        let local = min(exp, receivedAt + life)
        return local <= receivedAt + usableForConnection ? receivedAt + life : local
    }

    /// `exp − iat`; nil without both, or with no life between them.
    static func lifetime(_ claims: Claims) -> Double? {
        guard let iat = claims.iat, let exp = claims.exp, exp - iat > 0 else { return nil }
        return exp - iat
    }

    /// How long before it lapses a token is refreshed: `clamp(lifetime / 5, min(60, lifetime / 2), 600)`.
    static func lead(lifetime: Double) -> Double {
        max(min(60, lifetime / 2), min(lifetime / 5, 600))
    }

    /// The most a refresh is moved earlier, so a fleet does not refresh in step: `min(30, lifetime / 10)`.
    static func maxJitter(lifetime: Double) -> Double {
        min(30, lifetime / 10)
    }

    /// A new connection may go with a token that has more than 15 s left; one with no readable expiry always may.
    static func usable(localExp: Double?, now: Double) -> Bool {
        guard let exp = localExp else { return true }
        return exp - now > usableForConnection
    }

    /// The wait after the `failures`-th failure in a row, before its jitter: `min(60, 2^n)` seconds.
    static func backoff(failures: Int) -> Double {
        min(60, Double(1 << min(max(failures, 1), 6)))
    }

    /// The error code a refusal's body names, lower-cased; nil for none.
    static func code(_ body: Data?) -> String? {
        guard let object = JSON.object(from: body), let raw = JSON.unwrap(object["code"]) as? String else { return nil }
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return word.isEmpty ? nil : word
    }

    /// A refusal Graine can lift with a fresh token: the request is sent once more with one.
    static func refreshable(status: Int, body: Data?) -> Bool {
        guard !(200...299).contains(status), let word = code(body) else { return false }
        return refreshableCodes.contains(word)
    }

    /**
     * A refusal for the token, the key or the bot check — `refusalCodes` — as
     * the SDK's error, with Graine's sentence and its reason; nil for any
     * other answer, which goes where it always went.
     */
    static func refusal(status: Int, body: Data?) -> GraineServiceError? {
        refusal(status: status, object: JSON.object(from: body))
    }

    /// The same, for an answer already read as JSON.
    static func refusal(status: Int, object: [String: Any]?) -> GraineServiceError? {
        guard !(200...299).contains(status), let raw = JSON.unwrap(object?["code"]) as? String else { return nil }
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard refusalCodes.contains(word) else { return nil }
        let said = (JSON.unwrap(object?["error"]) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return GraineServiceError(
            code: GraineErrorCode(wire: word),
            message: said.flatMap { $0.isEmpty ? nil : $0 } ?? sentence(word),
            status: status,
            reason: GraineServiceError.reason(object)
        )
    }

    /// A call that could not start for one of `refusalCodes`: its error — the code first, then the sentence.
    static func callError(_ error: GraineServiceError) -> String {
        "\(error.code.wire): \(error.message)"
    }

    /// The SDK's own sentence for a refusal Graine sent without one.
    static func sentence(_ code: String) -> String {
        switch code {
        case "token_required": return "This agent requires a server token: set tokenProvider in GraineConfig."
        case "token_invalid": return "The server token could not be checked."
        case "token_expired": return "The server token expired, and a fresh one did not come in time."
        case "token_scope": return "The server token does not allow this."
        case "key_revoked": return "This publishable key was revoked. Update the app with the agent's new key."
        case "bot_check_failed": return "The bot check did not pass."
        default: return "Graine refused the request."
        }
    }
}

/**
 * ONE AGENT'S SERVER TOKENS (CLIENT-TOKENS.md §2.3): the newest token, when to
 * ask for the next, and everyone waiting for it.
 *
 *   at start        asked at once, in the background
 *   in the          at the token's local expiry, less the lead, less a jitter —
 *   background      never sooner than 30 s after the last token arrived; none
 *                   for a token with no readable expiry
 *   one at a time   one question to the provider at a time; every caller waits
 *                   on the one under way
 *   a failure       (nil, a throw, no answer in 15 s) asked again after 2, 4, 8,
 *                   16, 32, 60, 60… s, ±20 %; reset by a token
 *   the app away    nothing asked while the app is in the background; back in
 *                   front, asked when inside the lead
 *   a connection    (the session, a ticket, a call's credential) goes with the
 *                   token while it has more than 15 s left, else waits at most
 *                   10 s for a refresh, then goes with the newest it has
 *   a refusal       (token_required, token_expired, token_invalid) asks again —
 *                   at most once in 5 s — and the request goes once more, only
 *                   with a different token
 *   a ring          asked in the background before anyone answers
 *
 * Nothing here ever touches a live chat or call.
 *
 * WITHOUT A PROVIDER, a calls host (React Native, Flutter) may push the tokens
 * its own manager fetched (`push`); a refusal then asks it (`onNeed`, the
 * host's `needClientToken`) and waits at most 5 s for the next push. With
 * neither, tokens are not in play (`inPlay`) and no request carries one.
 *
 * Thread-safe; nothing blocks. Every answer (`forConnection`, `afterRefusal`,
 * `refreshForPage`) may come on any thread.
 */
final class ClientTokens: @unchecked Sendable {
    /// How the provider is asked: it hands its answer to `done` — once, from any thread; nil for none right now.
    typealias Fetch = (_ done: @escaping @Sendable (String?) -> Void) -> Void

    /// One question under way — to the provider, or to a calls host — and who waits for its answer. Under the lock.
    private final class Flight: @unchecked Sendable {
        let toHost: Bool
        var waiters: [(String?) -> Void] = []
        var cancelTimeout: CallTimer?
        var done = false
        /// Asked for the user before an identity change: its answer is not kept, and the question is asked again.
        var forUserBefore = false

        init(toHost: Bool) {
            self.toHost = toHost
        }
    }

    private let fetch: Fetch?
    private let clock: () -> Double
    private let random: () -> Double
    private let schedule: (_ seconds: Double, _ block: @escaping () -> Void) -> CallTimer
    private let background: (_ work: @escaping () -> Void) -> Void
    private let providerTimeout: Double
    private let connectionWait: Double
    private let pushWait: Double

    private let lock = NSLock()
    private var held: String?
    private var localExp: Double?
    private var lifetime: Double?
    /// This token's jitter, drawn when it arrived: its refresh moves earlier by it.
    private var jitter: Double = 0
    private var lastTokenAt: Double?
    private var lastForcedAt: Double?
    private var failures = 0
    private var flight: Flight?
    /// The background question armed, and its number: a timer that fires after it was replaced does nothing.
    private var timer: CallTimer?
    private var timerSeq = 0
    private var foreground = true
    private var pushedOnce = false
    private var watchers: [UUID: (String?) -> Void] = [:]
    private var ask: (() -> Void)?

    /**
     * - Parameters:
     *   - fetch: the app's provider; nil — a calls host pushes the tokens, or none are in play.
     *   - clock: the device's wall clock, in seconds since 1970: a token's life is read against it.
     *   - random: uniform in [0, 1): the jitter of a refresh and of a backoff.
     *   - schedule: runs a block after a delay, on any thread; returns what cancels it.
     *   - background: where the provider is asked — off the main thread, so a slow one holds up nothing.
     */
    init(
        fetch: Fetch?,
        clock: @escaping () -> Double = { Date().timeIntervalSince1970 },
        random: @escaping () -> Double = { Double.random(in: 0..<1) },
        schedule: @escaping (Double, @escaping () -> Void) -> CallTimer = ClientTokens.timer,
        background: @escaping (@escaping () -> Void) -> Void = { work in DispatchQueue.global(qos: .utility).async(execute: work) },
        providerTimeout: Double = ClientTokenRules.providerTimeout,
        connectionWait: Double = ClientTokenRules.connectionWait,
        pushWait: Double = ClientTokenRules.pushWait
    ) {
        self.fetch = fetch
        self.clock = clock
        self.random = random
        self.schedule = schedule
        self.background = background
        self.providerTimeout = providerTimeout
        self.connectionWait = connectionWait
        self.pushWait = pushWait
    }

    /// The timers every agent's tokens share: one queue, on the wall clock, so a phone that slept finds a refresh due.
    private static let queue = DispatchQueue(label: "ai.graine.inapp.tokens", qos: .utility)

    static func timer(_ seconds: Double, _ block: @escaping () -> Void) -> CallTimer {
        let item = DispatchWorkItem(block: block)
        queue.asyncAfter(wallDeadline: .now() + max(0, seconds), execute: item)
        return item
    }

    /**
     * The app's provider — an async function — as the manager asks it: started
     * off the main thread each time, its answer handed on once; a throw is nil.
     */
    static func fetch(async provider: @escaping @Sendable () async throws -> String?) -> Fetch {
        return { done in
            Task.detached(priority: .utility) {
                let token: String?
                do {
                    token = try await provider()
                } catch {
                    token = nil
                }
                done(token)
            }
        }
    }

    // MARK: - What the requests read

    /// The app gave a provider of its own: a calls host's pushes are ignored.
    var hasProvider: Bool { fetch != nil }

    /// Tokens are in play: the app gave a provider, or a calls host pushed one. Otherwise no request carries one — nothing changes.
    var inPlay: Bool {
        if fetch != nil { return true }
        lock.lock()
        defer { lock.unlock() }
        return pushedOnce
    }

    /// The newest token held — even one past its expiry: Graine may still take it, answering a ring within its grace.
    var newest: String? {
        lock.lock()
        defer { lock.unlock() }
        return held
    }

    /// The token's expiry by this device's clock, for the tests; nil without a token or a readable expiry.
    var localExpiry: Double? {
        lock.lock()
        defer { lock.unlock() }
        return localExp
    }

    /// Failures in a row since the last token, for the tests.
    var failuresInARow: Int {
        lock.lock()
        defer { lock.unlock() }
        return failures
    }

    /**
     * A calls host's way to ask its JavaScript or Dart manager for a token (the
     * `needClientToken` event), on any thread. Nil outside a host.
     */
    var onNeed: (() -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return ask
        }
        set {
            lock.lock()
            ask = newValue
            lock.unlock()
        }
    }

    /// The app's provider is asked at once, in the background.
    func start() {
        if fetch != nil { askNow(forced: false, then: nil) }
    }

    /// Hear every new token (nil: none) — the engine page is posted each. Returns what stops it.
    func onChange(_ watch: @escaping (String?) -> Void) -> () -> Void {
        let id = UUID()
        lock.lock()
        watchers[id] = watch
        lock.unlock()
        return { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.watchers.removeValue(forKey: id)
            self.lock.unlock()
        }
    }

    /**
     * THE TOKEN A NEW CONNECTION GOES WITH — the session, a ticket, a call's
     * credential: the one held while it has more than 15 s left; otherwise a
     * refresh, waited for at most 10 s, then the newest token there is (perhaps
     * none). A calls host's tokens are never waited for: it refreshes its own.
     */
    func forConnection(_ done: @escaping (String?) -> Void) {
        guard inPlay else { return done(nil) }
        lock.lock()
        let held = self.held
        let usable = held != nil && ClientTokenRules.usable(localExp: localExp, now: clock())
        lock.unlock()
        if usable || fetch == nil { return done(held) }
        wait(connectionWait, done) { [weak self] finished in self?.askNow(forced: false, then: finished) }
    }

    /**
     * A REQUEST CARRYING `sent` WAS REFUSED for its token (token_required,
     * token_expired, token_invalid): a fresh token is asked for — joining the
     * question under way, or asking anew at most once in 5 s — and waited for.
     * `done` hears the token to send the request again with, or nil when there
     * is none other than `sent`: nothing new could be had, and the refusal stands.
     */
    func afterRefusal(sent: String?, _ done: @escaping (String?) -> Void) {
        let limit: Double
        if fetch != nil {
            limit = connectionWait
        } else if onNeed != nil {
            limit = pushWait
        } else {
            return done(nil)
        }
        let answer: (String?) -> Void = { [weak self] _ in
            guard let now = self?.newest, now != sent else { return done(nil) }
            done(now)
        }
        guard mayAskAgain() else { return answer(nil) }
        wait(limit, answer) { [weak self] finished in self?.askNow(forced: true, then: finished) }
    }

    /**
     * The engine page asked for a token (`graine:need-client-token`): a fresh
     * one by the refusal rule, then `done` hears the newest — at once when none
     * may be asked for now. Always answered, with nil when there is none.
     */
    func refreshForPage(_ done: @escaping (String?) -> Void) {
        let canAsk = fetch != nil || onNeed != nil
        if canAsk && mayAskAgain() {
            askNow(forced: true, then: done)
        } else {
            done(newest)
        }
    }

    /**
     * A call is ringing: a fresh token is asked for in the background, so the
     * answer finds one — unless one arrived in the last 30 s or a question is
     * already under way. Only with the app's own provider.
     */
    func ring() {
        guard fetch != nil else { return }
        lock.lock()
        let busy = flight != nil
        let recent = lastTokenAt.map { clock() - $0 < ClientTokenRules.backgroundMinInterval } ?? false
        lock.unlock()
        guard !busy, !recent else { return }
        askNow(forced: false, then: nil)
    }

    /**
     * The app came to the front (true) or went to the background: nothing is
     * asked in the background; back in front, a token inside its lead — or
     * none, or one whose last question failed — is asked for (never sooner than
     * 30 s after the last token arrived), and any other is scheduled again.
     */
    func setForeground(_ inFront: Bool) {
        var now = false
        lock.lock()
        guard foreground != inFront else {
            lock.unlock()
            return
        }
        foreground = inFront
        guard inFront else {
            cancelTimer()
            lock.unlock()
            return
        }
        if fetch != nil, flight == nil {
            let at = clock()
            if held == nil || failures > 0 {
                now = true
            } else if let exp = localExp, let life = lifetime {
                if at >= exp - ClientTokenRules.lead(lifetime: life) {
                    let earliest = (lastTokenAt ?? at) + ClientTokenRules.backgroundMinInterval
                    if at >= earliest { now = true } else { arm(earliest - at) }
                } else {
                    armRefresh(at)
                }
            }
        }
        lock.unlock()
        if now { askNow(forced: false, then: nil) }
    }

    /**
     * A TOKEN A CALLS HOST PUSHED (CLIENT-TOKENS.md §2.4) — the newest its own
     * manager has; nil: none. It answers a question the host was asked, and is
     * sent from now on. Ignored when the app configured a provider of its own.
     */
    func push(_ token: String?) {
        guard fetch == nil else { return }
        let value = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = (value?.isEmpty ?? true) ? nil : value
        lock.lock()
        pushedOnce = true
        let changed = next != held
        if let next = next { accept(next, now: clock()) } else { forget() }
        let answering = flight?.toHost == true ? flight : nil
        lock.unlock()
        if changed { announce(next) }
        if let f = answering { finish(f, next) }
    }

    /**
     * WHO THE USER IS CHANGED — `identify` named another user, or nobody: the
     * token held was the last user's. It is let go (a sign-out sent before this
     * carried it), and a fresh one is asked for at once, in the background; a
     * question still under way for the user before is not kept, and asked
     * again. Only with the app's own provider: a calls host replaces its own.
     */
    func userChanged() {
        guard fetch != nil else { return }
        lock.lock()
        let had = held != nil
        forget()
        lastTokenAt = nil
        failures = 0
        cancelTimer()
        let under = flight
        under?.forUserBefore = true
        lock.unlock()
        if had { announce(nil) }
        if under == nil { askNow(forced: false, then: nil) }
    }

    // MARK: - Asking

    /// A refusal may ask for a token now: one is being asked for already (it is joined), or none was forced in the last 5 s.
    private func mayAskAgain() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if flight != nil { return true }
        guard let last = lastForcedAt else { return true }
        return clock() - last >= ClientTokenRules.forcedMinInterval
    }

    /**
     * One question at a time: `then` hears the newest token once the question
     * under way — or this one — has its answer. Asks the provider; without one,
     * the calls host (and waits for its push); with neither, answers at once.
     */
    private func askNow(forced: Bool, then: ((String?) -> Void)?) {
        let provider = fetch
        let host = provider == nil ? onNeed : nil
        if provider == nil && host == nil {
            then?(newest)
            return
        }
        let f = Flight(toHost: provider == nil)
        lock.lock()
        if let under = flight {
            if let then = then { under.waiters.append(then) }
            lock.unlock()
            return
        }
        if let then = then { f.waiters.append(then) }
        flight = f
        if forced { lastForcedAt = clock() }
        cancelTimer()
        // The answer's deadline before the question: an answer that comes at once finds it to cancel.
        if provider != nil {
            f.cancelTimeout = schedule(providerTimeout) { [weak self] in self?.finish(f, nil) }
        } else {
            // A host that pushes nothing in time leaves the request to go with what there is.
            f.cancelTimeout = schedule(pushWait) { [weak self] in self?.finish(f, self?.newest) }
        }
        lock.unlock()
        if let provider = provider {
            background { [weak self] in provider { token in self?.finish(f, token) } }
        } else {
            host?()
        }
    }

    /// The question `f` has its answer — the first one counts, a late one is ignored.
    private func finish(_ f: Flight, _ answer: String?) {
        var changed = false
        lock.lock()
        if f.done {
            lock.unlock()
            return
        }
        f.done = true
        if flight === f { flight = nil }
        f.cancelTimeout?.cancel()
        if f.forUserBefore {
            // The user changed while it was asked: not this user's token. Asked again, and its waiters wait for that.
            let waiting = f.waiters
            lock.unlock()
            askNow(forced: false) { token in for waiter in waiting { waiter(token) } }
            return
        }
        if !f.toHost {
            let now = clock()
            let value = answer?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let token = value, !token.isEmpty {
                changed = token != held
                accept(token, now: now)
                armRefresh(now)
            } else {
                failures += 1
                armBackoff()
            }
        }
        let newest = held
        let waiting = f.waiters
        lock.unlock()
        if changed { announce(newest) }
        for waiter in waiting { waiter(newest) }
    }

    /// Waits at most `limit` for the question `start` joins or asks; `done` hears the newest token then, once.
    private func wait(_ limit: Double, _ done: @escaping (String?) -> Void, start: (@escaping (String?) -> Void) -> Void) {
        let once = OnceLatch()
        var timeout: CallTimer?
        let over: () -> Void = { [weak self] in
            guard once.claim() else { return }
            timeout?.cancel()
            done(self?.newest)
        }
        timeout = schedule(limit) { over() }
        start { _ in over() }
    }

    // MARK: - The token held and its schedule (under the lock)

    private func accept(_ token: String, now: Double) {
        let claims = ClientTokenRules.decode(token)
        held = token
        lifetime = ClientTokenRules.lifetime(claims)
        localExp = ClientTokenRules.localExpiry(claims, receivedAt: now)
        jitter = lifetime.map { random() * ClientTokenRules.maxJitter(lifetime: $0) } ?? 0
        lastTokenAt = now
        failures = 0
    }

    private func forget() {
        held = nil
        localExp = nil
        lifetime = nil
        jitter = 0
    }

    /// The next refresh, in the background: the local expiry less the lead and the jitter, and never within 30 s of the last token.
    private func armRefresh(_ now: Double) {
        cancelTimer()
        guard fetch != nil, foreground, let exp = localExp, let life = lifetime else { return }
        let due = exp - ClientTokenRules.lead(lifetime: life) - jitter
        let earliest = (lastTokenAt ?? now) + ClientTokenRules.backgroundMinInterval
        arm(max(due, earliest) - now)
    }

    /// After a failure: 2, 4, 8, 16, 32, 60, 60… s, each ±20 % — in front only.
    private func armBackoff() {
        cancelTimer()
        guard fetch != nil, foreground else { return }
        let base = ClientTokenRules.backoff(failures: failures)
        arm(base * (1 + ClientTokenRules.backoffJitter * (2 * random() - 1)))
    }

    /// The background question, `delay` from now — replacing any other.
    private func arm(_ delay: Double) {
        cancelTimer()
        timerSeq += 1
        let mine = timerSeq
        timer = schedule(max(0, delay)) { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            // Replaced or cancelled while it was due: the newer one decides.
            guard self.timerSeq == mine, self.timer != nil else {
                self.lock.unlock()
                return
            }
            self.timer = nil
            let go = self.foreground && self.flight == nil
            self.lock.unlock()
            if go { self.askNow(forced: false, then: nil) }
        }
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
        timerSeq += 1
    }

    private func announce(_ token: String?) {
        lock.lock()
        let everyone = Array(watchers.values)
        lock.unlock()
        for watch in everyone { watch(token) }
    }
}

/// True for the first caller only, whichever thread it is on.
final class OnceLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}

/**
 * ONE REQUEST TO GRAINE WITH THE SERVER TOKEN (CLIENT-TOKENS.md §2.2): the body
 * carries the newest token as `clientToken` — a new connection's (the session,
 * a ticket, a call's credential) waits for a usable one first — and a refusal a
 * fresh token can lift is answered once: a refresh, and the same request again
 * with the token it brought (never with the same one). Without a manager the
 * body goes as it is; with tokens not in play it carries none.
 */
enum ClientTokenWire {
    /**
     * Any request: `send` posts the body it is handed and answers; `refreshable`
     * says whether an answer is a refusal a fresh token can lift. `done` hears
     * the last answer.
     */
    static func exchange<Answer>(
        _ tokens: ClientTokens?,
        body: Data,
        newConnection: Bool,
        refreshable: @escaping (Answer) -> Bool,
        send: @escaping (Data, @escaping (Answer) -> Void) -> Void,
        done: @escaping (Answer) -> Void
    ) {
        guard let tokens = tokens else { return send(body, done) }
        let go: (String?) -> Void = { first in
            send(carry(body, first)) { answer in
                guard refreshable(answer) else { return done(answer) }
                tokens.afterRefusal(sent: first) { next in
                    guard let next = next else { return done(answer) }
                    send(carry(body, next), done)
                }
            }
        }
        if !tokens.inPlay {
            go(nil)
        } else if newConnection {
            tokens.forConnection(go)
        } else {
            go(tokens.newest)
        }
    }

    /// An HTTP request: the status, the body and the answer's headers (names lower-cased).
    static func post(
        _ tokens: ClientTokens?,
        body: Data,
        newConnection: Bool,
        send: @escaping (Data, @escaping (Int, Data?, [String: String]) -> Void) -> Void,
        done: @escaping (Int, Data?, [String: String]) -> Void
    ) {
        exchange(
            tokens,
            body: body,
            newConnection: newConnection,
            refreshable: { (reply: HTTPReply) in ClientTokenRules.refreshable(status: reply.status, body: reply.data) },
            send: { json, answer in send(json) { status, data, headers in answer(HTTPReply(status: status, data: data, headers: headers)) } },
            done: { reply in done(reply.status, reply.data, reply.headers) }
        )
    }

    struct HTTPReply {
        let status: Int
        let data: Data?
        let headers: [String: String]
    }

    /// `body` — a JSON object — with `clientToken` as its last top-level field; unchanged without a token.
    static func carry(_ body: Data, _ token: String?) -> Data {
        guard let token = token else { return body }
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("{"), text.hasSuffix("}") else { return body }
        let open = String(text.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        let field = WireJSON.string(ClientTokenRules.field).text + ":" + WireJSON.string(token).text
        return Data((open + (open == "{" ? "" : ",") + field + "}").utf8)
    }
}
