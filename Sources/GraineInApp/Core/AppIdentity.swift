import CryptoKit
import Foundation
import Security

/*
 * YOUR APP AND YOUR USERS (APP-IDENTITY.md, 0.14.4) — the parts with no
 * moving pieces: what the session says the agent checks, what an answer's
 * `verification` says, the app's declaration, the Team ID, the debug token,
 * a JWT's expiry, and THE ONE FUNCTION every request to an embed route passes
 * through on its way out (`EmbedSeal.seal`): it adds the app's declaration
 * (`app: {platform, id, team?, pass?, debugToken?}`) at the top level, and,
 * inside `identity`, the identity token the app gave for exactly that value
 * and the user pass the server issued for it.
 *
 * Pure: Foundation, Security and CryptoKit only, so a Mac proves it.
 */

// MARK: - What the agent checks (the session's `security`, §2.1)

/// How strictly the agent checks the app or the user.
enum SecurityMode: String, Equatable, Sendable {
    case off
    case report
    case enforce

    /// The wire's word; anything else (absent, unknown) is `off` — nothing checked, as before.
    static func parse(_ raw: Any?) -> SecurityMode {
        guard let word = JSON.nonEmpty(raw)?.trimmingCharacters(in: .whitespaces).lowercased() else { return .off }
        return SecurityMode(rawValue: word) ?? .off
    }
}

/// The session's `security` (always present from 0.14.4's server; absent from an older one: nothing is checked).
struct SessionSecurity: Equatable, Sendable {
    var appVerify: SecurityMode = .off
    /// Android's Play Integrity project; read, never used on iOS.
    var cloudProjectNumber: String?
    var userVerify: SecurityMode = .off
    /// `hmac` or `jwt`, when the agent set one.
    var userMethod: String?

    static let none = SessionSecurity()

    /// Read the session's `security` object. Missing parts are `off`, never a crash.
    static func parse(_ raw: Any?) -> SessionSecurity {
        guard let o = JSON.unwrap(raw) as? [String: Any] else { return .none }
        let app = JSON.unwrap(o["app"]) as? [String: Any]
        let user = JSON.unwrap(o["user"]) as? [String: Any]
        return SessionSecurity(
            appVerify: SecurityMode.parse(app?["verify"]),
            cloudProjectNumber: JSON.nonEmpty(app?["cloudProjectNumber"]),
            userVerify: SecurityMode.parse(user?["verify"]),
            userMethod: JSON.nonEmpty(user?["method"])
        )
    }

    /// The app proves itself (§3) in the background after the session: the agent checks it at all.
    var proves: Bool { appVerify != .off }

    /// A ticket or call-session request waits (a little) for a proof when no pass is held: the agent refuses without one.
    var waitsForProof: Bool { appVerify == .enforce }
}

// MARK: - What an answer says (§2.2)

/// An answer's `verification`: the app's and the user's verdicts, and any pass the server issued with them.
struct VerificationAnswer: Equatable, Sendable {
    /// `verified` · `test_build` · `unverified` · `off`, as the wire says it.
    var app: String?
    var appPass: String?
    var appPassExpiresIn: Double?
    /// `verified` · `unverified` · `invalid` · `off`.
    var user: String?
    var userReason: String?
    var userPass: String?
    var userPassExpiresIn: Double?

    /// Nil when the answer carries no `verification` object.
    static func parse(_ raw: Any?) -> VerificationAnswer? {
        guard let o = JSON.unwrap(raw) as? [String: Any] else { return nil }
        func seconds(_ key: String) -> Double? {
            guard let v = JSON.unwrap(o[key]), let n = JSON.number(v) else { return nil }
            let d = n.doubleValue
            return d.isFinite && d > 0 ? d : nil
        }
        return VerificationAnswer(
            app: JSON.nonEmpty(o["app"]),
            appPass: JSON.unwrap(o["appPass"]) as? String,
            appPassExpiresIn: seconds("appPassExpiresIn"),
            user: JSON.nonEmpty(o["user"]),
            userReason: JSON.nonEmpty(o["userReason"]),
            userPass: JSON.unwrap(o["userPass"]) as? String,
            userPassExpiresIn: seconds("userPassExpiresIn")
        )
    }
}

// MARK: - The public state (§4)

/**
 * Whether this app is proven to be yours, for an agent that checks it
 * (Embed & Widgets → Install → Prove it's your app): `GraineVerification.app`.
 */
public enum GraineAppVerdict: String, Equatable, Hashable, Sendable, CaseIterable {
    /// The agent does not check the app (or its settings have not loaded yet).
    case off
    /// A proof is on its way.
    case checking
    /// App Attest proved this is your app, signed by your team.
    case verified
    /// A development build App Attest proved, accepted while the agent's "Allow development builds" is on.
    case testBuild
    /// A debug build whose debug token is registered on the agent (development mode, `debugToken`).
    case debugToken
    /// Not proven: no proof could be made, or the server did not accept it. `GraineVerification.appReason` says why when the server did.
    case unverified

    /// The wire's word (`verified`, `test_build`, `debug_token`, `unverified`, `off`); nil for one this build does not know.
    init?(wire: String) {
        switch wire.trimmingCharacters(in: .whitespaces).lowercased() {
        case "verified": self = .verified
        case "test_build": self = .testBuild
        case "debug_token": self = .debugToken
        case "unverified": self = .unverified
        case "off": self = .off
        default: return nil
        }
    }
}

/// Whether the identity your app gave with `identify` is proven by its identity token: `GraineVerification.user`.
public enum GraineUserVerdict: String, Equatable, Hashable, Sendable, CaseIterable {
    /// The agent does not verify users (or its settings have not loaded yet).
    case off
    /// The identity token (or the pass it earned) proved the identity.
    case verified
    /// One of the agent's test users, from an install whose debug token the agent registered: accepted without a token.
    case testUser
    /// No token proved it — none was given (`missing`), or it could not be checked.
    case unverified
    /// The token was refused: `GraineVerification.userReason` says why (`expired`, `signature`, `mismatch`…).
    case invalid

    /// The wire's word (`verified`, `test_user`, `unverified`, `invalid`, `off`); nil for one this build does not know.
    init?(wire: String) {
        switch wire.trimmingCharacters(in: .whitespaces).lowercased() {
        case "verified": self = .verified
        case "test_user": self = .testUser
        case "unverified": self = .unverified
        case "invalid": self = .invalid
        case "off": self = .off
        default: return nil
        }
    }
}

/**
 * DEVELOPMENT MODE — debug tokens instead of App Attest (the Simulator
 * cannot run App Attest; a debug build is not one Apple signs for the store).
 * `GraineConfig.debugTokenMode` / `GraineInApp.debugTokenMode`.
 */
public enum GraineDebugTokenMode: String, Equatable, Hashable, Sendable, CaseIterable {
    /// The default: a debug build (`DEBUG`, or the Simulator) creates a debug token once per install and sends it on every
    /// request instead of proving itself with App Attest; a release build never creates, logs or sends one.
    case automatic
    /// A release build sends the debug token too — an internal QA build, opted in explicitly.
    case always
    /// No debug token, even in a debug build: it proves itself with App Attest like a release build.
    case never
}

/**
 * WHAT GRAINE MADE OF THIS APP AND THIS USER, for an agent that checks them:
 * `app` — the app proven yours (App Attest), and `user` — the identity proven
 * by your identity token. Both `off` until the agent's settings say it checks
 * them; `unverified` / `invalid` carry the server's reason when it gave one.
 * `GraineInApp.verification`.
 */
public struct GraineVerification: Equatable, Sendable {
    public let app: GraineAppVerdict
    /// Why the app is `unverified`, as the server said it (`missing`, `expired`, `invalid`, `test_build`, `wrong_app`…); nil otherwise.
    public let appReason: String?
    public let user: GraineUserVerdict
    /// Why the user is `unverified` or `invalid`, as the server said it (`missing`, `expired`, `signature`, `mismatch`…); nil otherwise.
    public let userReason: String?

    public init(app: GraineAppVerdict = .off, appReason: String? = nil, user: GraineUserVerdict = .off, userReason: String? = nil) {
        self.app = app
        self.appReason = appReason
        self.user = user
        self.userReason = userReason
    }
}

// MARK: - The app's declaration (§1.1, §1.2)

/// `app: {platform: "ios", id, team?, pass?, debugToken?}` — Mac Catalyst and visionOS builds say "ios" too.
struct AppDeclaration: Equatable, Sendable {
    var id: String
    var team: String?
    var pass: String?
    var debugToken: String?

    var wire: WireJSON {
        var fields: [(String, WireJSON)] = [("platform", .string("ios")), ("id", .string(id))]
        if let team = team { fields.append(("team", .string(team))) }
        if let pass = pass { fields.append(("pass", .string(pass))) }
        if let token = debugToken { fields.append(("debugToken", .string(token))) }
        return .object(fields)
    }
}

/// The Team ID — the App ID prefix — as the Keychain's access group gives it (§1.2).
enum TeamId {
    /// The probe item: one generic password, added once per launch and read back for its access group.
    static let probeService = "ai.graine.inapp.app-id-probe"
    static let probeAccount = "probe"

    /// `^[A-Z0-9]{10}$`.
    static func isTeamId(_ s: String) -> Bool {
        s.unicodeScalars.count == 10 && s.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
    }

    /// The part of an access group before its first ".", when it is a Team ID; nil otherwise. Never guessed.
    static func from(accessGroup: String?) -> String? {
        guard let group = accessGroup, let dot = group.firstIndex(of: ".") else { return nil }
        let head = String(group[..<dot])
        return isTeamId(head) ? head : nil
    }
}

/// Where the Team ID comes from. The Keychain on a device; a fixed answer in tests.
protocol TeamIdSource: AnyObject {
    /// The Team ID once it has been read; nil while it is not (not yet, a simulator, an error). Never blocks.
    var known: String? { get }
    /// `done` with the Team ID (or nil) once it has been read — at once when it has. Any thread; never the main thread's work.
    func whenRead(_ done: @escaping (String?) -> Void)
}

/**
 * THE TEAM ID FROM THE KEYCHAIN (§1.2), read once per launch, off the main
 * thread: a generic password with service `ai.graine.inapp.app-id-probe`,
 * account `probe`, added (or found) and read back with its attributes; the
 * Team ID is its access group before the first ".". Any Keychain error, a
 * group that does not start with one (an unsigned simulator build), or a
 * platform without the iOS Keychain: unknown, and the declaration says none.
 */
final class KeychainTeamIdProbe: TeamIdSource {
    static let shared = KeychainTeamIdProbe()

    private let lock = NSLock()
    private var read = false
    private var started = false
    private var value: String?
    private var waiting: [(String?) -> Void] = []
    private let queue = DispatchQueue(label: "ai.graine.inapp.team-id", qos: .utility)

    var known: String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func whenRead(_ done: @escaping (String?) -> Void) {
        lock.lock()
        if read {
            let v = value
            lock.unlock()
            return done(v)
        }
        waiting.append(done)
        let start = !started
        started = true
        lock.unlock()
        guard start else { return }
        queue.async { [self] in
            let found = Self.probe()
            lock.lock()
            value = found
            read = true
            let ready = waiting
            waiting = []
            lock.unlock()
            for wait in ready { wait(found) }
        }
    }

    private static func probe() -> String? {
        #if os(iOS) || os(visionOS)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: TeamId.probeService,
            kSecAttrAccount as String: TeamId.probeAccount,
        ]
        var add = base
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecValueData as String] = Data("1".utf8)
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess || added == errSecDuplicateItem else { return nil }
        var query = base
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let attributes = item as? [String: Any] else { return nil }
        return TeamId.from(accessGroup: attributes[kSecAttrAccessGroup as String] as? String)
        #else
        // A Mac runs the tests only: there is no app to declare a team for.
        return nil
        #endif
    }
}

/// A Team ID known up front: tests.
final class FixedTeamId: TeamIdSource {
    let known: String?

    init(_ team: String?) {
        known = team
    }

    func whenRead(_ done: @escaping (String?) -> Void) {
        done(known)
    }
}

// MARK: - What a request carries besides its own fields

/// The identity token and the user pass for one identity value — each only when it was given (or issued) for exactly that value.
struct IdentityProof: Equatable, Sendable {
    var token: String?
    var pass: String?

    static let none = IdentityProof()
}

/// What every request to an embed route carries besides its own fields (§1.1, §1.3).
protocol EmbedCredentials: AnyObject {
    /// The app's declaration as it stands now; nil when the bundle id cannot be read (then no `app` is sent).
    func appDeclaration() -> AppDeclaration?
    /// The token and user pass for exactly `value`; `.none` for any other value than the one they were given or issued with.
    func identityProof(for value: String) -> IdentityProof
}

/**
 * THE ONE PLACE A REQUEST'S BODY IS FINISHED. Every builder — the embed
 * routes, the chat's and the native call's tickets, the call session's mint —
 * hands its fields here: `identity: {value}` gains the token and the pass
 * held for exactly that value (and loses any it carried), and the app's
 * declaration goes last, at the top level. The token rides nowhere else.
 */
enum EmbedSeal {
    static func seal(_ fields: [(String, WireJSON)], _ credentials: EmbedCredentials?) -> [(String, WireJSON)] {
        guard let credentials = credentials else { return fields }
        var out: [(String, WireJSON)] = []
        for (key, value) in fields {
            if key == "app" { continue }
            if key == "identity", case .object(let inner) = value, let named = text(inner, "value") {
                out.append((key, .object(withProof(inner, credentials.identityProof(for: named)))))
            } else {
                out.append((key, value))
            }
        }
        if let app = credentials.appDeclaration() { out.append(("app", app.wire)) }
        return out
    }

    /// `identity`'s own fields, with the proof for its value in place of any it carried: value, token, pass.
    static func withProof(_ inner: [(String, WireJSON)], _ proof: IdentityProof) -> [(String, WireJSON)] {
        var out = inner.filter { $0.0 != "token" && $0.0 != "pass" }
        if let token = proof.token { out.append(("token", .string(token))) }
        if let pass = proof.pass { out.append(("pass", .string(pass))) }
        return out
    }

    private static func text(_ fields: [(String, WireJSON)], _ key: String) -> String? {
        guard let found = fields.first(where: { $0.0 == key }), case .string(let s) = found.1 else { return nil }
        return s
    }

    /// The identity value a request names (`identity.value`), for the pass its answer may bring.
    static func identityValue(_ fields: [(String, WireJSON)]) -> String? {
        guard let found = fields.first(where: { $0.0 == "identity" }), case .object(let inner) = found.1 else { return nil }
        return text(inner, "value")
    }
}

// MARK: - The identity token (§1.3)

enum IdentityTokenRules {
    /// The longest token the server reads.
    static let maxLength = 4096
    /// A JWT this close to its `exp` is refreshed before a conversation starts.
    static let refreshWithinSeconds = 60.0
    /// The refresher is asked at most once in this long.
    static let minRefreshInterval = 30.0

    /// A token as given, when it is one: not empty, not blank, at most 4096 characters. Nil otherwise (nothing is sent).
    static func usable(_ token: String?) -> String? {
        guard let token = token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard token.count <= maxLength else { return nil }
        return token
    }

    /// The `exp` of a JWT — three base64url segments — read WITHOUT verifying it (only to decide when to refresh). Nil for anything else.
    static func jwtExpiry(_ token: String) -> Double? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(isBase64Url) }),
              let payload = base64UrlDecode(String(parts[1])),
              let claims = JSON.object(from: payload),
              let exp = JSON.unwrap(claims["exp"]).flatMap({ JSON.number($0) })?.doubleValue,
              exp.isFinite else { return nil }
        return exp
    }

    /// The token is a JWT whose `exp` is less than 60 s away (or past) at `now`.
    static func expiresSoon(_ token: String?, now: Date) -> Bool {
        guard let token = token, let exp = jwtExpiry(token) else { return false }
        return exp - now.timeIntervalSince1970 < refreshWithinSeconds
    }

    private static func isBase64Url(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "_")
    }

    static func base64UrlDecode(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let rest = s.count % 4
        if rest == 1 { return nil }
        if rest > 0 { s += String(repeating: "=", count: 4 - rest) }
        return Data(base64Encoded: s)
    }
}

// MARK: - Development mode (§3.6)

enum DebugToken {
    static let prefix = "gdt_"

    /// `gdt_` and the base64url of 24 random bytes: 32 characters, no padding.
    static func make(_ bytes: [UInt8]) -> String {
        prefix + Base64Url.encode(Data(bytes))
    }

    /// `^gdt_[A-Za-z0-9_-]{32}$`.
    static func isValid(_ s: String?) -> Bool {
        guard let s = s, s.hasPrefix(prefix) else { return false }
        let body = s.dropFirst(prefix.count)
        return body.count == 32 && body.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// The line the SDK logs once per install, exactly as the contract words it.
    static func logLine(_ token: String) -> String {
        "Graine debug token for this install: \(token) — register it under Agent → Embed & Widgets → Install → Development → "
            + "Debug tokens to use this build while \"Require a verified app\" is on."
    }

    /**
     * Whether this build sends a debug token: a debug build — the SDK is
     * compiled from source with the app's own configuration, so `DEBUG` is the
     * app's — or the Simulator, unless the app said `never`; any build the app
     * opted in with `always`.
     */
    static func inUse(mode: GraineDebugTokenMode, debugBuild: Bool) -> Bool {
        switch mode {
        case .automatic: return debugBuild
        case .always: return true
        case .never: return false
        }
    }

    /// A debug build, as the SDK was compiled: `DEBUG` (the app's configuration) or the Simulator.
    static var isDebugBuild: Bool {
        #if DEBUG || targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
}

enum Base64Url {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Random bytes from the system's generator.
enum SecureRandom {
    static func bytes(_ count: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &out) != errSecSuccess {
            // Never a predictable token: the system generator through CryptoKit instead.
            out = Array(SymmetricKey(size: SymmetricKeySize(bitCount: count * 8)).withUnsafeBytes { Data($0) })
        }
        return out
    }
}

// MARK: - App Attest's input (§3.2)

enum AppAttestWire {
    /// `clientDataHash = SHA256(UTF-8 bytes of challenge)`.
    static func clientDataHash(_ challenge: String) -> Data {
        Data(SHA256.hash(data: Data(challenge.utf8)))
    }

    /// `^[A-Za-z0-9_-]{48}$`: what a challenge looks like; anything else is not used.
    static func isChallenge(_ s: String?) -> Bool {
        guard let s = s, s.count == 48 else { return false }
        return s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}
