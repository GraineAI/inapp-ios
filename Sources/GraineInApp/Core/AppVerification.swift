import Foundation
import Security

/*
 * PROVING THE APP, AND KEEPING WHAT GRAINE SAID (APP-IDENTITY.md §2–§3, §6).
 *
 * One per agent. It holds the agent's checks (the session's `security`), the
 * app pass and the user's verdicts, and it proves the app with App Attest:
 *
 *   challenge   POST /api/embed/app-verify/challenge → 48 base64url characters
 *   first time  generateKey → attestKey(key, SHA256(challenge)) → app-verify `attest`
 *   then        generateAssertion(key, SHA256(challenge)) → app-verify `assert`
 *   answers     a pass (24 h) kept in the Keychain for this publishable key;
 *               `challenge` → a new challenge, once; `unknown_key` or
 *               DCError.invalidKey → the key forgotten, a new one attested, once;
 *               Apple or Graine out of reach → the pass kept, tried again in
 *               30 s, 2 min, 10 min, then at the next foreground — and, when
 *               attestKey could not reach Apple and a pass is held (even an
 *               expired one), `{kind: "unavailable"}` asks for a grace pass
 *
 * DEVELOPMENT MODE (§3.6): a debug build sends its debug token on every request
 * INSTEAD of a proof — App Attest never runs; a release build never creates,
 * logs or sends one unless the app says `always`.
 *
 * Before a ticket or a call session (`beforeConversation`): under "Require a
 * verified app" with no pass, a proof is waited for (10 s at most); a JWT
 * identity token less than a minute from its `exp` is refreshed first. A
 * refusal (`cure`): `app_not_verified` proves the app and asks once more;
 * `identity_unverified` asks the app's refresher and asks once more.
 *
 * Foundation and Security only: App Attest is behind `AppAttesting`, the
 * Keychain behind the stores, the clock behind `Environment`. Thread-safe.
 */

// MARK: - The seams

/// Apple's App Attest (`DCAppAttestService` on a device, AppAttestDevice.swift). Tests stand in for it.
protocol AppAttesting: AnyObject {
    var isSupported: Bool { get }
    func generateKey(_ done: @escaping (Result<String, AppAttestFailure>) -> Void)
    func attestKey(_ keyId: String, clientDataHash: Data, _ done: @escaping (Result<Data, AppAttestFailure>) -> Void)
    func generateAssertion(_ keyId: String, clientDataHash: Data, _ done: @escaping (Result<Data, AppAttestFailure>) -> Void)
}

enum AppAttestFailure: Error, Equatable {
    /// `DCError.invalidKey`: the key is gone (a restore to another phone) — a new one is made and attested.
    case invalidKey
    /// `DCError.serverUnavailable`: Apple could not be reached from the device.
    case serverUnavailable
    /// App Attest cannot run here.
    case unsupported
    case failed(String)
}

/// The app pass as it is kept: for one publishable key, with the verdict it was issued with and its expiry.
struct StoredAppPass: Equatable, Codable {
    var publishableKey: String
    var pass: String
    /// `verified` or `test_build`, as the wire said.
    var verdict: String
    /// Seconds since 1970.
    var expiresAt: Double
}

/// Where an agent's app pass lives between launches: the Keychain on a device, memory in tests.
protocol AppPassStore: AnyObject {
    func read() -> StoredAppPass?
    /// Nil deletes it.
    func write(_ pass: StoredAppPass?)
}

/// Where the App Attest key id lives: `UserDefaults` — never the Keychain, whose items outlive the key (§3.4).
protocol AttestKeyStore: AnyObject {
    func read() -> (keyId: String, attested: Bool)?
    /// Nil forgets it.
    func write(_ keyId: String?, attested: Bool)
}

/**
 * THE APP PASS IN THE KEYCHAIN: one item per agent, holding the publishable
 * key it was issued for — a pass for another key is dropped, never sent
 * (§3.3: cleared when the key changes). This device only, after the first
 * unlock (a ring can wake the app before anyone opens it).
 */
final class KeychainAppPassStore: AppPassStore {
    static let service = "ai.graine.inapp.app-pass"
    private let account: String

    init(agent: String) {
        account = agent
    }

    func read() -> StoredAppPass? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(StoredAppPass.self, from: data)
    }

    func write(_ pass: StoredAppPass?) {
        guard let pass = pass, let data = try? JSONEncoder().encode(pass) else {
            SecItemDelete(baseQuery as CFDictionary)
            return
        }
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        guard status == errSecItemNotFound else { return }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainAppPassStore.service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

/// An app pass that lives as long as the process: tests.
final class MemoryAppPassStore: AppPassStore {
    var value: StoredAppPass?
    private(set) var writes = 0

    init(_ value: StoredAppPass? = nil) {
        self.value = value
    }

    func read() -> StoredAppPass? { value }

    func write(_ pass: StoredAppPass?) {
        writes += 1
        value = pass
    }
}

/**
 * THE APP ATTEST KEY ID, in the SDK's `UserDefaults` keys: per publishable
 * key, so two agents of different workspaces in one app never undo each
 * other's key (a server that does not know a key answers `unknown_key`, and
 * a key shared between them would be replaced back and forth). The Secure
 * Enclave key does not survive a reinstall or a restore to another phone, and
 * neither do these defaults.
 */
final class DefaultsAttestKeyStore: AttestKeyStore {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults, publishableKey: String) {
        self.defaults = defaults
        key = "ai.graine.inapp.app-attest." + MemoryChoices.hash(field: "app-attest", value: publishableKey)
    }

    func read() -> (keyId: String, attested: Bool)? {
        guard let entry = defaults.dictionary(forKey: key), let id = entry["keyId"] as? String, !id.isEmpty else { return nil }
        return (id, (entry["attested"] as? Bool) ?? false)
    }

    func write(_ keyId: String?, attested: Bool) {
        guard let id = keyId else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(["keyId": id, "attested": attested], forKey: key)
    }
}

/// A key id that lives as long as the process: tests.
final class MemoryAttestKeyStore: AttestKeyStore {
    var value: (keyId: String, attested: Bool)?

    init(_ value: (keyId: String, attested: Bool)? = nil) {
        self.value = value
    }

    func read() -> (keyId: String, attested: Bool)? { value }

    func write(_ keyId: String?, attested: Bool) {
        value = keyId.map { ($0, attested) }
    }
}

/**
 * THE INSTALL'S DEBUG TOKEN (§3.6), kept with the install id in the Keychain:
 * made once per install from 24 random bytes, read back on every launch. A
 * Keychain that will not keep it gives this launch one of its own.
 */
enum DebugTokenVault {
    static func resolve(_ store: InstallIdStore, random: (Int) -> [UInt8]) -> String {
        if let kept = store.read(), DebugToken.isValid(kept) { return kept }
        let made = DebugToken.make(random(24))
        _ = store.write(made)
        return made
    }
}

// MARK: - What the conversation's routes ask

/// The app's and the user's proofs, for the requests that start a conversation and the routes that need the customer.
protocol EmbedProof: EmbedCredentials {
    /// Before a ticket or call-session request: what is worth waiting for, waited for (10 s at most). `ready` once; any thread.
    func beforeConversation(_ ready: @escaping () -> Void)
    /// An answer (or a refusal) from Graine: its `verification` kept. `identityValue`: who the request named.
    func heard(status: Int, body: [String: Any]?, identityValue: String?)
    /// A refusal that proving the app or a fresh identity token may cure: `retry(true)` once it is cured — then the request goes once more.
    func cure(_ error: GraineServiceError, _ retry: @escaping (Bool) -> Void)
}

// MARK: - The engine

final class AppVerification: EmbedProof {
    /// Everything it reads from the device, handed in so tests can stand in for each.
    struct Environment {
        var bundleId: () -> String? = { Bundle.main.bundleIdentifier }
        var team: TeamIdSource = KeychainTeamIdProbe.shared
        var attest: AppAttesting? = AppAttestDevice.make()
        /// This build is a debug one (`DEBUG`, or the Simulator) — development mode's `automatic`.
        var debugBuild: Bool = DebugToken.isDebugBuild
        var now: () -> Date = Date.init
        var after: (TimeInterval, @escaping () -> Void) -> Void = { seconds, block in
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: block)
        }
        var log: (String) -> Void = { GraineLog.info($0) }
        var warn: (String) -> Void = { GraineLog.warning($0) }
    }

    /// POST to an embed route with the body sealed (`declaration`: the `app` object to send instead of the current one), no cure.
    typealias Send = (_ path: String, _ fields: [(String, WireJSON)], _ declaration: AppDeclaration?,
                      _ done: @escaping (Result<[String: Any], GraineServiceError>) -> Void) -> Void

    /// Apple's own schedule for an outage (§3.2): 30 s, 2 min, 10 min, then the next time the app comes to the foreground.
    static let outageDelays: [TimeInterval] = [30, 120, 600]
    /// How long a conversation's start waits for a proof or a fresh token.
    static let conversationWait: TimeInterval = 10
    /// A pass with less than this left is renewed in the background (on launch, the foreground, a ring).
    static let refreshWithin: TimeInterval = 21_600
    /// A rate limit that did not say for how long.
    static let rateLimitWait: TimeInterval = 60

    let publishableKey: String
    private let env: Environment
    private let identity: IdentityState
    private let passes: AppPassStore
    private let keys: AttestKeyStore
    private let installId: () -> String
    private let debugTokenSource: () -> String
    private let defaults: UserDefaults

    /// The routes app-verify is asked on. Set by the agent, which owns the network.
    var send: Send?
    /// Ask the app's identity-token refresher (shared by every agent): `done(changed)`. Set by the agent.
    var refreshToken: ((@escaping (Bool) -> Void) -> Void)?
    /// The app has a refresher to ask.
    var hasRefresher: () -> Bool = { false }
    /// The public state changed. Any thread.
    var onChange: ((GraineVerification) -> Void)?
    /// A proof brought a new pass: what was prepared without one may be asked again.
    var onProven: (() -> Void)?

    private let lock = NSLock()
    private var security = SessionSecurity.none
    private var securityKnown = false
    private var modeValue: GraineDebugTokenMode
    private var passLoaded = false
    private var heldPass: StoredAppPass?
    private var app: (verdict: GraineAppVerdict, reason: String?) = (.off, nil)
    private var user: (verdict: GraineUserVerdict, reason: String?) = (.off, nil)
    private var published = GraineVerification()
    private var proving = false
    private var waiters: [(GraineAppVerdict) -> Void] = []
    /// Proofs in a row that Apple or Graine could not take (the outage ladder).
    private var failures = 0
    /// A retry is scheduled: background proofs wait for it.
    private var retryPending = false
    /// The ladder is spent: the next foreground tries again.
    private var waitingForForeground = false
    private var retryGeneration = 0
    private var debugTokenValue: String?
    private var unsupportedSaid = false

    init(
        publishableKey: String,
        identity: IdentityState,
        passes: AppPassStore,
        keys: AttestKeyStore,
        installId: @escaping () -> String,
        debugToken: @escaping () -> String,
        defaults: UserDefaults,
        mode: GraineDebugTokenMode = .automatic,
        environment: Environment = Environment()
    ) {
        self.publishableKey = publishableKey
        self.identity = identity
        self.passes = passes
        self.keys = keys
        self.installId = installId
        self.debugTokenSource = debugToken
        self.defaults = defaults
        self.modeValue = mode
        self.env = environment
    }

    // MARK: - State

    var verification: GraineVerification {
        lock.lock()
        defer { lock.unlock() }
        return published
    }

    var mode: GraineDebugTokenMode {
        get {
            lock.lock()
            defer { lock.unlock() }
            return modeValue
        }
        set {
            lock.lock()
            modeValue = newValue
            lock.unlock()
        }
    }

    /// Development mode is on for this build: the debug token goes instead of a proof.
    var developmentMode: Bool {
        DebugToken.inUse(mode: mode, debugBuild: env.debugBuild)
    }

    /// The install's debug token while development mode is on — made (and logged, once per install) the first time; nil otherwise.
    var debugToken: String? {
        guard developmentMode else { return nil }
        lock.lock()
        if let known = debugTokenValue {
            lock.unlock()
            return known
        }
        lock.unlock()
        let token = debugTokenSource()
        lock.lock()
        let first = debugTokenValue == nil
        if first { debugTokenValue = token }
        lock.unlock()
        if first { logOnce(token) }
        return token
    }

    /// Once per install (the SDK's defaults remember it), the sentence a developer registers the token from.
    private func logOnce(_ token: String) {
        let key = "ai.graine.inapp.debug-token-logged"
        let mark = MemoryChoices.hash(field: "debug-token", value: token)
        guard defaults.string(forKey: key) != mark else { return }
        defaults.set(mark, forKey: key)
        env.log(DebugToken.logLine(token))
    }

    /// The pass for this key, when one is held and unexpired at `now`. Under the lock.
    private func validPassLocked(_ now: Date) -> StoredAppPass? {
        guard let pass = storedPassLocked(), pass.expiresAt > now.timeIntervalSince1970 else { return nil }
        return pass
    }

    /// The pass held for this key, expired or not; one kept for another key is dropped. Under the lock.
    private func storedPassLocked() -> StoredAppPass? {
        if !passLoaded {
            passLoaded = true
            heldPass = passes.read()
            if let kept = heldPass, kept.publishableKey != publishableKey {
                heldPass = nil
                passes.write(nil)
            }
        }
        return heldPass
    }

    private var attestSupported: Bool { env.attest?.isSupported ?? false }

    /// A proof is due: the agent checks the app, this build proves itself, and no pass has six hours left.
    func needsProof(now: Date) -> Bool {
        guard attestSupported, !developmentMode else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard securityKnown, security.proves else { return false }
        guard let pass = validPassLocked(now) else { return true }
        return pass.expiresAt - now.timeIntervalSince1970 < AppVerification.refreshWithin
    }

    /// The agent refuses this install without a pass ("Require a verified app"), none is held, and a proof can bring one.
    func awaitingRequiredProof() -> Bool {
        guard attestSupported, !developmentMode else { return false }
        let now = env.now()
        lock.lock()
        defer { lock.unlock() }
        return securityKnown && security.waitsForProof && validPassLocked(now) == nil
    }

    /// The pass this install holds now, when unexpired (for tests and the declaration).
    func currentPass(now: Date) -> StoredAppPass? {
        lock.lock()
        defer { lock.unlock() }
        return validPassLocked(now)
    }

    private func publish() {
        lock.lock()
        let next = GraineVerification(app: app.verdict, appReason: app.reason, user: user.verdict, userReason: user.reason)
        let changed = next != published
        published = next
        lock.unlock()
        if changed { onChange?(next) }
    }

    /// The verdict a held pass gives, or unverified (`missing` / `expired`). Under the lock.
    private func heldVerdictLocked(_ now: Date) -> (GraineAppVerdict, String?) {
        if let pass = validPassLocked(now) { return (GraineAppVerdict(wire: pass.verdict) ?? .verified, nil) }
        return (.unverified, storedPassLocked() == nil ? "missing" : "expired")
    }

    // MARK: - EmbedCredentials

    func appDeclaration() -> AppDeclaration? {
        guard let id = env.bundleId(), !id.isEmpty else { return nil }
        let now = env.now()
        lock.lock()
        let pass = validPassLocked(now)?.pass
        lock.unlock()
        return AppDeclaration(id: id, team: env.team.known, pass: pass, debugToken: debugToken)
    }

    func identityProof(for value: String) -> IdentityProof {
        identity.proof(for: value, now: env.now())
    }

    /// `done` once the Team ID has been read (at once after the first time): the declaration then carries it.
    func whenDeclarationReady(_ done: @escaping () -> Void) {
        env.team.whenRead { _ in done() }
    }

    // MARK: - The session

    /// The session said what the agent checks. Proves the app in the background when a proof is due.
    func sessionArrived(_ next: SessionSecurity) {
        let now = env.now()
        lock.lock()
        security = next
        securityKnown = true
        if !next.proves {
            app = (.off, nil)
        } else if !proving && (app.verdict == .off || app.verdict == .checking) {
            app = heldVerdictLocked(now)
        }
        if next.userVerify == .off {
            user = (.off, nil)
        } else if user.verdict == .off {
            user = (.unverified, nil)
        }
        lock.unlock()
        publish()
        if next.proves, developmentMode {
            // Development mode: made (and logged once per install) now, so the developer sees it before the first conversation.
            _ = debugToken
        } else if next.proves, !attestSupported {
            sayUnsupportedOnce()
        }
        if needsProof(now: now) { prove() }
    }

    private func sayUnsupportedOnce() {
        lock.lock()
        let first = !unsupportedSaid
        unsupportedSaid = true
        lock.unlock()
        if first {
            env.warn("App Attest is not available on this device, so this install cannot prove it is your app. "
                + "A debug build uses its debug token instead (debugTokenMode).")
        }
    }

    /**
     * The checks the last session kept on the device said — used only until
     * this launch's session arrives: a ring that woke a closed app proves the
     * app before the person answers, as one in a running app does.
     */
    func sessionCached(_ kept: SessionSecurity) {
        lock.lock()
        defer { lock.unlock() }
        guard !securityKnown else { return }
        security = kept
        securityKnown = true
    }

    /// The identity changed: the user's verdict was another person's.
    func identityChanged() {
        lock.lock()
        if securityKnown, security.userVerify != .off {
            user = (.unverified, nil)
        } else {
            user = (.off, nil)
        }
        lock.unlock()
        publish()
    }

    // MARK: - Proving

    /**
     * Prove the app now, or join the proof on its way; `done` hears the
     * verdict it came to. `force` — someone is waiting (a conversation, a
     * ring, `prepareAppVerification`) — goes even while an outage's retry is
     * scheduled; a background proof waits for it.
     */
    func prove(force: Bool = false, required: Bool = false, _ done: ((GraineAppVerdict) -> Void)? = nil) {
        lock.lock()
        let attest = env.attest
        // `required`: Graine refused this install for want of a proof — the agent checks the app, whatever is known of its settings.
        let checks = required || (securityKnown && security.proves)
        let ready = checks && !DebugToken.inUse(mode: modeValue, debugBuild: env.debugBuild) && attest?.isSupported == true
        guard ready, let attest = attest, force || proving || !(retryPending || waitingForForeground) else {
            let verdict = app.verdict
            lock.unlock()
            done?(verdict)
            return
        }
        if let done = done { waiters.append(done) }
        if proving {
            lock.unlock()
            return
        }
        proving = true
        app = (.checking, nil)
        lock.unlock()
        publish()
        proofRound(attest, Round())
    }

    /// What one proof has already tried once.
    private struct Round {
        var challengeRetried = false
        var keyRenewed = false
        var graceAsked = false
    }

    private func proofRound(_ attest: AppAttesting, _ round: Round) {
        challenge { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                self.refused(error, attest: attest, round: round)
            case .success(let challenge):
                let hash = AppAttestWire.clientDataHash(challenge)
                if let kept = self.keys.read() {
                    if kept.attested {
                        self.assertKey(attest, kept.keyId, challenge: challenge, hash: hash, round: round)
                    } else {
                        self.attestKey(attest, kept.keyId, challenge: challenge, hash: hash, round: round)
                    }
                } else {
                    self.newKey(attest, challenge: challenge, hash: hash, round: round)
                }
            }
        }
    }

    private func challenge(_ done: @escaping (Result<String, GraineServiceError>) -> Void) {
        guard let send = send else {
            return done(.failure(GraineServiceError(code: .unavailable, message: "No network for the app's proof.")))
        }
        send("/api/embed/app-verify/challenge", [("installId", .string(installId()))], nil) { result in
            switch result {
            case .success(let body):
                let challenge = JSON.unwrap(body["challenge"]) as? String
                guard AppAttestWire.isChallenge(challenge), let found = challenge else {
                    return done(.failure(GraineServiceError(code: .unavailable, message: "The challenge was not readable.", status: 200)))
                }
                done(.success(found))
            case .failure(let error):
                done(.failure(error))
            }
        }
    }

    private func newKey(_ attest: AppAttesting, challenge: String, hash: Data, round: Round) {
        attest.generateKey { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let keyId):
                self.keys.write(keyId, attested: false)
                self.attestKey(attest, keyId, challenge: challenge, hash: hash, round: round)
            case .failure(let failure):
                self.deviceFailed(failure, attest: attest, round: round)
            }
        }
    }

    private func attestKey(_ attest: AppAttesting, _ keyId: String, challenge: String, hash: Data, round: Round) {
        attest.attestKey(keyId, clientDataHash: hash) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let attestation):
                let proof: [(String, WireJSON)] = [
                    ("kind", .string("attest")), ("keyId", .string(keyId)), ("attestation", .string(attestation.base64EncodedString())),
                ]
                self.verify(challenge: challenge, proof: proof, attest: attest, round: round) {
                    self.keys.write(keyId, attested: true)
                }
            case .failure(.invalidKey):
                self.renewKey(attest, challenge: challenge, hash: hash, round: round)
            case .failure(let failure):
                self.deviceFailed(failure, attest: attest, round: round)
            }
        }
    }

    private func assertKey(_ attest: AppAttesting, _ keyId: String, challenge: String, hash: Data, round: Round) {
        attest.generateAssertion(keyId, clientDataHash: hash) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let assertion):
                let proof: [(String, WireJSON)] = [
                    ("kind", .string("assert")), ("keyId", .string(keyId)), ("assertion", .string(assertion.base64EncodedString())),
                ]
                self.verify(challenge: challenge, proof: proof, attest: attest, round: round, accepted: nil)
            case .failure(.invalidKey):
                self.renewKey(attest, challenge: challenge, hash: hash, round: round)
            case .failure(let failure):
                self.deviceFailed(failure, attest: attest, round: round)
            }
        }
    }

    /// The key is gone: forgotten, and — once per proof — a new one made and attested with the same, unused challenge.
    private func renewKey(_ attest: AppAttesting, challenge: String, hash: Data, round: Round) {
        keys.write(nil, attested: false)
        guard !round.keyRenewed else { return finish(.unverified, reason: "invalid", proven: false) }
        var next = round
        next.keyRenewed = true
        newKey(attest, challenge: challenge, hash: hash, round: next)
    }

    /// App Attest itself failed on the device.
    private func deviceFailed(_ failure: AppAttestFailure, attest: AppAttesting, round: Round) {
        switch failure {
        case .serverUnavailable:
            // Apple out of reach: a grace pass when this install was proven before (§3.2 "Outage grace"); the ladder either way.
            askForGrace(round: round)
        case .unsupported:
            sayUnsupportedOnce()
            finish(.unverified, reason: nil, proven: false)
        case .invalidKey, .failed:
            outage()
        }
    }

    /// `proof: {kind: "unavailable"}` with the pass held, even an expired one — once per proof; no pass, no grace.
    private func askForGrace(round: Round) {
        lock.lock()
        let held = storedPassLocked()
        lock.unlock()
        guard let pass = held, !round.graceAsked, let send = send, let id = env.bundleId(), !id.isEmpty else { return outage() }
        let declaration = AppDeclaration(id: id, team: env.team.known, pass: pass.pass, debugToken: nil)
        let fields: [(String, WireJSON)] = [("installId", .string(installId())), ("proof", .object([("kind", .string("unavailable"))]))]
        send("/api/embed/app-verify", fields, declaration) { [weak self] result in
            guard let self = self else { return }
            if case .success(let body) = result, self.keepPass(from: body) != nil {
                // A grace pass: used like any other. App Attest is tried again on the ladder.
                self.scheduleOutageRetry()
                return self.finishWithHeldPass(newPass: true)
            }
            self.outage()
        }
    }

    /// The proof to Graine. `accepted` runs on a pass (the key is then known to Graine).
    private func verify(challenge: String, proof: [(String, WireJSON)], attest: AppAttesting, round: Round, accepted: (() -> Void)?) {
        guard let send = send else { return outage() }
        let fields: [(String, WireJSON)] = [
            ("installId", .string(installId())), ("challenge", .string(challenge)), ("proof", .object(proof)),
        ]
        send("/api/embed/app-verify", fields, nil) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let body):
                guard let verdict = self.keepPass(from: body) else {
                    let said = VerificationAnswer.parse(body["verification"])?.app.flatMap { GraineAppVerdict(wire: $0) }
                    return self.finish(said ?? .unverified, reason: nil, proven: false)
                }
                accepted?()
                self.resetOutage()
                self.finish(verdict, reason: nil, proven: true)
            case .failure(let error):
                self.refused(error, attest: attest, round: round)
            }
        }
    }

    /// Keep the pass an app-verify answer carries; its verdict, or nil when it carries none.
    @discardableResult
    private func keepPass(from body: [String: Any]) -> GraineAppVerdict? {
        guard let answer = VerificationAnswer.parse(body["verification"]) else { return nil }
        return keepPass(answer)
    }

    /// Keep an answer's app pass — one issued with a verdict that passes (`verified`, `test_build`) — for this key, until it expires.
    @discardableResult
    private func keepPass(_ answer: VerificationAnswer) -> GraineAppVerdict? {
        guard let pass = answer.appPass, !pass.isEmpty, let word = answer.app,
              let verdict = GraineAppVerdict(wire: word), verdict == .verified || verdict == .testBuild else { return nil }
        let life = answer.appPassExpiresIn ?? Double(86_400)
        let kept = StoredAppPass(publishableKey: publishableKey, pass: pass, verdict: word.lowercased(), expiresAt: env.now().timeIntervalSince1970 + life)
        lock.lock()
        passLoaded = true
        heldPass = kept
        lock.unlock()
        passes.write(kept)
        return verdict
    }

    /// A refusal of the challenge or the proof.
    private func refused(_ error: GraineServiceError, attest: AppAttesting, round: Round) {
        switch error.code {
        case .appNotVerified:
            switch error.reason {
            case "challenge"? where !round.challengeRetried:
                var next = round
                next.challengeRetried = true
                proofRound(attest, next)
            case "unknown_key"? where !round.keyRenewed:
                // Graine does not know the key (a reinstall restored the id without the key): a new key, attested.
                keys.write(nil, attested: false)
                var next = round
                next.keyRenewed = true
                proofRound(attest, next)
            default:
                finish(.unverified, reason: error.reason, proven: false)
            }
        case .rateLimited:
            scheduleRetry(after: error.retryAfterSeconds.map(Double.init) ?? AppVerification.rateLimitWait)
            finishWithHeldPass(newPass: false)
        case .unavailable, .network:
            outage()
        default:
            if error.status >= 500 { return outage() }
            finish(.unverified, reason: error.reason ?? (error.code == .appNotAllowed ? error.code.wire : nil), proven: false)
        }
    }

    /// Apple or Graine could not be reached: the pass is kept and the ladder climbs.
    private func outage() {
        scheduleOutageRetry()
        finishWithHeldPass(newPass: false)
    }

    /// The proof is over with the pass held now: its verdict, or unverified (`missing` / `expired`).
    private func finishWithHeldPass(newPass: Bool) {
        lock.lock()
        let held = heldVerdictLocked(env.now())
        lock.unlock()
        finish(held.0, reason: held.1, proven: newPass && held.0 != .unverified)
    }

    private func finish(_ verdict: GraineAppVerdict, reason: String?, proven: Bool) {
        lock.lock()
        proving = false
        app = (verdict, verdict == .unverified ? reason : nil)
        let ready = waiters
        waiters = []
        lock.unlock()
        publish()
        ready.forEach { $0(verdict) }
        if proven { onProven?() }
    }

    // MARK: - The outage ladder

    private func resetOutage() {
        lock.lock()
        failures = 0
        waitingForForeground = false
        lock.unlock()
    }

    private func scheduleOutageRetry() {
        lock.lock()
        failures += 1
        guard failures <= AppVerification.outageDelays.count else {
            waitingForForeground = true
            retryPending = false
            lock.unlock()
            return
        }
        let delay = AppVerification.outageDelays[failures - 1]
        lock.unlock()
        scheduleRetry(after: delay)
    }

    private func scheduleRetry(after seconds: TimeInterval) {
        lock.lock()
        retryPending = true
        retryGeneration += 1
        let mine = retryGeneration
        lock.unlock()
        env.after(seconds) { [weak self] in self?.retryDue(mine) }
    }

    private func retryDue(_ generation: Int) {
        lock.lock()
        guard generation == retryGeneration, retryPending else {
            lock.unlock()
            return
        }
        retryPending = false
        lock.unlock()
        if needsProof(now: env.now()) { prove() }
    }

    /// The app came back to the foreground: a spent ladder starts again, and a pass with less than six hours left is renewed.
    func foregroundReturned() {
        lock.lock()
        let wasWaiting = waitingForForeground
        waitingForForeground = false
        if wasWaiting {
            failures = 0
            retryPending = false
            retryGeneration += 1
        }
        lock.unlock()
        if needsProof(now: env.now()) { prove() }
    }

    /// A ring arrived (§6): the proof renewed now, before the person answers, whatever an outage's ladder says.
    func ringArrived() {
        if needsProof(now: env.now()) { prove(force: true) }
    }

    /// `prepareAppVerification()`: the verdict once a due proof is done. Off for an agent that does not check the app.
    func prepare(_ done: @escaping (GraineAppVerdict) -> Void) {
        let now = env.now()
        lock.lock()
        let checks = securityKnown && security.proves
        let current = app.verdict
        lock.unlock()
        guard checks else { return done(.off) }
        if developmentMode || !attestSupported {
            if !attestSupported && !developmentMode { sayUnsupportedOnce() }
            return done(current == .checking ? .unverified : current)
        }
        if !needsProof(now: now) {
            lock.lock()
            let held = heldVerdictLocked(now).0
            lock.unlock()
            return done(held)
        }
        prove(force: true, done)
    }

    // MARK: - EmbedProof

    func beforeConversation(_ ready: @escaping () -> Void) {
        let now = env.now()
        lock.lock()
        let waitProof = securityKnown && security.waitsForProof && validPassLocked(now) == nil
        lock.unlock()
        let proofDue = waitProof && attestSupported && !developmentMode
        let tokenDue = hasRefresher() && IdentityTokenRules.expiresSoon(identity.currentToken(), now: now)
        guard proofDue || tokenDue else { return ready() }
        let gate = Countdown(proofDue && tokenDue ? 2 : 1, ready)
        env.after(AppVerification.conversationWait) { gate.fire() }
        if proofDue { prove(force: true) { _ in gate.tick() } }
        if tokenDue, let refresh = refreshToken {
            refresh { _ in gate.tick() }
        } else if tokenDue {
            gate.tick()
        }
    }

    func heard(status: Int, body: [String: Any]?, identityValue: String?) {
        if (200...299).contains(status) {
            guard let answer = VerificationAnswer.parse(body?["verification"]) else { return }
            apply(answer, identityValue: identityValue)
            return
        }
        guard let word = JSON.nonEmpty(body?["code"]) else { return }
        switch GraineErrorCode(wire: word) {
        case .appNotVerified:
            lock.lock()
            if !proving { app = (.unverified, JSON.nonEmpty(body?["reason"])) }
            lock.unlock()
            publish()
        case .identityUnverified:
            lock.lock()
            user = (.unverified, JSON.nonEmpty(body?["reason"]) ?? user.reason)
            lock.unlock()
            publish()
        default:
            break
        }
    }

    private func apply(_ answer: VerificationAnswer, identityValue: String?) {
        let now = env.now()
        lock.lock()
        if let word = answer.app, let verdict = GraineAppVerdict(wire: word), !proving {
            // An answer's verdict carries no reason of its own: none is kept from before.
            app = (verdict, nil)
        }
        if let word = answer.user, let verdict = GraineUserVerdict(wire: word) {
            user = (verdict, verdict == .unverified || verdict == .invalid ? answer.userReason : nil)
        }
        lock.unlock()
        if let pass = answer.userPass, !pass.isEmpty, let value = identityValue {
            let life = answer.userPassExpiresIn ?? Double(3_600)
            identity.keepUserPass(pass, expiresAt: now.addingTimeInterval(life), for: value)
        }
        // Passes come from app-verify; one on any other answer is kept the same way.
        keepPass(answer)
        publish()
        // The token ran out: a fresh one is asked for in the background, for the next conversation.
        if answer.user == "invalid", answer.userReason == "expired", let refresh = refreshToken {
            refresh { _ in }
        }
    }

    func cure(_ error: GraineServiceError, _ retry: @escaping (Bool) -> Void) {
        switch error.code {
        case .appNotVerified:
            lock.lock()
            if !proving { app = (.unverified, error.reason) }
            let before = storedPassLocked()?.pass
            lock.unlock()
            publish()
            guard attestSupported, !developmentMode else { return retry(false) }
            // Proved, then asked once more — only with a new pass to show for it, and within ten seconds.
            let once = Once(retry)
            env.after(AppVerification.conversationWait) { once.call(false) }
            prove(force: true, required: true) { [weak self] _ in
                guard let self = self else { return once.call(false) }
                let now = self.env.now()
                self.lock.lock()
                let after = self.validPassLocked(now)?.pass
                self.lock.unlock()
                once.call(after != nil && after != before)
            }
        case .identityUnverified:
            lock.lock()
            user = (.unverified, error.reason ?? user.reason)
            lock.unlock()
            publish()
            guard let refresh = refreshToken, hasRefresher() else { return retry(false) }
            let once = Once(retry)
            env.after(AppVerification.conversationWait) { once.call(false) }
            refresh { changed in once.call(changed) }
        default:
            retry(false)
        }
    }
}

// MARK: - Small things that run once

/// A callback that runs at most once, whichever of several paths reaches it first. Thread-safe (its lock).
final class Once<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var block: ((Value) -> Void)?

    init(_ block: @escaping (Value) -> Void) {
        self.block = block
    }

    func call(_ value: Value) {
        lock.lock()
        let run = block
        block = nil
        lock.unlock()
        run?(value)
    }
}

/// `done` once `count` ticks have arrived, or at the first `fire()`. Thread-safe (its lock).
final class Countdown: @unchecked Sendable {
    private let lock = NSLock()
    private var left: Int
    private var done: (() -> Void)?

    init(_ count: Int, _ done: @escaping () -> Void) {
        left = count
        self.done = done
    }

    func tick() {
        lock.lock()
        left -= 1
        let run = left <= 0 ? done : nil
        if run != nil { done = nil }
        lock.unlock()
        run?()
    }

    func fire() {
        lock.lock()
        let run = done
        done = nil
        lock.unlock()
        run?()
    }
}

// MARK: - Where an agent keeps it

/**
 * Where an agent's proof lives between launches: the app pass in the Keychain
 * (per agent, bound to its publishable key), the App Attest key id in the
 * SDK's `UserDefaults` keys, the debug token beside the install id. A Mac
 * runs the tests only, so there they live in memory and never touch the
 * login Keychain.
 */
struct AppVerificationStores {
    var passes: AppPassStore
    var keys: AttestKeyStore
    var debugTokens: InstallIdStore

    static func device(agent: String, publishableKey: String, defaults: UserDefaults) -> AppVerificationStores {
        #if os(iOS) || os(visionOS)
        return AppVerificationStores(
            passes: KeychainAppPassStore(agent: agent),
            keys: DefaultsAttestKeyStore(defaults: defaults, publishableKey: publishableKey),
            debugTokens: KeychainInstallIdStore(account: "debug-token")
        )
        #else
        return memory()
        #endif
    }

    static func memory() -> AppVerificationStores {
        AppVerificationStores(passes: MemoryAppPassStore(), keys: MemoryAttestKeyStore(), debugTokens: MemoryInstallIdStore())
    }

    /// The device's own environment; on a Mac (tests only) a Team ID that is never read from the Keychain.
    static var environment: AppVerification.Environment {
        var env = AppVerification.Environment()
        #if !(os(iOS) || os(visionOS))
        env.team = FixedTeamId(nil)
        #endif
        return env
    }
}
