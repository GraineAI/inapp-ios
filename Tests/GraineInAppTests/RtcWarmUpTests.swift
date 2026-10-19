import Foundation
import Testing
@_spi(GraineRTC) @testable import GraineInApp

/*
 * THE NEXT TAP'S GRANT, ASKED FOR BEFORE THE TAP (GraineInApp.warmCalls):
 * when the session arrives, when the customer or their memory choice changes —
 * through the Swift API and through the Objective-C facade Kotlin
 * Multiplatform and Objective-C apps drive — with a stand-in for the WebRTC
 * module. Who the customer is goes with it, never a call; and nothing is asked
 * where a call would not try WebRTC.
 */
@Suite @MainActor struct RtcWarmUpTests {
    private func rig(_ module: FakeRtcModule?) -> PlatformRig {
        let rig = PlatformRig()
        rig.graine.rtcModule = { module }
        return rig
    }

    /// What a warm-up hands the module: a mint body, read back, without a session id yet.
    private func body(_ request: GraineRtcRequest?) -> [String: Any] {
        request.flatMap { JSON.object(from: $0.mintBody("")) } ?? [:]
    }

    private func customer(_ request: GraineRtcRequest?) -> String? {
        (body(request)["identity"] as? [String: Any])?["value"] as? String
    }

    @Test func theSessionArrivingWarmsTheCallsForWhoTheCustomerIs() throws {
        let module = FakeRtcModule()
        let rig = rig(module)
        defer { rig.sandbox.clean() }
        rig.graine.identify(["user_id": "P-1", "name": "Riya"])
        #expect(module.warmUps.isEmpty, "who the customer is cannot be read before the session")
        rig.session()
        #expect(module.warmUps.count == 1)
        let request = try #require(module.warmUps.first)
        #expect(request.baseUrl == "https://www.graine.ai")
        #expect(request.controlHost == "wss://ws.graine.ai")
        let sent = body(request)
        #expect(sent["publishableKey"] as? String == "pk_test_rig")
        #expect(customer(request) == "P-1")
        #expect(sent["installId"] as? String == "3f2504e0-4f89-11d3-9a0c-0305e82c3301")
        #expect(sent["memory"] as? Bool == true)
        #expect(sent["timezone"] as? String == TimeZone.current.identifier)
        #expect(sent["callId"] == nil, "the next call's id is the module's to choose, ahead of the call")
        #expect(sent["variables"] == nil, "a call's variables are the call's")
        #expect(module.warmUpLogs == [false], "no debug, no log")
        #expect(module.calls.isEmpty, "nothing placed: no call, no microphone")
    }

    @Test func anotherCustomerOrMemoryChoiceWarmsAgain() {
        let module = FakeRtcModule()
        let rig = rig(module)
        defer { rig.sandbox.clean() }
        rig.session()
        rig.graine.identify(["user_id": "P-2"])
        #expect(module.warmUps.count == 2)
        #expect(customer(module.warmUps.last) == "P-2")
        rig.graine.setMemory(false)
        #expect(module.warmUps.count == 3)
        #expect(body(module.warmUps.last)["memory"] as? Bool == false, "the memory choice is signed into the grant too")
        rig.graine.identify(nil)
        #expect(module.warmUps.count == 4)
        #expect(customer(module.warmUps.last) == nil, "signed out: a grant for nobody in particular")
    }

    /**
     * KOTLIN MULTIPLATFORM'S WAY IN. `Graine.configure` is
     * `+[GraineObjC configureWithBaseUrl:…name:]`, which is
     * `GraineInApp.configure` — whose session fetch ends in `finishSession`,
     * delivered here as the network would; `Graine.identify` and `setMemory`
     * are `-identifyJSON:`, `-identifyJSON:memory:` and `-setMemory:`.
     */
    @Test func theObjectiveCFacadeKotlinDrivesWarmsTheCallsTheSameWay() {
        let module = FakeRtcModule()
        let rig = rig(module)
        defer { rig.sandbox.clean() }
        let facade = GraineObjC(graine: rig.graine)
        rig.session()
        #expect(module.warmUps.count == 1, "the session the configure selector fetched")
        facade.identifyJSON(#"{"user_id":"P-1","name":"Riya"}"#)
        #expect(customer(module.warmUps.last) == "P-1")
        facade.identifyJSON(#"{"user_id":"P-1"}"#, memory: false)
        #expect(body(module.warmUps.last)["memory"] as? Bool == false)
        facade.setMemory(true)
        #expect(body(module.warmUps.last)["memory"] as? Bool == true)
        facade.identify(["user_id": "P-3"])
        #expect(customer(module.warmUps.last) == "P-3")
        facade.identifyJSON(nil)
        #expect(customer(module.warmUps.last) == nil)
        #expect(module.warmUps.count == 6, "the session, then one for each change")
        #expect(module.warmUps.allSatisfy { body($0)["callId"] == nil })
    }

    /**
     * startCall's id — GraineCalls asks `nextCallId`, from Swift or through
     * `startCallJSONWithReason:` from Kotlin: the warm grant's, while the
     * module says it is usable for this customer; else an id of its own.
     */
    @Test func aCallTheCustomerPlacesTakesTheWarmGrantsId() throws {
        let module = FakeRtcModule()
        module.nextCallIdAnswer = "call_next1"
        let rig = rig(module)
        defer { rig.sandbox.clean() }
        #expect(rig.graine.nextCallId() == nil, "before the session: an id of its own")
        #expect(module.nextCallIdRequests.isEmpty)
        rig.session()
        rig.graine.identify(["user_id": "P-1"])
        #expect(rig.graine.nextCallId() == "call_next1")
        let asked = try #require(module.nextCallIdRequests.last)
        #expect(customer(asked) == "P-1", "asked for this customer's")
        #expect(body(asked)["callId"] == nil)
        module.nextCallIdAnswer = nil
        #expect(rig.graine.nextCallId() == nil, "no usable grant: an id of its own")

        let switched = FakeRtcModule()
        switched.nextCallIdAnswer = "call_next1"
        let off = self.rig(switched)
        defer { off.sandbox.clean() }
        off.session(["calls": ["audioTransport": "websocket"]])
        #expect(off.graine.nextCallId() == nil, "a call on the WebSocket takes an id of its own")
        #expect(switched.nextCallIdRequests.isEmpty)
    }

    /// A ring: a grant asked for exactly its id while it rings (RingPreparation asks once WebRTC is chosen).
    @Test func aRingingCallsGrantIsAskedForItsOwnId() throws {
        let module = FakeRtcModule()
        let rig = rig(module)
        defer { rig.sandbox.clean() }
        rig.session()
        rig.graine.identify(["user_id": "P-1"])
        let before = module.warmUps.count
        rig.graine.warmCalls(ringing: "call_ring_0000000001", session: nil)
        #expect(module.warmUps.count == before + 1)
        #expect(JSON.string(body(module.warmUps.last)["callId"]) == "call_ring_0000000001", "the ring's own id")
        #expect(customer(module.warmUps.last) == "P-1")

        // A cold start, woken by the ring: the session the ring was prepared with (the kept one) is enough.
        let cold = FakeRtcModule()
        let woken = self.rig(cold)
        defer { woken.sandbox.clean() }
        woken.graine.warmCalls(ringing: "call_ring_0000000002", session: GraineSessionConfig(agentId: "agent-1", webcallAgentId: "web-1"))
        #expect(JSON.string(body(cold.warmUps.last)["callId"]) == "call_ring_0000000002")

        // On the WebSocket, nothing.
        let switched = FakeRtcModule()
        let ws = self.rig(switched)
        defer { ws.sandbox.clean() }
        ws.session(["calls": ["audioTransport": "websocket"]])
        ws.graine.warmCalls(ringing: "call_ring_0000000003", session: nil)
        #expect(switched.warmUps.isEmpty)
    }

    /// A ring that arrived before the customer was known (a push-woken app): the session arriving, or identify(), asks for its grant again under them.
    @Test func aRingingCallsGrantIsAskedForAgainWhenTheCustomerChanges() throws {
        let module = FakeRtcModule()
        let rig = rig(module)
        defer { rig.sandbox.clean() }
        let ringId = "call_ring_0000000004"
        let rings = { module.warmUps.filter { JSON.string(self.body($0)["callId"]) == ringId } }
        rig.graine.ringingCallId = { _ in ringId }
        rig.graine.identify(["user_id": "P-1"])
        #expect(rings().isEmpty, "nothing before the session")
        rig.session()
        #expect(rings().count == 1, "the session arrived mid-ring")
        #expect(customer(rings().last) == "P-1")
        rig.graine.identify(["user_id": "P-2"])
        #expect(rings().count == 2, "identify() changed who it is")
        #expect(customer(rings().last) == "P-2")
        #expect(module.warmUps.filter { self.body($0)["callId"] == nil }.count == 2, "beside the next call's grant each time")
        rig.graine.ringingCallId = { _ in nil }
        rig.graine.identify(["user_id": "P-3"])
        #expect(rings().count == 2, "no ring, no ring's grant")
    }

    @Test func nothingIsAskedWhereACallWouldNotTryWebRtc() {
        let switched = FakeRtcModule()
        let off = rig(switched)
        defer { off.sandbox.clean() }
        off.session(["calls": ["audioTransport": "websocket"]])
        off.graine.identify(["user_id": "P-1"])
        #expect(switched.warmUps.isEmpty, "the dashboard keeps this agent's calls on the WebSocket")

        let unable = FakeRtcModule()
        unable.isSupported = false
        let old = rig(unable)
        defer { old.sandbox.clean() }
        old.session()
        #expect(unable.warmUps.isEmpty, "the module cannot run here")

        // No module in the app: nothing asked, nothing broken.
        let none = rig(nil)
        defer { none.sandbox.clean() }
        none.session()
        none.graine.identify(["user_id": "P-1"])
        #expect(none.graine.identity.snapshot().value == "P-1")
    }
}
