import Foundation
import Testing
@_spi(GraineRTC) @testable import GraineInApp

/*
 * WHAT CALLS FETCH AHEAD OF THE TAP WAITS FOR THE TOKEN THE APP IS STILL
 * FETCHING (0.14.7). The next call's grant (warmCalls) and a call prepared
 * ahead of the tap (prepareNextCall) carry the customer; asked for while an
 * agent that verifies users has the customer identified with no identity
 * token and the app's refresher set, each would go without it — a row the
 * agent's Security log notes as anonymous, made stale by the token moments
 * later. So neither goes yet: the refresher is asked (one refresh, joined by
 * everything that asks), nobody waits on it, and each goes once — with the
 * token it brings, or as it is when it brings none or ten seconds pass, so the
 * first tap stays fast. Exactly as before with nothing to wait for; a ring's
 * grant never waits. On SecureRig's fakes, with the WebRTC module stood in for.
 */

@MainActor
private final class WarmRig {
    let secure = SecureRig()
    let module = FakeRtcModule()
    var now = 1_000.0
    private(set) var timers: [(seconds: TimeInterval, fire: () -> Void)] = []
    var graine: GraineInApp { secure.graine }

    init() {
        let module = self.module
        secure.graine.rtcModule = { module }
        secure.graine.uptime = { [unowned self] in self.now }
        secure.graine.afterDelay = { [unowned self] seconds, fire in self.timers.append((seconds, fire)) }
        secure.graine.callInProgress = { _ in false }
    }

    func clean() { secure.clean() }

    func body(_ request: GraineRtcRequest) -> [String: Any] { JSON.object(from: request.mintBody("")) ?? [:] }

    /// The next call's grants the module was asked for that name `customer` (not a ring's: no call id).
    func grants(for customer: String = "user-123") -> [[String: Any]] {
        module.warmUps.map(body).filter { $0["callId"] == nil && named($0) == customer }
    }

    /// A ringing call's grants, by its id.
    func ringGrants(_ callId: String) -> [[String: Any]] {
        module.warmUps.map(body).filter { JSON.string($0["callId"]) == callId }
    }

    /// The calls prepared ahead of the tap: what each was minted with.
    var prepared: [[String: Any]] { module.requests.map(body) }

    func prepare(reason: String? = "support", own: [String: String] = ["order": "A-1043"]) {
        graine.prepareNextCall(reason: reason, own: own)
    }

    /// The refresher, the customer identified without a token, and the session of an agent that checks its users (`user`).
    func identifiedWithoutToken(_ refresher: TestRefresher, user: String = "enforce") {
        secure.session(user: user)
        graine.identityTokenRefresher = { await refresher.refresh() }
        graine.identify(["user_id": "user-123"])
    }
}

/// The identity token a body carried inside `identity`.
private func token(_ body: [String: Any]?) -> String? {
    (body?["identity"] as? [String: Any])?["token"] as? String
}

/// Who a body named: `identity.value`.
private func named(_ body: [String: Any]?) -> String? {
    (body?["identity"] as? [String: Any])?["value"] as? String
}

/// Long enough for anything still on its way to the main queue to arrive.
private func settle() async throws {
    try await Task.sleep(nanoseconds: 50_000_000)
}

@Suite @MainActor struct CallWarmUpTokenTests {
    // MARK: - The next call's grant

    /// Identified without a token: no grant for the customer until the token comes — whatever asks meanwhile — then exactly one, with it.
    @Test func theNextCallsGrantWaitsForTheTokenThenGoesOnceWithIt() async throws {
        for mode in ["enforce", "report"] {
            let rig = WarmRig()
            defer { rig.clean() }
            let refresher = TestRefresher(.hold)
            rig.identifiedWithoutToken(refresher, user: mode)
            try await eventually("asked") { refresher.holding == 1 }
            // More reasons to warm while it is on its way: the app back in front, another memory choice.
            rig.graine.setForeground(false)
            rig.graine.setForeground(true)
            rig.graine.setMemory(false)
            try await settle()
            #expect(rig.grants().isEmpty, "\(mode): nothing goes for the customer without the token")
            #expect(refresher.calls == 1, "\(mode): one refresh, joined by every warm-up")
            #expect(rig.secure.network.posts.isEmpty, "\(mode): and nothing else was sent")
            refresher.answer("fresh")
            try await eventually("the grant") { !rig.grants().isEmpty }
            try await settle()
            let sent = rig.grants()
            #expect(sent.count == 1, "\(mode): exactly one")
            #expect(token(sent.first) == "fresh", "\(mode): with the token")
            #expect(sent.first?["memory"] as? Bool == false, "\(mode): and who is calling as they are now")
            #expect(refresher.calls == 1)
        }
    }

    /// The app sets the token itself while the refresher is still out: the grant goes at once, with it — and the refresher's empty answer later sends nothing more.
    @Test func aTokenTheAppSetsMeanwhileSendsTheGrantOnceWithIt() async throws {
        let rig = WarmRig()
        defer { rig.clean() }
        let refresher = TestRefresher(.hold)
        rig.identifiedWithoutToken(refresher)
        try await eventually("asked") { refresher.holding == 1 }
        rig.graine.setIdentityToken("from-the-app")
        try await eventually("the grant") { !rig.grants().isEmpty }
        refresher.answer(nil)
        try await settle()
        #expect(rig.grants().count == 1)
        #expect(token(rig.grants().first) == "from-the-app")
    }

    /// The refresher answers nil: one grant, as it is, at once — no ten seconds — and asked again within the 30 s, no second refresh.
    @Test func aRefresherWithNoTokenLetsTheGrantGoOnceAsItIs() async throws {
        let rig = WarmRig()
        defer { rig.clean() }
        let refresher = TestRefresher(.answer(nil))
        rig.identifiedWithoutToken(refresher)
        // The clock never moves: it went on the refresher's answer, not at the cap.
        try await eventually("the grant") { !rig.grants().isEmpty }
        try await settle()
        #expect(rig.grants().count == 1, "one, after the refresh ended")
        #expect(token(rig.grants().first) == nil, "nothing to carry: as it is")
        #expect(refresher.calls == 1)
        // Back in front a moment later: the module is asked as before (it sends nothing while its grant holds); the refresher is not.
        rig.graine.setForeground(false)
        rig.graine.setForeground(true)
        try await eventually("asked again") { rig.grants().count == 2 }
        #expect(refresher.calls == 1, "at most once every 30 s")
    }

    /// The refresher hangs: one grant, as it is, at ten seconds; nobody waited, so a conversation starting then still waits for it; its late token sends the grant again, with it.
    @Test func aSlowRefresherLetsTheGrantGoAtTenSeconds() async throws {
        let rig = WarmRig()
        defer { rig.clean() }
        let refresher = TestRefresher(.hold)
        rig.identifiedWithoutToken(refresher)
        try await eventually("asked") { refresher.holding == 1 }
        rig.secure.clock.advance(9)
        try await settle()
        #expect(rig.grants().isEmpty)
        rig.secure.clock.advance(1)
        try await eventually("ten seconds: it goes as it is") { rig.grants().count == 1 }
        #expect(token(rig.grants().first) == nil)
        #expect(refresher.calls == 1)
        // Not a wait that ran out: the chat opened now waits for the refresh still on its way.
        rig.graine.chat.open()
        try await settle()
        #expect(rig.secure.network.bodies("/api/embed/ticket").isEmpty, "the conversation waits for the token")
        refresher.answer("late")
        try await eventually("the ticket") { !rig.secure.network.bodies("/api/embed/ticket").isEmpty }
        #expect(token(rig.secure.network.bodies("/api/embed/ticket").first) == "late")
        try await eventually("the grant again, with the token") { rig.grants().count == 2 }
        #expect(token(rig.grants().last) == "late")
        #expect(refresher.calls == 1, "never two refreshes")
    }

    /// Another customer while the refresh is out: nothing goes for the first one; the second's grant waits for their own token.
    @Test func anotherCustomerMeanwhileGetsNothingOfTheLastOnes() async throws {
        let rig = WarmRig()
        defer { rig.clean() }
        let refresher = TestRefresher(.hold)
        rig.identifiedWithoutToken(refresher)
        try await eventually("asked for the first") { refresher.isHolding(call: 1) }
        rig.graine.identify(["user_id": "user-456"])
        try await eventually("asked for the second") { refresher.isHolding(call: 2) }
        refresher.answer("token-1", call: 1)
        try await settle()
        #expect(rig.grants(for: "user-123").isEmpty, "never sent for who left")
        #expect(rig.grants(for: "user-456").isEmpty, "the second waits for their token")
        refresher.answer("token-2", call: 2)
        try await eventually("their grant") { !rig.grants(for: "user-456").isEmpty }
        try await settle()
        #expect(rig.grants(for: "user-456").count == 1)
        #expect(token(rig.grants(for: "user-456").first) == "token-2")
        #expect(!rig.module.warmUps.map { String(decoding: $0.mintBody(""), as: UTF8.self) }.joined().contains("token-1"))
    }

    /// Nothing to wait for — an agent that does not verify users (or an older server), a token held, no refresher, nobody identified: the grant goes at once, exactly as before.
    @Test func withNothingToWaitForTheGrantGoesAsBefore() throws {
        // The agent does not verify users, or the server says nothing of it.
        for verify in ["off", nil] as [String?] {
            let rig = WarmRig()
            defer { rig.clean() }
            if let verify = verify { rig.secure.session(user: verify) } else { rig.secure.session() }
            let refresher = TestRefresher(.hold)
            rig.graine.identityTokenRefresher = { await refresher.refresh() }
            rig.graine.identify(["user_id": "user-123"])
            #expect(rig.grants().count == 1, "\(verify ?? "no security"): at once")
            #expect(token(rig.grants().first) == nil)
            #expect(refresher.calls == 0)
        }
        // A token held.
        let held = WarmRig()
        defer { held.clean() }
        held.secure.session(user: "enforce")
        let idle = TestRefresher(.hold)
        held.graine.identityTokenRefresher = { await idle.refresh() }
        held.graine.identify(["user_id": "user-123"], identityToken: "held")
        #expect(held.grants().count == 1)
        #expect(token(held.grants().first) == "held")
        #expect(idle.calls == 0)
        // No refresher: nothing to ask, so nothing to wait for.
        let none = WarmRig()
        defer { none.clean() }
        none.secure.session(user: "enforce")
        none.graine.identify(["user_id": "user-123"])
        #expect(none.grants().count == 1)
        #expect(token(none.grants().first) == nil)
        // Nobody identified: a grant for nobody in particular, at once.
        let nobody = WarmRig()
        defer { nobody.clean() }
        let unasked = TestRefresher(.hold)
        nobody.graine.identityTokenRefresher = { await unasked.refresh() }
        nobody.secure.session(user: "enforce")
        #expect(nobody.module.warmUps.count == 1)
        #expect(named(nobody.module.warmUps.first.map(nobody.body)) == nil)
        #expect(unasked.calls == 0)
    }

    // MARK: - A ringing call's grant

    /// A ring's grant never waits for the token: asked for at once, beside the next call's grant still waiting — and the ring asks the refresher nothing.
    @Test func aRingsGrantNeverWaits() async throws {
        let rig = WarmRig()
        defer { rig.clean() }
        let refresher = TestRefresher(.hold)
        rig.identifiedWithoutToken(refresher)
        try await eventually("asked") { refresher.holding == 1 }
        rig.graine.warmCalls(ringing: "call_ring_0000000001", session: nil)
        #expect(rig.ringGrants("call_ring_0000000001").count == 1, "at once")
        #expect(named(rig.ringGrants("call_ring_0000000001").first) == "user-123")
        // A ring under way when who is calling changes: its grant again, at once, while the next call's waits.
        rig.graine.ringingCallId = { _ in "call_ring_0000000002" }
        rig.graine.setMemory(false)
        #expect(rig.ringGrants("call_ring_0000000002").count == 1, "at once")
        try await settle()
        #expect(rig.grants().isEmpty, "the next call's grant still waits")
        #expect(refresher.calls == 1, "the rings asked nothing")
        refresher.answer(nil)
    }

    // MARK: - A call prepared ahead of the tap

    /// prepareCall while the token is on its way: nothing prepared until it comes — asked again meanwhile, still one refresh — then one call, with it, that the tap dials.
    @Test func aCallPreparedAheadWaitsForTheTokenThenIsPreparedOnceWithIt() async throws {
        let rig = WarmRig()
        defer { rig.clean() }
        let refresher = TestRefresher(.hold)
        rig.identifiedWithoutToken(refresher)
        rig.prepare(reason: "billing")
        rig.prepare(reason: "support")
        try await eventually("asked") { refresher.holding == 1 }
        try await settle()
        #expect(rig.prepared.isEmpty, "nothing prepared without the token")
        #expect(refresher.calls == 1)
        refresher.answer("fresh")
        try await eventually("prepared") { !rig.prepared.isEmpty }
        try await settle()
        #expect(rig.prepared.count == 1, "exactly one")
        let call = try #require(rig.prepared.first)
        #expect(token(call) == "fresh" && named(call) == "user-123")
        #expect((call["variables"] as? [String: Any])?["call_reason"] as? String == "support", "what was asked for last")
        #expect(rig.module.call?.steps == ["prepare"], "nothing dialled")
        #expect(rig.graine.preparedCallId(reason: "support", own: ["order": "A-1043"]) != nil, "the tap dials it: it mints what the call would")
    }

    /// The refresher brings nothing — nil, or no answer in ten seconds: the call is prepared once, as it is, after the refresh ends.
    @Test func aCallPreparedAheadGoesAsItIsWhenNoTokenComes() async throws {
        let quick = WarmRig()
        defer { quick.clean() }
        let empty = TestRefresher(.answer(nil))
        quick.identifiedWithoutToken(empty)
        quick.prepare()
        try await eventually("prepared") { !quick.prepared.isEmpty }
        try await settle()
        #expect(quick.prepared.count == 1)
        #expect(token(quick.prepared.first) == nil)
        #expect(empty.calls == 1)

        let slow = WarmRig()
        defer { slow.clean() }
        let hung = TestRefresher(.hold)
        slow.identifiedWithoutToken(hung)
        slow.prepare()
        try await eventually("asked") { hung.holding == 1 }
        slow.secure.clock.advance(9)
        try await settle()
        #expect(slow.prepared.isEmpty)
        slow.secure.clock.advance(1)
        try await eventually("ten seconds: prepared as it is") { slow.prepared.count == 1 }
        #expect(token(slow.prepared.first) == nil)
        #expect(hung.calls == 1)
        hung.answer(nil)
    }

    /// Sent to the background, or another customer, while it waits: nothing is prepared when the token comes.
    @Test func aCallWaitingForTheTokenIsLetGoInTheBackgroundOrForAnotherCustomer() async throws {
        let away = WarmRig()
        defer { away.clean() }
        let refresher = TestRefresher(.hold)
        away.identifiedWithoutToken(refresher)
        away.prepare()
        try await eventually("asked") { refresher.holding == 1 }
        away.graine.setForeground(false)
        refresher.answer("fresh")
        try await eventually("the token held") { away.graine.identity.currentToken() == "fresh" }
        try await settle()
        #expect(away.prepared.isEmpty, "nobody taps a call in the background")

        let switched = WarmRig()
        defer { switched.clean() }
        let asked = TestRefresher(.hold, .answer(nil))
        switched.identifiedWithoutToken(asked)
        switched.prepare()
        try await eventually("asked") { asked.isHolding(call: 1) }
        switched.graine.identify(["user_id": "user-456"])
        asked.answer("token-1", call: 1)
        try await settle()
        #expect(switched.prepared.isEmpty, "never prepared for who left, nor for who came without asking")
    }

    /// Nothing to wait for: prepared at once, exactly as before.
    @Test func withNothingToWaitForACallIsPreparedAsBefore() throws {
        let off = WarmRig()
        defer { off.clean() }
        off.secure.session(user: "off")
        let refresher = TestRefresher(.hold)
        off.graine.identityTokenRefresher = { await refresher.refresh() }
        off.graine.identify(["user_id": "user-123"])
        off.prepare()
        #expect(off.prepared.count == 1, "at once")
        let held = WarmRig()
        defer { held.clean() }
        held.secure.session(user: "enforce")
        held.graine.identityTokenRefresher = { await refresher.refresh() }
        held.graine.identify(["user_id": "user-123"], identityToken: "held")
        held.prepare()
        #expect(token(held.prepared.first) == "held")
        let none = WarmRig()
        defer { none.clean() }
        none.secure.session(user: "enforce")
        none.graine.identify(["user_id": "user-123"])
        none.prepare()
        #expect(none.prepared.count == 1)
        #expect(refresher.calls == 0)
    }
}
