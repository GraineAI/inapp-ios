import Foundation
import Testing
@_spi(GraineRTC) @testable import GraineInApp

/*
 * AN IDENTITY TOKEN THE APP FETCHES AFTER `identify` (0.14.6). Before a
 * conversation starts — the chat's ticket, a call the customer places, on the
 * voice socket or on WebRTC — and before a request for the identified user,
 * an agent that verifies users has the SDK ask the app's refresher when no
 * token is held, and wait for it, 10 s at most. Never when nobody is
 * identified, when the agent does not verify users, or when the customer
 * answers a ring; never two refreshes at once; a JWT about to expire is
 * refreshed as before. The 30 s limit is per person — another person's first
 * conversation asks at once, and the last person's late token never lands on
 * them — and a refresh that already ran out a wait is not waited for again.
 * On SecureRig's fakes: the network scripted, the clock moved by hand.
 */

/// The app's refresher: each call answers at once or is held until the test answers it (the last mode repeats). Counts its calls. Thread-safe.
final class TestRefresher: @unchecked Sendable {
    enum Mode {
        case hold
        case answer(String?)
    }

    private let lock = NSLock()
    private let modes: [Mode]
    private var asked = 0
    /// Held calls, by their number (1 = the first call).
    private var held: [(call: Int, continuation: CheckedContinuation<String?, Never>)] = []

    init(_ modes: Mode...) {
        self.modes = modes.isEmpty ? [.hold] : modes
    }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return asked
    }

    func refresh() async -> String? {
        let (call, mode) = asking()
        if case .answer(let token) = mode { return token }
        return await withCheckedContinuation { continuation in hold(call, continuation) }
    }

    private func asking() -> (Int, Mode) {
        lock.lock()
        defer { lock.unlock() }
        asked += 1
        return (asked, modes[min(asked, modes.count) - 1])
    }

    private func hold(_ call: Int, _ continuation: CheckedContinuation<String?, Never>) {
        lock.lock()
        held.append((call, continuation))
        lock.unlock()
    }

    /// Answer every call held so far.
    func answer(_ token: String?) {
        lock.lock()
        let waiting = held
        held = []
        lock.unlock()
        waiting.forEach { $0.continuation.resume(returning: token) }
    }

    /// Answer the `call`th call (1 = the first), when it is held.
    func answer(_ token: String?, call: Int) {
        lock.lock()
        guard let index = held.firstIndex(where: { $0.call == call }) else {
            lock.unlock()
            return
        }
        let continuation = held.remove(at: index).continuation
        lock.unlock()
        continuation.resume(returning: token)
    }

    /// Calls held now, waiting for `answer`.
    var holding: Int {
        lock.lock()
        defer { lock.unlock() }
        return held.count
    }

    /// Whether the `call`th call is held now.
    func isHolding(call: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return held.contains { $0.call == call }
    }
}

/// What a refresh applied, in order. Thread-safe.
final class Applied: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String] = []

    /// The apply function IdentityTokenRefresh's `capture` returns: records `label:token`, and says it changed the token.
    func recorder(_ label: String) -> (String) -> Bool {
        return { [self] token in
            lock.lock()
            tokens.append(label + ":" + token)
            lock.unlock()
            return true
        }
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return tokens
    }
}

/// Something that happened on another thread. Thread-safe.
final class Happened: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func mark() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var yes: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// A native call's setup for the rig's agent: one the customer places, or a ring they answer.
@MainActor
private func callSetup(_ rig: SecureRig, answering: Bool) -> CallEngine.Setup {
    CallEngine.Setup(
        publishableKey: SecureRig.key, baseUrl: "https://www.graine.ai", variables: [("who_called", "customer")],
        contextFrame: { nil }, session: { $0(GraineSessionConfig(agentId: "agent-1", webcallAgentId: "web-1")) },
        runAction: { _, _, answer in answer(.ok("")) }, identity: rig.graine.identityFields(callId: "call_7"),
        security: rig.graine.security, answering: answering
    )
}

/// The call on the voice socket, as GraineCalls drives it.
@MainActor
private func socketCall(_ rig: SecureRig, answering: Bool) -> CallEngine {
    CallEngine(setup: callSetup(rig, answering: answering), audio: ScriptedAudio(), network: rig.network, scheduler: rig.scheduler, onEvent: { _ in })
}

/// The same call's WebRTC request: its mint waits behind `beforeMint`.
@MainActor
private func rtcRequest(_ rig: SecureRig, answering: Bool) -> GraineRtcRequest {
    CallConversation.rtcRequest(setup: callSetup(rig, answering: answering), session: GraineSessionConfig(agentId: "agent-1", webcallAgentId: "web-1"), debug: false)
}

/// The identity token a body carried inside `identity`.
private func token(_ body: [String: Any]?) -> String? {
    (body?["identity"] as? [String: Any])?["token"] as? String
}

/// Who a body named: `identity.value`.
private func named(_ body: [String: Any]?) -> String? {
    (body?["identity"] as? [String: Any])?["value"] as? String
}

private let sessionId = "0123456789abcdef0123456789abcdef"

@Suite @MainActor struct MissingTokenWaitTests {
    @Test func theWaitIsANamedTenSeconds() {
        #expect(AppVerification.missingTokenWait == 10)
    }

    /// No token, a refresher, an agent that verifies users (enforce or report): the chat's ticket waits for the token and carries it.
    @Test func theChatsTicketWaitsForTheTokenAndCarriesIt() async throws {
        for mode in ["enforce", "report"] {
            let rig = SecureRig()
            defer { rig.clean() }
            rig.session(user: mode)
            rig.graine.identify(["user_id": "user-123"])
            let refresher = TestRefresher(.hold)
            rig.graine.identityTokenRefresher = { await refresher.refresh() }
            rig.graine.chat.open()
            try await eventually("asked") { refresher.holding == 1 }
            #expect(rig.network.bodies("/api/embed/ticket").isEmpty, "\(mode): the ticket waits for the token")
            refresher.answer("fresh")
            try await eventually("the ticket") { !rig.network.bodies("/api/embed/ticket").isEmpty }
            #expect(token(rig.network.bodies("/api/embed/ticket").first) == "fresh", "\(mode)")
            #expect(rig.graine.identity.currentToken() == "fresh", "held, as setIdentityToken holds it")
            #expect(refresher.calls == 1)
            #expect(rig.network.bodies("/api/embed/ticket").count == 1, "asked once, never refused first")
        }
    }

    /// A call the customer places waits too — its ticket on the voice socket, its mint on WebRTC — and carries the token.
    @Test func aPlacedCallWaitsOnTheSocketAndOnWebRtc() async throws {
        let rig = SecureRig()
        defer { rig.clean() }
        rig.session(user: "report")
        rig.graine.identify(["user_id": "user-123"])
        let refresher = TestRefresher(.hold)
        rig.graine.identityTokenRefresher = { await refresher.refresh() }
        let placed = socketCall(rig, answering: false)
        placed.start()
        let request = rtcRequest(rig, answering: false)
        let minted = Happened()
        request.beforeMint?({ minted.mark() })
        try await eventually("asked") { refresher.holding >= 1 }
        #expect(rig.network.bodies("/api/embed/ticket").isEmpty, "the socket's ticket waits")
        #expect(!minted.yes, "the mint waits")
        refresher.answer("fresh")
        try await eventually("both went") { !rig.network.bodies("/api/embed/ticket").isEmpty && minted.yes }
        #expect(token(rig.network.bodies("/api/embed/ticket").first) == "fresh")
        // The mint's body is read after the wait: it carries what the wait brought.
        #expect(token(JSON.object(from: request.mintBody(sessionId))) == "fresh")
        #expect(refresher.calls == 1, "one refresh, joined by both")
        withExtendedLifetime(placed) {}
    }

    /// Each request for the identified user waits for the token — and goes once, with it, never refused first.
    @Test func everyRequestForTheUserWaitsForTheTokenAndCarriesIt() async throws {
        let at = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 86_400).rounded())
        let requests: [(String, (GraineInApp) async throws -> Void)] = [
            ("/api/embed/memory/list", { _ = try await $0.memories() }),
            ("/api/embed/memory/forget", { _ = try await $0.forgetMemory() }),
            ("/api/embed/sessions/list", { $0.chat.refreshPastSessions() }),
            ("/api/embed/sessions/transcript", { _ = try await $0.chat.sessionTranscript(id: "exec-1") }),
            ("/api/embed/conversation/new", { try await $0.chat.newConversation() }),
            ("/api/embed/calls/list", { _ = try await $0.scheduledCalls() }),
            ("/api/embed/calls/schedule", { _ = try await $0.scheduleCall(at: at) }),
            ("/api/embed/calls/cancel", { _ = try await $0.cancelScheduledCall(id: "s1") }),
            ("/api/embed/workflows/start", { _ = try await $0.startWorkflow("welcome") }),
        ]
        #expect(Set(requests.map { $0.0 }) == EmbedRequests.userRoutes, "every route that acts for the user is driven here")
        for (path, ask) in requests {
            let rig = SecureRig()
            defer { rig.clean() }
            rig.session(user: "enforce", ["calls": ["hosted": true, "scheduling": ["usersCanBook": true, "maxDaysAhead": 14, "minLeadMinutes": 5]]])
            rig.network.answer("/api/embed/calls/schedule", (201, #"{"call":{"id":"s1","at":"\#(Scheduling.isoTime(at))","status":"scheduled","source":"sdk","reason":null}}"#))
            rig.network.answer("/api/embed/workflows/start", (200, #"{"runId":"oex_1","workflowId":"owf_1","alreadyRunning":false}"#))
            rig.graine.identify(["user_id": "user-123"])
            let refresher = TestRefresher(.answer("fresh"))
            rig.graine.identityTokenRefresher = { await refresher.refresh() }
            try await ask(rig.graine)
            try await eventually(path) { !rig.network.bodies(path).isEmpty }
            let sent = rig.network.bodies(path)
            #expect(sent.count == 1, "\(path): once, with the token")
            #expect(token(sent.first) == "fresh", "\(path)")
            #expect(refresher.calls == 1, "\(path)")
        }
    }

    /// The refresher answers nil: the conversation goes at once, as it is — no ten seconds — and the next is not held up asking again.
    @Test func aRefresherThatAnswersNilAddsNoWait() async throws {
        let rig = SecureRig()
        defer { rig.clean() }
        rig.session(user: "enforce")
        rig.graine.identify(["user_id": "user-123"])
        let refresher = TestRefresher(.answer(nil))
        rig.graine.identityTokenRefresher = { await refresher.refresh() }
        rig.graine.chat.open()
        // The clock never moves: it went on the refresher's answer, not at the cap.
        try await eventually("the ticket") { !rig.network.bodies("/api/embed/ticket").isEmpty }
        #expect(token(rig.network.bodies("/api/embed/ticket").first) == nil, "nothing to carry: as it is")
        #expect(refresher.calls == 1)
        _ = try await rig.graine.memories()
        #expect(refresher.calls == 1, "asked a moment ago: not asked again (at most once every 30 s)")
        #expect(token(rig.network.bodies("/api/embed/memory/list").first) == nil)
    }

    /// A refresher slower than the cap: the conversation goes at ten seconds, as it is; the late token is kept for the next.
    @Test func aSlowRefresherLetsTheConversationGoAtTheCap() async throws {
        let rig = SecureRig()
        defer { rig.clean() }
        rig.session(user: "enforce")
        rig.graine.identify(["user_id": "user-123"])
        let refresher = TestRefresher(.hold)
        rig.graine.identityTokenRefresher = { await refresher.refresh() }
        rig.graine.chat.open()
        try await eventually("asked") { refresher.holding == 1 }
        rig.clock.advance(9)
        #expect(rig.network.bodies("/api/embed/ticket").isEmpty)
        rig.clock.advance(1)
        #expect(rig.network.bodies("/api/embed/ticket").count == 1, "ten seconds: it goes as it is")
        #expect(token(rig.network.bodies("/api/embed/ticket").first) == nil)
        refresher.answer("late")
        try await eventually("the late token is kept") { rig.graine.identity.currentToken() == "late" }
        #expect(rig.network.bodies("/api/embed/ticket").count == 1, "the conversation is not asked again")
    }

    /// An agent that does not verify users — or an older server that says nothing — never has the refresher asked.
    @Test func anAgentThatDoesNotVerifyUsersNeverAsks() async throws {
        for verify in ["off", nil] as [String?] {
            let rig = SecureRig()
            defer { rig.clean() }
            if let verify = verify { rig.session(user: verify) } else { rig.session() }
            rig.graine.identify(["user_id": "user-123"])
            let refresher = TestRefresher(.hold)
            rig.graine.identityTokenRefresher = { await refresher.refresh() }
            rig.graine.chat.open()
            #expect(rig.network.bodies("/api/embed/ticket").count == 1, "at once")
            let placed = socketCall(rig, answering: false)
            placed.start()
            #expect(rig.network.bodies("/api/embed/ticket").count == 2, "at once")
            _ = try await rig.graine.memories()
            #expect(refresher.calls == 0, "\(verify ?? "no security"): never asked")
        }
    }

    /// Nobody identified — or traits without the one the agent names — never has the refresher asked.
    @Test func nobodyIdentifiedNeverAsks() async throws {
        let rig = SecureRig()
        defer { rig.clean() }
        rig.session(user: "enforce")
        let refresher = TestRefresher(.hold)
        rig.graine.identityTokenRefresher = { await refresher.refresh() }
        rig.graine.chat.open()
        #expect(rig.network.bodies("/api/embed/ticket").count == 1, "at once")
        _ = try await rig.graine.scheduledCalls()
        rig.graine.identify(["email": "asha@example.com"])
        let placed = socketCall(rig, answering: false)
        placed.start()
        #expect(rig.network.bodies("/api/embed/ticket").count == 2, "at once")
        _ = try await rig.graine.scheduledCalls()
        #expect(rig.network.bodies("/api/embed/calls/list").count == 2)
        #expect(refresher.calls == 0)
    }

    /// Two conversations and a request at once: one refresher call, joined by all three, each going with its token.
    @Test func severalAtOnceAskTheRefresherOnce() async throws {
        let rig = SecureRig()
        defer { rig.clean() }
        rig.session(user: "enforce")
        rig.graine.identify(["user_id": "user-123"])
        let refresher = TestRefresher(.hold)
        rig.graine.identityTokenRefresher = { await refresher.refresh() }
        rig.graine.chat.open()
        let placed = socketCall(rig, answering: false)
        placed.start()
        let listed = Task { try await rig.graine.memories() }
        try await eventually("asked") { refresher.holding == 1 }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(rig.network.bodies("/api/embed/ticket").isEmpty, "both tickets wait")
        #expect(rig.network.bodies("/api/embed/memory/list").isEmpty, "the request waits")
        refresher.answer("fresh")
        _ = try await listed.value
        try await eventually("both tickets") { rig.network.bodies("/api/embed/ticket").count == 2 }
        #expect(refresher.calls == 1, "never two at once")
        for body in rig.network.bodies("/api/embed/ticket") + rig.network.bodies("/api/embed/memory/list") {
            #expect(token(body) == "fresh")
        }
        withExtendedLifetime(placed) {}
    }

    /// Answering a ring never waits: the ring asked for the token when it arrived, and the answer goes with what is held — on either road.
    @Test func answeringARingNeverWaitsForTheToken() async throws {
        let rig = SecureRig()
        defer { rig.clean() }
        rig.session(user: "enforce")
        rig.graine.identify(["user_id": "user-123"])
        let refresher = TestRefresher(.hold)
        rig.graine.identityTokenRefresher = { await refresher.refresh() }
        rig.graine.ringArrived()
        try await eventually("asked when it rang") { refresher.holding == 1 }
        let answered = socketCall(rig, answering: true)
        answered.start()
        #expect(rig.network.bodies("/api/embed/ticket").count == 1, "the answer's ticket goes at once, the refresh still on its way")
        #expect(token(rig.network.bodies("/api/embed/ticket").first) == nil)
        let request = rtcRequest(rig, answering: true)
        let minted = Happened()
        request.beforeMint?({ minted.mark() })
        #expect(minted.yes, "the answer's mint goes at once")
        #expect(refresher.calls == 1, "the answer asked nothing more")
        #expect(rig.clock.waiting.isEmpty, "and holds no wait of its own")
        refresher.answer("fresh")
        try await eventually("kept for the next") { rig.graine.identity.currentToken() == "fresh" }
        withExtendedLifetime(answered) {}
    }

    /// A JWT about to expire is refreshed before the conversation exactly as before — on an answer too — at most ten seconds.
    @Test func anExpiringTokenIsRefreshedAsBefore() async throws {
        let rig = SecureRig()
        defer { rig.clean() }
        rig.session(user: "enforce")
        let now = rig.clock.now.timeIntervalSince1970
        let soon = fakeJwt(exp: now + 30)
        let fresh = fakeJwt(exp: now + 3600, salt: "b")
        rig.graine.identify(["user_id": "user-123"], identityToken: soon)
        let refresher = TestRefresher(.answer(fresh))
        rig.graine.identityTokenRefresher = { await refresher.refresh() }
        let answered = socketCall(rig, answering: true)
        answered.start()
        try await eventually("the ticket") { !rig.network.bodies("/api/embed/ticket").isEmpty }
        #expect(token(rig.network.bodies("/api/embed/ticket").first) == fresh, "refreshed first, as before")
        #expect(refresher.calls == 1)

        // A slow refresher: the conversation goes at ten seconds with the token held, as before.
        let slow = SecureRig()
        defer { slow.clean() }
        slow.session(user: "report")
        slow.graine.identify(["user_id": "user-123"], identityToken: soon)
        let held = TestRefresher(.hold)
        slow.graine.identityTokenRefresher = { await held.refresh() }
        slow.graine.chat.open()
        try await eventually("asked") { held.holding == 1 }
        slow.clock.advance(9)
        #expect(slow.network.bodies("/api/embed/ticket").isEmpty)
        slow.clock.advance(1)
        #expect(token(slow.network.bodies("/api/embed/ticket").first) == soon)
        held.answer(nil)

        // An hour left: a token is held, so nothing is missing and nothing is asked.
        let calm = SecureRig()
        defer { calm.clean() }
        calm.session(user: "enforce")
        calm.graine.identify(["user_id": "user-123"], identityToken: fresh)
        let idle = TestRefresher(.hold)
        calm.graine.identityTokenRefresher = { await idle.refresh() }
        calm.graine.chat.open()
        _ = try await calm.graine.memories()
        #expect(calm.network.bodies("/api/embed/ticket").count == 1)
        #expect(token(calm.network.bodies("/api/embed/memory/list").first) == fresh)
        #expect(idle.calls == 0)
        withExtendedLifetime(answered) {}
    }

    /// A refreshed token is kept as setIdentityToken keeps one: an agent configured later starts with it — never for someone else.
    @Test func aRefreshedTokenReachesAnAgentConfiguredLater() async throws {
        let registry = GraineAgentRegistry()
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        let network = ProofNetwork()
        func agent(_ name: String) -> GraineInApp {
            let made = GraineInApp(
                config: GraineConfig(baseUrl: "https://www.graine.ai", publishableKey: "pk_test_\(name)"),
                installIds: MemoryInstallIdStore("3f2504e0-4f89-11d3-9a0c-0305e82c3301"), defaults: sandbox.defaults,
                sessionCache: SessionCache(directory: sandbox.folder, agent: name), network: network,
                chatScheduler: ManualScheduler(), name: name, registry: registry, appStores: .memory()
            )
            registry.add(made)
            return made
        }
        let support = agent("default")
        support.finishSession(.success(GraineSessionConfig.parse([
            "agentId": "agent-support", "webcallAgentId": "web-support", "security": ["user": ["verify": "enforce", "method": "hmac"]],
        ])))
        support.identify(["user_id": "P-1"])
        let refresher = TestRefresher(.answer("fresh"))
        support.identityTokenRefresher = { await refresher.refresh() }
        support.chat.open()
        try await eventually("the ticket") { !network.bodies("/api/embed/ticket").isEmpty }
        #expect(token(network.bodies("/api/embed/ticket").first) == "fresh")

        let care = agent("care")
        care.adoptShared()
        care.finishSession(.success(GraineSessionConfig.parse(["agentId": "agent-care"])))
        #expect(care.identity.currentToken() == "fresh", "an agent configured after the refresh starts with its token")

        // Kept only for whom it was asked: another person identified meanwhile never gets it.
        support.identify(["user_id": "P-2"])
        registry.rememberRefreshedToken("for-P-1", for: ["user_id": "P-1"])
        #expect(registry.shared().identified?.token == nil, "P-2 never holds P-1's token")
        registry.rememberRefreshedToken("for-P-2", for: ["user_id": "P-2"])
        #expect(registry.shared().identified?.token == "for-P-2")
        support.identify(nil)
        registry.rememberRefreshedToken("nobody", for: nil)
        #expect(registry.shared().identified?.token == nil, "signed out: nothing to attach it to")
    }

    // MARK: - Per person

    /// A asked at t = 0 (and got nothing); B identified at t = 5 s: B's first conversation asks again — the 30 s are A's — and waits.
    @Test func anotherPersonsFirstConversationAsksAgainAndWaits() async throws {
        let rig = SecureRig()
        defer { rig.clean() }
        rig.session(user: "enforce")
        rig.graine.identify(["user_id": "user-A"])
        let refresher = TestRefresher(.answer(nil), .hold)
        rig.graine.identityTokenRefresher = { await refresher.refresh() }
        let callA = socketCall(rig, answering: false)
        callA.start()
        try await eventually("A's ticket") { rig.network.bodies("/api/embed/ticket").count == 1 }
        #expect(refresher.calls == 1 && token(rig.network.bodies("/api/embed/ticket").first) == nil)
        rig.clock.advance(5)
        rig.graine.identify(["user_id": "user-B"])
        let callB = socketCall(rig, answering: false)
        callB.start()
        try await eventually("asked again, for B") { refresher.isHolding(call: 2) }
        #expect(rig.network.bodies("/api/embed/ticket").count == 1, "B's ticket waits for B's token")
        refresher.answer("token-B", call: 2)
        try await eventually("B's ticket") { rig.network.bodies("/api/embed/ticket").count == 2 }
        let forB = rig.network.bodies("/api/embed/ticket").dropFirst().first
        #expect(named(forB) == "user-B" && token(forB) == "token-B")
        // The same person within the 30 s: not asked again.
        _ = try await rig.graine.memories()
        #expect(refresher.calls == 2)
        withExtendedLifetime((callA, callB)) {}
    }

    /// A's refresh still on its way when B is identified (t = 5 s): A's wait ends at once, B asks anew, and A's late token never lands on B.
    @Test func aLateTokenForTheLastPersonNeverLandsOnTheNext() async throws {
        let rig = SecureRig()
        defer { rig.clean() }
        rig.session(user: "enforce")
        rig.graine.identify(["user_id": "user-A"])
        let refresher = TestRefresher(.hold)
        rig.graine.identityTokenRefresher = { await refresher.refresh() }
        let callA = socketCall(rig, answering: false)
        callA.start()
        try await eventually("asked for A") { refresher.isHolding(call: 1) }
        rig.clock.advance(5)
        #expect(rig.network.bodies("/api/embed/ticket").isEmpty)
        rig.graine.identify(["user_id": "user-B"])
        #expect(rig.network.bodies("/api/embed/ticket").count == 1, "A's wait ends with A: no token can come for them now")
        #expect(token(rig.network.bodies("/api/embed/ticket").first) == nil)
        let callB = socketCall(rig, answering: false)
        callB.start()
        try await eventually("asked again, for B — A's refresh is not joined") { refresher.isHolding(call: 2) }
        #expect(rig.network.bodies("/api/embed/ticket").count == 1, "B's ticket waits for B's token")
        // A's token arrives late: dropped — never held, never sent.
        refresher.answer("token-A", call: 1)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(rig.graine.identity.currentToken() == nil, "A's late token never lands on B")
        #expect(rig.network.bodies("/api/embed/ticket").count == 1, "and does not end B's wait")
        refresher.answer("token-B", call: 2)
        try await eventually("B's ticket") { rig.network.bodies("/api/embed/ticket").count == 2 }
        let forB = rig.network.bodies("/api/embed/ticket").dropFirst().first
        #expect(named(forB) == "user-B" && token(forB) == "token-B")
        #expect(rig.graine.identity.currentToken() == "token-B")
        #expect(!rig.network.posts.map(\.raw).joined().contains("token-A"), "nothing ever carried A's token")
        withExtendedLifetime((callA, callB)) {}
    }

    /// The refresher itself: another person lets the last one's request go (its callers hear "nothing new" at once), asks anew within the 30 s, and never applies the old answer.
    @Test func anotherPersonStartsTheRefresherAfresh() async throws {
        var now = 1_000.0
        let refresh = IdentityTokenRefresh(clock: { now }, after: { _, _ in })
        let refresher = TestRefresher(.hold)
        refresh.refresher = { await refresher.refresh() }
        let applied = Applied()
        var forA: Bool?
        let roundA = refresh.refresh(capture: { applied.recorder("A") }) { forA = $0 }
        #expect(roundA != nil)
        try await eventually("asked for A") { refresher.isHolding(call: 1) }
        now += 5
        refresh.personChanged()
        #expect(forA == false, "A's callers hear nothing new at once")
        var forB: Bool?
        let roundB = refresh.refresh(capture: { applied.recorder("B") }) { forB = $0 }
        #expect(roundB != nil && roundB != roundA, "asked anew, though A was asked 5 s ago")
        try await eventually("asked for B") { refresher.isHolding(call: 2) }
        refresher.answer("token-A", call: 1)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(applied.all.isEmpty, "A's answer is never applied")
        #expect(forB == nil, "nor does it answer B's callers")
        refresher.answer("token-B", call: 2)
        try await eventually("B answered") { forB != nil }
        #expect(forB == true)
        #expect(applied.all == ["B:token-B"])
    }

    // MARK: - A refresh that ran out a wait

    /// The refresher hangs past ten seconds: the first conversation goes at the cap, and the ones after go at once — until it answers.
    @Test func aRefreshThatRanOutAWaitIsNotWaitedForAgain() async throws {
        let rig = SecureRig()
        defer { rig.clean() }
        rig.session(user: "enforce")
        rig.graine.identify(["user_id": "user-123"])
        let refresher = TestRefresher(.hold)
        rig.graine.identityTokenRefresher = { await refresher.refresh() }
        rig.graine.chat.open()
        try await eventually("asked") { refresher.holding == 1 }
        rig.clock.advance(10)
        #expect(rig.network.bodies("/api/embed/ticket").count == 1, "the first waited its ten seconds")
        // Still no answer: nothing waits for it again.
        let placed = socketCall(rig, answering: false)
        placed.start()
        #expect(rig.network.bodies("/api/embed/ticket").count == 2, "a call placed now goes at once")
        let listed = Task { try await rig.graine.memories() }
        try await eventually("a request goes at once") { !rig.network.bodies("/api/embed/memory/list").isEmpty }
        rig.clock.advance(10)
        _ = try await listed.value
        let request = rtcRequest(rig, answering: false)
        let minted = Happened()
        request.beforeMint?({ minted.mark() })
        #expect(minted.yes, "a WebRTC mint goes at once")
        #expect(refresher.calls == 1, "not asked again while it is on its way")
        // It answers at last: the token is held, and carried from then on, nothing asked.
        refresher.answer("late")
        try await eventually("kept") { rig.graine.identity.currentToken() == "late" }
        _ = try await rig.graine.memories()
        #expect(token(rig.network.bodies("/api/embed/memory/list").last) == "late")
        #expect(refresher.calls == 1)
        withExtendedLifetime(placed) {}
    }

    /// The refresher itself: a request someone waited for in vain is not joined — "nothing new", at once — until its place is freed and the 30 s pass; then it is asked again.
    @Test func aRefreshThatRanOutAWaitIsAskedAgainOnceItsWindowPasses() async throws {
        var now = 1_000.0
        var freeing: [() -> Void] = []
        let refresh = IdentityTokenRefresh(clock: { now }, after: { _, block in freeing.append(block) })
        let refresher = TestRefresher(.hold)
        refresh.refresher = { await refresher.refresh() }
        let applied = Applied()
        var first: Bool?
        let started = refresh.refresh(capture: { applied.recorder("1") }) { first = $0 }
        let round = try #require(started)
        try await eventually("asked") { refresher.isHolding(call: 1) }
        refresh.timedOut(round)
        var later: Bool?
        let joined = refresh.refresh(capture: { applied.recorder("2") }) { later = $0 }
        #expect(joined == nil, "not joined")
        #expect(later == false, "nothing new, at once")
        #expect(refresher.calls == 1)
        // Its place freed and the 30 s passed: asked again, and that one is waited for.
        now += 30
        freeing.forEach { $0() }
        #expect(first == false, "its place freed")
        var again: Bool?
        let next = refresh.refresh(capture: { applied.recorder("3") }) { again = $0 }
        #expect(next != nil && next != round)
        try await eventually("asked again") { refresher.isHolding(call: 2) }
        #expect(again == nil, "waiting for it")
        refresher.answer("t2", call: 2)
        try await eventually("answered") { again != nil }
        #expect(again == true)
        // The hung one answers at last: still applied, for the same person.
        refresher.answer("t1", call: 1)
        try await eventually("the late answer is kept") { applied.all.contains("1:t1") }
    }

    // MARK: - The device's registration for the calls Graine rings

    private static var rings: [String: Any] { ["calls": ["hosted": true]] }
    private static let devices = "/api/embed/devices"

    private func register(_ rig: SecureRig) {
        rig.graine.registerDeviceEverywhere(token: "abc123", appId: "com.acme.app", apnsEnvironment: "sandbox")
    }

    /// The registration waits (unseen) for the token the app has not given yet, and carries it: never sent as anonymous first.
    @Test func theRegistrationWaitsForTheTokenAndCarriesIt() async throws {
        let rig = SecureRig()
        defer { rig.clean() }
        rig.session(user: "enforce", Self.rings)
        rig.graine.identify(["user_id": "user-123"])
        let refresher = TestRefresher(.hold)
        rig.graine.identityTokenRefresher = { await refresher.refresh() }
        register(rig)
        try await eventually("asked") { refresher.holding == 1 }
        #expect(rig.network.bodies(Self.devices).isEmpty, "the registration waits for the token")
        refresher.answer("fresh")
        try await eventually("registered") { !rig.network.bodies(Self.devices).isEmpty }
        try await Task.sleep(nanoseconds: 50_000_000)
        let sent = rig.network.bodies(Self.devices)
        #expect(sent.count == 1, "once")
        #expect(named(sent.first) == "user-123" && token(sent.first) == "fresh")
        #expect(refresher.calls == 1)
    }

    /// Registered without a token (the refresher had none; it ran out its ten seconds): the token that arrives later sends it again — exactly once.
    @Test func aLateTokenRegistersTheDeviceAgainExactlyOnce() async throws {
        // The refresher had none: setIdentityToken brings it.
        let rig = SecureRig()
        defer { rig.clean() }
        rig.session(user: "enforce", Self.rings)
        rig.graine.identify(["user_id": "user-123"])
        let refresher = TestRefresher(.answer(nil))
        rig.graine.identityTokenRefresher = { await refresher.refresh() }
        register(rig)
        try await eventually("registered as it is") { rig.network.bodies(Self.devices).count == 1 }
        #expect(token(rig.network.bodies(Self.devices).first) == nil)
        rig.graine.setIdentityToken("late")
        try await eventually("registered again") { rig.network.bodies(Self.devices).count == 2 }
        #expect(named(rig.network.bodies(Self.devices).dropFirst().first) == "user-123" && token(rig.network.bodies(Self.devices).dropFirst().first) == "late")
        // Carried now: neither another token nor the next due check sends it again.
        rig.graine.setIdentityToken("later")
        register(rig)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(rig.network.bodies(Self.devices).count == 2, "exactly one registration again")

        // The refresher hangs past its ten seconds: its late answer sends it again, once.
        let slow = SecureRig()
        defer { slow.clean() }
        slow.session(user: "report", Self.rings)
        slow.graine.identify(["user_id": "user-123"])
        let held = TestRefresher(.hold)
        slow.graine.identityTokenRefresher = { await held.refresh() }
        register(slow)
        try await eventually("asked") { held.holding == 1 }
        slow.clock.advance(10)
        #expect(slow.network.bodies(Self.devices).count == 1, "ten seconds: registered as it is")
        #expect(token(slow.network.bodies(Self.devices).first) == nil)
        held.answer("late")
        try await eventually("registered again") { slow.network.bodies(Self.devices).count == 2 }
        #expect(token(slow.network.bodies(Self.devices).dropFirst().first) == "late")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(slow.network.bodies(Self.devices).count == 2, "exactly once")
    }

    /// Registered without a token for A, then B identified: a token that arrives afterwards — B's, or A's late — sends nothing for A.
    @Test func anIdentityChangeInBetweenRegistersNothingForTheLastPerson() async throws {
        // A token given for B after the switch.
        let rig = SecureRig()
        defer { rig.clean() }
        rig.session(user: "enforce", Self.rings)
        rig.graine.identify(["user_id": "user-A"])
        register(rig)
        try await eventually("registered") { rig.network.bodies(Self.devices).count == 1 }
        #expect(token(rig.network.bodies(Self.devices).first) == nil, "no refresher: registered as it is")
        rig.graine.identify(["user_id": "user-B"])
        rig.graine.setIdentityToken("token-B")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(rig.network.bodies(Self.devices).count == 1, "nothing is sent again for A")

        // A's refresh answers late, after the switch.
        let late = SecureRig()
        defer { late.clean() }
        late.session(user: "enforce", Self.rings)
        late.graine.identify(["user_id": "user-A"])
        let refresher = TestRefresher(.hold)
        late.graine.identityTokenRefresher = { await refresher.refresh() }
        register(late)
        try await eventually("asked for A") { refresher.isHolding(call: 1) }
        late.clock.advance(10)
        #expect(late.network.bodies(Self.devices).count == 1 && named(late.network.bodies(Self.devices).first) == "user-A")
        late.graine.identify(["user_id": "user-B"])
        refresher.answer("token-A", call: 1)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(late.network.bodies(Self.devices).count == 1, "nothing is sent again for A")
        #expect(late.graine.identity.currentToken() == nil)
        #expect(!late.network.posts.map(\.raw).joined().contains("token-A"))
    }
}
