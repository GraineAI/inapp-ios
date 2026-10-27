import Foundation
import Testing
@_spi(GraineRTC) @testable import GraineInApp

/*
 * 0.14.4, THE RIGHT REASON: a call that needs the customer waits for the
 * agent's settings (they name the trait that identifies the customer) and
 * hands on the session's own refusal when it could not be loaded — never
 * "nobody is identified" to an app that identified someone. identity_required
 * names the trait; 502/504 read as unavailable; booking reads say not_loaded,
 * not "not identified", while the session is still to come. And the public
 * reportEvent, whose pacing keys travel at the event's own level.
 */

/// A session fetch the test answers by hand: each request is kept until `answer`.
private final class HandFetch {
    private(set) var requests = 0
    private var waiting: [(Result<GraineSessionConfig, Error>) -> Void] = []

    func install(on graine: GraineInApp) {
        graine.sessionFetch = { [unowned self] done in
            self.requests += 1
            self.waiting.append(done)
        }
    }

    func answer(_ result: Result<GraineSessionConfig, Error>) {
        let pending = waiting
        waiting = []
        pending.forEach { $0(result) }
    }

    static func session(field: String = "patient_id", calls: [String: Any]? = nil) -> GraineSessionConfig {
        var body: [String: Any] = ["agentId": "agent-1", "webcallAgentId": "web-1", "identity": ["field": field]]
        if let calls = calls { body["calls"] = calls }
        return GraineSessionConfig.parse(body)
    }
}

/// Wait on the main queue for `condition`, a little at a time.
private func settle(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() { try? await Task.sleep(nanoseconds: 5_000_000) }
}

@Suite struct MemoryReportingTests {
    @Test @MainActor func aScreenOpenedAtLaunchWaitsForTheSessionThenAsks() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        let fetch = HandFetch()
        fetch.install(on: rig.graine)
        rig.graine.identify(["patient_id": "P-1"])
        rig.network.replies["/api/embed/memory/list"] = (200, #"{"memories":[{"id":"m1","text":"Prefers Hindi"}]}"#)
        let asked = Task { try await rig.graine.memories() }
        await settle { fetch.requests == 1 }
        #expect(rig.network.bodies("/api/embed/memory/list").isEmpty, "nothing asked before the session names the trait")
        fetch.answer(.success(HandFetch.session()))
        let memories = try await asked.value
        #expect(memories.map(\.id) == ["m1"], "the identified customer's answer — not identity_required")
    }

    @Test @MainActor func aSessionThatCouldNotLoadIsItsOwnReasonAndTheNextCallLoadsItAgain() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        let fetch = HandFetch()
        fetch.install(on: rig.graine)
        rig.graine.identify(["patient_id": "P-1"])
        let refused = GraineServiceError(code: .invalidKey, message: "Publishable key was rejected. Check it against Embed & Widgets in the dashboard.", status: 401)
        let first = Task { try await rig.graine.memories() }
        await settle { fetch.requests == 1 }
        fetch.answer(.failure(refused))
        await #expect(throws: refused) { _ = try await first.value }
        let forget = Task { try await rig.graine.forgetMemory() }
        await settle { fetch.requests == 2 }
        #expect(fetch.requests == 2, "the next call loads the session again")
        fetch.answer(.failure(GraineServiceError(code: .network, message: "The Internet connection appears to be offline.")))
        do {
            _ = try await forget.value
            Issue.record("expected the session's refusal")
        } catch let error as GraineServiceError {
            #expect(error.code == .network, "never identity_required for a session that could not load")
        }
        #expect(rig.network.bodies("/api/embed/memory/list").isEmpty && rig.network.bodies("/api/embed/memory/forget").isEmpty)
    }

    @Test @MainActor func identityRequiredNamesTheTraitThisAgentIdentifiesCustomersBy() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session(["identity": ["field": "patient_id"]])
        do {
            _ = try await rig.graine.memories()
            Issue.record("expected identity_required")
        } catch let error as GraineServiceError {
            #expect(error.code == .identityRequired)
            #expect(error.message == #"Nobody is identified: call identify() with the customer's "patient_id" first."#)
        }
        // The common wiring mistake: user_id sent to a patient_id agent.
        rig.graine.identify(["user_id": "u-1"])
        do {
            _ = try await rig.graine.forgetMemory()
            Issue.record("expected identity_required")
        } catch let error as GraineServiceError {
            #expect(error.code == .identityRequired)
            #expect(error.message.hasPrefix(#"identify() was given no usable "patient_id" — the trait this agent identifies customers by"#))
        }
        #expect(IdentityRules.missingIdentityMessage(field: nil, identified: true) == "Nobody is identified: call identify() with the customer's identifier first.")
    }

    // MARK: A request belongs to whoever was identified when it was made

    @Test @MainActor func aForgetAskedForOneCustomerNeverForgetsTheNextOne() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        let fetch = HandFetch()
        fetch.install(on: rig.graine)
        rig.graine.identify(["patient_id": "A-1"])
        rig.network.replies["/api/embed/memory/forget"] = (200, #"{"deleted":3}"#)
        let forget = Task { try await rig.graine.forgetMemory() }
        await settle { fetch.requests == 1 }
        // A signs out and B signs in on the same phone while the session is still on its way.
        rig.graine.identify(nil)
        rig.graine.identify(["patient_id": "B-2"])
        fetch.answer(.success(HandFetch.session()))
        do {
            _ = try await forget.value
            Issue.record("expected identity_required: the customer who asked is gone")
        } catch let error as GraineServiceError {
            #expect(error.code == .identityRequired)
            #expect(error.message.hasPrefix("Someone else was identified while the agent's settings were loading"))
        }
        #expect(rig.network.bodies("/api/embed/memory/forget").isEmpty, "B's memories are never forgotten for A")
    }

    @Test @MainActor func aBookingAskedForOneCustomerIsNeverMadeForTheNextOne() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        let fetch = HandFetch()
        fetch.install(on: rig.graine)
        rig.graine.identify(["patient_id": "A-1"])
        let booked = Task { try await rig.graine.scheduleCall(at: Date().addingTimeInterval(3_600), reason: "A's blood test results") }
        await settle { fetch.requests == 1 }
        rig.graine.identify(["patient_id": "B-2"])
        fetch.answer(.success(HandFetch.session(calls: ["hosted": true, "scheduling": ["usersCanBook": true]])))
        do {
            _ = try await booked.value
            Issue.record("expected identity_required")
        } catch let error as GraineServiceError {
            #expect(error.code == .identityRequired)
        }
        #expect(rig.network.bodies("/api/embed/calls/schedule").isEmpty, "B is never booked a call, with A's reason, that B did not ask for")
    }

    @Test @MainActor func signedOutWhileTheSessionLoadsIsIdentityRequiredNamingTheTrait() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        let fetch = HandFetch()
        fetch.install(on: rig.graine)
        rig.graine.identify(["patient_id": "A-1"])
        let listed = Task { try await rig.graine.memories() }
        await settle { fetch.requests == 1 }
        rig.graine.identify(nil)
        fetch.answer(.success(HandFetch.session()))
        do {
            _ = try await listed.value
            Issue.record("expected identity_required")
        } catch let error as GraineServiceError {
            #expect(error.code == .identityRequired)
            #expect(error.message == #"Nobody is identified: call identify() with the customer's "patient_id" first."#)
        }
        #expect(rig.network.bodies("/api/embed/memory/list").isEmpty)
    }

    @Test @MainActor func aTranscriptAskedForOneCustomerIsNeverFetchedForTheNextOne() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        let fetch = HandFetch()
        fetch.install(on: rig.graine)
        rig.graine.identify(["patient_id": "A-1"])
        let transcript = Task { try await rig.graine.chat.sessionTranscript(id: "s-1") }
        await settle { fetch.requests == 1 }
        rig.graine.identify(["patient_id": "B-2"])
        fetch.answer(.success(HandFetch.session()))
        do {
            _ = try await transcript.value
            Issue.record("expected identity_required")
        } catch let error as GraineServiceError {
            #expect(error.code == .identityRequired)
        }
        #expect(rig.network.bodies(PastSessionsWire.transcriptPath).isEmpty, "B's session is never fetched for A's screen")
    }

    @Test @MainActor func theSameCustomerWrittenAnotherWayWhileTheSessionLoadsStillGetsTheirAnswer() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        let fetch = HandFetch()
        fetch.install(on: rig.graine)
        rig.graine.identify(["email": "Asha@Example.com"])
        rig.network.replies["/api/embed/memory/forget"] = (200, #"{"deleted":2}"#)
        let forget = Task { try await rig.graine.forgetMemory() }
        await settle { fetch.requests == 1 }
        rig.graine.identify(["email": "asha@example.com"])
        fetch.answer(.success(HandFetch.session(field: "email")))
        #expect(try await forget.value == 2, "one customer as Graine keys them: not someone else")
    }

    @Test @MainActor func theSameCustomerIdentifiedAgainWithOtherTraitsStillGetsTheirAnswer() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        let fetch = HandFetch()
        fetch.install(on: rig.graine)
        rig.graine.identify(["patient_id": "A-1"])
        rig.network.replies["/api/embed/memory/list"] = (200, #"{"memories":[{"id":"m1","text":"Walks every evening"}]}"#)
        let listed = Task { try await rig.graine.memories() }
        await settle { fetch.requests == 1 }
        rig.graine.identify(["patient_id": "A-1", "name": "Asha"])
        fetch.answer(.success(HandFetch.session()))
        let memories = try await listed.value
        #expect(memories.map(\.id) == ["m1"], "the same customer: no refusal")
        #expect(JSON.string((rig.network.bodies("/api/embed/memory/list").first?["identity"] as? [String: Any])?["value"]) == "A-1")
    }

    @Test @MainActor func theTraitIsKnownTheMomentTheSessionIsSeen() {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.graine.identify(["patient_id": "P-1"])
        var atPublish: (seen: Bool, reason: String?, available: Bool)?
        rig.graine.sessionPublished = {
            // What a reader on another thread could read at this moment.
            atPublish = (rig.graine.session != nil, rig.graine.bookingUnavailableReason, rig.graine.bookingAvailable)
        }
        rig.graine.finishSession(.success(HandFetch.session(calls: ["hosted": true, "scheduling": ["usersCanBook": true]])))
        #expect(atPublish?.seen == true)
        #expect(atPublish?.reason == nil && atPublish?.available == true, "never a transient not_identified for P-1: \(String(describing: atPublish))")
    }

    @Test @MainActor func bookedCallsListedOrCancelledWithASessionThatCouldNotLoadSayWhy() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        let fetch = HandFetch()
        fetch.install(on: rig.graine)
        rig.graine.identify(["patient_id": "P-1"])
        let listed = Task { try await rig.graine.scheduledCalls() }
        await settle { fetch.requests == 1 }
        fetch.answer(.failure(GraineServiceError(code: .network, message: "The Internet connection appears to be offline.")))
        do {
            _ = try await listed.value
            Issue.record("expected the session's refusal, not this install's calls alone")
        } catch let error as GraineServiceError {
            #expect(error.code == .network)
        }
        let cancelled = Task { try await rig.graine.cancelScheduledCall(id: "sc_1") }
        await settle { fetch.requests == 2 }
        fetch.answer(.failure(GraineServiceError(code: .unavailable, message: "Graine is busy.", status: 503)))
        do {
            _ = try await cancelled.value
            Issue.record("expected the session's refusal")
        } catch let error as GraineServiceError {
            #expect(error.code == .unavailable)
        }
        #expect(rig.network.bodies("/api/embed/calls/list").isEmpty && rig.network.bodies("/api/embed/calls/cancel").isEmpty)
    }

    @Test func everyRefusalReadsTheContractsOneRule() throws {
        // sdk/contract/http-status.json: the one rule every SDK runs (inapp-platform-contract.md, "A refusal's code").
        let file = try ContractFile.load("http-status.json")
        let vectors = try #require(file["vectors"] as? [[String: Any]])
        #expect(vectors.count >= 20)
        for v in vectors {
            let name = v["name"] as? String ?? "?"
            let status = (v["status"] as? NSNumber)?.intValue ?? 0
            let heard = GraineServiceError.from(status: status, body: v["body"] as? [String: Any]).code
            let code = v["code"] as? String ?? ""
            let want = code == "unknown" ? GraineErrorCode.unknown(v["raw"] as? String ?? "") : GraineErrorCode(wire: code)
            #expect(heard == want, "\(name): \(heard)")
        }
    }

    @Test func aGatewayThatCouldNotReachGraineIsUnavailableAndABare500Unknown() {
        for status in [502, 503, 504] {
            #expect(GraineServiceError.from(status: status, body: nil).code == .unavailable, "\(status)")
        }
        #expect(GraineServiceError.from(status: 500, body: nil).code == .unknown("http_500"))
        #expect(GraineServiceError.from(status: 502, body: ["code": "rate_limited"]).code == .rateLimited, "a code the server sent wins")
    }

    @Test @MainActor func bookingReadsSayNotLoadedNotNotIdentifiedWhileTheSessionIsStillToCome() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        let calls: [String: Any] = ["hosted": true, "scheduling": ["usersCanBook": true]]
        // A session kept from an earlier launch: it books, but does not say who this launch's customer is.
        SessionCache(directory: rig.sandbox.folder).save(HandFetch.session(calls: calls))
        let fetch = HandFetch()
        fetch.install(on: rig.graine)
        rig.graine.identify(["patient_id": "P-1"])
        #expect(rig.graine.bookingUnavailableReason == "not_loaded", "not yet — never a not_identified that may be wrong")
        #expect(!rig.graine.bookingAvailable)
        #expect(rig.graine.bookingBlocked != "Sign in to book a call", "nobody who may be signed in is told to sign in")
        rig.graine.loadSession { _ in }
        fetch.answer(.success(HandFetch.session(calls: calls)))
        await settle { rig.graine.session != nil }
        #expect(rig.graine.bookingUnavailableReason == nil && rig.graine.bookingAvailable, "the session named the trait: P-1 can book")
        rig.graine.identify(["user_id": "u-1"])
        #expect(rig.graine.bookingUnavailableReason == "not_identified", "known now: the traits lack it")
        rig.graine.identify(nil)
        #expect(rig.graine.bookingUnavailableReason == "not_identified")
    }

    @Test func aCallsEventIsTheChatsEventAndTheAppsDataNeverRenamesIt() throws {
        let data: [String: Any] = ["name": "spoofed", "detail": "not this", "quiet": true, "max_per_session": 5, "meal": "breakfast"]
        let message = GraineProtocol.appEvent(name: "reminder_opened", detail: "The customer came from the breakfast reminder", data: data)
        #expect(JSON.string(message["type"]) == GraineProtocol.Out.appEvent)
        // The page's event form ({event}), which it hands the runtime as it is: never {name, data} for it to merge.
        let event = try #require(message["event"] as? [String: Any])
        #expect(JSON.string(event["name"]) == "reminder_opened")
        #expect(JSON.string(event["detail"]) == "The customer came from the breakfast reminder")
        #expect(event["quiet"] as? Bool == true && (event["max_per_session"] as? NSNumber)?.intValue == 5)
        let inner = try #require(event["data"] as? [String: Any])
        #expect(JSON.string(inner["name"]) == "spoofed" && JSON.string(inner["detail"]) == "not this" && JSON.string(inner["meal"]) == "breakfast")
        // The same event the chat sends.
        let chat = try #require(JSON.object(from: ChatWire.appEventFrame(name: "reminder_opened", detail: "The customer came from the breakfast reminder", data: data)))
        #expect(JSON.canonical(chat["event"]) == JSON.canonical(event))
    }

    @Test func reportEventsPacingKeysTravelAtTheEventsOwnLevel() throws {
        let frame = ChatWire.appEventFrame(name: "reminder_opened", detail: "The customer came from the breakfast reminder",
                                           data: ["cooldown_seconds": 0, "max_per_session": 5, "quiet": false, "meal": "breakfast"])
        let object = try #require(JSON.object(from: frame))
        let event = try #require(object["event"] as? [String: Any])
        #expect(JSON.string(object["type"]) == "app_event" && JSON.string(event["name"]) == "reminder_opened")
        #expect(JSON.string(event["detail"]) == "The customer came from the breakfast reminder")
        #expect((event["cooldown_seconds"] as? NSNumber)?.intValue == 0 && (event["max_per_session"] as? NSNumber)?.intValue == 5)
        #expect(event["quiet"] as? Bool == false)
        #expect((event["data"] as? [String: Any])?["meal"] as? String == "breakfast", "anything else rides in data")
        #expect((event["data"] as? [String: Any])?["quiet"] == nil, "never nested where the runtime does not read it")
    }
}
