import Foundation
import Testing
@_spi(GraineRTC) @testable import GraineInApp

/*
 * 0.14.4, A CALL NOBODY CAN HEAR: the WebRTC call is watched as the socket's
 * is (connected at once only when its own audio runs), the leg's own direct
 * start counts as that audio, the leg's playout watch can end a call whose
 * audio never plays (cause `audio_watch`), every WebRTC mint says the phone
 * will tell the greeting when its audio plays, and the `audio` row says what
 * happened to the phone's audio. On fakes: CallKit's activation and the
 * speaker are the device's to prove.
 */

@Suite struct CallAudioRescueTests {
    // MARK: - the WebRTC call is watched

    @Test func aWebRtcCallOpenedWithoutItsAudioIsRescuedThenFailed() {
        var steps: [CallAudioWatch.Step] = []
        var pending: [() -> Void] = []
        let fire = { let next = pending.removeFirst(); next() }
        let watch = CallAudioWatch(schedule: { _, run in pending.append(run); return {} }, act: { steps.append($0) })
        watch.opened(audioRunning: CallAudioWatch.runningAtOpen(callKitActivated: false, startedDirectly: false))
        #expect(steps.isEmpty && watch.isWaiting, "media up, its audio taken back: the watch waits")
        fire()
        #expect(steps == [.retry], "3 s: started directly")
        watch.audioStarted()
        #expect(steps == [.retry, .connect], "and connected once it runs")

        steps = []
        watch.opened(audioRunning: false)
        fire()
        watch.retryFailed()
        #expect(steps == [.retry, .fail], "a direct start that fails ends the call")
    }

    // MARK: - the conversation

    @Test func theLegsOwnDirectStartIsThisCallsAudio() throws {
        let rig = ConversationRig()
        rig.make().start()
        let call = try #require(rig.module.call)
        call.emit(.ready)
        rig.scheduler.advance(3.1)
        #expect(call.steps.contains("direct"))
        #expect(rig.events.contains { if case .audioStartedDirectly = $0 { return true }; return false }, "said before the media is up")

        let callKit = ConversationRig()
        let conversation = callKit.make()
        conversation.start()
        callKit.module.call?.emit(.ready)
        conversation.startAudio()
        callKit.module.call?.emit(.connected)
        #expect(!callKit.events.contains { if case .audioStartedDirectly = $0 { return true }; return false }, "CallKit's activation is not a direct start")
    }

    @Test func aLegWhoseAudioNeverPlaysEndsTheCallAsTheAudioWatchDoes() throws {
        let rig = ConversationRig()
        rig.make().start()
        let call = try #require(rig.module.call)
        call.emit(.playoutFailed("audio arrived and nothing played"))
        #expect(!rig.events.contains { if case .audioFailed = $0 { return true }; return false }, "nothing before the media is up")
        call.emit(.ready)
        call.emit(.connected)
        call.emit(.playoutFailed("audio arrived and nothing played"))
        let failed = rig.events.compactMap { event -> String? in if case .audioFailed(let why) = event { return why }; return nil }
        #expect(failed == [CallAudioWatch.failure])
        #expect(GraineCallEndCause.of(.failed(CallAudioWatch.failure), from: .active) == .audioWatch, "the call's ended row says audio_watch")
        var machine = CallMachine()
        _ = machine.handle(.outgoing(id: "c1"))
        _ = machine.handle(.connected)
        #expect(machine.handle(.failed(CallAudioWatch.failure)).outcomes == [.ended(.failed)])
    }

    // MARK: - the greeting waits for the phone

    @Test func everyWebRtcMintSaysThePhoneWillSayWhenItsAudioPlays() throws {
        let body = RtcMintBody.json(publishableKey: "pk_test_x", sessionId: "s", callVariables: [], variables: [], identity: ConversationRig.identity)
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.hasSuffix(#","audio_ready_signal":true}"#), "last, after who the customer is")
        #expect(String(decoding: RtcMintBody.json(publishableKey: "pk", sessionId: "", callVariables: [], variables: [], identity: nil), as: UTF8.self)
            == #"{"publishableKey":"pk","session_id":"","audio_ready_signal":true}"#)
        #expect(GraineRtcSignal.audioReady == #"{"type":"audio","state":"ready"}"#, "the frame the server holds the greeting for, exactly")

        let rig = ConversationRig()
        rig.make().start()
        let request = try #require(rig.module.requests.first)
        let mint = try #require(JSON.object(from: request.mintBody("0123456789abcdef0123456789abcdef")))
        #expect(mint["audio_ready_signal"] as? Bool == true, "the call's own mint")
    }

    // MARK: - the audio row

    @Test func theAudioRowSaysWhatHappenedToThePhonesAudio() throws {
        let restarted = try #require(GraineCallTelemetry.audioFrame(event: "playout_restarted", transport: "rtc", via: "callkit", reason: "interrupted", afterMs: 2_400))
        #expect(restarted == #"{"type":"app_event","event":{"name":"audio","detail":"audio arrived, nothing played: restarted after 2.4s, activated by the system (interrupted)","quiet":true,"telemetry":true,"data":{"event":"playout_restarted","transport":"rtc","via":"callkit","reason":"interrupted","after_ms":2400}}}"#)
        #expect(GraineCallTelemetry.audioFrame(event: "ready", transport: "rtc", via: "direct", afterMs: 3_650)?
            .contains(#""detail":"audio playing after 3.7s, started directly""#) == true)
        #expect(GraineCallTelemetry.audioFrame(event: "failed", reason: "no_playout")?.contains(#""detail":"audio never played: the call ends (no_playout)""#) == true)
        #expect(GraineCallTelemetry.audioFrame(event: "deactivated_live", transport: "ws", via: "callkit", afterMs: 5_000)?
            .contains(#""detail":"audio taken back by the system after 5.0s, activated by the system""#) == true)
        let odd = try #require(GraineCallTelemetry.audioFrame(event: "rescued", transport: "carrier", via: "magic", reason: "card_blocked", afterMs: -1))
        #expect(odd.contains(#""data":{"event":"rescued"}"#), "a value that does not fit is left out, as in every row")
        #expect(GraineCallTelemetry.audioFrame(event: "card_blocked") == nil, "only an event of its list")
        #expect(GraineCallTelemetry.frame("audio", ["event": "ready"]) == nil, "sent ahead of the contract: v1's builder does not make it")
        var fold = CallConnectionFold()
        #expect(!fold.read(restarted) && fold.report == nil, "nor is it read into the connection report")
    }

    // MARK: - the route: headsets, car kits and the speaker

    @Test func aHeadsetThatIsConnectedTakesTheCallNotTheDefaultLoudspeaker() {
        // AirPods connected as the call starts: listed as an input before their hands-free link is the output.
        #expect(CallAudioRoute.choice(speaker: true, chosen: false, outputs: ["Receiver"], inputs: ["MicrophoneBuiltIn", "BluetoothHFP"]) == .leave,
                "the default never takes the call to the loudspeaker over the customer's headset")
        // The default loudspeaker set a moment before the headset appeared: lifted, so the headset takes the call.
        #expect(CallAudioRoute.choice(speaker: true, chosen: false, outputs: ["Speaker"], inputs: ["MicrophoneBuiltIn", "BluetoothHFP"]) == .leave)
        #expect(CallAudioRoute.choice(speaker: true, chosen: false, outputs: ["BluetoothHFP"], inputs: ["BluetoothHFP"]) == .leave, "AirPods carrying it")
        #expect(CallAudioRoute.choice(speaker: true, chosen: false, outputs: ["Headphones"], inputs: ["MicrophoneWired"]) == .leave, "a wired headset, alike")
        #expect(CallAudioRoute.choice(speaker: true, chosen: false, outputs: ["CarAudio"], inputs: ["CarAudio"]) == .leave, "a car")
        // The customer asks for the loudspeaker over their headset: theirs to ask; asking back is the headset again.
        #expect(CallAudioRoute.choice(speaker: true, chosen: true, outputs: ["BluetoothHFP"], inputs: ["BluetoothHFP"]) == .speaker)
        #expect(CallAudioRoute.choice(speaker: false, chosen: true, outputs: ["Speaker"], inputs: ["BluetoothHFP"]) == .receiver,
                "no override: the route goes back to the headset")
        // Nothing of the customer's own: the loudspeaker by default, as before.
        #expect(CallAudioRoute.choice(speaker: true, chosen: false, outputs: ["Receiver"], inputs: ["MicrophoneBuiltIn"]) == .speaker)
        #expect(CallAudioRoute.choice(speaker: true, chosen: false, outputs: ["Receiver"]) == .speaker)
        #expect(!CallAudioRoute.onSpeaker(["BluetoothHFP"]) && CallAudioRoute.onSpeaker(["Speaker"]), "speakerOn follows the route")
    }

    @Test func aRouteThatMovesIsSaidByItsKindOnly() throws {
        let frame = try #require(GraineCallTelemetry.audioFrame(event: "route_changed", transport: "rtc", via: "callkit", afterMs: 12_300, route: "bluetooth"))
        #expect(frame == #"{"type":"app_event","event":{"name":"audio","detail":"audio moved to bluetooth after 12.3s, activated by the system","quiet":true,"telemetry":true,"data":{"event":"route_changed","transport":"rtc","via":"callkit","route":"bluetooth","after_ms":12300}}}"#)
        let named = try #require(GraineCallTelemetry.audioFrame(event: "route_changed", route: "Jo's AirPods"))
        #expect(named.contains(#""data":{"event":"route_changed"}"#), "a kind from its list, never a device's name")
        for kind in ["speaker", "receiver", "bluetooth", "wired", "airplay", "car"] {
            #expect(GraineCallTelemetry.audioFrame(event: "route_changed", route: kind)?.contains(#""route":"\#(kind)""#) == true, "\(kind)")
        }
    }

    @Test func theSocketSaysWhenTheSystemTookItsAudioBackAndWhenItWasStartedAgain() throws {
        let rig = ConversationRig()
        let conversation = rig.make(.websocket)
        conversation.start()
        let socket = try #require(rig.network.socket)
        conversation.startAudio()
        conversation.stopAudio()
        #expect(!socket.sent.contains { $0.contains(#""name":"audio""#) }, "nothing before the conversation is open")
        conversation.startAudio()
        socket.open()
        conversation.stopAudio()
        var started: Bool?
        conversation.startAudio { started = $0 }
        #expect(started == true)
        let rows = socket.sentFrames.compactMap { $0["event"] as? [String: Any] }.filter { $0["name"] as? String == "audio" }
        let data = rows.compactMap { $0["data"] as? [String: Any] }
        #expect(data.map { JSON.string($0["event"]) } == ["deactivated_live", "rescued"])
        #expect(JSON.string(data.first?["via"]) == "callkit" && JSON.string(data.last?["via"]) == "direct")
        #expect(JSON.string(data.last?["reason"]) == "deactivated" && JSON.string(data.last?["transport"]) == "ws")
    }
}
