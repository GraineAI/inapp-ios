import Foundation
import Testing
@_spi(GraineRTC) @testable import GraineInApp

/*
 * SERVER TOKENS (CLIENT-TOKENS.md §2.2–2.5) — the token manager on a clock the
 * test moves (asked at start; one question at a time however many wait; backoff
 * after a failure or a throw; a provider that never answers; nothing asked in
 * the background; a ring; refusals asked once, at most once in 5 s, and retried
 * only with a different token), every request a real agent makes carrying the
 * token (and none without a provider), live chats and calls untouched by a
 * token that expires, the chat and a call refused for good, the calls host's
 * pushed tokens, and the Objective-C facade's token block.
 */

/// A body refused with `code` (and Graine's sentence, and its reason when given).
func tokenRefusal(_ code: String, reason: String? = nil) -> Data {
    var o: [String: Any] = ["error": "Refused for its \(code).", "code": code]
    if let reason = reason { o["reason"] = reason }
    return try! JSONSerialization.data(withJSONObject: o)
}

/// Polls, a little at a time, until `condition` holds (or about two seconds pass).
func eventually(_ condition: () -> Bool) async {
    for _ in 0..<400 where !condition() { try? await Task.sleep(nanoseconds: 5_000_000) }
}

/// A count several threads may move.
final class TokenCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

// MARK: - The manager

@Suite struct ClientTokenManagerTests {
    private let base = 1_793_000_000.0
    private let sched = ManualScheduler()

    private var nowSec: Double { base + (sched.now - 1_000) }

    /// A token minted now for `life` seconds.
    private func fresh(_ life: Double = 3_600, id: String = "ct_1") -> String {
        TestTokens.mint(iat: nowSec, exp: nowSec + life, id: id)
    }

    private func tokens(_ p: TestProvider?, random: Double = 0.5, connectionWait: Double = 10, pushWait: Double = 5, providerTimeout: Double = 15) -> ClientTokens {
        let sched = self.sched
        let base = self.base
        return ClientTokens(
            fetch: p.map { $0.fetch },
            clock: { base + (sched.now - 1_000) },
            random: { random },
            schedule: { sched.after($0, $1) },
            background: { $0() },
            providerTimeout: providerTimeout,
            connectionWait: connectionWait,
            pushWait: pushWait
        )
    }

    private func ok() -> Data { Data(#"{"ok":true}"#.utf8) }

    @Test func startAsksAtOnceAndAgainAtTheLeadBeforeExpiry() {
        let first = fresh(id: "ct_1")
        let p = TestProvider { first }
        let t = tokens(p, random: 0)
        #expect(p.asked == 0, "nothing asked before start")
        t.start()
        #expect(p.asked == 1 && t.newest == first && t.inPlay)
        // An hour's token: asked again 600 s (the lead) before it lapses.
        sched.advance(3_000 - 0.01)
        #expect(p.asked == 1)
        p.answer = { [self] in fresh(id: "ct_2") }
        sched.advance(0.01)
        #expect(p.asked == 2)
        #expect(TestTokens.id(t.newest) == "ct_2")
    }

    @Test func aProviderThatThrowsBacksOffThenSucceeds() async {
        struct Down: Error {}
        let good = fresh()
        let calls = TokenCounter()
        let sched = self.sched
        let base = self.base
        let t = ClientTokens(
            fetch: ClientTokens.fetch(async: {
                if calls.next() <= 2 { throw Down() }
                return good
            }),
            clock: { base + (sched.now - 1_000) },
            random: { 0.5 },
            schedule: { sched.after($0, $1) },
            background: { $0() }
        )
        t.start()
        await eventually { t.failuresInARow == 1 }
        #expect(calls.value == 1 && t.newest == nil)
        sched.advance(1.99)
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(calls.value == 1, "2 s after the first failure, not before")
        sched.advance(0.01)
        await eventually { t.failuresInARow == 2 }
        #expect(calls.value == 2)
        sched.advance(3.99)
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(calls.value == 2, "then 4 s")
        sched.advance(0.01)
        await eventually { t.newest != nil }
        #expect(calls.value == 3 && t.newest == good)
        #expect(t.failuresInARow == 0, "a token resets the backoff")
        // The next question is the token's own refresh, not 8 s on.
        sched.advance(8)
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(calls.value == 3)
    }

    @Test func nullIsAFailureAndTheBackoffIsJitteredAndCapped() {
        let p = TestProvider { nil }
        let t = tokens(p, random: 1)
        t.start()
        var waits: [Double] = []
        for _ in 0..<8 {
            let before = p.asked
            let from = sched.now
            while p.asked == before { sched.advance(0.1) }
            waits.append(((sched.now - from) * 10).rounded() / 10)
        }
        // 2, 4, 8, 16, 32, 60, 60, 60 s — each 20 % later at the jitter's top.
        #expect(waits == [2.4, 4.8, 9.6, 19.2, 38.4, 72, 72, 72])
        #expect(t.newest == nil)
    }

    @Test func aProviderThatNeverAnswersHasAnsweredNilAfterFifteenSeconds() {
        let silent = TestProvider()
        silent.manual = true
        let t = tokens(silent)
        t.start()
        #expect(silent.asked == 1)
        sched.advance(14.99)
        #expect(t.failuresInARow == 0, "still waiting")
        sched.advance(0.01)
        #expect(t.failuresInARow == 1, "timed out: a failure")
        sched.advance(2)
        #expect(silent.asked == 2, "then asked again 2 s on")
        // Its late answer is ignored.
        silent.reply("late")
        #expect(t.newest == nil)
    }

    @Test func twoConnectionsAtOnceAskTheProviderOnce() {
        let p = TestProvider()
        p.manual = true
        let t = tokens(p)
        var got: [String?] = []
        t.forConnection { got.append($0) }
        t.forConnection { got.append($0) }
        #expect(p.asked == 1, "one question, however many connections wait")
        #expect(got.isEmpty)
        let token = fresh()
        p.reply(token)
        #expect(got == [token, token])
        #expect(p.asked == 1)
    }

    @Test func aConnectionDuringABackgroundRefreshWaitsForItAndNeverAsksAgain() {
        let short = fresh(60, id: "ct_short")
        let p = TestProvider { short }
        // A slow provider: still answering once the token has 15 s or less left.
        let t = tokens(p, random: 0, providerTimeout: 60)
        t.start()
        // The background refresh is under way (the provider has not answered yet)…
        p.manual = true
        sched.advance(30)
        #expect(p.asked == 2)
        // …and the token has 15 s or less left: a connection waits for that refresh, never asks one of its own.
        sched.advance(16)
        var got: [String?] = []
        t.forConnection { got.append($0) }
        #expect(p.asked == 2 && got.isEmpty)
        let next = fresh(id: "ct_next")
        p.reply(next)
        #expect(got == [next])
        #expect(p.asked == 2)
    }

    @Test func aUsableTokenIsUsedAtOnceAndAConnectionWaitsAtMostItsLimit() {
        let short = fresh(20, id: "ct_short")
        let p = TestProvider { short }
        let t = tokens(p, connectionWait: 10)
        t.start()
        var got: [String?] = []
        t.forConnection { got.append($0) }
        #expect(got == [short] && p.asked == 1, "plenty left: no question")
        // 14 s left: not usable. A provider that does not answer: the connection goes with the newest token after its wait.
        p.manual = true
        sched.advance(6)
        got = []
        t.forConnection { got.append($0) }
        #expect(p.asked == 2 && got.isEmpty)
        sched.advance(9.99)
        #expect(got.isEmpty)
        sched.advance(0.01)
        #expect(got == [short], "after 10 s, the newest it has")
    }

    @Test func nothingIsAskedInTheBackgroundAndAForegroundReturnInsideTheLeadAsks() {
        let p = TestProvider { nil }
        let t = tokens(p, random: 0.5)
        t.start()
        #expect(p.asked == 1)
        t.setForeground(false)
        sched.advance(300)
        #expect(p.asked == 1, "no retries while the app is in the background")
        p.answer = { [self] in fresh() }
        t.setForeground(true)
        #expect(p.asked == 2, "back in front after a failure: asked at once")
        // An hour's token, its refresh due at 2985 s: the app away past it, then back.
        t.setForeground(false)
        sched.advance(3_100)
        #expect(p.asked == 2)
        t.setForeground(true)
        #expect(p.asked == 3, "inside the lead: asked")
        // Back in front well before the lead: nothing now, the refresh at its moment.
        t.setForeground(false)
        sched.advance(60)
        t.setForeground(true)
        #expect(p.asked == 3)
        sched.advance(3_000 - 60)
        #expect(p.asked == 4)
    }

    @Test func aRingAsksForAFreshTokenUnlessOneJustArrived() {
        let p = TestProvider { [self] in fresh() }
        let t = tokens(p)
        t.start()
        t.ring()
        #expect(p.asked == 1, "one arrived just now: enough")
        sched.advance(31)
        t.setForeground(false)
        t.ring()
        #expect(p.asked == 2, "asked, even with the app in the background")
        tokens(nil).ring()
    }

    @Test func theEnginePageAskingForATokenAsksAtMostOnceInFiveSecondsAndIsAlwaysAnswered() {
        let p = TestProvider()
        p.answer = { [self] in fresh(id: "ct_\(p.asked)") }
        let t = tokens(p)
        t.start()
        sched.advance(10)
        var heard: [String?] = []
        t.refreshForPage { heard.append($0) }
        #expect(p.asked == 2 && TestTokens.id(heard.last ?? nil) == "ct_2")
        t.refreshForPage { heard.append($0) }
        #expect(p.asked == 2, "at most one asked anew in 5 s: answered with the newest")
        #expect(heard.count == 2 && heard[1] == t.newest)
        tokens(nil).refreshForPage { heard.append($0) }
        #expect(heard.count == 3 && heard[2] == nil, "none at all: answered at once, with null")
    }

    // MARK: Refusals

    @Test func aTokenExpiredRefusalAsksOnceAndTheRequestGoesOnceMoreWithTheNewToken() {
        let first = fresh(id: "ct_first")
        let second = fresh(id: "ct_second")
        let p = TestProvider { first }
        let t = tokens(p)
        t.start()
        p.answer = { second }
        var sent: [[String: Any]] = []
        var status: Int?
        ClientTokenWire.post(t, body: Data(#"{"publishableKey":"pk"}"#.utf8), newConnection: false, send: { json, answer in
            sent.append(JSON.object(from: json) ?? [:])
            answer(sent.count == 1 ? 401 : 200, sent.count == 1 ? tokenRefusal("token_expired") : self.ok(), [:])
        }) { s, _, _ in status = s }
        #expect(status == 200)
        #expect(p.asked == 2, "exactly one more question")
        #expect(sent.count == 2, "exactly one retry")
        #expect(sent.first?[ClientTokenRules.field] as? String == first)
        #expect(sent.last?[ClientTokenRules.field] as? String == second)
        #expect(sent.last?["publishableKey"] as? String == "pk", "the body as it was, with the new token")
    }

    @Test func tokenScopeKeyRevokedAndTheBotCheckAreFinalAndNeverRetried() {
        let p = TestProvider { [self] in fresh() }
        let t = tokens(p)
        t.start()
        for (code, refused) in [("token_scope", 403), ("key_revoked", 401), ("bot_check_failed", 403)] {
            var sends = 0
            var status: Int?
            ClientTokenWire.post(t, body: Data("{}".utf8), newConnection: true, send: { _, answer in
                sends += 1
                answer(refused, tokenRefusal(code), [:])
            }) { s, _, _ in status = s }
            #expect(sends == 1 && status == refused, "\(code): sent once")
            #expect(p.asked == 1, "\(code): the provider is not asked")
        }
        // Through every request's own path, the refusal arrives as the code with its reason.
        let network = RoutedNetwork()
        network.replies["/api/embed/calls/list"] = (403, #"{"error":"Not for this agent.","code":"token_scope","reason":"agent"}"#)
        let requests = EmbedRequests(baseUrl: "https://www.graine.ai", publishableKey: "pk", network: network, tokens: t)
        var failure: GraineServiceError?
        requests.post("/api/embed/calls/list", []) { result in if case .failure(let e) = result { failure = e } }
        #expect(failure?.code == .tokenScope && failure?.reason == "agent" && failure?.message == "Not for this agent.")
        #expect(network.bodies("/api/embed/calls/list").count == 1)
        #expect(network.bodies("/api/embed/calls/list").first?[ClientTokenRules.field] as? String == t.newest)
        #expect(p.asked == 1)
    }

    @Test func aRefusalAsksAtMostOnceInFiveSecondsAndNeverRetriesWithTheSameToken() {
        let p = TestProvider { [self] in fresh(id: "ct_a") }
        let t = tokens(p)
        t.start()
        // The app's server hands out the same token again: the refusal stands, with no second request.
        let same = t.newest
        p.answer = { same }
        var sends = 0
        ClientTokenWire.post(t, body: Data("{}".utf8), newConnection: false, send: { _, answer in sends += 1; answer(401, tokenRefusal("token_invalid"), [:]) }) { _, _, _ in }
        #expect(p.asked == 2 && sends == 1)
        // A second refusal a second later asks nobody: the refusal stands.
        sched.advance(1)
        sends = 0
        ClientTokenWire.post(t, body: Data("{}".utf8), newConnection: false, send: { _, answer in sends += 1; answer(401, tokenRefusal("token_required"), [:]) }) { _, _, _ in }
        #expect(p.asked == 2 && sends == 1)
        // 5 s on, a refusal may ask again — and goes once more with what it brought.
        p.answer = { [self] in fresh(id: "ct_b") }
        sched.advance(5)
        var sent: [String?] = []
        ClientTokenWire.post(t, body: Data("{}".utf8), newConnection: false, send: { json, answer in
            sent.append(JSON.object(from: json)?[ClientTokenRules.field] as? String)
            answer(sent.count == 1 ? 401 : 200, sent.count == 1 ? tokenRefusal("token_expired") : self.ok(), [:])
        }) { _, _, _ in }
        #expect(p.asked == 3)
        let newest = t.newest
        #expect(sent == [same, newest])
        // A refusal for a token older than the newest — a refresh arrived while it was on its way — goes once more with
        // the newest, asking nobody; one refused with the newest itself, within the 5 s: the refusal stands.
        sched.advance(1)
        var retried: [String?] = []
        t.afterRefusal(sent: same) { retried.append($0) }
        t.afterRefusal(sent: newest) { retried.append($0) }
        #expect(retried == [newest, nil])
        #expect(p.asked == 3)
    }

    @Test func withoutAProviderNoRequestCarriesATokenAndNothingIsRetried() {
        let t = tokens(nil)
        t.start()
        #expect(!t.inPlay)
        var got: [String?] = []
        t.forConnection { got.append($0) }
        #expect(got == [nil])
        var sent: [[String: Any]] = []
        var status: Int?
        ClientTokenWire.post(t, body: Data(#"{"publishableKey":"pk"}"#.utf8), newConnection: true, send: { json, answer in
            sent.append(JSON.object(from: json) ?? [:])
            answer(401, tokenRefusal("token_required"), [:])
        }) { s, _, _ in status = s }
        #expect(status == 401 && sent.count == 1 && sent.first?[ClientTokenRules.field] == nil)
        // And with no manager at all, the body goes as it is.
        var raw: String?
        ClientTokenWire.post(nil, body: Data(#"{"a":1}"#.utf8), newConnection: true, send: { json, answer in
            raw = String(decoding: json, as: UTF8.self)
            answer(200, nil, [:])
        }) { _, _, _ in }
        #expect(raw == #"{"a":1}"#)
        #expect(String(decoding: ClientTokenWire.carry(Data("{}".utf8), "t1"), as: UTF8.self) == #"{"clientToken":"t1"}"#)
        #expect(String(decoding: ClientTokenWire.carry(Data(#"{"a":1}"#.utf8), "t1"), as: UTF8.self) == #"{"a":1,"clientToken":"t1"}"#,
                "the last top-level field; the fields before keep their order")
    }

    // MARK: A calls host's tokens

    @Test func aPushedTokenIsSentAndARefusalAsksTheHostAndWaitsForItsPush() {
        let t = tokens(nil, pushWait: 2)
        var heard: [String?] = []
        _ = t.onChange { heard.append($0) }
        #expect(!t.inPlay)
        t.push("host_1")
        #expect(t.inPlay && t.newest == "host_1")
        var got: [String?] = []
        t.forConnection { got.append($0) }
        #expect(got == ["host_1"], "a connection goes with what the host pushed")
        #expect(heard == ["host_1"])
        var asked = 0
        t.onNeed = { asked += 1; t.push("host_2") }
        var sent: [String] = []
        var status: Int?
        ClientTokenWire.post(t, body: Data("{}".utf8), newConnection: false, send: { json, answer in
            sent.append(JSON.object(from: json)?[ClientTokenRules.field] as? String ?? "")
            answer(sent.count == 1 ? 401 : 200, sent.count == 1 ? tokenRefusal("token_expired") : self.ok(), [:])
        }) { s, _, _ in status = s }
        #expect(status == 200 && asked == 1 && sent == ["host_1", "host_2"])
        // A host that pushes nothing in time: the refusal stands after the wait.
        sched.advance(10)
        t.onNeed = { asked += 1 }
        status = nil
        ClientTokenWire.post(t, body: Data("{}".utf8), newConnection: false, send: { _, answer in answer(401, tokenRefusal("token_expired"), [:]) }) { s, _, _ in status = s }
        #expect(asked == 2 && status == nil, "waiting for the push")
        sched.advance(2)
        #expect(status == 401)
        t.push(nil)
        #expect(t.newest == nil)
        #expect(t.inPlay, "nil is a push too: still the host's tokens")
    }

    @Test func anotherUserLetsTheTokenGoAndAsksAFreshOneAndAnAnswerForTheUserBeforeIsNotKept() {
        let p = TestProvider()
        p.answer = { [self] in fresh(id: "ct_\(p.asked)") }
        let t = tokens(p)
        t.start()
        #expect(TestTokens.id(t.newest) == "ct_1")
        var heard: [String?] = []
        _ = t.onChange { heard.append($0) }
        t.userChanged()
        #expect(heard.first == .some(nil), "the last user's token is let go")
        #expect(p.asked == 2 && TestTokens.id(t.newest) == "ct_2", "and a fresh one asked for at once")
        // A question under way when the user changes again: its answer is not kept, and the question is asked again.
        p.manual = true
        t.userChanged()
        #expect(p.asked == 3 && t.newest == nil)
        var got: [String?] = []
        t.forConnection { got.append($0) }
        t.userChanged()
        #expect(p.asked == 3, "the question under way is not doubled")
        p.reply(fresh(id: "ct_before"))
        #expect(t.newest == nil && got.isEmpty && p.asked == 4, "not kept; asked again, and the connection still waits")
        let mine = fresh(id: "ct_now")
        p.reply(mine)
        #expect(t.newest == mine && got == [mine])
        // A calls host replaces its own tokens.
        let host = tokens(nil)
        host.push("host_1")
        host.userChanged()
        #expect(host.newest == "host_1")
    }

    @Test func anAppsOwnProviderIgnoresPushedTokens() {
        let p = TestProvider { [self] in fresh(id: "ct_app") }
        let t = tokens(p)
        t.start()
        let own = t.newest
        t.push("host_token")
        #expect(t.newest == own)
    }

    @Test func theAsyncProviderHandsOnItsAnswerAndAThrowIsNil() async {
        struct Down: Error {}
        let heard = TokenCounter()
        let answers = AnswerBox()
        ClientTokens.fetch(async: { "tok" })({ token in answers.add(token); _ = heard.next() })
        ClientTokens.fetch(async: { throw Down() })({ token in answers.add(token); _ = heard.next() })
        await eventually { heard.value == 2 }
        #expect(Set(answers.all.map { $0 ?? "nil" }) == ["tok", "nil"])
    }
}

/// Answers several threads may hand over.
final class AnswerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String?] = []
    func add(_ value: String?) { lock.lock(); items.append(value); lock.unlock() }
    var all: [String?] { lock.lock(); defer { lock.unlock() }; return items }
}

// MARK: - A real agent

/// An agent on fakes whose server tokens run on the test's clock, with a session route the test answers.
@MainActor
final class TokenAgentRig {
    static let base = 1_793_000_000.0

    let sandbox = Sandbox()
    let network = RoutedNetwork()
    let scheduler = ManualScheduler()
    let graine: GraineInApp
    /// Every body the session route was asked with.
    private(set) var sessionBodies: [[String: Any]] = []
    /// What the session route answers.
    var sessionAnswer: (Data) -> GraineInApp.SessionReply = { _ in TokenAgentRig.session }

    static let session = GraineInApp.SessionReply(
        status: 200, data: Data(#"{"agentId":"agent-1","webcallAgentId":"web-1","identity":{"field":"user_id"}}"#.utf8), failure: nil
    )

    init(provider: TestProvider?, registry: GraineAgentRegistry? = nil, key: String = "pk_test_rig", name: String = "default") {
        let sched = scheduler
        let tokens = ClientTokens(
            fetch: provider.map { $0.fetch },
            clock: { TokenAgentRig.base + (sched.now - 1_000) },
            random: { 0.5 },
            schedule: { sched.after($0, $1) },
            background: { $0() },
            connectionWait: 1,
            pushWait: 1
        )
        graine = GraineInApp(
            config: GraineConfig(baseUrl: "https://www.graine.ai", publishableKey: key),
            installIds: MemoryInstallIdStore("3f2504e0-4f89-11d3-9a0c-0305e82c3301"),
            defaults: sandbox.defaults,
            sessionCache: SessionCache(directory: sandbox.folder),
            network: network,
            chatScheduler: scheduler,
            name: name,
            registry: registry,
            clientTokens: tokens
        )
        registry?.add(graine)
        // The session route, answered through the network like every embed request (sealed by the one door).
        network.respond["/api/embed/session"] = { [weak self] body in
            guard let self = self else { return (0, nil) }
            self.sessionBodies.append(JSON.object(from: body) ?? [:])
            let reply = self.sessionAnswer(body)
            return (reply.failure == nil ? reply.status : 0, reply.data)
        }
    }

    var nowSec: Double { TokenAgentRig.base + (scheduler.now - 1_000) }

    func mint(_ life: Double = 3_600, id: String) -> String {
        TestTokens.mint(iat: nowSec, exp: nowSec + life, id: id)
    }

    /// As configure starts an agent: its tokens, then the session.
    func start() async {
        graine.startClientTokens()
        graine.loadSession { _ in }
        try? await Task.sleep(nanoseconds: 30_000_000)
    }

    func tickets() -> [[String: Any]] { network.bodies("/api/embed/ticket") }
}

// HeardErrors (what a listener hears) is shared with AppIdentityTests.swift.

@Suite @MainActor struct ClientTokensAgentTests {
    /// Every route the SDK asks on its own, once each.
    private func everyRoute(_ rig: TokenAgentRig) async {
        let g = rig.graine
        g.identify(["user_id": "u-1"])
        _ = try? await g.memories()
        _ = try? await g.forgetMemory()
        _ = try? await g.scheduledCalls()
        _ = try? await g.cancelScheduledCall(id: "sc_1")
        g.chat.refreshPastSessions()
        _ = try? await g.chat.sessionTranscript(id: "s_1")
        try? await g.chat.newConversation()
        g.chat.shown(true)
        g.identify(nil)
        // The routes the calls and the device reach go through the same requests.
        for path in ["/api/embed/devices", "/api/embed/calls/outcome", "/api/embed/calls/schedule"] {
            g.requests.post(path, [("installId", .string(g.installId))]) { _ in }
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
    }

    private let routes = [
        "/api/embed/ticket", "/api/embed/memory/list", "/api/embed/memory/forget", "/api/embed/calls/list", "/api/embed/calls/cancel",
        "/api/embed/sessions/list", "/api/embed/sessions/transcript", "/api/embed/conversation/new", "/api/embed/identity/signout",
        "/api/embed/devices", "/api/embed/calls/outcome", "/api/embed/calls/schedule",
    ]

    @Test func withAProviderEveryRequestCarriesTheToken() async {
        let p = TestProvider()
        let rig = TokenAgentRig(provider: p)
        defer { rig.sandbox.clean() }
        let token = rig.mint(id: "ct_app")
        p.answer = { token }
        await rig.start()
        #expect(p.asked == 1, "asked at start, before the session")
        #expect(rig.sessionBodies.map { $0[ClientTokenRules.field] as? String } == [token], "the session carried it")
        await everyRoute(rig)
        for path in routes { #expect(!rig.network.bodies(path).isEmpty, "\(path) was asked") }
        for post in rig.network.posts { #expect(post.body[ClientTokenRules.field] as? String == token, "\(post.path) carried it") }
        // One token per user, used everywhere: asked at start, then once for each change of user (u-1, then nobody).
        #expect(p.asked == 3, "asked at start and once per change of user — never per request")
    }

    @Test func withoutAProviderNoRequestCarriesOne() async {
        let rig = TokenAgentRig(provider: nil)
        defer { rig.sandbox.clean() }
        await rig.start()
        #expect(rig.sessionBodies.count == 1 && rig.sessionBodies[0][ClientTokenRules.field] == nil)
        await everyRoute(rig)
        for path in routes { #expect(!rig.network.bodies(path).isEmpty, "\(path) was asked") }
        for post in rig.network.posts { #expect(post.body[ClientTokenRules.field] == nil, "\(post.path)") }
    }

    @Test func anotherUserSignsOutWithTheTokenItHeldAndTheNextUserGetsAFreshOne() async throws {
        let p = TestProvider()
        let rig = TokenAgentRig(provider: p)
        defer { rig.sandbox.clean() }
        p.answer = { rig.mint(id: "ct_\(rig.graine.identity.snapshot().value ?? "nobody")") }
        await rig.start()
        #expect(TestTokens.id(rig.graine.clientTokens.newest) == "ct_nobody")
        rig.graine.identify(["user_id": "u-1"])
        #expect(TestTokens.id(rig.graine.clientTokens.newest) == "ct_u-1", "a fresh token for the user identified")
        rig.graine.chat.shown(true)
        #expect(TestTokens.id(rig.tickets().last?[ClientTokenRules.field] as? String) == "ct_u-1")
        try #require(rig.network.socket).open()
        rig.graine.identify(["user_id": "u-2"])
        let signOuts = rig.network.bodies("/api/embed/identity/signout")
        #expect(TestTokens.id(signOuts.last?[ClientTokenRules.field] as? String) == "ct_u-1", "the sign-out carried the token it held")
        #expect(TestTokens.id(rig.graine.clientTokens.newest) == "ct_u-2")
        #expect(TestTokens.id(rig.tickets().last?[ClientTokenRules.field] as? String) == "ct_u-2", "the chat connected again with the new user's token")
        rig.graine.identify(nil)
        #expect(TestTokens.id(rig.network.bodies("/api/embed/identity/signout").last?[ClientTokenRules.field] as? String) == "ct_u-2")
        #expect(TestTokens.id(rig.graine.clientTokens.newest) == "ct_nobody")
        // The same user with other traits, or another memory choice, keeps the token.
        let asked = p.asked
        rig.graine.identify(["user_id": "u-3"])
        rig.graine.identify(["user_id": "u-3", "name": "Asha"])
        rig.graine.setMemory(false)
        #expect(p.asked == asked + 1)
    }

    @Test func aSessionRefusedForAnExpiredTokenAsksOnceAndLoads() async {
        let p = TestProvider()
        let rig = TokenAgentRig(provider: p)
        defer { rig.sandbox.clean() }
        let first = rig.mint(id: "ct_1")
        let second = rig.mint(id: "ct_2")
        p.answer = { p.asked == 1 ? first : second }
        rig.sessionAnswer = { body in
            JSON.object(from: body)?[ClientTokenRules.field] as? String == first
                ? GraineInApp.SessionReply(status: 401, data: tokenRefusal("token_expired"), failure: nil) : TokenAgentRig.session
        }
        await rig.start()
        #expect(rig.sessionBodies.map { $0[ClientTokenRules.field] as? String } == [first, second])
        #expect(p.asked == 2)
        #expect(rig.graine.session != nil)
    }

    @Test func aSessionRefusedForARevokedKeyIsTheRefusalEveryRequestHears() async {
        let p = TestProvider()
        let rig = TokenAgentRig(provider: p)
        defer { rig.sandbox.clean() }
        let heard = HeardErrors()
        rig.graine.addListener(heard)
        p.answer = { rig.mint(id: "ct_1") }
        rig.sessionAnswer = { _ in GraineInApp.SessionReply(status: 401, data: tokenRefusal("key_revoked"), failure: nil) }
        await rig.start()
        #expect(rig.sessionBodies.count == 1, "final: never sent again")
        #expect(p.asked == 1, "and no token asked for")
        #expect(rig.graine.session == nil)
        #expect(heard.errors.contains("Refused for its key_revoked."))
        rig.graine.identify(["user_id": "u-1"])
        do {
            _ = try await rig.graine.memories()
            Issue.record("refused")
        } catch let e as GraineServiceError {
            #expect(e.code == .keyRevoked)
        } catch { Issue.record("\(error)") }
        rig.sessionAnswer = { _ in GraineInApp.SessionReply(status: 403, data: tokenRefusal("token_scope", reason: "user"), failure: nil) }
        do {
            _ = try await rig.graine.forgetMemory()
            Issue.record("refused")
        } catch let e as GraineServiceError {
            #expect(e.code == .tokenScope && e.reason == "user")
            #expect(!e.message.contains("app://"), "never the allowed-domains sentence")
        } catch { Issue.record("\(error)") }
    }

    @Test func aChatTicketRefusedForAnExpiredTokenAsksOnceAndConnects() async throws {
        let p = TestProvider()
        let rig = TokenAgentRig(provider: p)
        defer { rig.sandbox.clean() }
        p.answer = { rig.mint(id: "ct_\(p.asked)") }
        await rig.start()
        rig.network.replies["/api/embed/ticket"] = (401, String(decoding: tokenRefusal("token_expired"), as: UTF8.self))
        rig.network.beforeAnswer["/api/embed/ticket"] = { rig.network.replies["/api/embed/ticket"] = nil }
        rig.graine.chat.shown(true)
        #expect(p.asked == 2, "exactly one more question")
        let asks = rig.tickets()
        #expect(asks.count == 2, "exactly one retry")
        #expect(asks.map { TestTokens.id($0[ClientTokenRules.field] as? String) } == ["ct_1", "ct_2"])
        let socket = try #require(rig.network.socket)
        #expect(socket.protocols == [CallWire.subprotocol, "tkt-1"])
        socket.open()
        #expect(rig.graine.chat.status == .online)
        #expect(rig.graine.chat.error == nil)
    }

    @Test func aChatRefusedForARevokedKeyFailsWithItAndNeverTriesAnotherWay() async throws {
        let p = TestProvider()
        let rig = TokenAgentRig(provider: p)
        defer { rig.sandbox.clean() }
        let heard = HeardErrors()
        rig.graine.addListener(heard)
        p.answer = { rig.mint(id: "ct_1") }
        await rig.start()
        rig.network.replies["/api/embed/ticket"] = (401, String(decoding: tokenRefusal("key_revoked"), as: UTF8.self))
        rig.graine.chat.shown(true)
        rig.graine.chat.send("Hello")
        #expect(rig.graine.chat.status == .offline)
        #expect(rig.graine.chat.error?.code == .keyRevoked)
        #expect(rig.network.sockets.isEmpty, "no direct socket past the refusal")
        #expect(heard.errors.contains("Refused for its key_revoked."))
        #expect(rig.graine.chat.turns.last?.delivery == .failed)
        // The Objective-C facade says the same.
        let objc = GraineObjC(graine: rig.graine).chat
        #expect(objc.error?.userInfo["code"] as? String == "key_revoked")
        let snapshot = JSON.object(from: objc.snapshotJSON)
        #expect((snapshot?["error"] as? [String: Any])?["code"] as? String == "key_revoked")
        let asked = rig.tickets().count
        rig.scheduler.advance(120)
        #expect(rig.tickets().count == asked, "no reconnect: the next would meet the same answer")
        #expect(p.asked == 1, "never asked for a token for it")
        // The app asks again: a new try — and the line the customer typed goes on it, once.
        rig.network.replies["/api/embed/ticket"] = nil
        rig.graine.chat.retry()
        #expect(rig.graine.chat.error == nil)
        let socket = try #require(rig.network.socket)
        socket.open()
        #expect(rig.graine.chat.status == .online)
        #expect(socket.sent.filter { $0.contains("Hello") }.count == 1)
        #expect(rig.graine.chat.turns.last?.delivery == .sent)
    }

    @Test func aChatRefusedForTheTokensScopeIsNeverRetried() async {
        let p = TestProvider()
        let rig = TokenAgentRig(provider: p)
        defer { rig.sandbox.clean() }
        p.answer = { rig.mint(id: "ct_1") }
        await rig.start()
        rig.network.replies["/api/embed/ticket"] = (403, String(decoding: tokenRefusal("token_scope", reason: "scope"), as: UTF8.self))
        rig.graine.chat.shown(true)
        #expect(rig.tickets().count == 1 && p.asked == 1)
        #expect(rig.graine.chat.error?.code == .tokenScope && rig.graine.chat.error?.reason == "scope")
        #expect(rig.network.sockets.isEmpty)
        #expect(rig.graine.chat.status == .offline)
    }

    // MARK: Nothing live is touched

    @Test func aTokenThatExpiresDuringALiveChatEndsPausesAndReconnectsNothing() async throws {
        let p = TestProvider()
        let rig = TokenAgentRig(provider: p)
        defer { rig.sandbox.clean() }
        p.answer = { rig.mint(60, id: "ct_minute") }
        await rig.start()
        rig.graine.chat.shown(true)
        let socket = try #require(rig.network.socket)
        socket.open()
        #expect(rig.graine.chat.status == .online)
        // The app's server goes down: the minute's token lapses, and every refresh fails, for ten minutes.
        p.answer = { nil }
        let tickets = rig.tickets().count
        for _ in 0..<20 {
            rig.scheduler.advance(30)
            socket.frame(["type": "text", "data": "<beginning_of_stream>Still here.<end_of_stream>"])
        }
        #expect(p.asked > 2, "the refreshes were tried")
        rig.graine.chat.send("And now?")
        #expect(rig.graine.chat.status == .online)
        #expect(!socket.closed)
        #expect(!socket.sentTypes.contains("stop"), "no stop frame")
        #expect(socket.sent.contains { $0.contains("And now?") }, "the line went on the live socket")
        #expect(rig.tickets().count == tickets, "no new ticket")
        #expect(rig.network.sockets.count == 1)
    }

    @Test func aTokenThatExpiresDuringALiveCallEndsPausesAndReconnectsNothing() {
        let rig = EngineRig()
        let p = TestProvider()
        let sched = rig.scheduler
        let mint = { (life: Double, id: String) -> String in
            let now = TokenAgentRig.base + (sched.now - 1_000)
            return TestTokens.mint(iat: now, exp: now + life, id: id)
        }
        p.answer = { mint(60, "ct_minute") }
        let tokens = ClientTokens(
            fetch: p.fetch, clock: { TokenAgentRig.base + (sched.now - 1_000) }, random: { 0.5 },
            schedule: { sched.after($0, $1) }, background: { $0() }
        )
        tokens.start()
        rig.tokens = tokens
        let socket = rig.open()
        #expect(TestTokens.id(JSON.object(from: rig.network.posts.first?.body)?[ClientTokenRules.field] as? String) == "ct_minute")
        p.answer = { nil }
        for _ in 0..<20 {
            rig.scheduler.advance(30)
            socket.frame(["type": "pong"])
        }
        #expect(p.asked > 2, "the refreshes were tried")
        #expect(rig.endings.isEmpty, "nothing ended")
        #expect(!rig.events.contains { if case .reconnecting = $0 { return true }; return false }, "nothing reconnected")
        #expect(!socket.closed)
        #expect(rig.network.posts.count == 1, "no new ticket")
        rig.engine.hangUp()
    }

    @Test func aCallWhoseTicketIsRefusedForItsScopeEndsWithTheCodeAndNoDirectSocket() {
        let rig = EngineRig()
        let sched = rig.scheduler
        let tokens = ClientTokens(
            fetch: TestProvider { TestTokens.mint(iat: TokenAgentRig.base, exp: TokenAgentRig.base + 3_600) }.fetch,
            clock: { TokenAgentRig.base + (sched.now - 1_000) }, random: { 0.5 }, schedule: { sched.after($0, $1) }, background: { $0() }
        )
        tokens.start()
        rig.tokens = tokens
        rig.network.ticketReply = (403, tokenRefusal("token_scope", reason: "scope"))
        rig.engine.start()
        #expect(rig.endings == [.couldNotOpen("token_scope: Refused for its token_scope.")])
        #expect(rig.network.sockets.isEmpty, "the direct socket is not another way past it")
        #expect(rig.network.posts.count == 1, "never retried")
    }

    @Test func aWebRtcRefusalForTheTokenEndsTheCallWithTheCodeAndNeverFallsBack() throws {
        let rig = ConversationRig()
        let conversation = rig.make()
        conversation.start()
        let call = try #require(rig.module.call)
        // The module ends a mint refused for the token or the key (GraineRtcRefusal.ends) — Graine sent no sentence here.
        #expect(GraineRtcRefusal.ends("token_scope") && GraineRtcRefusal.ends("key_revoked") && GraineRtcRefusal.ends("agent_off"))
        #expect(!GraineRtcRefusal.ends("rate_limited") && !GraineRtcRefusal.ends(nil))
        #expect(GraineRtcTokens.refreshable("token_expired") && !GraineRtcTokens.refreshable("token_scope"))
        call.emit(.refused(code: "token_scope", message: ""))
        #expect(rig.endings == [.couldNotOpen("token_scope: The server token does not allow this.")])
        #expect(rig.ticketPosts == 0, "no fallback to the WebSocket")
        // The request handed to the module carries the agent's tokens; the mint body never does.
        let tokens = ClientTokens(fetch: { $0("tok") }, background: { $0() })
        tokens.start()
        let request = CallConversation.rtcRequest(
            setup: CallEngine.Setup(
                publishableKey: "pk", baseUrl: "https://www.graine.ai", variables: [], contextFrame: { nil }, session: { $0(nil) },
                runAction: { _, _, answer in answer(.ok("")) }, tokens: tokens
            ),
            session: GraineSessionConfig(agentId: "agent-1", webcallAgentId: "web-1"), debug: false
        )
        #expect(request.clientTokens?.tokens === tokens)
        #expect(JSON.object(from: request.mintBody("s1"))?[ClientTokenRules.field] == nil)
    }

    // MARK: The Objective-C facade

    @Test func theFacadesBlockIsTheProviderAndItsFirstAnswerCounts() async {
        var dones: [(String?) -> Void] = []
        let config = GraineObjC.config(
            baseUrl: "https://www.graine.ai", publishableKey: "pk_test_objc", appVersion: nil, debug: false, endOnBackground: true,
            captureTaps: true, transport: nil, variablesJSON: nil, chatSize: nil, chatCloseDelaySeconds: 15,
            tokenProvider: { done in dones.append(done) }
        )
        #expect(config.tokenFetch != nil && config.tokenProvider == nil)
        let sched = ManualScheduler()
        let manager = ClientTokens(fetch: config.clientTokenFetch, clock: { 1_000 + sched.now }, schedule: { sched.after($0, $1) }, background: { $0() })
        manager.start()
        #expect(dones.count == 1, "asked at start")
        dones[0]("tok_objc")
        dones[0]("tok_late")
        #expect(manager.newest == "tok_objc", "the first answer counts")
        let plain = GraineObjC.config(
            baseUrl: "https://www.graine.ai", publishableKey: "pk_test_objc", appVersion: nil, debug: false, endOnBackground: true,
            captureTaps: true, transport: nil, variablesJSON: nil
        )
        #expect(plain.clientTokenFetch == nil, "no block: no server tokens")
        // An agent made from it asks the block itself, off the main thread, and holds what it answers.
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        let blockConfig = GraineObjC.config(
            baseUrl: "https://www.graine.ai", publishableKey: "pk_test_objc", appVersion: nil, debug: false, endOnBackground: true,
            captureTaps: true, transport: nil, variablesJSON: nil, chatSize: nil, chatCloseDelaySeconds: 15,
            tokenProvider: { done in done("tok_block") }
        )
        let agent = GraineInApp(
            config: blockConfig, installIds: MemoryInstallIdStore("3f2504e0-4f89-11d3-9a0c-0305e82c3301"), defaults: sandbox.defaults,
            sessionCache: SessionCache(directory: sandbox.folder), network: RoutedNetwork(), chatScheduler: ManualScheduler()
        )
        agent.startClientTokens()
        await eventually { agent.clientTokens.newest != nil }
        #expect(agent.clientTokens.newest == "tok_block")
        // And Swift's async provider the same way.
        let swift = GraineInApp(
            config: GraineConfig(baseUrl: "https://www.graine.ai", publishableKey: "pk_test_swift", tokenProvider: { "tok_async" }),
            installIds: MemoryInstallIdStore("3f2504e0-4f89-11d3-9a0c-0305e82c3301"), defaults: sandbox.defaults,
            sessionCache: SessionCache(directory: sandbox.folder), network: RoutedNetwork(), chatScheduler: ManualScheduler()
        )
        swift.startClientTokens()
        await eventually { swift.clientTokens.newest != nil }
        #expect(swift.clientTokens.newest == "tok_async")
    }

    @Test func theFacadesErrorsCarryTheReason() {
        let e = ObjCBridge.nsError(GraineServiceError(code: .tokenScope, message: "No.", status: 403, reason: "scope"))
        #expect(e.userInfo["code"] as? String == "token_scope" && e.userInfo["reason"] as? String == "scope" && e.code == 403)
        #expect(ObjCBridge.nsError(GraineServiceError(code: .keyRevoked, message: "Revoked.")).userInfo["reason"] == nil)
        #expect(ObjCBridge.tokenFetch(nil) == nil)
    }

    // MARK: The calls host (React Native, Flutter)

    /// The platform as iOS's runs it, as far as tokens go: every agent hears the push and asks through the host.
    private final class Platform: CallsHostPlatform {
        let made: () -> GraineInApp
        var graine: GraineInApp?
        init(_ made: @escaping () -> GraineInApp) { self.made = made }

        func makeInstance(_ options: CallsHostOptions) -> (publishableKey: String, baseUrl: String, debug: Bool) {
            let g = made()
            graine = g
            return (g.config.publishableKey, g.config.baseUrl, g.config.debug)
        }
        func setClientToken(_ token: String?) { graine?.pushClientToken(token) }
        func askForClientTokens(_ ask: @escaping () -> Void) { graine?.askHostForClientTokens(ask) }
        func nextTurn(_ block: @escaping () -> Void) { block() }
        func configureCalls(_ options: CallsHostOptions) {}
        func enableVoIPPushes(onToken: @escaping (String?) -> Void) {}
        func startCall(reason: String?, variables: [String: Any], agent: String?) -> String? { nil }
        func prepareCall(reason: String?, variables: [String: Any], agent: String?) {}
        func answer() {}
        func end() {}
        func setMuted(_ muted: Bool) {}
        func setSpeaker(_ on: Bool) {}
        func identify(_ traits: [String: Any]?) {}
        func setMemory(_ enabled: Bool) {}
        var installId: String? { nil }
        func setVariables(_ values: [String: Any?]) {}
        func setScreen(_ screen: GraineScreen?) {}
        func registerAction(_ name: String, handler: @escaping GraineInApp.DeferredActionHandler) -> () -> Void { {} }
        func callFields() -> CallsHostSnapshot { CallsHostSnapshot() }
        var appActive: Bool { true }
        var missedCallPending: Bool { false }
        func presentCallScreen() {}
        func dismissCallScreen() {}
        func after(_ seconds: TimeInterval, _ block: @escaping () -> Void) {}
        func callPermissions() -> GraineCallPermissions { GraineCallPermissions(microphone: .granted, notifications: .notNeeded, fullScreen: .notNeeded) }
        func requestCallPermissions(_ done: @escaping (GraineCallPermissions) -> Void) { done(callPermissions()) }
        func openCallSettings(_ item: GraineCallPermission) -> Bool { false }
        func callSetupProblems() -> [GraineCallSetupProblem] { [] }
    }

    private let options: [String: Any] = ["publishableKey": "pk_host", "displayName": "Acme"]

    private func lastToken(_ rig: TokenAgentRig, _ path: String) -> String? {
        rig.network.bodies(path).last?[ClientTokenRules.field] as? String
    }

    @Test func aPushedTokenReachesTheRequestsAndARefusalAsksTheWrapperForAnother() async throws {
        let registry = GraineAgentRegistry()
        let rig = TokenAgentRig(provider: nil, registry: registry, key: "pk_host")
        defer { rig.sandbox.clean() }
        let suite = "ai.graine.inapp.tests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let core = CallsHostCore(platform: Platform { rig.graine }, store: CallsHostStore(defaults: UserDefaults(suiteName: suite)!))
        // Pushed before configure: held, and applied when the instance is made.
        core.setClientToken("host_1")
        try core.configure(options)
        var needs = 0
        var pushes = 0
        _ = core.addSink { event, _ in
            guard event == CallsHostEvent.needClientToken else { return }
            needs += 1
            // The wrapper's manager answers the event with a fresh token, as React Native's and Flutter's do.
            pushes += 1
            core.setClientToken("host_\(1 + pushes)")
        }
        await rig.start()
        rig.graine.requests.post("/api/embed/calls/list", []) { _ in }
        #expect(lastToken(rig, "/api/embed/calls/list") == "host_1")
        #expect(needs == 0)
        // Refused for its token: the wrapper is asked once, and the request goes once more with what it pushed.
        rig.network.replies["/api/embed/calls/list"] = (401, #"{"code":"token_expired"}"#)
        rig.network.beforeAnswer["/api/embed/calls/list"] = { rig.network.replies["/api/embed/calls/list"] = nil }
        var listed: Result<[String: Any], GraineServiceError>?
        rig.graine.requests.post("/api/embed/calls/list", []) { listed = $0 }
        #expect(needs == 1)
        #expect(rig.network.bodies("/api/embed/calls/list").suffix(2).map { $0[ClientTokenRules.field] as? String } == ["host_1", "host_2"])
        if case .success = listed {} else { Issue.record("the second try succeeded: \(String(describing: listed))") }
        // A value that is not a token is none.
        core.setClientToken(42)
        #expect(rig.graine.clientTokens.newest == nil)
    }

    @Test func anAgentMadeLaterStartsWithThePushedTokenAndOneWithItsOwnProviderIgnoresIt() async throws {
        let registry = GraineAgentRegistry()
        let rig = TokenAgentRig(provider: nil, registry: registry, key: "pk_host")
        defer { rig.sandbox.clean() }
        let suite = "ai.graine.inapp.tests.\(UUID().uuidString)"
        let core = CallsHostCore(platform: Platform { rig.graine }, store: CallsHostStore(defaults: UserDefaults(suiteName: suite)!))
        try core.configure(options)
        core.setClientToken("host_1")
        let later = TokenAgentRig(provider: nil, registry: registry, key: "pk_later", name: "later")
        defer { later.sandbox.clean() }
        later.graine.startClientTokens()
        #expect(later.graine.clientTokens.newest == "host_1")
        let own = TokenAgentRig(provider: TestProvider { "own_token" }, registry: registry, key: "pk_own", name: "own")
        defer { own.sandbox.clean() }
        own.graine.startClientTokens()
        core.setClientToken("host_2")
        #expect(later.graine.clientTokens.newest == "host_2")
        #expect(own.graine.clientTokens.newest == "own_token")
        UserDefaults().removePersistentDomain(forName: suite)
    }

    @Test func withNoPushNothingCarriesATokenButARefusalStillAsksTheWrapper() async throws {
        let registry = GraineAgentRegistry()
        let rig = TokenAgentRig(provider: nil, registry: registry, key: "pk_host")
        defer { rig.sandbox.clean() }
        let suite = "ai.graine.inapp.tests.\(UUID().uuidString)"
        let core = CallsHostCore(platform: Platform { rig.graine }, store: CallsHostStore(defaults: UserDefaults(suiteName: suite)!))
        try core.configure(options)
        var events: [String] = []
        _ = core.addSink { event, _ in events.append(event) }
        await rig.start()
        rig.graine.requests.post("/api/embed/calls/list", []) { _ in }
        #expect(rig.network.posts.last?.body[ClientTokenRules.field] == nil)
        rig.network.replies["/api/embed/calls/list"] = (401, #"{"code":"token_required"}"#)
        var failure: GraineServiceError?
        rig.graine.requests.post("/api/embed/calls/list", []) { if case .failure(let e) = $0 { failure = e } }
        #expect(events.contains(CallsHostEvent.needClientToken))
        rig.scheduler.advance(1)
        #expect(failure?.code == .tokenRequired, "nothing pushed in time: the refusal stands")
        UserDefaults().removePersistentDomain(forName: suite)
    }
}
