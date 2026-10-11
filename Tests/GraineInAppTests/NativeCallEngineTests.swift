import Foundation
import Testing
@testable import GraineInApp

/*
 * The native call's conversation, driven frame by frame on a clock the test
 * moves: what goes on the socket, when, and what the app is told. The
 * sequences are the ones measured on the production socket (NATIVE-CALLS.md).
 */

@Suite struct NativeCallOpeningTests {
    @Test func theGatewayCarriesTheTicketInTheSubprotocolAndTheVariablesTwice() throws {
        let rig = EngineRig()
        rig.contextFrame = ["context": ["screen": "cart"], "availableActions": ["open_screen"], "seq": 3]
        rig.engine.start()

        // The ticket: a voice ticket, with the variables on it (the gateway reads only these).
        let post = try #require(rig.network.posts.first)
        #expect(post.url.absoluteString == "https://www.graine.ai/api/embed/ticket")
        let body = try #require(JSON.object(from: post.body))
        #expect(body["publishableKey"] as? String == "pk_test_rig")
        #expect(body["mode"] as? String == "voice")
        #expect(body["metadata"] as? [String: String] == ["who_called": "agent", "call_reason": "payment_due"])

        // The socket: the ticket's URL, the token on it, the ticket in the subprotocol — never the query.
        let socket = try #require(rig.network.socket)
        #expect(socket.protocols == ["graine.embed.v1", "tkt-1"])
        let token = try #require(CallWire.contextToken([("who_called", "agent"), ("call_reason", "payment_due")]))
        #expect(socket.url.absoluteString == "wss://ws.graine.ai/v1/embed?context_token=" + GraineProtocol.encode(token))
        #expect(!socket.url.absoluteString.contains("tkt-1"))

        // Open: init, then the screen, then nothing until the first ping.
        socket.open()
        #expect(rig.transports == [.gateway])
        #expect(socket.sentTypes == ["init", "app_context"])
        let initFrame = socket.sentFrames[0]
        #expect(initFrame["event"] as? String == "start")
        let meta = try #require(initFrame["meta_data"] as? [String: Any])
        #expect(meta["client"] as? String == "graine-ios-sdk")
        #expect(meta["context_data"] as? [String: String] == ["who_called": "agent", "call_reason": "payment_due"])
        let context = socket.sentFrames[1]
        #expect((context["context"] as? [String: Any])?["screen"] as? String == "cart")
        #expect(context["available_actions"] as? [String] == ["open_screen"])
        #expect(context["seq"] as? Int == 3)

        rig.scheduler.advance(24.9)
        #expect(socket.sentTypes == ["init", "app_context"])
        rig.scheduler.advance(0.2)
        #expect(socket.sentTypes == ["init", "app_context", "ping"])
        rig.scheduler.advance(25)
        #expect(socket.sentTypes.filter { $0 == "ping" }.count == 2)
    }

    @Test func noTicketMeansTheDirectSocketWithNoSubprotocol() throws {
        for reply in [(503, Data?.none), (0, nil), (200, Data(#"{"ticket":"t"}"#.utf8)), (403, Data(#"{"error":"no"}"#.utf8))] {
            let rig = EngineRig()
            rig.network.ticketReply = reply
            rig.session = GraineSessionConfig(agentId: "agent-1", webcallAgentId: "web-1", wsHost: "wss://ws.graine.ai/")
            rig.engine.start()
            let socket = try #require(rig.network.socket)
            #expect(socket.protocols.isEmpty, "status \(reply.0)")
            #expect(socket.url.absoluteString.hasPrefix("wss://ws.graine.ai/chat/v1/web-1?webcall=1&context_token="), "status \(reply.0)")
            socket.open()
            #expect(rig.transports == [.direct])
        }
    }

    @Test func noScreenAndNoIdentityMeansNoContextFrame() throws {
        let rig = EngineRig()
        let socket = rig.open(clearOpening: false)
        #expect(socket.sentTypes == ["init"])
    }

    @Test func aSocketThatNeverOpensFailsAtFifteenSeconds() throws {
        let rig = EngineRig()
        rig.engine.start()
        let socket = try #require(rig.network.socket)
        rig.scheduler.advance(14.9)
        #expect(rig.endings.isEmpty)
        rig.scheduler.advance(0.2)
        #expect(rig.endings == [.couldNotOpen("The conversation did not open within 15 seconds.")])
        #expect(socket.closed)
        #expect(rig.audio.stopped)
    }

    @Test func noSessionIsACallThatCouldNotOpen() {
        let rig = EngineRig()
        rig.session = nil
        rig.engine.start()
        #expect(rig.network.posts.isEmpty)
        #expect(rig.endings == [.couldNotOpen("The agent's configuration could not be loaded.")])
    }

    @Test func theCallsOwnVariablesComeFirstAndWin() {
        let merged = CallEngine.variables(
            sdk: ["name": "Asha", "call_reason": "old", "who_called": "customer", "plan": "Plus"],
            whoCalled: "agent",
            reason: "payment_due",
            own: ["order": "42", "plan": "Pro"]
        )
        #expect(merged.map { $0.0 } == ["who_called", "call_reason", "order", "plan", "name"])
        #expect(merged.map { $0.1 } == ["agent", "payment_due", "42", "Pro", "Asha"])
        let noReason = CallEngine.variables(sdk: [:], whoCalled: "customer", reason: nil, own: [:])
        #expect(noReason.map { $0.0 } == ["who_called"])
    }

    @Test func theTicketKeepsTheCallsVariablesEvenBehindALongIdentify() throws {
        let call = [("who_called", "agent"), ("call_reason", "payment_due")]
        let traits = (0..<20).map { ("trait\($0)", "v\($0)") }
        let t = try #require(CallWire.ticketVariables(call: call, rest: call + traits))
        #expect(t.count == 12)
        #expect(t.first { $0.0 == "who_called" }?.1 == "agent")
        #expect(t.first { $0.0 == "call_reason" }?.1 == "payment_due")
        // Over a kilobyte, the SDK's give way; the call's stay. (All at once, this was nothing at all.)
        let big = (0..<12).map { ("key\($0)", String(repeating: "x", count: 150)) }
        #expect(CallWire.ticketMetadata((call + big).map { ($0.0, $0.1 as Any?) }) == nil)
        let t2 = try #require(CallWire.ticketVariables(call: [("who_called", "agent")], rest: big))
        #expect(t2.first?.0 == "who_called")
        #expect((2...11).contains(t2.count))
        #expect(CallWire.ticketVariables(call: [], rest: []) == nil)
    }
}

@Suite struct NativeCallAudioTests {
    @Test func agentAudioIsDecodedAsPcmAt24kAndLatched() throws {
        let rig = EngineRig()
        let socket = rig.open()
        socket.frame(["type": "audio", "data": NativeAudioFixtures.agentFrame()])
        let first = try #require(rig.audio.played.first)
        #expect(first.rate == 24_000)
        #expect(first.samples.count == 4_800)
        #expect(rig.formats == [AgentAudioFormat(kind: .pcm, sampleRate: 24_000)])
        // Silence afterwards is still PCM at 24 kHz: the stream was decided once.
        socket.frame(["type": "audio", "data": Data(count: 9_600).base64EncodedString()])
        #expect(rig.audio.played.last?.rate == 24_000)
        #expect(rig.audio.played.last?.samples.count == 4_800)
        #expect(rig.formats.count == 1)
    }

    @Test func marksAreAckedWhenTheAudioBeforeThemHasBeenHeard() throws {
        let rig = EngineRig()
        let socket = rig.open()
        // Nothing queued: at once.
        socket.frame(["type": "mark", "name": "m0"])
        #expect(socket.sentFrames.last?["name"] as? String == "m0")
        socket.clearSent()

        // 0.6 s still to play: never on arrival, and not a moment early.
        rig.audio.buffered = 0.6
        socket.frame(["type": "mark", "name": "m1"])
        #expect(socket.sentTypes.isEmpty)
        rig.scheduler.advance(0.59)
        #expect(socket.sentTypes.isEmpty)
        rig.scheduler.advance(0.02)
        #expect(socket.sentFrames.map { $0["name"] as? String } == ["m1"])
        #expect(socket.sentTypes == ["mark"])
        socket.clearSent()

        // A runaway depth is capped at ten seconds.
        rig.audio.buffered = 42
        socket.frame(["type": "mark", "name": "m2"])
        rig.scheduler.advance(9.99)
        #expect(socket.sentTypes.isEmpty)
        rig.scheduler.advance(0.02)
        #expect(socket.sentFrames.map { $0["name"] as? String } == ["m2"])
    }

    @Test func aNamelessMarkIsNotAcked() {
        let rig = EngineRig()
        let socket = rig.open()
        socket.frame(["type": "mark"])
        socket.frame(["type": "mark", "name": ""])
        #expect(socket.sentTypes.isEmpty)
    }

    /*
     * The coordinator's sequence, measured on production: a text chunk, then
     * "<end_of_stream>" (the TEXT is done), then audio keeps arriving — and the
     * agent is speaking until that audio has been heard.
     */
    @Test func speechFollowsTheAudioNotTheEndMarker() throws {
        let rig = EngineRig()
        let socket = rig.open()

        socket.frame(["type": "text", "data": "Welcome to Tring "])
        #expect(rig.speaking.isEmpty, "words alone are not the agent speaking")
        #expect(rig.captions.last == GraineCaption(role: .agent, text: "Welcome to Tring ", live: true))

        rig.audio.buffered = 0.2
        socket.frame(["type": "audio", "data": NativeAudioFixtures.agentFrame()])
        #expect(rig.speaking == [true])

        socket.frame(["type": "text", "data": "<end_of_stream>"])
        #expect(rig.captions.last == GraineCaption(role: .agent, text: "Welcome to Tring ", live: false), "the caption turn closes")
        #expect(rig.speaking == [true], "the end marker must not end speech")

        rig.scheduler.advance(0.1)
        socket.frame(["type": "audio", "data": NativeAudioFixtures.agentFrame()])   // audio after the marker
        rig.audio.buffered = 0.6                                                    // and still being heard
        rig.scheduler.advance(0.4)
        #expect(rig.speaking == [true], "speech ended with audio still queued")
        rig.audio.buffered = 0.3
        rig.scheduler.advance(0.25)
        #expect(rig.speaking == [true])
        rig.audio.buffered = 0
        rig.scheduler.advance(1.0)
        #expect(rig.speaking == [true, false], "speech never ended once the audio had played")
    }

    @Test func speakingNeedsThreeHundredQuietMilliseconds() {
        let rig = EngineRig()
        let socket = rig.open()
        rig.audio.buffered = 0
        socket.frame(["type": "audio", "data": NativeAudioFixtures.agentFrame(ms: 20)])
        rig.scheduler.advance(0.29)
        #expect(rig.speaking == [true])
        rig.scheduler.advance(0.02)
        #expect(rig.speaking == [true, false])
    }

    @Test func clearDropsTheQueueEndsSpeechAndClosesTheCaption() {
        for type in ["clear", "interruption"] {
            let rig = EngineRig()
            let socket = rig.open()
            rig.audio.buffered = 1.2
            socket.frame(["type": "text", "data": "Let me check"])
            socket.frame(["type": "audio", "data": NativeAudioFixtures.agentFrame()])
            socket.frame(["type": type])
            #expect(rig.audio.clears == 1, "\(type)")
            #expect(rig.speaking == [true, false], "\(type)")
            #expect(rig.captions.last == GraineCaption(role: .agent, text: "Let me check", live: false), "\(type)")
            // The next phrase starts a new turn: no space carried over.
            socket.frame(["type": "text", "data": "Sure"])
            #expect(rig.captions.last == GraineCaption(role: .agent, text: "Sure", live: true), "\(type)")
        }
    }

    @Test func theSpeechFramesNeverDriveSpeaking() {
        let rig = EngineRig()
        let socket = rig.open()
        socket.frame(["type": "beginning_of_stream"])
        #expect(rig.speaking.isEmpty)
        rig.audio.buffered = 0.5
        socket.frame(["type": "audio", "data": NativeAudioFixtures.agentFrame()])
        socket.frame(["type": "end_of_stream"])
        #expect(rig.speaking == [true], "end_of_stream with audio still playing")
    }

    @Test func spokenPhrasesAreCaptionedWithTheirSpaces() {
        let rig = EngineRig()
        let socket = rig.open()
        for chunk in ["Sure! I can", "help you", "change your", "settings,", "like"] {
            socket.frame(["type": "text", "data": chunk])
        }
        #expect(rig.captions.last == GraineCaption(role: .agent, text: "Sure! I can help you change your settings, like", live: true))
        socket.frame(["type": "text", "data": "<end_of_stream>"])
        socket.frame(["type": "text", "data": "Next"])
        #expect(rig.captions.last == GraineCaption(role: .agent, text: "Next", live: true), "a new turn starts clean")
    }

    @Test func theCustomersWordsAreCaptionedLiveThenFinal() {
        let rig = EngineRig()
        let socket = rig.open()
        socket.frame(["type": "interim_transcript_received", "data": "what can"])
        socket.frame(["type": "transcript", "data": "What can you do?"])
        #expect(rig.captions == [
            GraineCaption(role: .customer, text: "what can", live: true),
            GraineCaption(role: .customer, text: "What can you do?", live: false),
        ])
    }
}

@Suite struct NativeCallMicrophoneTests {
    /// Agent audio arriving and still queued: the agent is audible.
    private func agentTalking(_ rig: EngineRig, _ socket: FakeSocket) {
        rig.audio.buffered = 0.5
        socket.frame(["type": "audio", "data": NativeAudioFixtures.agentFrame()])
    }

    /// One 20 ms microphone frame, and the 20 ms it takes.
    private func speak(_ rig: EngineRig, amp: Double, frames: Int = 1) {
        for _ in 0..<frames {
            rig.audio.speak(amp: amp)
            rig.scheduler.advance(0.02)
        }
    }

    @Test func theCustomerIsHeardWhileTheAgentIsSilent() {
        let rig = EngineRig()
        let socket = rig.open()
        speak(rig, amp: 120, frames: 3)
        #expect(socket.sentTypes == ["audio", "audio", "audio"])
        let frame = socket.sentFrames[0]
        let meta = frame["meta_info"] as? [String: Any]
        #expect(meta?["format"] as? String == "pcm")
        #expect(meta?["sample_rate"] as? Int == 16_000)
        #expect(meta?["encoding"] as? String == "base64")
        #expect(Data(base64Encoded: frame["data"] as? String ?? "")?.count == 640)
    }

    /*
     * The barge-in rule: the first frame the echo guard releases while the
     * agent is audible goes up preceded by ONE barge_in — once per agent turn.
     */
    @Test func talkingOverTheAgentSendsOneBargeInBeforeTheFirstReleasedFrame() {
        let rig = EngineRig()
        let socket = rig.open()
        agentTalking(rig, socket)

        speak(rig, amp: 1_500, frames: 12)            // the agent's echo: held
        #expect(socket.sentTypes.isEmpty)
        speak(rig, amp: 9_000, frames: 11)            // the customer, not yet sustained
        #expect(socket.sentTypes.isEmpty)
        socket.frame(["type": "audio", "data": NativeAudioFixtures.agentFrame()])   // the agent still talking
        speak(rig, amp: 9_000)                        // 240 ms: an interruption, with its pre-roll
        #expect(socket.sentTypes == ["barge_in"] + Array(repeating: "audio", count: 13))

        socket.clearSent()
        speak(rig, amp: 9_000, frames: 3)
        #expect(socket.sentTypes == ["audio", "audio", "audio"], "one barge_in per turn")

        // The agent stops (the runtime clears it): the customer goes straight up, with no barge_in,
        // and the next turn may be barged into once more.
        socket.frame(["type": "clear"])
        socket.clearSent()
        speak(rig, amp: 120, frames: 2)
        #expect(socket.sentTypes == ["audio", "audio"])
        socket.clearSent()
        agentTalking(rig, socket)
        speak(rig, amp: 1_500, frames: 12)
        speak(rig, amp: 9_000, frames: 12)
        #expect(socket.sentTypes.first == "barge_in")
        #expect(socket.sentTypes.filter { $0 == "barge_in" }.count == 1)
    }

    @Test func theAgentsOwnEchoNeverReachesTheSocket() {
        let rig = EngineRig()
        let socket = rig.open()
        for _ in 0..<40 {
            socket.frame(["type": "audio", "data": NativeAudioFixtures.agentFrame(ms: 20)])
            speak(rig, amp: 1_500)
        }
        #expect(socket.sentTypes.isEmpty)
    }

    @Test func mutedFramesNeverLeaveTheDeviceAndInterruptNothing() {
        let rig = EngineRig()
        let socket = rig.open()
        rig.engine.setMuted(true)
        speak(rig, amp: 120, frames: 5)
        agentTalking(rig, socket)
        speak(rig, amp: 1_500, frames: 12)
        speak(rig, amp: 9_000, frames: 14)
        #expect(socket.sentTypes.isEmpty)
        rig.engine.setMuted(false)
        speak(rig, amp: 9_000)
        #expect(socket.sentTypes.first == "barge_in")
    }

    @Test func theGuardFailsOpenOneAndAHalfSecondsAfterTheAudioShouldHavePlayed() {
        let rig = EngineRig()
        let socket = rig.open()
        agentTalking(rig, socket)                       // 0.5 s queued: due to have played by +0.5 s
        rig.audio.buffered = 3                          // a stalled player that still claims to be busy
        rig.scheduler.advance(2.1)                      // 1.6 s past the projected end
        socket.clearSent()
        speak(rig, amp: 120)
        #expect(socket.sentTypes.contains("audio"), "a stalled player kept the customer muted")
    }

    @Test func aReplyThatArrivesInABurstHoldsTheMicUntilItHasPlayed() {
        // Production sends a reply far faster than real time: 6.3 s of speech in 0.8 s.
        let rig = EngineRig()
        let socket = rig.open()
        rig.audio.buffered = 4                          // the burst: 4 s queued at once
        socket.frame(["type": "audio", "data": NativeAudioFixtures.agentFrame()])
        rig.scheduler.advance(1.6)                      // 1.6 s after it ARRIVED...
        rig.audio.buffered = 2.4                        // ...with 2.4 s still to play
        socket.clearSent()
        speak(rig, amp: 1_500)                          // the agent's own voice, through the mic
        #expect(!socket.sentTypes.contains("audio"), "the agent's echo went up as the customer")
        #expect(!socket.sentTypes.contains("barge_in"))
    }

    @Test func nothingIsSentBeforeTheSocketOpens() throws {
        let rig = EngineRig()
        rig.engine.start()
        rig.engine.startAudio()
        speak(rig, amp: 9_000, frames: 3)
        let socket = try #require(rig.network.socket)
        #expect(socket.sent.isEmpty)
    }
}

@Suite struct NativeCallActionTests {
    private func ask(_ socket: FakeSocket, _ name: String, id: String = "act-1", args: [String: Any] = [:]) {
        socket.frame(["type": "app_action", "action": ["action_id": id, "name": name, "arguments": args]])
    }

    private func result(_ socket: FakeSocket) -> [String: Any]? {
        socket.sentFrames.last { $0["type"] as? String == "app_action_result" }
    }

    @Test func anUnregisteredActionIsRefused() throws {
        let rig = EngineRig()
        let socket = rig.open()
        ask(socket, "fly")
        let r = try #require(result(socket))
        #expect(r["action_id"] as? String == "act-1")
        #expect(r["status"] as? String == "refused")
        #expect(r["message"] as? String == "This app build does not implement \"fly\".")
    }

    @Test func aHandlerThatThrowsIsAnError() throws {
        let rig = EngineRig()
        rig.actionRunner = { _, _, answer in answer(.error("the form is locked")) }
        let socket = rig.open()
        ask(socket, "submit")
        let r = try #require(result(socket))
        #expect(r["status"] as? String == "error")
        #expect(r["message"] as? String == "the form is locked")
    }

    @Test func anOkCarriesItsArgumentsInAndItsDataOut() throws {
        let rig = EngineRig()
        var heard: [String: Any] = [:]
        rig.actionRunner = { _, args, answer in
            heard = args
            answer(.ok("Tenure set", data: ["months": 24]))
        }
        let socket = rig.open()
        ask(socket, "set_tenure", args: ["months": 24])
        #expect(heard["months"] as? Int == 24)
        let r = try #require(result(socket))
        #expect(r["status"] as? String == "ok")
        #expect(r["message"] as? String == "Tenure set")
        #expect((r["data"] as? [String: Any])?["months"] as? Int == 24)
    }

    @Test func aHandlerThatNeverAnswersIsAnsweredInsideSixSeconds() throws {
        let rig = EngineRig()
        var late: ((GraineActionResult) -> Void)?
        rig.actionRunner = { _, _, answer in late = answer }
        let socket = rig.open()
        ask(socket, "slow")
        rig.scheduler.advance(5.5)
        #expect(result(socket) == nil)
        rig.scheduler.advance(0.2)
        let r = try #require(result(socket))
        #expect(r["status"] as? String == "error")
        #expect(r["message"] as? String == "\"slow\" did not finish in time.")
        // An answer after that is not a second answer.
        late?(.ok("done at last"))
        #expect(socket.sentTypes.filter { $0 == "app_action_result" }.count == 1)
    }

    @Test func everyActionIsAnsweredOnceEvenWhenTheRunnerAnswersTwice() {
        let rig = EngineRig()
        rig.actionRunner = { _, _, answer in
            answer(.ok())
            answer(.error("again"))
        }
        let socket = rig.open()
        ask(socket, "x")
        rig.scheduler.advance(10)
        #expect(socket.sentTypes.filter { $0 == "app_action_result" }.count == 1)
    }
}

/// The real runner — the handlers `registerAction` holds — on every path, with the native call's deadline.
@MainActor
@Suite struct NativeCallRunnerTests {
    private func graine() -> GraineInApp {
        GraineInApp(config: GraineConfig(baseUrl: "https://example.invalid", publishableKey: "pk_test"))
    }

    private func run(_ graine: GraineInApp, _ name: String, deadlineMs: Int = CallWire.actionAnswerMs) async -> GraineActionResult {
        let runner = CallEngine.actionRunner(graine, deadlineMs: deadlineMs)
        return await withCheckedContinuation { continuation in
            runner(name, [:]) { continuation.resume(returning: $0) }
        }
    }

    @Test func unregisteredIsRefused() async {
        let result = await run(graine(), "fly")
        #expect(result.status == .refused)
    }

    @Test func aThrowIsAnErrorWithWhatWentWrong() async {
        struct Locked: LocalizedError { var errorDescription: String? { "the form is locked" } }
        let g = graine()
        g.registerAction("submit") { _ in throw Locked() }
        let result = await run(g, "submit")
        #expect(result.status == .error)
        #expect(result.message == "the form is locked")
    }

    @Test func aRegisteredHandlerAnswersOk() async {
        let g = graine()
        g.registerAction("open_screen") { _ in .ok("Opened") }
        let result = await run(g, "open_screen")
        #expect(result.status == .ok)
        #expect(result.message == "Opened")
    }

    @Test func aHandlerPastTheDeadlineDidNotFinishInTime() async {
        let g = graine()
        g.registerAction("slow", deferred: { _, _ in })
        let started = Date()
        let result = await run(g, "slow", deadlineMs: 150)
        #expect(result.status == .error)
        #expect(result.message == "\"slow\" did not finish in time.")
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func theNativeDeadlineIsInsideTheRuntimes() {
        #expect(CallWire.actionAnswerMs + 100 < CallWire.actionDeadlineMs)
    }
}

@Suite struct NativeCallEndingTests {
    @Test func hangingUpSendsStopThenClosesTwoHundredMillisecondsLater() throws {
        let rig = EngineRig()
        let socket = rig.open()
        rig.engine.hangUp()
        #expect(socket.sentTypes == ["stop"])
        #expect(socket.sentFrames.last?["event"] as? String == "stop")
        #expect(socket.sentFrames.last?["data"] as? String == "client_hangup")
        #expect(!socket.closed)
        rig.scheduler.advance(0.19)
        #expect(!socket.closed)
        rig.scheduler.advance(0.02)
        #expect(socket.closed)
        #expect(rig.endings == [.local])
        #expect(rig.audio.stopped)
        // Nothing after the end: no ping, no second ending.
        rig.scheduler.advance(60)
        #expect(socket.sentTypes == ["stop"])
        rig.engine.hangUp()
        #expect(rig.endings == [.local])
    }

    @Test func theAgentHangingUpIsARemoteEnd() {
        let rig = EngineRig()
        let socket = rig.open()
        rig.audio.buffered = 0.4
        socket.frame(["type": "audio", "data": NativeAudioFixtures.agentFrame()])
        socket.serverClose()
        #expect(rig.endings == [.remote])
        #expect(rig.speaking == [true, false])
        #expect(rig.audio.stopped)
        #expect(!socket.sentTypes.contains("stop"))
    }

    @Test func aSocketErrorMidCallIsADrop() {
        let rig = EngineRig()
        let socket = rig.open()
        socket.fail("The network connection was lost.")
        #expect(rig.endings == [.dropped("The network connection was lost.")])
    }

    @Test func aSocketThatFailsToOpenCouldNotOpen() throws {
        let rig = EngineRig()
        rig.engine.start()
        try #require(rig.network.socket).fail("refused (403)")
        #expect(rig.endings == [.couldNotOpen("refused (403)")])
    }

    @Test func hangingUpBeforeTheSocketOpensSendsNoStop() throws {
        let rig = EngineRig()
        rig.engine.start()
        let socket = try #require(rig.network.socket)
        rig.engine.hangUp()
        #expect(socket.closed)
        #expect(socket.sent.isEmpty)
        #expect(rig.endings == [.local])
        socket.open()   // too late: nothing happens
        #expect(socket.sent.isEmpty)
        #expect(rig.transports.isEmpty)
    }

    @Test func aMicrophoneThatWillNotStartEndsTheCall() {
        struct NoMic: LocalizedError { var errorDescription: String? { "no microphone" } }
        let rig = EngineRig()
        rig.audio.startError = NoMic()
        rig.engine.start()
        rig.network.socket?.open()
        rig.engine.startAudio()
        #expect(rig.endings == [.dropped("no microphone")])
    }

    @Test func theSystemTakingTheAudioBackReleasesItAndGivingItBackRestartsIt() {
        let rig = EngineRig()
        let socket = rig.open()
        #expect(rig.audio.starts == 1)
        rig.engine.stopAudio()
        #expect(rig.audio.stopped)
        rig.audio.speak(amp: 9_000)                  // a frame from a stopped microphone goes nowhere
        #expect(socket.sentTypes.isEmpty)
        rig.engine.startAudio()
        #expect(rig.audio.starts == 2)
        #expect(!rig.audio.stopped)
        rig.audio.speak(amp: 120)
        #expect(socket.sentTypes == ["audio"])
        #expect(rig.endings.isEmpty, "the call goes on")
    }

    @Test func pendingAcksDieWithTheCall() {
        let rig = EngineRig()
        let socket = rig.open()
        rig.audio.buffered = 2
        socket.frame(["type": "mark", "name": "m1"])
        socket.serverClose()
        rig.scheduler.advance(5)
        #expect(!socket.sentTypes.contains("mark"))
        #expect(rig.scheduler.waiting == 0)
    }
}
