import Foundation
import Testing
@_spi(GraineRTC) @testable import GraineInApp

/*
 * WHICH ROAD A CALL TAKES, AND WHAT HAPPENS WHEN WEBRTC CANNOT CARRY IT —
 * the conversation (CallConversation) with a stand-in for the opt-in module,
 * the real voice-socket engine behind it, and the clock moved by hand.
 */

// MARK: - A stand-in for the WebRTC module

final class FakeRtcCall: GraineRtcCall {
    var onEvent: ((GraineRtcEvent) -> Void)?
    /// Who hears this leg's readiness and loss while it is prepared ahead: the test reports through it.
    var onPrepared: ((GraineRtcPreparedState) -> Void)?
    /// Whether the call dialling it said it was prepared ahead of the tap, and the transport row it handed it.
    var preparedAhead = false
    var transportRow: String?
    private(set) var steps: [String] = []
    private(set) var sent: [(frame: String, kind: String?)] = []
    var directResult = true

    func prepare() { steps.append("prepare") }
    func begin() { steps.append("begin") }
    func audioActivated() { steps.append("audio") }
    func startAudioDirectly(_ done: @escaping (Bool) -> Void) {
        steps.append("direct")
        done(directResult)
    }
    func audioDeactivated() { steps.append("audioOff") }
    func setMuted(_ muted: Bool) { steps.append("muted(\(muted))") }
    func sendControl(_ frame: String, kind: String?) { sent.append((frame, kind)) }
    func hangUp() { steps.append("hangUp") }

    func emit(_ event: GraineRtcEvent) { onEvent?(event) }
    func control(_ object: [String: Any]) { emit(.control(JSON.string(from: object) ?? "{}")) }
}

final class FakeRtcModule: GraineRtcModule {
    var isSupported = true
    private(set) var calls: [FakeRtcCall] = []
    private(set) var requests: [GraineRtcRequest] = []
    /// What the SDK asked to be prepared ahead of any call, and whether it handed a log with it.
    private(set) var warmUps: [GraineRtcRequest] = []
    private(set) var warmUpLogs: [Bool] = []
    /// What startCall asked for its id with, and what this module answers.
    private(set) var nextCallIdRequests: [GraineRtcRequest] = []
    var nextCallIdAnswer: String?

    func makeCall(_ request: GraineRtcRequest) -> GraineRtcCall {
        requests.append(request)
        let call = FakeRtcCall()
        calls.append(call)
        return call
    }

    func warmUp(_ request: GraineRtcRequest, log: ((String) -> Void)?) {
        warmUps.append(request)
        warmUpLogs.append(log != nil)
    }

    func nextCallId(_ request: GraineRtcRequest) -> String? {
        nextCallIdRequests.append(request)
        return nextCallIdAnswer
    }

    var call: FakeRtcCall? { calls.last }
}

final class ConversationRig {
    let scheduler = ManualScheduler()
    let network = FakeNetwork()
    let audio = ScriptedAudio()
    let module = FakeRtcModule()
    var installed = true
    var session: GraineSessionConfig? = GraineSessionConfig(agentId: "agent-1", webcallAgentId: "web-1")
    var contextFrame: [String: Any]?
    var prepared: GraineRtcCall?
    private(set) var takenFor: [String?] = []
    /// What the answer would mint with, as it asked for the prepared leg; and what that leg was minted with (nil: anything).
    private(set) var takenMints: [Data] = []
    var preparedMint: Data?
    var actionRunner: (String, [String: Any], @escaping (GraineActionResult) -> Void) -> Void = { _, _, answer in answer(.ok("done")) }
    private(set) var events: [CallEngine.Event] = []
    private(set) var reports: [CallTransportReport] = []

    static let identity = IdentityWire.Fields(value: "customer-1", installId: "install-1", memory: true, timezone: "Asia/Kolkata", callId: "call_1")
    /// Held here as GraineCalls holds it: its event hops are weak.
    private(set) var conversation: CallConversation?

    func make(_ transport: GraineCallTransport = .auto) -> CallConversation {
        let made = build(transport)
        conversation = made
        return made
    }

    private func build(_ transport: GraineCallTransport) -> CallConversation {
        CallConversation(
            setup: CallEngine.Setup(
                publishableKey: "pk_test_rig",
                baseUrl: "https://www.graine.ai",
                variables: [("who_called", "customer"), ("call_reason", "card_blocked"), ("plan", "gold")],
                contextFrame: { [unowned self] in self.contextFrame },
                session: { [unowned self] done in done(self.session) },
                runAction: { [unowned self] name, args, answer in self.actionRunner(name, args, answer) },
                callVariables: [("who_called", "customer"), ("call_reason", "card_blocked")],
                identity: Self.identity
            ),
            audio: audio,
            network: network,
            scheduler: scheduler,
            transport: transport,
            rtcModule: { [unowned self] in self.installed ? self.module : nil },
            takePrepared: { [unowned self] id, mint in
                self.takenFor.append(id)
                self.takenMints.append(mint)
                // Through a RingPreparation of its own, as the shared one hands a prepared leg over.
                let store = RingPreparation()
                if let leg = self.prepared, let id = id { store.put(id, leg, mint: self.preparedMint) }
                self.prepared = nil
                return store.take(id, mint: mint)
            },
            onTransport: { [unowned self] in self.reports.append($0) },
            onEvent: { [unowned self] in self.events.append($0) }
        )
    }

    func session(audioTransport: String?) {
        let calls = GraineHostedCallsSettings.parse(audioTransport.map { ["audioTransport": $0] } ?? [:])
        session = GraineSessionConfig(agentId: "agent-1", webcallAgentId: "web-1", wsHost: "wss://ws.graine.ai/", calls: calls)
    }

    var ticketPosts: Int { network.posts.filter { $0.url.path == "/api/embed/ticket" }.count }

    var transports: [CallEngine.Transport] {
        events.compactMap { if case .opened(let t) = $0 { return t }; return nil }
    }

    var endings: [CallEngine.Ending] {
        events.compactMap { if case .ended(let e) = $0 { return e }; return nil }
    }

    var captions: [GraineCaption] {
        events.compactMap { if case .caption(let c) = $0 { return c }; return nil }
    }
}

// MARK: - The choice

@Suite struct CallTransportChoiceTests {
    @Test func theOptionReadsItsWords() {
        #expect(GraineCallTransport.from("auto") == .auto)
        #expect(GraineCallTransport.from(" WebRTC ") == .webrtc)
        #expect(GraineCallTransport.from("rtc") == .webrtc)
        #expect(GraineCallTransport.from("websocket") == .websocket)
        #expect(GraineCallTransport.from("ws") == .websocket)
        #expect(GraineCallTransport.from("carrier pigeon") == nil)
        #expect(GraineCallTransport.from(nil) == nil)
    }

    /// The table: the app's choice × the dashboard's switch × the module being there.
    @Test func theDashboardCanOnlyTurnWebRtcOff() {
        let table: [(GraineCallTransport, GraineCallTransport?, Bool, GraineCallTransport)] = [
            (.auto, nil, true, .webrtc),
            (.auto, nil, false, .websocket),
            (.auto, .webrtc, true, .webrtc),
            (.auto, .websocket, true, .websocket),
            (.webrtc, nil, true, .webrtc),
            (.webrtc, nil, false, .websocket),
            (.webrtc, .websocket, true, .websocket),
            (.websocket, nil, true, .websocket),
            (.websocket, .webrtc, true, .websocket),
        ]
        for (asked, dashboard, available, expected) in table {
            #expect(CallTransportChoice.decide(requested: asked, dashboard: dashboard, rtcAvailable: available) == expected,
                    "\(asked) / \(String(describing: dashboard)) / \(available)")
        }
    }

    @Test func theSessionCarriesTheSwitch() {
        #expect(GraineHostedCallsSettings.parse(["audioTransport": "websocket"])?.audioTransport == .websocket)
        #expect(GraineHostedCallsSettings.parse(["audioTransport": "webrtc"])?.audioTransport == .webrtc)
        #expect(GraineHostedCallsSettings.parse(["audioTransport": "auto"])?.audioTransport == nil, "no opinion")
        #expect(GraineHostedCallsSettings.parse(["audioTransport": 7])?.audioTransport == nil)
        #expect(GraineHostedCallsSettings.parse([:])?.audioTransport == nil)
    }

    /// The mint carries what the ticket carries: the same variables (the ticket's limits) and identity fields.
    @Test func theMintsBodyIsTheTickets() throws {
        let many = (1...20).map { ("var\($0)", "value\($0)") }
        let data = RtcMintBody.json(
            publishableKey: "pk_test_x",
            sessionId: "0123456789abcdef0123456789abcdef",
            callVariables: [("who_called", "scheduled"), ("call_reason", "payment_due")],
            variables: [("who_called", "scheduled"), ("call_reason", "payment_due")] + many,
            identity: ConversationRig.identity
        )
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix(#"{"publishableKey":"pk_test_x","session_id":"0123456789abcdef0123456789abcdef","variables":{"who_called":"scheduled","call_reason":"payment_due","var1":"value1""#))
        let body = try #require(JSON.object(from: data))
        let variables = try #require(body["variables"] as? [String: Any])
        #expect(variables.count == CallWire.ticketKeyLimit, "the ticket's twelve, the call's own first")
        #expect(JSON.string(body["installId"]) == "install-1", "without it the agent's memory stays off")
        #expect(JSON.string(body["callId"]) == "call_1", "a call Graine rang names itself")
        #expect((body["identity"] as? [String: Any])?["value"] as? String == "customer-1")
        #expect(body["memory"] as? Bool == true)
        #expect(JSON.string(body["timezone"]) == "Asia/Kolkata")
        #expect(body["direct"] == nil && body["grant"] == nil)
    }
}

// MARK: - The conversation

@Suite struct CallConversationTests {
    @Test func withTheModuleTheCallTriesWebRtcAndConnectsOnIt() throws {
        let rig = ConversationRig()
        rig.contextFrame = ["context": ["screen": "home"], "seq": 1]
        let conversation = rig.make()
        conversation.start()
        let call = try #require(rig.module.call)
        #expect(call.steps == ["prepare", "muted(false)", "begin"], "prepared, then wanted; no INVITE without the audio")
        #expect(call.sent.first?.kind == "app_context", "the screen, queued for the agent's first line")
        #expect(rig.ticketPosts == 0, "no socket on this road")
        let request = try #require(rig.module.requests.first)
        #expect(request.baseUrl == "https://www.graine.ai")
        #expect(request.controlHost == "wss://ws.graine.ai")
        #expect(request.budgetSeconds == 12)
        conversation.startAudio()
        #expect(call.steps.last == "audio")
        call.emit(.ready)
        call.emit(.connected)
        #expect(rig.transports == [.webrtc])
        #expect(rig.reports == [CallTransportReport(transport: .webrtc)])
        conversation.hangUp()
        #expect(call.steps.last == "hangUp")
        #expect(rig.endings == [.local])
    }

    /// The module mints with the call's own id — the one its grant, if it holds one, was asked for.
    @Test func theModuleMintsWithTheCallsOwnId() throws {
        let rig = ConversationRig()
        rig.make().start()
        let request = try #require(rig.module.requests.first)
        let body = try #require(JSON.object(from: request.mintBody("0123456789abcdef0123456789abcdef")))
        #expect(JSON.string(body["callId"]) == "call_1")
    }

    @Test func theDashboardsSwitchAndTheAppsChoiceKeepTheSocket() {
        let killed = ConversationRig()
        killed.session(audioTransport: "websocket")
        killed.make().start()
        #expect(killed.module.calls.isEmpty)
        #expect(killed.ticketPosts == 1, "the voice socket's ticket")
        #expect(killed.reports == [CallTransportReport(transport: .websocket)])

        let asked = ConversationRig()
        asked.make(.websocket).start()
        #expect(asked.module.calls.isEmpty)
        #expect(asked.ticketPosts == 1)

        let missing = ConversationRig()
        missing.installed = false
        missing.make(.webrtc).start()
        #expect(missing.ticketPosts == 1, "asked for WebRTC without the module: the socket")

        let unsupported = ConversationRig()
        unsupported.module.isSupported = false
        unsupported.make().start()
        #expect(unsupported.module.calls.isEmpty)
    }

    @Test func beforeMediaAFailureContinuesOnTheSocketInTheSameCall() throws {
        let rig = ConversationRig()
        let conversation = rig.make()
        conversation.start()
        conversation.startAudio()
        conversation.setMuted(true)
        let call = try #require(rig.module.call)
        call.emit(.unreachable(.noAnswer, detail: "not answered"))
        #expect(call.steps.last == "hangUp", "the WebRTC leg is let go")
        #expect(rig.reports == [CallTransportReport(transport: .websocket, requested: .webrtc, reason: "no_answer")])
        #expect(rig.ticketPosts == 1, "the socket path starts")
        #expect(rig.audio.started, "with the audio CallKit already handed over")
        let socket = try #require(rig.network.socket)
        socket.open()
        #expect(rig.transports == [.gateway])
        call.emit(.connected)
        #expect(rig.transports == [.gateway], "the old leg is not heard any more")
        #expect(rig.endings.isEmpty)
    }

    @Test func aGateRefusalEndsTheCallWithItsWords() throws {
        let rig = ConversationRig()
        let conversation = rig.make()
        conversation.start()
        let call = try #require(rig.module.call)
        call.emit(.refused(code: "insufficient_credits", message: "This account is out of credits."))
        #expect(rig.endings == [.couldNotOpen("insufficient_credits: This account is out of credits.")])
        #expect(rig.ticketPosts == 0, "no fallback: the socket would refuse it the same way")
        #expect(rig.reports.isEmpty)
    }

    @Test func afterMediaNothingMovesToTheSocket() throws {
        let rig = ConversationRig()
        let conversation = rig.make()
        conversation.start()
        let call = try #require(rig.module.call)
        call.emit(.connected)
        call.emit(.ended(.dropped("the media path was lost")))
        #expect(rig.endings == [.dropped("the media path was lost")])
        #expect(rig.ticketPosts == 0)

        let remote = ConversationRig()
        remote.make().start()
        remote.module.call?.emit(.connected)
        remote.module.call?.emit(.ended(.remote))
        #expect(remote.endings == [.remote])
    }

    @Test func theControlChannelsFramesBecomeTheCallsCaptions() throws {
        let rig = ConversationRig()
        rig.make().start()
        let call = try #require(rig.module.call)
        call.emit(.connected)
        call.control(["type": "text", "data": "Welcome to"])
        call.control(["type": "text", "data": "Tring"])
        call.control(["type": "end_of_stream"])
        call.control(["type": "interim_transcript_received", "content": "I need"])
        call.control(["type": "transcript", "content": "I need help"])
        call.control(["type": "transcript", "data": ["content": "nested"]])
        call.control(["type": "widget", "widget": ["kind": "list"]])
        #expect(rig.captions == [
            GraineCaption(role: .agent, text: "Welcome to", live: true),
            GraineCaption(role: .agent, text: "Welcome to Tring", live: true),
            GraineCaption(role: .agent, text: "Welcome to Tring", live: false),
            GraineCaption(role: .customer, text: "I need", live: true),
            GraineCaption(role: .customer, text: "I need help", live: false),
            GraineCaption(role: .customer, text: "nested", live: false),
        ])
    }

    @Test func theAgentsActionsAreAnsweredOnTheControlChannel() throws {
        let rig = ConversationRig()
        rig.actionRunner = { name, args, answer in answer(.ok("opened \(name) \(args["id"] as? String ?? "")")) }
        rig.make().start()
        let call = try #require(rig.module.call)
        call.control(["type": "app_action", "action": ["action_id": "a1", "name": "open_order", "arguments": ["id": "A-1"]]])
        let answer = try #require(call.sent.last)
        #expect(answer.kind == nil)
        let frame = try #require(JSON.object(from: answer.frame))
        #expect(JSON.string(frame["type"]) == "app_action_result")
        #expect(JSON.string(frame["action_id"]) == "a1")
        #expect(JSON.string(frame["status"]) == "ok")

        // A handler that never answers is answered for it, inside the agent's six seconds.
        rig.actionRunner = { _, _, _ in }
        call.control(["type": "app_action", "action": ["action_id": "a2", "name": "slow"]])
        rig.scheduler.advance(5.7)
        let late = try #require(JSON.object(from: call.sent.last!.frame))
        #expect(JSON.string(late["action_id"]) == "a2")
        #expect(JSON.string(late["status"]) == "error")
    }

    @Test func theScreenGoesOverTheControlChannel() throws {
        let rig = ConversationRig()
        let conversation = rig.make()
        conversation.start()
        let call = try #require(rig.module.call)
        conversation.sendContext(["context": ["screen": "cart"], "availableActions": ["checkout"], "seq": 4])
        let frame = try #require(call.sent.last)
        #expect(frame.kind == "app_context", "the newest screen replaces a queued one")
        #expect(frame.frame.contains(#""available_actions":["checkout"]"#))
    }

    @Test func withoutCallKitsAudioTheCallStartsItDirectlyThenFails() throws {
        let rig = ConversationRig()
        rig.make().start()
        let call = try #require(rig.module.call)
        call.directResult = false
        call.emit(.ready)
        rig.scheduler.advance(2.9)
        #expect(!call.steps.contains("direct"))
        rig.scheduler.advance(0.2)
        #expect(call.steps.contains("direct"), "3 s without CallKit's audio: started directly")
        #expect(rig.endings == [.couldNotOpen(CallAudioWatch.failure)], "and it would not start")

        let fine = ConversationRig()
        fine.make().start()
        fine.module.call?.emit(.ready)
        fine.scheduler.advance(3.1)
        #expect(fine.module.call?.steps.contains("direct") == true)
        fine.scheduler.advance(10)
        #expect(fine.endings.isEmpty, "the direct start worked: the call dials")

        let callKit = ConversationRig()
        let conversation = callKit.make()
        conversation.start()
        callKit.module.call?.emit(.ready)
        conversation.startAudio()
        callKit.scheduler.advance(10)
        #expect(callKit.module.call?.steps.contains("direct") == false, "CallKit's audio arrived in time")
    }

    @Test func theAudioWatchsDirectStartReachesTheModule() throws {
        let rig = ConversationRig()
        let conversation = rig.make()
        conversation.start()
        let call = try #require(rig.module.call)
        var started: Bool?
        conversation.startAudio { started = $0 }
        #expect(call.steps.last == "direct", "a start with an answer is the direct one, not CallKit's")
        #expect(started == true)
    }

    @Test func aRingPreparedLegIsTakenNotMadeAgain() throws {
        let rig = ConversationRig()
        let prepared = FakeRtcCall()
        rig.prepared = prepared
        rig.make().start()
        #expect(rig.takenFor == ["call_1"], "by the call's id")
        #expect(rig.module.calls.isEmpty, "nothing minted twice")
        #expect(prepared.steps == ["muted(false)", "begin"], "already prepared while it rang")

        // Minted with exactly what the answer would mint with: taken.
        let same = ConversationRig()
        same.make().start()
        let body = try #require(same.takenMints.first)
        let again = ConversationRig()
        let leg = FakeRtcCall()
        again.prepared = leg
        again.preparedMint = body
        again.make().start()
        #expect(again.module.calls.isEmpty)
        #expect(leg.steps.contains("begin"))
    }

    /// The customer became known (or changed) while it rang — a push-woken app's session arrived: the leg is minted again, as Android does.
    @Test func aLegPreparedForAnotherCustomerIsMintedAgainAtTheAnswer() throws {
        let rig = ConversationRig()
        let stale = FakeRtcCall()
        rig.prepared = stale
        rig.preparedMint = RtcMintBody.json(publishableKey: "pk_test_rig", sessionId: "", callVariables: [], variables: [],
                                            identity: IdentityWire.Fields(value: nil, installId: "install-1", memory: true, timezone: "Asia/Kolkata", callId: "call_1"))
        rig.make().start()
        #expect(stale.steps == ["hangUp"], "the leg minted for nobody is let go — no INVITE ever left it")
        let fresh = try #require(rig.module.call)
        #expect(fresh.steps.contains("prepare"), "and the call minted again")
        let request = try #require(rig.module.requests.first)
        let body = try #require(JSON.object(from: request.mintBody("")))
        #expect((body["identity"] as? [String: Any])?["value"] as? String == "customer-1", "as who the customer is now")
        #expect(JSON.string(body["callId"]) == "call_1", "still the ring's own id")
    }

    @Test func endedBeforeMediaIsAFailureNotARemoteEnd() throws {
        let rig = ConversationRig()
        rig.make().start()
        rig.module.call?.emit(.ended(.remote))
        #expect(rig.endings == [.couldNotOpen("The call ended before it connected.")])
    }
}

@Suite struct RingPreparationTests {
    @Test func theAnswerTakesItAnythingElseHangsItUp() {
        let store = RingPreparation()
        let leg = FakeRtcCall()
        store.put("call_9", leg)
        #expect(store.count == 1)
        #expect(store.take("call_8") == nil)
        #expect(store.take("call_9") === leg)
        #expect(store.count == 0)
        #expect(leg.steps.isEmpty, "taken, not hung up")

        let declined = FakeRtcCall()
        store.put("call_10", declined)
        store.discard("call_10")
        #expect(declined.steps == ["hangUp"])

        let first = FakeRtcCall()
        let second = FakeRtcCall()
        store.put("call_11", first)
        store.put("call_11", second)
        #expect(first.steps == ["hangUp"], "one per call")
        store.discard("call_11", only: first)
        #expect(second.steps.isEmpty, "only the one asked for")
        #expect(store.take(nil) == nil)
        #expect(store.take("") == nil)
    }

    @Test func aLegMintedWithSomethingElseIsHungUpNotTaken() {
        let store = RingPreparation()
        let leg = FakeRtcCall()
        store.put("call_12", leg, mint: Data("anonymous".utf8))
        #expect(store.take("call_12", mint: Data("customer-1".utf8)) == nil)
        #expect(leg.steps == ["hangUp"])
        #expect(store.count == 0)

        let kept = FakeRtcCall()
        store.put("call_13", kept, mint: Data("customer-1".utf8))
        #expect(store.take("call_13", mint: Data("customer-1".utf8)) === kept)
        #expect(kept.steps.isEmpty)
    }
}
