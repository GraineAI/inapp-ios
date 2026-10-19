import Foundation
import Testing
@_spi(GraineRTC) @testable import GraineInApp

/*
 * A CALL PREPARED BEFORE THE TAP (GraineCalls.prepareCall → GraineInApp's
 * prepared call), on fakes: the WebRTC module stood in for, the clock and the
 * four-minute timer moved by hand. What is prepared and when nothing is sent;
 * the tap dialling it, by its id, only when the call would mint exactly the
 * same — who is calling, every field, with the reason and the variables; each
 * thing that lets it go; and the times it does nothing at all.
 */

@MainActor
private final class PrepareRig {
    let base = PlatformRig()
    let module = FakeRtcModule()
    var now = 1_000.0
    private(set) var timers: [(seconds: TimeInterval, fire: () -> Void)] = []
    var graine: GraineInApp { base.graine }

    init(installed: Bool = true) {
        let module = self.module
        base.graine.rtcModule = { installed ? module : nil }
        base.graine.uptime = { [unowned self] in self.now }
        base.graine.afterDelay = { [unowned self] seconds, fire in self.timers.append((seconds, fire)) }
        base.graine.callInProgress = { _ in false }
    }

    deinit { base.sandbox.clean() }

    func session(_ extra: [String: Any] = [:]) { base.session(extra) }

    func prepare(reason: String? = "support", own: [String: String] = ["order": "A-1043"]) {
        graine.prepareNextCall(reason: reason, own: own)
    }

    var leg: FakeRtcCall? { module.call }
    var requests: Int { module.requests.count }

    func body(_ data: Data) -> [String: Any] { JSON.object(from: data) ?? [:] }
    func body(_ request: GraineRtcRequest?) -> [String: Any] { request.map { body($0.mintBody("")) } ?? [:] }

    /// What startCall and its call do: the prepared call's id when this is that call, then its leg, by that id.
    func tap(reason: String? = "support", own: [String: String] = ["order": "A-1043"]) -> (id: String?, leg: GraineRtcCall?) {
        guard let id = graine.preparedCallId(reason: reason, own: own) else { return (nil, nil) }
        return (id, graine.takePreparedCall(id: id, mint: graine.outgoingMint(reason: reason, own: own, callId: id)))
    }

    var prepared: String? { graine.preparedCallId(reason: "support", own: ["order": "A-1043"]) }
}

@Suite @MainActor struct PrepareCallTests {
    // MARK: What is prepared

    @Test func preparingMakesTheNextCallReadyAndDialsNothing() throws {
        let rig = PrepareRig()
        rig.module.nextCallIdAnswer = "call_next1"
        rig.session()
        rig.graine.identify(["user_id": "P-1"])
        rig.prepare()
        let leg = try #require(rig.leg)
        #expect(leg.steps == ["prepare"], "minted, gathered, registered — never begun, no audio: nothing dialled")
        let body = rig.body(rig.module.requests.last)
        #expect(JSON.string(body["callId"]) == "call_next1", "the warm grant's id: it mints at the gateway")
        #expect((body["identity"] as? [String: Any])?["value"] as? String == "P-1")
        let variables = try #require(body["variables"] as? [String: Any])
        #expect(variables["who_called"] as? String == "customer")
        #expect(variables["call_reason"] as? String == "support")
        #expect(variables["order"] as? String == "A-1043")
        #expect(rig.timers.map(\.seconds) == [240], "let go after four minutes")
    }

    @Test func askingAgainSendsNothingWhileItIsTheSameCall() {
        let rig = PrepareRig()
        rig.session()
        rig.prepare()
        rig.prepare()
        rig.now += 239
        rig.prepare()
        #expect(rig.requests == 1, "the same call, under four minutes: nothing sent")
        #expect(rig.leg?.steps == ["prepare"])
    }

    @Test func anotherReasonOrOtherVariablesArePreparedAfresh() {
        let rig = PrepareRig()
        rig.session()
        rig.prepare(reason: "support")
        let first = rig.leg
        rig.prepare(reason: "billing")
        #expect(rig.requests == 2)
        #expect(first?.steps.last == "hangUp", "at most one prepared call: the old one let go")
        rig.prepare(reason: "billing", own: ["order": "B-7"])
        #expect(rig.requests == 3)
        rig.graine.setVariables(["plan": "gold"])
        rig.prepare(reason: "billing", own: ["order": "B-7"])
        #expect(rig.requests == 4, "the app's variables are in what the call carries too")
    }

    @Test func fourMinutesOldIsLetGoAndPreparedAfresh() {
        let rig = PrepareRig()
        rig.session()
        rig.prepare()
        let old = rig.leg
        rig.now += 240
        #expect(rig.prepared == nil, "four minutes old: not dialled")
        #expect(old?.steps.last == "hangUp")
        rig.prepare()
        #expect(rig.requests == 2)
        let fresh = rig.leg
        rig.timers.first?.fire()
        #expect(fresh?.steps == ["prepare"], "the first call's timer never lets the second go")
        rig.timers.last?.fire()
        #expect(fresh?.steps.last == "hangUp", "its own four minutes do")
        #expect(rig.prepared == nil)
    }

    // MARK: The tap

    @Test func theTapDialsThePreparedCallWithItsId() throws {
        let rig = PrepareRig()
        rig.module.nextCallIdAnswer = "call_next1"
        rig.session()
        rig.prepare()
        let leg = try #require(rig.leg)
        let tap = rig.tap()
        #expect(tap.id == "call_next1", "the prepared call's id")
        #expect(tap.leg === leg, "its leg, handed to the call")
        #expect(leg.steps == ["prepare"], "not hung up: the call begins it")
        #expect(leg.onPrepared == nil, "the call listens from here")
        #expect(rig.tap().id == nil, "taken once")
    }

    @Test func aTapWithAnotherReasonPreparesAtTheTap() {
        let rig = PrepareRig()
        rig.session()
        rig.prepare(reason: "support")
        #expect(rig.graine.preparedCallId(reason: "billing", own: ["order": "A-1043"]) == nil)
        #expect(rig.leg?.steps.last == "hangUp", "let go: the call is prepared at the tap, as before")
    }

    @Test func theCallNeverTakesALegMintedForSomethingElseOrAnotherCall() throws {
        let rig = PrepareRig()
        rig.module.nextCallIdAnswer = "call_next1"
        rig.session()
        rig.prepare()
        #expect(rig.graine.takePreparedCall(id: "call_someone_else", mint: Data()) == nil)
        #expect(rig.leg?.steps == ["prepare"], "kept for its own call")
        #expect(rig.graine.takePreparedCall(id: "call_next1", mint: Data(#"{"other":true}"#.utf8)) == nil)
        #expect(rig.leg?.steps.last == "hangUp", "minted for something else: let go, never dialled")
    }

    // MARK: The microphone

    /// 19 Oct, on Android: a prepared call recorded from the microphone on the Home screen. Prepared here is only
    /// prepared — never begun, its audio never turned on — and a call let go never had it on.
    @Test func aPreparedCallNeverHasItsAudioTurnedOnAndOneLetGoNeverDid() throws {
        let rig = PrepareRig()
        rig.session()
        rig.prepare()
        let leg = try #require(rig.leg)
        rig.prepare()
        #expect(leg.steps == ["prepare"], "prepared, never begun, no audio")
        rig.graine.setForeground(false)
        #expect(leg.steps == ["prepare", "hangUp"], "let go: its audio was never turned on")
    }

    // MARK: What lets it go

    @Test func theBackgroundLetsItGo() {
        let rig = PrepareRig()
        rig.session()
        rig.prepare()
        rig.graine.setForeground(false)
        #expect(rig.leg?.steps.last == "hangUp")
        #expect(rig.prepared == nil)
    }

    @Test func anotherCustomerLetsItGoTheSameCustomerAgainDoesNot() {
        let rig = PrepareRig()
        rig.session()
        rig.graine.identify(["user_id": "P-1"])
        rig.prepare()
        rig.graine.identify(["user_id": "P-1"])
        #expect(rig.leg?.steps == ["prepare"], "identify with the same customer: nothing changed")
        rig.graine.identify(["user_id": "P-2"])
        #expect(rig.leg?.steps.last == "hangUp")
    }

    @Test func aTimeZoneChangeLetsItGo() {
        let rig = PrepareRig()
        rig.session()
        rig.prepare()
        rig.graine.timeZoneChanged()
        #expect(rig.leg?.steps == ["prepare"], "the same zone: kept")
        rig.graine.deviceTimezone = { "Pacific/Auckland" }
        rig.graine.timeZoneChanged()
        #expect(rig.leg?.steps.last == "hangUp")
    }

    @Test func callsOffWebRtcLetItGo() {
        let rig = PrepareRig()
        rig.session()
        rig.prepare()
        rig.session(["calls": ["audioTransport": "websocket"]])
        #expect(rig.leg?.steps.last == "hangUp", "the dashboard turned this agent's calls to the WebSocket")
    }

    /// What a ring arriving (and calls reconfigured to the WebSocket) do to every agent: let the prepared call go.
    @Test func aRingLetsItGo() {
        let rig = PrepareRig()
        rig.session()
        rig.prepare()
        rig.graine.releasePreparedCall()
        #expect(rig.leg?.steps.last == "hangUp")
        #expect(rig.prepared == nil)
    }

    @Test func aPreparedCallThatLostItsRegistrationIsLetGoQuietly() throws {
        let rig = PrepareRig()
        rig.session()
        rig.prepare()
        let leg = try #require(rig.leg)
        leg.onPrepared?(.ready(milliseconds: 412, direct: true))
        #expect(rig.prepared != nil)
        leg.onPrepared?(.lost)
        #expect(leg.steps.last == "hangUp")
        #expect(rig.prepared == nil, "the tap prepares afresh")
    }

    // MARK: When it does nothing

    @Test func nothingWithoutWebRtcBeforeTheSessionOrWhileACallIsOn() {
        let missing = PrepareRig(installed: false)
        missing.session()
        missing.prepare()
        #expect(missing.requests == 0, "no WebRTC module")

        let unable = PrepareRig()
        unable.module.isSupported = false
        unable.session()
        unable.prepare()
        #expect(unable.requests == 0, "the module cannot run here")

        let socket = PrepareRig()
        socket.session(["calls": ["audioTransport": "websocket"]])
        socket.prepare()
        #expect(socket.requests == 0, "calls on the WebSocket")

        let early = PrepareRig()
        early.prepare()
        #expect(early.requests == 0, "before the session")

        let busy = PrepareRig()
        busy.session()
        busy.graine.callInProgress = { _ in true }
        busy.prepare()
        #expect(busy.requests == 0, "while a call rings or is live")
    }

    // MARK: Who is calling

    /// User A prepares, A signs out, B signs in and calls: B's call is minted for B and never dials A's prepared call.
    @Test func aCallPreparedForOneCustomerIsNeverDialledForAnother() throws {
        let rig = PrepareRig()
        rig.module.nextCallIdAnswer = "call_next1"
        rig.session()
        rig.graine.identify(["user_id": "A-1"])
        rig.prepare()
        let aLeg = try #require(rig.leg)
        rig.graine.identify(nil)
        #expect(aLeg.steps.last == "hangUp", "A signed out: A's prepared call let go")
        rig.graine.identify(["user_id": "B-2"])
        #expect(rig.prepared == nil, "nothing prepared for B")
        let bMint = rig.graine.outgoingMint(reason: "support", own: ["order": "A-1043"], callId: "call_next1")
        #expect(rig.graine.takePreparedCall(id: "call_next1", mint: bMint) == nil, "B's call never takes A's leg")
        #expect((rig.body(bMint)["identity"] as? [String: Any])?["value"] as? String == "B-2", "B's call is minted for B")

        // And were A's call somehow still held, the dial would not take it: every field is compared.
        let held = PrepareRig()
        held.module.nextCallIdAnswer = "call_next1"
        held.session()
        held.graine.identify(["user_id": "A-1"])
        held.prepare()
        let other = RtcMintBody.json(publishableKey: "pk_test_rig", sessionId: "", callVariables: [], variables: [],
                                     identity: IdentityWire.Fields(value: "B-2", installId: held.graine.installId, memory: true,
                                                                   timezone: held.graine.deviceTimezone(), callId: "call_next1"))
        #expect(held.graine.takePreparedCall(id: "call_next1", mint: other) == nil)
        #expect(held.leg?.steps.last == "hangUp")
    }

    /// Memory on, prepare, setMemory(false), call: the call carries memory off — a fresh mint.
    @Test func turningMemoryOffLetsThePreparedCallGoAndTheCallCarriesItOff() throws {
        let rig = PrepareRig()
        rig.session()
        rig.graine.identify(["user_id": "P-1"], memory: true)
        rig.prepare()
        #expect(rig.body(rig.module.requests.last)["memory"] as? Bool == true)
        let leg = try #require(rig.leg)
        rig.graine.setMemory(false)
        #expect(leg.steps.last == "hangUp", "the memory choice is in what the call carries")
        #expect(rig.prepared == nil)
        let mint = rig.graine.outgoingMint(reason: "support", own: ["order": "A-1043"], callId: "call_fresh")
        #expect(rig.body(mint)["memory"] as? Bool == false, "the call, minted afresh, carries memory off")
    }

    /// Two agents in one app: each agent's prepared call is dialled only by that agent's startCall.
    @Test func eachAgentsPreparedCallServesOnlyThatAgent() throws {
        let registry = GraineAgentRegistry()
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        let installs = MemoryInstallIdStore("3f2504e0-4f89-11d3-9a0c-0305e82c3301")
        func agent(_ key: String, _ name: String, _ module: FakeRtcModule) -> GraineInApp {
            let made = GraineInApp(
                config: GraineConfig(baseUrl: "https://www.graine.ai", publishableKey: key),
                installIds: installs, defaults: sandbox.defaults,
                sessionCache: SessionCache(directory: sandbox.folder, agent: name),
                network: RoutedNetwork(), chatScheduler: ManualScheduler(), name: name, registry: registry
            )
            registry.add(made)
            made.rtcModule = { module }
            made.uptime = { 1_000 }
            made.afterDelay = { _, _ in }
            made.callInProgress = { _ in false }
            made.finishSession(.success(GraineSessionConfig.parse(["agentId": "agent-\(name)", "webcallAgentId": "web-\(name)"])))
            return made
        }
        let supportModule = FakeRtcModule()
        supportModule.nextCallIdAnswer = "call_support1"
        let salesModule = FakeRtcModule()
        salesModule.nextCallIdAnswer = "call_sales1"
        let support = agent("pk_test_support", "default", supportModule)
        let sales = agent("pk_test_sales", "sales", salesModule)
        support.identify(["user_id": "P-1"])
        support.prepareNextCall(reason: "support", own: [:])
        sales.prepareNextCall(reason: "upgrade", own: [:])
        let supportLeg = try #require(supportModule.call)
        let salesLeg = try #require(salesModule.call)

        let supportMint = support.outgoingMint(reason: "support", own: [:], callId: "call_support1")
        #expect(sales.takePreparedCall(id: "call_support1", mint: supportMint) == nil, "sales never dials support's call")
        #expect(supportLeg.steps == ["prepare"], "support's stays support's")
        #expect(sales.preparedCallId(reason: "upgrade", own: [:]) == "call_sales1")
        #expect(sales.takePreparedCall(id: "call_sales1", mint: sales.outgoingMint(reason: "upgrade", own: [:], callId: "call_sales1")) === salesLeg)
        #expect(support.preparedCallId(reason: "support", own: [:]) == "call_support1")
        #expect(support.takePreparedCall(id: "call_support1", mint: supportMint) === supportLeg)
    }
}

/// The tap hands the prepared leg to its call: begun at once, its audio turned on only by the call's own (CallKit's didActivate).
@Suite struct PreparedCallAudioTests {
    @Test func thePreparedLegsAudioIsTurnedOnOnlyWhenTheCallsAudioIsHandedOver() throws {
        let rig = ConversationRig()
        let prepared = FakeRtcCall()
        rig.prepared = prepared
        let conversation = rig.make()
        conversation.start()
        #expect(prepared.steps == ["muted(false)", "begin"], "dialled from the tap: its audio not yet")
        conversation.startAudio()               // CallKit's didActivate
        #expect(prepared.steps == ["muted(false)", "begin", "audio"])
    }
}
