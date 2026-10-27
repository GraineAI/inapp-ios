import CryptoKit
import Foundation
import Testing
@_spi(GraineRTC) @testable import GraineInApp

/*
 * YOUR APP AND YOUR USERS (contract/APP-IDENTITY.md, contract/app-identity.json):
 * the app's declaration on every request, the identity token inside `identity`
 * and nowhere else, account changes, the refresher, App Attest's proof and its
 * pass, development mode's debug token, the outage ladder and grace, the
 * public state and the Objective-C mirror — on fakes: App Attest scripted, the
 * network scripted per route, the clock and its timers moved by hand.
 *
 * A missing app-identity.json FAILS — it never skips.
 */

// MARK: - The fakes

/// App Attest, scripted: each call answers the next scripted result, else succeeds.
final class FakeAttest: AppAttesting {
    var isSupported = true
    private var nextKey = 0
    var generateResults: [Result<String, AppAttestFailure>] = []
    var attestResults: [Result<Data, AppAttestFailure>] = []
    var assertResults: [Result<Data, AppAttestFailure>] = []
    private(set) var calls: [String] = []
    private(set) var hashes: [Data] = []

    func generateKey(_ done: @escaping (Result<String, AppAttestFailure>) -> Void) {
        calls.append("generate")
        if !generateResults.isEmpty { return done(generateResults.removeFirst()) }
        nextKey += 1
        done(.success("key-\(nextKey)"))
    }

    func attestKey(_ keyId: String, clientDataHash: Data, _ done: @escaping (Result<Data, AppAttestFailure>) -> Void) {
        calls.append("attest(\(keyId))")
        hashes.append(clientDataHash)
        if !attestResults.isEmpty { return done(attestResults.removeFirst()) }
        done(.success(Data("attestation-\(keyId)".utf8)))
    }

    func generateAssertion(_ keyId: String, clientDataHash: Data, _ done: @escaping (Result<Data, AppAttestFailure>) -> Void) {
        calls.append("assert(\(keyId))")
        hashes.append(clientDataHash)
        if !assertResults.isEmpty { return done(assertResults.removeFirst()) }
        done(.success(Data("assertion-\(keyId)".utf8)))
    }
}

/// Every route answered from a script — in order, the last answer repeating — and every body recorded. Thread-safe.
final class ProofNetwork: CallNetwork {
    struct Post {
        let path: String
        let body: [String: Any]
        let raw: String
    }

    static let challenges = (1...9).map { String(repeating: "c", count: 47) + "\($0)" }
    private let lock = NSLock()
    private var postsValue: [Post] = []
    private var socketsValue: [FakeSocket] = []
    private var script: [String: [(Int, String)]] = [:]
    private var challengeCount = 0
    /// Routes whose answers wait for `release`.
    var holding: Set<String> = []
    private var held: [String: [() -> Void]] = [:]

    /// Answer `path` with these, in order; the last one repeats.
    func answer(_ path: String, _ replies: (Int, String)...) {
        lock.lock()
        script[path] = replies
        lock.unlock()
    }

    func post(_ url: URL, body: Data, completion: @escaping (Int, Data?) -> Void) {
        postWithHeaders(url, body: body) { status, data, _ in completion(status, data) }
    }

    /// Routes asked with the longer, slow-network budget.
    private(set) var patientPaths: [String] = []

    func postPatiently(_ url: URL, body: Data, completion: @escaping (Int, Data?, [String: String]) -> Void) {
        lock.lock()
        patientPaths.append(url.path)
        lock.unlock()
        postWithHeaders(url, body: body, completion: completion)
    }

    func postWithHeaders(_ url: URL, body: Data, completion: @escaping (Int, Data?, [String: String]) -> Void) {
        lock.lock()
        let raw = String(decoding: body, as: UTF8.self)
        postsValue.append(Post(path: url.path, body: JSON.object(from: body) ?? [:], raw: raw))
        var reply: (Int, String)
        if var queue = script[url.path], let first = queue.first {
            reply = first
            if queue.count > 1 { queue.removeFirst() }
            script[url.path] = queue
        } else {
            switch url.path {
            case "/api/embed/ticket":
                reply = (200, #"{"ticket":"tkt-1","wsUrl":"wss://ws.graine.ai/v1/embed"}"#)
            case "/api/embed/app-verify/challenge":
                challengeCount += 1
                reply = (200, #"{"challenge":"\#(ProofNetwork.challenges[min(challengeCount, 9) - 1])","expiresIn":300}"#)
            case "/api/embed/app-verify":
                reply = (200, #"{"verification":{"app":"verified","appPass":"ap1.pass","appPassExpiresIn":86400}}"#)
            default:
                reply = (200, "{}")
            }
        }
        let answer = { completion(reply.0, Data(reply.1.utf8), [:]) }
        if holding.contains(url.path) {
            held[url.path, default: []].append(answer)
            lock.unlock()
            return
        }
        lock.unlock()
        answer()
    }

    func release(_ path: String) {
        lock.lock()
        holding.remove(path)
        let answers = held[path] ?? []
        held[path] = nil
        lock.unlock()
        answers.forEach { $0() }
    }

    func openSocket(_ url: URL, protocols: [String], events: CallSocketEvents) -> CallSocket {
        let socket = FakeSocket(url: url, protocols: protocols, events: events)
        lock.lock()
        socketsValue.append(socket)
        lock.unlock()
        return socket
    }

    var posts: [Post] {
        lock.lock()
        defer { lock.unlock() }
        return postsValue
    }

    var sockets: [FakeSocket] {
        lock.lock()
        defer { lock.unlock() }
        return socketsValue
    }

    func bodies(_ path: String) -> [[String: Any]] {
        posts.filter { $0.path == path }.map(\.body)
    }

    func raws(_ path: String) -> [String] {
        posts.filter { $0.path == path }.map(\.raw)
    }

    var paths: [String] { posts.map(\.path) }
}

/// A wall clock and its timers, moved by hand. Thread-safe.
final class HandClock {
    private let lock = NSLock()
    private var nowValue = Date(timeIntervalSince1970: 1_792_000_000)
    private var timers: [(due: Date, block: () -> Void)] = []

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return nowValue
    }

    func after(_ seconds: TimeInterval, _ block: @escaping () -> Void) {
        lock.lock()
        timers.append((nowValue.addingTimeInterval(seconds), block))
        lock.unlock()
    }

    /// Timers still waiting, as seconds from now.
    var waiting: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return timers.map { $0.due.timeIntervalSince(nowValue) }.sorted()
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        let target = nowValue.addingTimeInterval(seconds)
        lock.unlock()
        while true {
            lock.lock()
            guard let index = timers.indices.filter({ timers[$0].due <= target }).min(by: { timers[$0].due < timers[$1].due }) else {
                nowValue = target
                lock.unlock()
                return
            }
            let timer = timers.remove(at: index)
            nowValue = max(nowValue, timer.due)
            lock.unlock()
            timer.block()
        }
    }
}

/// What the SDK logged.
final class LogBook {
    private let lock = NSLock()
    private var linesValue: [String] = []

    func add(_ line: String) {
        lock.lock()
        linesValue.append(line)
        lock.unlock()
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return linesValue
    }
}

/// An agent on fakes, its app identified as `com.acme.app` of team ABCDE12345 unless the test says otherwise.
@MainActor
final class SecureRig {
    nonisolated static let key = "pk_test_secure"
    let sandbox: Sandbox
    let network = ProofNetwork()
    let scheduler = ManualScheduler()
    let attest = FakeAttest()
    let clock = HandClock()
    let log = LogBook()
    let passes: MemoryAppPassStore
    let keys: MemoryAttestKeyStore
    let debugTokens: MemoryInstallIdStore
    let graine: GraineInApp

    init(
        bundleId: String? = "com.acme.app",
        team: String? = "ABCDE12345",
        debugBuild: Bool = false,
        mode: GraineDebugTokenMode = .automatic,
        pass: StoredAppPass? = nil,
        key: (keyId: String, attested: Bool)? = nil,
        attestSupported: Bool = true,
        debugTokens: MemoryInstallIdStore = MemoryInstallIdStore(),
        sandbox: Sandbox = Sandbox()
    ) {
        self.sandbox = sandbox
        passes = MemoryAppPassStore(pass)
        keys = MemoryAttestKeyStore(key)
        self.debugTokens = debugTokens
        attest.isSupported = attestSupported
        var env = AppVerification.Environment()
        env.bundleId = { bundleId }
        env.team = FixedTeamId(team)
        env.attest = attest
        env.debugBuild = debugBuild
        let clock = self.clock
        let log = self.log
        env.now = { clock.now }
        env.after = { seconds, block in clock.after(seconds, block) }
        env.log = { log.add($0) }
        env.warn = { log.add("warning: " + $0) }
        graine = GraineInApp(
            config: GraineConfig(baseUrl: "https://www.graine.ai", publishableKey: SecureRig.key, debugTokenMode: mode),
            installIds: MemoryInstallIdStore("3f2504e0-4f89-11d3-9a0c-0305e82c3301"),
            defaults: sandbox.defaults,
            sessionCache: SessionCache(directory: sandbox.folder),
            network: network,
            chatScheduler: scheduler,
            appStores: AppVerificationStores(passes: passes, keys: keys, debugTokens: debugTokens),
            appEnvironment: env
        )
    }

    /// The session the server would send, with this `security` (nil: an older server, nothing checked).
    func session(app: String? = nil, user: String? = nil, _ extra: [String: Any] = [:]) {
        var body: [String: Any] = ["agentId": "agent-1", "webcallAgentId": "web-1"]
        if app != nil || user != nil {
            var security: [String: Any] = [:]
            security["app"] = ["verify": app ?? "off"]
            security["user"] = ["verify": user ?? "off", "method": "hmac"]
            body["security"] = security
        }
        for (k, v) in extra { body[k] = v }
        graine.finishSession(.success(GraineSessionConfig.parse(body)))
    }

    /// A pass for this agent's key, `hoursLeft` from the rig's clock.
    func pass(_ value: String = "ap1.kept", hoursLeft: Double, key: String = SecureRig.key) -> StoredAppPass {
        StoredAppPass(publishableKey: key, pass: value, verdict: "verified", expiresAt: clock.now.timeIntervalSince1970 + hoursLeft * 3600)
    }

    func clean() { sandbox.clean() }

    static func app(_ body: [String: Any]?) -> [String: Any]? { body?["app"] as? [String: Any] }
    static func identity(_ body: [String: Any]?) -> [String: Any]? { body?["identity"] as? [String: Any] }
}

/// Wait (a little) for what another thread finishes: the refresher runs on Swift's own pool.
@MainActor
func eventually(_ what: String = "", _ condition: () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    #expect(condition(), "never happened: \(what)")
}

/// An identity token a JWT-shaped way: `exp` readable, nothing else meaningful.
func fakeJwt(exp: Double, salt: String = "a") -> String {
    func b64(_ s: String) -> String { Base64Url.encode(Data(s.utf8)) }
    return b64(#"{"alg":"RS256","kid":"k1"}"#) + "." + b64(#"{"sub":"user-123","exp":\#(Int(exp)),"n":"\#(salt)"}"#) + "." + b64("sig")
}

private func contract() throws -> [String: Any] {
    try ContractFile.load("app-identity.json")
}

// MARK: - The contract's vectors

@Suite struct AppIdentityContractTests {
    @Test func theErrorCodesAreTheContractsWords() throws {
        let codes = try #require(try contract()["errorCodes"] as? [[String: Any]])
        let cases: [String: GraineErrorCode] = [
            "appNotAllowed": .appNotAllowed, "appNotVerified": .appNotVerified, "identityUnverified": .identityUnverified,
        ]
        #expect(codes.count == 3)
        for entry in codes {
            let wire = try #require(entry["wire"] as? String)
            let swift = try #require(entry["swift"] as? String)
            let expected = try #require(cases[swift], "a case named \(swift)")
            #expect(GraineErrorCode(wire: wire) == expected, "\(wire)")
            #expect(expected.wire == wire)
            let status = try #require(entry["status"] as? Int)
            let refusal = GraineServiceError.from(status: status, body: ["code": wire, "reason": "missing"])
            #expect(refusal.code == expected)
            #expect(refusal.reason == "missing")
            #expect(!refusal.message.isEmpty)
        }
    }

    @Test func theTeamIdIsReadFromTheAccessGroupNeverGuessed() throws {
        let vectors = try #require(try contract()["teamIdFromAccessGroup"] as? [[String: Any]])
        #expect(vectors.count >= 5)
        for v in vectors {
            let group = try #require(v["accessGroup"] as? String)
            #expect(TeamId.from(accessGroup: group) == v["team"] as? String, "\(group)")
        }
        #expect(TeamId.from(accessGroup: nil) == nil)
    }

    @Test func theVerdictsAreTheContractsStates() throws {
        let c = try contract()
        #expect(GraineAppVerdict.allCases.map(\.rawValue) == c["appVerdicts"] as? [String])
        #expect(GraineUserVerdict.allCases.map(\.rawValue) == c["userVerdicts"] as? [String])
        let wireApp = try #require(c["wireAppVerdicts"] as? [String: String])
        for (wire, state) in wireApp { #expect(GraineAppVerdict(wire: wire)?.rawValue == state, "\(wire)") }
        let wireUser = try #require(c["wireUserVerdicts"] as? [String: String])
        for (wire, state) in wireUser { #expect(GraineUserVerdict(wire: wire)?.rawValue == state, "\(wire)") }
        #expect(GraineAppVerdict(wire: "something_new") == nil)
    }

    @Test func theSessionsSecuritySaysWhenToProve() throws {
        let examples = try #require(try contract()["sessionSecurityExamples"] as? [[String: Any]])
        for example in examples {
            let security = SessionSecurity.parse(example["security"])
            #expect(security.proves == (example["prove"] as? Bool), "\(example)")
            #expect(security.waitsForProof == ((example["waitForProofBeforeTicket"] as? Bool) ?? false), "\(example)")
        }
        #expect(SessionSecurity.parse(nil) == .none, "an older server: nothing checked")
        #expect(SessionSecurity.parse(["app": ["verify": "enforce", "cloudProjectNumber": "123456789012"]]).cloudProjectNumber == "123456789012")
    }

    @Test func aJwtsExpiryIsReadWithoutVerifyingIt() throws {
        let c = try #require(try contract()["jwtExpiry"] as? [String: Any])
        let example = try #require(c["example"] as? [String: Any])
        let token = try #require(example["token"] as? String)
        let exp = try #require(example["exp"] as? Double)
        #expect(IdentityTokenRules.jwtExpiry(token) == exp)
        let window = try #require(c["refreshWhenSecondsLeftBelow"] as? Double)
        #expect(IdentityTokenRules.refreshWithinSeconds == window)
        #expect(!IdentityTokenRules.expiresSoon(token, now: Date(timeIntervalSince1970: exp - window - 1)))
        #expect(IdentityTokenRules.expiresSoon(token, now: Date(timeIntervalSince1970: exp - window + 1)))
        let hmac = try #require((try contract()["identityWire"] as? [String: Any]).flatMap { ($0["identity"] as? [String: Any])?["token"] as? String })
        #expect(IdentityTokenRules.jwtExpiry(hmac) == nil, "an HMAC is not a JWT: never refreshed for an expiry")
        #expect(IdentityTokenRules.jwtExpiry("a.b") == nil)
    }

    @Test func theShapesAreTheContractsShapes() throws {
        let shapes = try #require(try contract()["shapes"] as? [String: Any])
        func matches(_ pattern: String, _ text: String) -> Bool {
            text.range(of: pattern, options: .regularExpression) != nil
        }
        let debugShape = try #require(shapes["debugToken"] as? String)
        for seed in 0..<20 {
            let token = DebugToken.make((0..<24).map { UInt8(($0 * 37 + seed * 11) % 256) })
            #expect(matches(debugShape, token), "\(token)")
            #expect(DebugToken.isValid(token))
        }
        #expect(DebugToken.make(SecureRandom.bytes(24)).count == 36)
        #expect(!DebugToken.isValid("gdt_short"))
        let challengeShape = try #require(shapes["challenge"] as? String)
        #expect(matches(challengeShape, ProofNetwork.challenges[0]))
        #expect(AppAttestWire.isChallenge(ProofNetwork.challenges[0]))
        #expect(!AppAttestWire.isChallenge("short"))
        #expect(shapes["maxIdentityTokenLength"] as? Int == IdentityTokenRules.maxLength)
        #expect(IdentityTokenRules.usable(String(repeating: "x", count: 4096)) != nil)
        #expect(IdentityTokenRules.usable(String(repeating: "x", count: 4097)) == nil)
        #expect(IdentityTokenRules.usable("  ") == nil)
    }

    @Test func developmentModeIsTheContracts() throws {
        let dev = try #require(try contract()["debugTokens"] as? [String: Any])
        #expect(GraineDebugTokenMode.allCases.map(\.rawValue) == dev["modes"] as? [String])
        #expect(GraineConfig(baseUrl: "https://www.graine.ai", publishableKey: "pk").debugTokenMode.rawValue == dev["defaultMode"] as? String)
        let line = try #require(dev["logLine"] as? String)
        #expect(DebugToken.logLine("gdt_0123456789abcdefghijklmnopqrstuv") == line.replacingOccurrences(of: "{token}", with: "gdt_0123456789abcdefghijklmnopqrstuv"))
        #expect(DebugToken.inUse(mode: .automatic, debugBuild: true))
        #expect(!DebugToken.inUse(mode: .automatic, debugBuild: false), "a release build never sends one")
        #expect(DebugToken.inUse(mode: .always, debugBuild: false))
        #expect(!DebugToken.inUse(mode: .never, debugBuild: true))
    }

    @Test func thePassesAgesAreTheContracts() throws {
        let passes = try #require(try contract()["passes"] as? [String: Any])
        #expect(passes["appRefreshWhenSecondsLeftBelow"] as? Double == AppVerification.refreshWithin)
        #expect(AppVerification.outageDelays == [30, 120, 600])
    }

    /// `identity: {value, token, pass}` exactly as the contract's example — sealed by the one function every builder calls.
    @Test func theProofRidesInsideIdentityAsTheContractWritesIt() throws {
        let wire = try #require(try contract()["identityWire"] as? [String: Any])
        let expected = try #require(wire["identity"] as? [String: Any])
        final class Held: EmbedCredentials {
            func appDeclaration() -> AppDeclaration? { nil }
            func identityProof(for value: String) -> IdentityProof {
                value == "user-123" ? IdentityProof(token: "6c249fec755515370f7f8bbc1ea341f1a9b2a40d62d1be9480ae9dece9c103a8", pass: "up1.opaque") : .none
            }
        }
        let sealed = EmbedSeal.seal([("identity", .object([("value", .string("user-123"))]))], Held())
        let body = try #require(JSON.object(from: WireJSON.object(sealed).text))
        #expect(JSON.canonical(body["identity"]) == JSON.canonical(expected))
        // Another value: nothing, and whatever a builder put there is not sent.
        let other = EmbedSeal.seal([("identity", .object([("value", .string("user-9")), ("token", .string("stale"))]))], Held())
        #expect(JSON.object(from: WireJSON.object(other).text)?["identity"] as? [String: String] == ["value": "user-9"])
    }

    @Test func theDebugLogShowsNoTokenFromTheEnginePagesIdentityMessage() {
        let message = GraineProtocol.out(GraineProtocol.Out.identity, ["value": "user-123", "installId": "i", "memory": true, "token": "secret-token-123"])
        let line = GraineProtocol.redactForLog(message)
        #expect(!line.contains("secret-token-123"))
        #expect(!line.contains("user-123"))
    }
}

// MARK: - The app's declaration on every request

@Suite @MainActor struct AppDeclarationTests {
    private let declared: [String: String] = ["platform": "ios", "id": "com.acme.app", "team": "ABCDE12345"]

    private func app(_ body: [String: Any]) -> [String: String]? {
        SecureRig.app(body) as? [String: String]
    }

    /// Every route the SDK asks, driven through the network seam: each body names the app.
    @Test func everyRequestPathCarriesTheApp() async throws {
        let rig = SecureRig()
        defer { rig.clean() }
        // The session, from the network.
        rig.network.answer("/api/embed/session", (200, #"{"agentId":"agent-1","webcallAgentId":"web-1","calls":{"hosted":true,"scheduling":{"usersCanBook":true,"maxDaysAhead":14,"minLeadMinutes":5}},"security":{"app":{"verify":"off"},"user":{"verify":"off"}}}"#))
        _ = await rig.graine.sessionNow()
        rig.graine.identify(["user_id": "P-1"])
        // Devices, signout, booking, the outcome of a ring, memory, conversations, past sessions.
        rig.graine.registerDeviceEverywhere(token: "abc123", appId: "com.acme.app", apnsEnvironment: "sandbox")
        rig.graine.identify(["user_id": "P-2"])
        let at = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 86_400).rounded())
        rig.network.answer("/api/embed/calls/schedule", (201, #"{"call":{"id":"s1","at":"\#(Scheduling.isoTime(at))","status":"scheduled","source":"sdk","reason":null}}"#))
        _ = try await rig.graine.scheduleCall(at: at)
        _ = try await rig.graine.scheduledCalls()
        _ = try await rig.graine.cancelScheduledCall(id: "s1")
        _ = try await rig.graine.requests.post("/api/embed/calls/outcome", HostedOutcome.fields(HostedOutcome.ringing(callId: "call_1"), installId: rig.graine.installId))
        _ = try await rig.graine.memories()
        _ = try await rig.graine.forgetMemory()
        try await rig.graine.letGoOfConversation()
        rig.graine.chat.refreshPastSessions()
        _ = try? await rig.graine.chat.sessionTranscript(id: "exec-1")
        // The chat's ticket.
        rig.graine.chat.open()
        // The native call's ticket.
        let engine = CallEngine(
            setup: CallEngine.Setup(
                publishableKey: SecureRig.key, baseUrl: "https://www.graine.ai", variables: [("who_called", "customer")],
                contextFrame: { nil }, session: { $0(GraineSessionConfig(agentId: "agent-1", webcallAgentId: "web-1")) },
                runAction: { _, _, answer in answer(.ok("")) }, identity: rig.graine.identityFields(callId: "call_2"),
                security: rig.graine.security
            ),
            audio: ScriptedAudio(), network: rig.network, scheduler: rig.scheduler, onEvent: { _ in }
        )
        engine.start()
        try await eventually("past sessions") { !rig.network.bodies("/api/embed/sessions/list").isEmpty }

        let paths = [
            "/api/embed/session", "/api/embed/devices", "/api/embed/identity/signout", "/api/embed/calls/schedule", "/api/embed/calls/list",
            "/api/embed/calls/cancel", "/api/embed/calls/outcome", "/api/embed/memory/list", "/api/embed/memory/forget",
            "/api/embed/conversation/new", "/api/embed/sessions/list", "/api/embed/sessions/transcript", "/api/embed/ticket",
        ]
        for path in paths {
            let bodies = rig.network.bodies(path)
            #expect(!bodies.isEmpty, "\(path) was asked")
            for body in bodies { #expect(app(body) == declared, "\(path) names the app") }
        }
        #expect(rig.network.bodies("/api/embed/ticket").count == 2, "the chat's ticket and the call's")
        #expect(Set(rig.network.paths).isSubset(of: Set(paths)), "every route the SDK asked is one the test checked: \(Set(rig.network.paths).subtracting(paths))")
    }

    /// The call session's body (a mint, and the grant renewal built from it) and the warm-up's.
    @Test func theCallSessionsBodiesCarryTheApp() throws {
        let rig = SecureRig()
        defer { rig.clean() }
        let module = FakeRtcModule()
        rig.graine.rtcModule = { module }
        rig.graine.identify(["user_id": "P-1"], identityToken: "tok-P-1")
        rig.session()
        let warm = try #require(module.warmUps.first)
        let warmBody = try #require(JSON.object(from: warm.mintBody("")))
        #expect(app(warmBody) == declared)
        #expect(SecureRig.identity(warmBody)?["token"] as? String == "tok-P-1")
        #expect(warm.mintAnswered != nil, "a grant's renewal reports what the call session said")
        let setup = CallEngine.Setup(
            publishableKey: SecureRig.key, baseUrl: "https://www.graine.ai", variables: [], contextFrame: { nil },
            session: { $0(nil) }, runAction: { _, _, answer in answer(.ok("")) },
            identity: rig.graine.identityFields(callId: "call_9"), security: rig.graine.security
        )
        let request = CallConversation.rtcRequest(setup: setup, session: GraineSessionConfig(agentId: "a", webcallAgentId: "w"), debug: false)
        let mint = try #require(JSON.object(from: request.mintBody("0123456789abcdef0123456789abcdef")))
        #expect(app(mint) == declared)
        #expect(mint["session_id"] as? String == "0123456789abcdef0123456789abcdef")
        #expect(request.beforeMint != nil && request.cure != nil && request.mintAnswered != nil)
        // What renews on its own does not make another call of it; the token does.
        var other = mint
        other["app"] = ["platform": "ios", "id": "com.acme.app", "pass": "ap1.renewed"]
        var identity = try #require(other["identity"] as? [String: Any])
        identity["pass"] = "up1.renewed"
        other["identity"] = identity
        let otherData = try JSONSerialization.data(withJSONObject: other)
        #expect(RtcMintBody.sameCall(request.mintBody("0123456789abcdef0123456789abcdef"), otherData))
        identity["token"] = "tok-other"
        other["identity"] = identity
        #expect(!RtcMintBody.sameCall(request.mintBody("0123456789abcdef0123456789abcdef"), try JSONSerialization.data(withJSONObject: other)))
    }

    @Test func anUnknownTeamIsLeftOutAndNoBundleIdMeansNoApp() async throws {
        let noTeam = SecureRig(team: nil)
        defer { noTeam.clean() }
        _ = await noTeam.graine.sessionNow()
        #expect(app(try #require(noTeam.network.bodies("/api/embed/session").first)) == ["platform": "ios", "id": "com.acme.app"])

        let noBundle = SecureRig(bundleId: nil)
        defer { noBundle.clean() }
        _ = await noBundle.graine.sessionNow()
        #expect(try #require(noBundle.network.bodies("/api/embed/session").first)["app"] == nil, "no bundle id: no declaration at all")
    }

    /// The Team ID is read off the main thread: the first request waits for it, and carries it.
    @Test func theFirstRequestWaitsForTheTeamId() async throws {
        final class SlowTeam: TeamIdSource {
            var known: String?
            private var waiting: [(String?) -> Void] = []
            func whenRead(_ done: @escaping (String?) -> Void) {
                if known != nil { return done(known) }
                waiting.append(done)
            }
            func read(_ team: String) {
                known = team
                waiting.forEach { $0(team) }
                waiting = []
            }
        }
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        let team = SlowTeam()
        var env = AppVerification.Environment()
        env.bundleId = { "com.acme.app" }
        env.team = team
        env.attest = nil
        env.debugBuild = false
        let network = ProofNetwork()
        let graine = GraineInApp(
            config: GraineConfig(baseUrl: "https://www.graine.ai", publishableKey: "pk_test_slow"),
            installIds: MemoryInstallIdStore("3f2504e0-4f89-11d3-9a0c-0305e82c3301"), defaults: sandbox.defaults,
            sessionCache: SessionCache(directory: sandbox.folder), network: network, chatScheduler: ManualScheduler(),
            appStores: .memory(), appEnvironment: env
        )
        graine.loadSession { _ in }
        #expect(network.posts.isEmpty, "nothing leaves before the Team ID is read")
        team.read("ABCDE12345")
        #expect(app(try #require(network.bodies("/api/embed/session").first)) == declared)
    }
}

// MARK: - The identity token

@Suite @MainActor struct IdentityTokenTests {
    private let hex = "6c249fec755515370f7f8bbc1ea341f1a9b2a40d62d1be9480ae9dece9c103a8"

    @Test func theTokenRidesInsideIdentityAndNowhereElse() throws {
        let rig = SecureRig()
        defer { rig.clean() }
        rig.session(app: "off", user: "enforce")
        rig.graine.identify(["user_id": "user-123", "name": "Asha"], identityToken: hex)
        rig.graine.setVariables(["plan": "gold"])
        rig.graine.setScreen(GraineScreen(screen: "home"))
        rig.graine.chat.open()
        let raw = try #require(rig.network.raws("/api/embed/ticket").first)
        let body = try #require(rig.network.bodies("/api/embed/ticket").first)
        #expect(SecureRig.identity(body) as? [String: String] == ["value": "user-123", "token": hex])
        #expect(raw.components(separatedBy: hex).count == 2, "the token is in the body exactly once: inside identity")
        #expect(!(JSON.string(from: body["metadata"] as? [String: Any] ?? [:]) ?? "").contains(hex), "never in the ticket's variables")
        #expect(!rig.graine.currentVariables().values.contains { $0.contains(hex) }, "never a prompt variable")
        #expect(!(JSON.string(from: rig.graine.currentContextFrame() ?? [:]) ?? "").contains(hex), "never in the screen context")
        let socket = try #require(rig.network.sockets.first)
        #expect(!socket.url.absoluteString.contains(hex), "never on a URL")
        #expect(!socket.protocols.joined().contains(hex))
        #expect(!rig.log.lines.joined().contains(hex), "never logged")
        // The engine page's identity message carries it inside its own field; its debug line never.
        #expect(!GraineProtocol.redactForLog(GraineProtocol.out(GraineProtocol.Out.identity, ["value": "user-123", "token": hex])).contains(hex))
    }

    /// Sign out, sign in as someone else: the last person's token and pass go nowhere, not even with their own sign-out.
    @Test func anAccountChangeNeverSendsTheOldTokenOrPass() async throws {
        let rig = SecureRig()
        defer { rig.clean() }
        rig.session(app: "off", user: "report")
        rig.graine.identify(["user_id": "user-A"], identityToken: "token-A")
        rig.network.answer("/api/embed/ticket", (200, #"{"ticket":"tkt-1","wsUrl":"wss://ws.graine.ai/v1/embed","verification":{"user":"verified","userPass":"up1.A","userPassExpiresIn":3600}}"#))
        rig.graine.chat.open()
        // Later tickets (the chat reconnecting for whoever comes next) bring no pass of anyone's.
        rig.network.answer("/api/embed/ticket", (200, #"{"ticket":"tkt-2","wsUrl":"wss://ws.graine.ai/v1/embed"}"#))
        _ = try await rig.graine.memories()
        let kept = try #require(rig.network.bodies("/api/embed/memory/list").last)
        #expect(SecureRig.identity(kept) as? [String: String] == ["value": "user-A", "token": "token-A", "pass": "up1.A"], "the pass Graine issued goes with its identity")
        #expect(rig.graine.verification.user == .verified)

        rig.graine.identify(nil)
        let signout = try #require(rig.network.bodies("/api/embed/identity/signout").last)
        #expect(SecureRig.identity(signout) as? [String: String] == ["value": "user-A"], "a sign-out names who left — with no token, no pass")
        rig.graine.identify(["user_id": "user-B"])
        _ = try await rig.graine.memories()
        let other = try #require(rig.network.bodies("/api/embed/memory/list").last)
        #expect(SecureRig.identity(other) as? [String: String] == ["value": "user-B"])
        #expect(rig.graine.verification.user == .unverified, "the last person's verdict is not theirs")
        rig.graine.identify(["user_id": "user-B"], identityToken: "token-B")
        _ = try await rig.graine.memories()
        #expect(SecureRig.identity(rig.network.bodies("/api/embed/memory/list").last) as? [String: String] == ["value": "user-B", "token": "token-B"])
        let everything = rig.network.posts.filter { !$0.raw.contains("user-A") }.map(\.raw).joined()
        #expect(!everything.contains("token-A") && !everything.contains("up1.A"), "nothing of user-A's goes with anyone else")
    }

    @Test func setIdentityTokenKeepsTheIdentity() async throws {
        let rig = SecureRig()
        defer { rig.clean() }
        rig.session()
        rig.graine.setIdentityToken("orphan")
        #expect(rig.graine.identity.currentToken() == nil, "nobody identified: nothing to attach it to")
        rig.graine.identify(["user_id": "user-123"], identityToken: "t1")
        rig.graine.setIdentityToken("t2")
        #expect(rig.graine.identity.snapshot().value == "user-123")
        _ = try await rig.graine.memories()
        #expect(SecureRig.identity(rig.network.bodies("/api/embed/memory/list").last) as? [String: String] == ["value": "user-123", "token": "t2"])
        // The same identity with other traits keeps it; another identity drops it.
        rig.graine.identify(["user_id": "user-123", "name": "Asha"])
        #expect(rig.graine.identity.currentToken() == "t2")
        rig.graine.setIdentityToken(nil)
        #expect(rig.graine.identity.currentToken() == nil)
        #expect(rig.graine.identity.snapshot().value == "user-123", "clearing the token keeps the identity")
        rig.graine.identify(["user_id": "user-123"], identityToken: String(repeating: "x", count: 5000))
        #expect(rig.graine.identity.currentToken() == nil, "a token that cannot be sent replaces nothing with nothing")
    }

    @Test func beforeTheSessionATokenOutlivesOnlyTheSameTraits() {
        let state = IdentityState(choices: nil)
        state.identify(["user_id": "u1", "name": "A"], memory: nil, token: .set("t1"))
        state.identify(["user_id": "u1", "name": "A"], memory: nil)
        state.setField("user_id")
        #expect(state.currentToken() == "t1")
        let early = IdentityState(choices: nil)
        early.identify(["user_id": "u1", "name": "A"], memory: nil, token: .set("t1"))
        early.identify(["user_id": "u1", "name": "B"], memory: nil)
        early.setField("user_id")
        #expect(early.currentToken() == nil, "who the traits name cannot be told before the session: the token is not carried over")
        #expect(early.proof(for: "u2") == .none)
    }

    /// `identity_unverified` asks the refresher and sends the request once more, with the new token — once.
    @Test func identityUnverifiedRefreshesTheTokenAndRetriesOnce() async throws {
        let rig = SecureRig()
        defer { rig.clean() }
        rig.session(user: "enforce")
        rig.graine.identify(["user_id": "user-123"], identityToken: "stale")
        var asked = 0
        rig.graine.identityTokenRefresher = {
            asked += 1
            return "fresh"
        }
        rig.network.answer("/api/embed/memory/list", (403, #"{"code":"identity_unverified","error":"Not verified."}"#), (200, #"{"memories":[]}"#))
        _ = try await rig.graine.memories()
        let sent = rig.network.bodies("/api/embed/memory/list")
        #expect(sent.count == 2)
        #expect(SecureRig.identity(sent[0])?["token"] as? String == "stale")
        #expect(SecureRig.identity(sent[1])?["token"] as? String == "fresh")
        #expect(asked == 1)

        // Refused again after the refresh: one retry, then the refusal is the app's.
        let again = SecureRig()
        defer { again.clean() }
        again.session(user: "enforce")
        again.graine.identify(["user_id": "user-123"], identityToken: "stale")
        again.graine.identityTokenRefresher = { "fresh" }
        again.network.answer("/api/embed/memory/list", (403, #"{"code":"identity_unverified","error":"Not verified."}"#))
        await #expect(throws: GraineServiceError.self) { _ = try await again.graine.memories() }
        #expect(again.network.bodies("/api/embed/memory/list").count == 2, "asked once more, never a third time")

        // No refresher: nothing to cure with — the refusal is the app's at once.
        let bare = SecureRig()
        defer { bare.clean() }
        bare.session(user: "enforce")
        bare.graine.identify(["user_id": "user-123"])
        bare.network.answer("/api/embed/memory/list", (403, #"{"code":"identity_unverified"}"#))
        do {
            _ = try await bare.graine.memories()
            Issue.record("refused")
        } catch let error as GraineServiceError {
            #expect(error.code == .identityUnverified)
        }
        #expect(bare.network.bodies("/api/embed/memory/list").count == 1)
    }

    @Test func theRefresherIsAskedAtMostOnceIn30SecondsAndNeverTwiceAtOnce() async throws {
        var now = 1_000.0
        let refresh = IdentityTokenRefresh(clock: { now }, after: { _, _ in })
        var calls = 0
        refresh.refresher = {
            calls += 1
            try? await Task.sleep(nanoseconds: 20_000_000)
            return "t\(calls)"
        }
        var applied: [String] = []
        var answers: [Bool] = []
        let capture: () -> (String) -> Bool = { { token in applied.append(token); return true } }
        refresh.refresh(capture: capture) { answers.append($0) }
        refresh.refresh(capture: capture) { answers.append($0) }
        try await eventually("both answered") { answers.count == 2 }
        #expect(calls == 1, "a caller while one is on its way hears its answer")
        #expect(answers == [true, true])
        #expect(applied == ["t1"])
        now += 10
        var soon: Bool?
        refresh.refresh(capture: capture) { soon = $0 }
        #expect(soon == false && calls == 1, "not again within 30 s")
        now += 25
        var later: Bool?
        refresh.refresh(capture: capture) { later = $0 }
        try await eventually("asked again") { later != nil }
        #expect(calls == 2 && later == true)
        // nil changes nothing.
        refresh.refresher = { nil }
        now += 31
        var none: Bool?
        refresh.refresh(capture: capture) { none = $0 }
        try await eventually("answered nil") { none != nil }
        #expect(none == false && applied == ["t1", "t2"])
    }

    /// A refresh asked for one person never lands on the next.
    @Test func aTokenRefreshedForSomeoneWhoSignedOutIsDropped() async throws {
        let rig = SecureRig()
        defer { rig.clean() }
        rig.session(user: "enforce")
        rig.graine.identify(["user_id": "user-A"], identityToken: "token-A")
        var release: CheckedContinuation<Void, Never>?
        rig.graine.identityTokenRefresher = {
            await withCheckedContinuation { release = $0 }
            return "token-A2"
        }
        var changed: Bool?
        rig.graine.refreshIdentityToken { changed = $0 }
        try await eventually("asked") { release != nil }
        rig.graine.identify(["user_id": "user-B"])
        release?.resume()
        try await eventually("answered") { changed != nil }
        #expect(changed == false)
        #expect(rig.graine.identity.currentToken() == nil, "user-B never gets user-A's token")
    }

    @Test func aJwtAboutToExpireIsRefreshedBeforeTheTicket() async throws {
        let rig = SecureRig()
        defer { rig.clean() }
        rig.session(user: "enforce")
        let now = rig.clock.now.timeIntervalSince1970
        let soon = fakeJwt(exp: now + 30)
        let fresh = fakeJwt(exp: now + 3600, salt: "b")
        rig.graine.identify(["user_id": "user-123"], identityToken: soon)
        rig.graine.identityTokenRefresher = { fresh }
        rig.graine.chat.open()
        try await eventually("the ticket") { !rig.network.bodies("/api/embed/ticket").isEmpty }
        #expect(SecureRig.identity(rig.network.bodies("/api/embed/ticket").first)?["token"] as? String == fresh)

        // An hour left: nothing asked, nothing waited for.
        let calm = SecureRig()
        defer { calm.clean() }
        calm.session(user: "enforce")
        calm.graine.identify(["user_id": "user-123"], identityToken: fresh)
        var asked = false
        calm.graine.identityTokenRefresher = {
            asked = true
            return "x"
        }
        calm.graine.chat.open()
        #expect(calm.network.bodies("/api/embed/ticket").count == 1, "at once")
        #expect(!asked)
    }

    @Test func anAnswerSayingTheTokenExpiredAsksTheRefresherInTheBackground() async throws {
        let rig = SecureRig()
        defer { rig.clean() }
        rig.session(user: "report")
        rig.graine.identify(["user_id": "user-123"], identityToken: "old")
        var asked = 0
        rig.graine.identityTokenRefresher = {
            asked += 1
            return "new"
        }
        rig.network.answer("/api/embed/ticket", (200, #"{"ticket":"tkt-1","wsUrl":"wss://ws.graine.ai/v1/embed","verification":{"user":"invalid","userReason":"expired"}}"#))
        rig.graine.chat.open()
        #expect(rig.graine.verification.user == .invalid)
        #expect(rig.graine.verification.userReason == "expired")
        try await eventually("refreshed") { rig.graine.identity.currentToken() == "new" }
        #expect(asked == 1)
        #expect(rig.network.bodies("/api/embed/ticket").count == 1, "the conversation is not asked again: the next one has the new token")
    }
}

// MARK: - Proving the app

@Suite @MainActor struct AppProofTests {
    @Test func theFirstProofAttestsAKeyThenAssertsIt() throws {
        let rig = SecureRig()
        defer { rig.clean() }
        rig.session(app: "report")
        #expect(rig.attest.calls == ["generate", "attest(key-1)"])
        let challenge = ProofNetwork.challenges[0]
        #expect(rig.attest.hashes.first == Data(SHA256.hash(data: Data(challenge.utf8))), "clientDataHash = SHA256(challenge)")
        let verify = try #require(rig.network.bodies("/api/embed/app-verify").first)
        #expect(verify["challenge"] as? String == challenge)
        #expect(verify["installId"] as? String == "3f2504e0-4f89-11d3-9a0c-0305e82c3301")
        let proof = try #require(verify["proof"] as? [String: String])
        #expect(proof == ["kind": "attest", "keyId": "key-1", "attestation": Data("attestation-key-1".utf8).base64EncodedString()])
        #expect(SecureRig.app(verify)?["pass"] == nil, "no pass yet")
        #expect(rig.keys.value?.keyId == "key-1" && rig.keys.value?.attested == true)
        #expect(rig.passes.value?.pass == "ap1.pass" && rig.passes.value?.publishableKey == SecureRig.key)
        #expect(rig.graine.verification.app == .verified)

        // The pass goes with every request now.
        rig.graine.chat.open()
        #expect(SecureRig.app(rig.network.bodies("/api/embed/ticket").first)?["pass"] as? String == "ap1.pass")

        // Less than six hours left: renewed at the next foreground — an assertion this time.
        rig.clock.advance(19 * 3600)
        rig.graine.setForeground(false)
        rig.graine.setForeground(true)
        #expect(rig.attest.calls == ["generate", "attest(key-1)", "assert(key-1)"])
        let renewal = try #require(rig.network.bodies("/api/embed/app-verify").last?["proof"] as? [String: String])
        #expect(renewal == ["kind": "assert", "keyId": "key-1", "assertion": Data("assertion-key-1".utf8).base64EncodedString()])
    }

    @Test func thePassIsKeptForItsKeyUntilItExpires() async throws {
        // A pass kept for another publishable key is dropped, never sent.
        let foreign = SecureRig(pass: StoredAppPass(publishableKey: "pk_other", pass: "ap1.foreign", verdict: "verified", expiresAt: 1_792_000_000 + 80_000))
        defer { foreign.clean() }
        foreign.session(app: "report")
        #expect(!foreign.network.posts.map(\.raw).joined().contains("ap1.foreign"))
        #expect(foreign.passes.value?.pass == "ap1.pass", "replaced by this key's own")

        // Twelve hours left: sent, and nothing proven.
        let kept = SecureRig(key: ("key-1", true))
        defer { kept.clean() }
        kept.passes.write(kept.pass(hoursLeft: 12))
        kept.session(app: "report")
        #expect(kept.attest.calls.isEmpty)
        #expect(kept.graine.verification.app == .verified)
        _ = try await kept.graine.scheduledCalls()
        #expect(SecureRig.app(kept.network.bodies("/api/embed/calls/list").first)?["pass"] as? String == "ap1.kept")
        // Expired: not sent.
        kept.clock.advance(13 * 3600)
        _ = try await kept.graine.scheduledCalls()
        #expect(SecureRig.app(kept.network.bodies("/api/embed/calls/list").last)?["pass"] == nil)
    }

    @Test func enforceWaitsForAProofBeforeATicket() throws {
        let rig = SecureRig()
        defer { rig.clean() }
        rig.network.holding.insert("/api/embed/app-verify")
        rig.session(app: "enforce")
        #expect(rig.graine.verification.app == .checking)
        rig.graine.chat.open()
        #expect(rig.network.bodies("/api/embed/ticket").isEmpty, "the ticket waits for the proof on its way")
        rig.network.release("/api/embed/app-verify")
        let ticket = try #require(rig.network.bodies("/api/embed/ticket").first)
        #expect(SecureRig.app(ticket)?["pass"] as? String == "ap1.pass")

        // Ten seconds at most: then the ticket goes, without.
        let slow = SecureRig()
        defer { slow.clean() }
        slow.network.holding.insert("/api/embed/app-verify")
        slow.session(app: "enforce")
        slow.graine.chat.open()
        slow.clock.advance(9)
        #expect(slow.network.bodies("/api/embed/ticket").isEmpty)
        slow.clock.advance(1)
        #expect(slow.network.bodies("/api/embed/ticket").count == 1)
        #expect(SecureRig.app(slow.network.bodies("/api/embed/ticket").first)?["pass"] == nil)

        // Report: nothing waits.
        let report = SecureRig()
        defer { report.clean() }
        report.network.holding.insert("/api/embed/app-verify")
        report.session(app: "report")
        report.graine.chat.open()
        #expect(report.network.bodies("/api/embed/ticket").count == 1)
    }

    @Test func appNotVerifiedProvesThenRetriesOnce() async throws {
        let rig = SecureRig()
        defer { rig.clean() }
        rig.session(app: "enforce")
        #expect(rig.passes.value?.pass == "ap1.pass")
        rig.network.answer("/api/embed/app-verify", (200, #"{"verification":{"app":"verified","appPass":"ap1.second","appPassExpiresIn":86400}}"#))
        rig.network.answer("/api/embed/memory/list", (403, #"{"code":"app_not_verified","reason":"expired"}"#), (200, #"{"memories":[]}"#))
        rig.graine.identify(["user_id": "user-123"])
        _ = try await rig.graine.memories()
        let sent = rig.network.bodies("/api/embed/memory/list")
        #expect(sent.count == 2)
        #expect(SecureRig.app(sent[0])?["pass"] as? String == "ap1.pass")
        #expect(SecureRig.app(sent[1])?["pass"] as? String == "ap1.second", "asked again with the pass the proof brought")
        #expect(rig.attest.calls.last == "assert(key-1)")

        // Refused again: once, and the refusal is the app's.
        let again = SecureRig()
        defer { again.clean() }
        again.network.answer("/api/embed/app-verify", (200, #"{"verification":{"app":"verified","appPass":"ap1.one","appPassExpiresIn":86400}}"#),
                             (200, #"{"verification":{"app":"verified","appPass":"ap1.two","appPassExpiresIn":86400}}"#))
        again.session(app: "enforce")
        again.network.answer("/api/embed/memory/list", (403, #"{"code":"app_not_verified","reason":"invalid"}"#))
        again.graine.identify(["user_id": "user-123"])
        do {
            _ = try await again.graine.memories()
            Issue.record("refused")
        } catch let error as GraineServiceError {
            #expect(error.code == .appNotVerified)
            #expect(error.reason == "invalid")
        }
        #expect(again.network.bodies("/api/embed/memory/list").count == 2)
    }

    @Test func appNotAllowedIsFinal() throws {
        let rig = SecureRig()
        defer { rig.clean() }
        rig.session(app: "report")
        rig.network.answer("/api/embed/ticket", (403, #"{"code":"app_not_allowed","error":"This app is not allowed."}"#))
        let heard = HeardErrors()
        rig.graine.addListener(heard)
        rig.graine.chat.open()
        #expect(rig.network.bodies("/api/embed/ticket").count == 1, "never asked again")
        #expect(rig.network.sockets.isEmpty, "never the direct socket either")
        #expect(rig.graine.chat.status == .failed, "refused: it gave up (0.14.5: failed, where it said offline)")
        #expect(heard.errors == ["This app is not allowed."])
    }

    @Test func anUnknownKeyIsForgottenAndANewOneAttested() throws {
        let rig = SecureRig(key: ("key-old", true))
        defer { rig.clean() }
        rig.network.answer("/api/embed/app-verify", (403, #"{"code":"app_not_verified","reason":"unknown_key"}"#), (200, #"{"verification":{"app":"verified","appPass":"ap1.new","appPassExpiresIn":86400}}"#))
        rig.session(app: "report")
        #expect(rig.attest.calls == ["assert(key-old)", "generate", "attest(key-1)"])
        #expect(rig.network.bodies("/api/embed/app-verify/challenge").count == 2, "the used challenge is never sent twice")
        #expect(rig.keys.value?.keyId == "key-1" && rig.keys.value?.attested == true)
        #expect(rig.passes.value?.pass == "ap1.new")

        // App Attest says the key is gone (a restore to another phone): a new key, attested with the same, unused challenge.
        let gone = SecureRig(key: ("key-old", true))
        defer { gone.clean() }
        gone.attest.assertResults = [.failure(.invalidKey)]
        gone.session(app: "report")
        #expect(gone.attest.calls == ["assert(key-old)", "generate", "attest(key-1)"])
        #expect(gone.network.bodies("/api/embed/app-verify/challenge").count == 1)
        #expect(gone.graine.verification.app == .verified)
    }

    @Test func aRefusedChallengeIsAskedForAgainOnce() throws {
        let rig = SecureRig()
        defer { rig.clean() }
        rig.network.answer("/api/embed/app-verify", (403, #"{"code":"app_not_verified","reason":"challenge"}"#), (200, #"{"verification":{"app":"verified","appPass":"ap1.ok","appPassExpiresIn":86400}}"#))
        rig.session(app: "report")
        let verifies = rig.network.bodies("/api/embed/app-verify")
        #expect(verifies.count == 2)
        #expect(verifies[0]["challenge"] as? String == ProofNetwork.challenges[0])
        #expect(verifies[1]["challenge"] as? String == ProofNetwork.challenges[1])
        #expect(rig.graine.verification.app == .verified)

        let twice = SecureRig()
        defer { twice.clean() }
        twice.network.answer("/api/embed/app-verify", (403, #"{"code":"app_not_verified","reason":"challenge"}"#))
        twice.session(app: "report")
        #expect(twice.network.bodies("/api/embed/app-verify").count == 2, "once more, not a third time")
        #expect(twice.graine.verification.app == .unverified)
        #expect(twice.graine.verification.appReason == "challenge")
    }

    @Test func anOutageIsTriedAgainIn30Seconds2Minutes10MinutesThenAtTheNextForeground() {
        let rig = SecureRig()
        defer { rig.clean() }
        rig.network.answer("/api/embed/app-verify", (503, #"{"code":"unavailable"}"#))
        rig.session(app: "report")
        func proofs() -> Int { rig.network.bodies("/api/embed/app-verify").count }
        #expect(proofs() == 1)
        #expect(rig.clock.waiting == [30])
        rig.clock.advance(29)
        #expect(proofs() == 1)
        rig.clock.advance(1)
        #expect(proofs() == 2)
        #expect(rig.clock.waiting == [120])
        rig.clock.advance(120)
        #expect(proofs() == 3)
        #expect(rig.clock.waiting == [600])
        rig.clock.advance(600)
        #expect(proofs() == 4)
        #expect(rig.clock.waiting.isEmpty, "spent: the next foreground")
        rig.graine.setForeground(false)
        rig.graine.setForeground(true)
        #expect(proofs() == 5)
        // Apple out of reach (DCError.serverUnavailable) climbs the same ladder.
        let apple = SecureRig()
        defer { apple.clean() }
        apple.attest.attestResults = [.failure(.serverUnavailable)]
        apple.session(app: "report")
        #expect(apple.network.bodies("/api/embed/app-verify").isEmpty, "no pass held: no grace to ask for")
        #expect(apple.clock.waiting == [30])
        apple.clock.advance(30)
        #expect(apple.network.bodies("/api/embed/app-verify").count == 1, "tried again, and through")
        #expect(apple.graine.verification.app == .verified)
    }

    /// Apple out of reach with a pass held — even an expired one: `{kind: "unavailable"}`, and a grace pass is a pass.
    @Test func anOutageWithAPassHeldAsksForAGracePass() throws {
        let rig = SecureRig()
        defer { rig.clean() }
        rig.passes.write(rig.pass("ap1.expired", hoursLeft: -2))
        rig.attest.attestResults = [.failure(.serverUnavailable)]
        rig.network.answer("/api/embed/app-verify", (200, #"{"verification":{"app":"verified","appPass":"ap1.grace","appPassExpiresIn":3600}}"#))
        rig.session(app: "enforce")
        let grace = try #require(rig.network.bodies("/api/embed/app-verify").first)
        #expect(grace["proof"] as? [String: String] == ["kind": "unavailable"])
        #expect(grace["challenge"] == nil, "no challenge needed")
        #expect(SecureRig.app(grace)?["pass"] as? String == "ap1.expired", "the pass held, expired as it is")
        #expect(rig.passes.value?.pass == "ap1.grace")
        #expect(rig.graine.verification.app == .verified)
        #expect(rig.clock.waiting == [30], "App Attest tried again on the ladder")
        rig.graine.chat.open()
        #expect(SecureRig.app(rig.network.bodies("/api/embed/ticket").first)?["pass"] as? String == "ap1.grace")
    }

    @Test func aRingRenewsTheProofAndRefreshesTheTokenBeforeTheAnswer() async throws {
        let rig = SecureRig()
        defer { rig.clean() }
        rig.network.answer("/api/embed/app-verify", (503, #"{"code":"unavailable"}"#), (200, #"{"verification":{"app":"verified","appPass":"ap1.ring","appPassExpiresIn":86400}}"#))
        rig.session(app: "report", user: "report")
        #expect(rig.clock.waiting == [30], "an outage: the next try in 30 s")
        rig.graine.identify(["user_id": "user-123"], identityToken: "before-ring")
        var asked = 0
        rig.graine.identityTokenRefresher = {
            asked += 1
            return "after-ring"
        }
        rig.graine.ringArrived()
        #expect(rig.network.bodies("/api/embed/app-verify").count == 2, "proven now, whatever the ladder says: the person is about to answer")
        #expect(rig.passes.value?.pass == "ap1.ring")
        try await eventually("token refreshed") { rig.graine.identity.currentToken() == "after-ring" }
        #expect(asked == 1)
    }

    /// A ring that woke a closed app: the checks the last session kept stand in, and the proof is renewed before the answer.
    @Test func aRingOnAColdStartUsesTheChecksTheLastSessionKept() throws {
        let rig = SecureRig()
        defer { rig.clean() }
        rig.graine.sessionCache.save(GraineSessionConfig.parse([
            "agentId": "agent-1", "security": ["app": ["verify": "enforce"], "user": ["verify": "off"]],
        ]))
        #expect(rig.graine.session == nil, "this launch's session has not arrived")
        rig.graine.ringArrived()
        #expect(rig.attest.calls == ["generate", "attest(key-1)"])
        #expect(rig.passes.value?.pass == "ap1.pass")
    }

    /// Refused for want of a proof before this launch's session said anything: the refusal says the agent checks the app.
    @Test func aRefusalForWantOfAProofIsCuredBeforeTheSessionArrives() async throws {
        let rig = SecureRig()
        defer { rig.clean() }
        let retried = await withCheckedContinuation { c in
            rig.graine.security.cure(GraineServiceError(code: .appNotVerified, message: "No pass.", status: 403, reason: "missing")) { c.resume(returning: $0) }
        }
        #expect(retried, "proven, so asked once more")
        #expect(rig.attest.calls == ["generate", "attest(key-1)"])
    }

    @Test func theAgentsSettingsKeepTheirLongerBudgetOnASlowNetwork() async throws {
        let rig = SecureRig()
        defer { rig.clean() }
        _ = await rig.graine.sessionNow()
        _ = try await rig.graine.scheduledCalls()
        #expect(rig.network.patientPaths == ["/api/embed/session"], "only the session: 30 s in all, as it always had")
    }

    /// An answer's verdict carries no reason of its own: an old one is not kept with it.
    /// The App Attest key id lives in the SDK's defaults — never the Keychain — one per publishable key.
    @Test func theKeyIdLivesInTheDefaultsPerKey() {
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        let one = DefaultsAttestKeyStore(defaults: sandbox.defaults, publishableKey: "pk_test_one")
        let two = DefaultsAttestKeyStore(defaults: sandbox.defaults, publishableKey: "pk_test_two")
        one.write("key-one", attested: false)
        one.write("key-one", attested: true)
        #expect(one.read()?.keyId == "key-one" && one.read()?.attested == true)
        #expect(two.read() == nil, "another agent's key is its own")
        #expect(sandbox.defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("ai.graine.inapp.app-attest.") })
        one.write(nil, attested: false)
        #expect(one.read() == nil)
    }

    @Test func anAnswersVerdictKeepsNoStaleReason() throws {
        let rig = SecureRig()
        defer { rig.clean() }
        rig.network.answer("/api/embed/app-verify", (403, #"{"code":"app_not_verified","reason":"wrong_app"}"#))
        rig.session(app: "report")
        #expect(rig.graine.verification.appReason == "wrong_app")
        rig.network.answer("/api/embed/ticket", (200, #"{"ticket":"t","wsUrl":"wss://ws.graine.ai/v1/embed","verification":{"app":"unverified"}}"#))
        rig.graine.chat.open()
        #expect(rig.graine.verification.app == .unverified)
        #expect(rig.graine.verification.appReason == nil)
    }

    @Test func theVerificationIsPublished() async throws {
        let rig = SecureRig()
        defer { rig.clean() }
        #expect(rig.graine.verification == GraineVerification(), "off before the session says otherwise")
        rig.network.holding.insert("/api/embed/app-verify")
        rig.session(app: "report", user: "report")
        #expect(rig.graine.verification.app == .checking)
        #expect(rig.graine.verification.user == .unverified)
        rig.network.release("/api/embed/app-verify")
        #expect(rig.graine.verification.app == .verified)
        rig.network.answer("/api/embed/ticket", (200, #"{"ticket":"t","wsUrl":"wss://ws.graine.ai/v1/embed","verification":{"app":"debug_token","user":"test_user"}}"#))
        rig.graine.identify(["user_id": "qa-1"])
        rig.graine.chat.open()
        #expect(rig.graine.verification == GraineVerification(app: .debugToken, user: .testUser))
        // Off when the agent checks nothing.
        let off = SecureRig()
        defer { off.clean() }
        off.session(app: "off", user: "off")
        #expect(off.graine.verification == GraineVerification())
        #expect(off.attest.calls.isEmpty)
    }

    @Test func prepareAppVerificationProvesWhenTheAgentChecks() async throws {
        let rig = SecureRig()
        defer { rig.clean() }
        rig.network.answer("/api/embed/session", (200, #"{"agentId":"a","security":{"app":{"verify":"enforce"},"user":{"verify":"off"}}}"#))
        let verdict = await rig.graine.prepareAppVerification()
        #expect(verdict == .verified)
        #expect(rig.network.bodies("/api/embed/app-verify").count == 1, "proven once: the session's own proof is the one awaited")
        #expect(await rig.graine.prepareAppVerification() == .verified)
        #expect(rig.network.bodies("/api/embed/app-verify").count == 1, "a fresh pass: nothing proven again")

        let off = SecureRig()
        defer { off.clean() }
        off.network.answer("/api/embed/session", (200, #"{"agentId":"a","security":{"app":{"verify":"off"},"user":{"verify":"off"}}}"#))
        #expect(await off.graine.prepareAppVerification() == .off)
        #expect(off.attest.calls.isEmpty)

        let refused = SecureRig()
        defer { refused.clean() }
        refused.network.answer("/api/embed/session", (200, #"{"agentId":"a","security":{"app":{"verify":"report"},"user":{"verify":"off"}}}"#))
        refused.network.answer("/api/embed/app-verify", (403, #"{"code":"app_not_verified","reason":"wrong_app"}"#))
        #expect(await refused.graine.prepareAppVerification() == .unverified)
        #expect(refused.graine.verification.appReason == "wrong_app")
    }
}

/// Collects `onError`.
final class HeardErrors: GraineListener {
    var errors: [String] = []
    func onError(_ message: String) { errors.append(message) }
}

// MARK: - Development mode

@Suite @MainActor struct DevelopmentModeTests {
    private func token(_ body: [String: Any]?) -> String? { SecureRig.app(body)?["debugToken"] as? String }

    @Test func aDebugBuildSendsItsDebugTokenInsteadOfAProof() async throws {
        let store = MemoryInstallIdStore()
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        let rig = SecureRig(debugBuild: true, debugTokens: store, sandbox: sandbox)
        rig.session(app: "enforce")
        #expect(rig.attest.calls.isEmpty, "App Attest never runs in development mode")
        #expect(rig.network.bodies("/api/embed/app-verify").isEmpty)
        let made = try #require(rig.graine.debugToken)
        #expect(DebugToken.isValid(made))
        #expect(store.value == made, "kept with the install id")
        rig.graine.chat.open()
        #expect(rig.network.bodies("/api/embed/ticket").count == 1, "nothing waits for a proof")
        #expect(token(rig.network.bodies("/api/embed/ticket").first) == made)
        _ = try await rig.graine.scheduledCalls()
        #expect(token(rig.network.bodies("/api/embed/calls/list").first) == made, "on every request")
        let line = DebugToken.logLine(made)
        #expect(rig.log.lines.filter { $0 == line }.count == 1, "logged once, word for word")
        #expect(await rig.graine.prepareAppVerification() == .unverified, "nothing to prove: the verdict comes with the next conversation")
        #expect(rig.attest.calls.isEmpty)

        // The same install, launched again: the same token, not logged again.
        let again = SecureRig(debugBuild: true, debugTokens: store, sandbox: sandbox)
        again.session(app: "report")
        #expect(again.graine.debugToken == made)
        #expect(again.log.lines.filter { $0.contains(made) }.isEmpty, "once per install")
    }

    @Test func aReleaseBuildNeverSendsOne() async throws {
        let store = MemoryInstallIdStore()
        let rig = SecureRig(debugBuild: false, debugTokens: store)
        defer { rig.clean() }
        rig.session(app: "enforce")
        rig.graine.chat.open()
        _ = try await rig.graine.scheduledCalls()
        #expect(rig.graine.debugToken == nil)
        #expect(!rig.network.posts.map(\.raw).joined().contains("gdt_"), "never created, never sent")
        #expect(store.writes == 0, "never created")
        #expect(!rig.log.lines.joined().contains("gdt_"), "never logged")
        #expect(rig.attest.calls == ["generate", "attest(key-1)"], "it proves itself")
    }

    @Test func alwaysOptsAReleaseBuildIn() async throws {
        let rig = SecureRig(debugBuild: false, mode: .always)
        defer { rig.clean() }
        rig.session(app: "enforce")
        let made = try #require(rig.graine.debugToken)
        _ = try await rig.graine.scheduledCalls()
        #expect(token(rig.network.bodies("/api/embed/calls/list").first) == made)
        #expect(rig.attest.calls.isEmpty)
    }

    @Test func neverMakesADebugBuildProveItself() async throws {
        let rig = SecureRig(debugBuild: true, mode: .never)
        defer { rig.clean() }
        rig.session(app: "enforce")
        #expect(rig.graine.debugToken == nil)
        #expect(rig.attest.calls == ["generate", "attest(key-1)"])
        _ = try await rig.graine.scheduledCalls()
        #expect(token(rig.network.bodies("/api/embed/calls/list").first) == nil)
        // Switched at run time: from the next request.
        rig.graine.debugTokenMode = .always
        _ = try await rig.graine.scheduledCalls()
        #expect(token(rig.network.bodies("/api/embed/calls/list").last) != nil)
    }

    @Test func anUnregisteredDebugTokenIsNotCuredByProving() async throws {
        let rig = SecureRig(debugBuild: true)
        defer { rig.clean() }
        rig.session(app: "enforce")
        rig.network.answer("/api/embed/memory/list", (403, #"{"code":"app_not_verified","reason":"debug_token_unknown"}"#))
        rig.graine.identify(["user_id": "user-123"])
        do {
            _ = try await rig.graine.memories()
            Issue.record("refused")
        } catch let error as GraineServiceError {
            #expect(error.code == .appNotVerified)
            #expect(error.reason == "debug_token_unknown")
        }
        #expect(rig.network.bodies("/api/embed/memory/list").count == 1, "nothing to cure: register the token")
        #expect(rig.graine.verification.appReason == "debug_token_unknown")
    }
}

// MARK: - The Objective-C facade

@Suite @MainActor struct AppIdentityObjCTests {
    @Test func theFacadeMirrorsYourAppAndYourUsers() async throws {
        let rig = SecureRig()
        defer { rig.clean() }
        rig.network.answer("/api/embed/session", (200, #"{"agentId":"a","security":{"app":{"verify":"report"},"user":{"verify":"enforce","method":"hmac"}}}"#))
        let graine = GraineObjC(graine: rig.graine)
        var events: [String] = []
        let watching = graine.observeEvents { name, _ in events.append(name) }
        var changes: [String] = []
        let observing = graine.observeVerification { changes.append($0) }
        let verdict = await withCheckedContinuation { c in graine.prepareAppVerification { c.resume(returning: $0) } }
        #expect(verdict == "verified")
        #expect(graine.verificationApp == "verified")
        #expect(graine.verificationAppReason == nil)
        #expect(graine.verificationUser == "unverified")
        let json = try #require(JSON.object(from: graine.verificationJSON))
        #expect(json["app"] as? String == "verified" && json["user"] as? String == "unverified")
        try await eventually("observed") { !changes.isEmpty && events.contains("verification") }

        graine.identify(["user_id": "user-123"], identityToken: "t1")
        #expect(rig.graine.identity.currentToken() == "t1")
        graine.setIdentityToken("t2")
        #expect(rig.graine.identity.currentToken() == "t2")
        graine.identifyJSON(#"{"user_id":"user-123"}"#, memory: false, identityToken: "t3")
        #expect(rig.graine.identity.currentToken() == "t3" && graine.memoryChoice == false)

        // A block-based refresher, for Kotlin Multiplatform.
        graine.setIdentityTokenRefresher { done in done("from-the-block") }
        #expect(graine.hasIdentityTokenRefresher)
        rig.network.answer("/api/embed/memory/list", (403, #"{"code":"identity_unverified"}"#), (200, #"{"memories":[]}"#))
        let listed = await withCheckedContinuation { c in graine.memories { list, error in c.resume(returning: (list, error)) } }
        #expect(listed.1 == nil)
        #expect(SecureRig.identity(rig.network.bodies("/api/embed/memory/list").last)?["token"] as? String == "from-the-block")
        graine.setIdentityTokenRefresher(nil)
        #expect(!graine.hasIdentityTokenRefresher)

        // Development mode.
        #expect(graine.debugTokenMode == "automatic")
        #expect(graine.debugToken == nil, "a release build: none")
        graine.debugTokenMode = "always"
        #expect(rig.graine.debugTokenMode == .always)
        #expect(DebugToken.isValid(graine.debugToken))
        graine.debugTokenMode = "sometimes"
        #expect(graine.debugTokenMode == "always", "a word it does not know is ignored")
        watching.unregister()
        observing.unregister()
    }

    @Test func theNewSelectorsAreAnsweredByTheirNames() throws {
        let cls = try #require(NSClassFromString("GraineObjC") as? NSObject.Type)
        for s in [
            "identify:identityToken:", "identify:memory:identityToken:", "identifyJSON:identityToken:", "identifyJSON:memory:identityToken:",
            "setIdentityToken:", "setIdentityTokenRefresher:", "hasIdentityTokenRefresher", "prepareAppVerificationWithCompletion:",
            "verificationApp", "verificationAppReason", "verificationUser", "verificationUserReason", "verificationJSON", "observeVerification:",
            "debugTokenMode", "setDebugTokenMode:", "debugToken",
        ] {
            #expect(cls.instancesRespond(to: NSSelectorFromString(s)), "-[GraineObjC \(s)]")
        }
    }
}
