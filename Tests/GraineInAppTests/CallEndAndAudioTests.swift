import Foundation
import Testing
@_spi(GraineRTC) @testable import GraineInApp

/*
 * 0.14.0, THE CALL'S END AND ITS AUDIO: who or what ended a call (its cause,
 * on the public state, the outcome and the call's "ended" row), where its
 * voice comes out (the loudspeaker by default, never off the customer's own
 * headset unasked), and the chat after the agent ends its conversation. On
 * fakes: CallKit's own audio activation is the device's to prove — see the
 * on-device checks in the reference.
 */

@Suite struct CallEndCauseTests {
    @Test func theCauseIsReadFromWhereTheCallStood() {
        func cause(_ event: CallMachine.Event, _ state: GraineCallState) -> GraineCallEndCause? {
            GraineCallEndCause.of(event, from: state)
        }
        #expect(cause(.hangUp, .active) == .localEnd)
        #expect(cause(.hangUp, .connecting) == .localEnd)
        #expect(cause(.hangUp, .ringing) == nil, "a ring declined is a decline: the state's reason says so")
        #expect(cause(.decline, .ringing) == nil)
        #expect(cause(.ringTimeout, .ringing) == nil)
        #expect(cause(.remoteEnded, .active) == .remoteBye)
        #expect(cause(.dropped, .active) == .mediaDrop)
        #expect(cause(.failed(CallAudioWatch.failure), .connecting) == .audioWatch, "the audio watch's own failure")
        #expect(cause(.failed("The microphone permission was not granted."), .connecting) == .failed)
        #expect(cause(.failed("The audio engine stopped."), .active) == .failed)
        #expect(cause(.reset, .active) == .providerReset)
        #expect(cause(.reset, .connecting) == .providerReset)
        #expect(cause(.reset, .ringing) == nil)
        #expect(cause(.settle, .ended(.local)) == nil)
        #expect(cause(.connected, .connecting) == nil)
        #expect([GraineCallEndCause.localEnd, .remoteBye, .mediaDrop, .audioWatch, .providerReset, .failed].map(\.rawValue)
            == ["local_end", "remote_bye", "media_drop", "audio_watch", "provider_reset", "failed"])
    }

    @Test func theEndedRowIsAndroidsRowKeyForKey() throws {
        let frame = try #require(GraineCallTelemetry.endedFrame(cause: "local_end", transport: "rtc", afterMs: 3_000, voiceHeard: true))
        #expect(frame == #"{"type":"app_event","event":{"name":"ended","detail":"hung up on this side after 3.0s, the agent heard","quiet":true,"telemetry":true,"data":{"cause":"local_end","transport":"rtc","after_ms":3000,"voice_heard":true}}}"#,
                "Android's CallAnalyticsRowsTest, byte for byte")
        let bare = try #require(GraineCallTelemetry.endedFrame(cause: "audio_watch"))
        #expect(bare == #"{"type":"app_event","event":{"name":"ended","detail":"nothing arrived: ended on this side","quiet":true,"telemetry":true,"data":{"cause":"audio_watch"}}}"#)
        #expect(GraineCallTelemetry.endedFrame(cause: "remote_bye", transport: "ws", afterMs: 12_449, voiceHeard: false)?
            .contains(#""detail":"the far side hung up after 12.4s, the agent not heard""#) == true)
        // A value that does not fit its type is left out, as every row leaves it out.
        let odd = try #require(GraineCallTelemetry.endedFrame(cause: "media_drop", transport: "carrier", afterMs: -5, voiceHeard: nil))
        #expect(odd.contains(#""detail":"the audio path dropped","#) && odd.contains(#""data":{"cause":"media_drop"}"#))
        #expect(GraineCallTelemetry.endedFrame(cause: "provider_reset")?.contains(#""detail":"the system reset the call""#) == true, "iOS's own cause")
        #expect(GraineCallTelemetry.endedFrame(cause: "failed", transport: "ws")?.contains(#""detail":"failed""#) == true)
        for cause in GraineCallTelemetry.endCauses { #expect(GraineCallTelemetry.endedFrame(cause: cause) != nil, "\(cause)") }
        #expect(Set([GraineCallEndCause.localEnd, .remoteBye, .mediaDrop, .audioWatch, .providerReset, .failed].map(\.rawValue)) == GraineCallTelemetry.endCauses)
        #expect(GraineCallTelemetry.endedFrame(cause: "card_blocked") == nil, "only a cause: a word of the app's never rides in it")
        #expect(GraineCallTelemetry.frame("ended", ["cause": "local_end"]) == nil, "sent ahead of the contract: v1's builder does not make it")
        var fold = CallConnectionFold()
        let read = fold.read(frame)
        #expect(!read && fold.report == nil, "nor is it read into the connection report")
    }

    @Test func theConversationSendsItOnTheChannelStillUp() throws {
        // The voice socket, open.
        let socketRig = ConversationRig()
        let onSocket = socketRig.make(.websocket)
        onSocket.start()
        let socket = try #require(socketRig.network.socket)
        socket.open()
        onSocket.sendEnded(.localEnd)
        onSocket.hangUp()
        let sent = socket.sentFrames.compactMap { $0["event"] as? [String: Any] }.filter { $0["name"] as? String == "ended" }
        #expect(sent.count == 1)
        let data = try #require(sent.first?["data"] as? [String: Any])
        #expect(data["cause"] as? String == "local_end" && data["transport"] as? String == "ws")
        #expect(data["voice_heard"] as? Bool == false, "the agent's voice never came")
        let detail = JSON.string(sent.first?["detail"])
        #expect(detail.hasPrefix("hung up on this side"))
        let stopAt = socket.sentTypes.firstIndex(of: "stop")
        let endedAt = socket.sent.firstIndex { $0.contains(#""name":"ended""#) }
        #expect(endedAt != nil && stopAt != nil && endedAt! < stopAt!, "before the stop frame")
        onSocket.sendEnded(.localEnd)
        #expect(socket.sent.filter { $0.contains(#""name":"ended""#) }.count == 1, "nothing once the call is over")

        // WebRTC: on the control channel.
        let rtcRig = ConversationRig()
        let onRtc = rtcRig.make()
        onRtc.start()
        let call = try #require(rtcRig.module.call)
        onRtc.sendEnded(.audioWatch)
        #expect(call.sent.last?.frame.contains(#""detail":"nothing arrived: ended on this side""#) == true && call.sent.last?.kind == nil)
        #expect(call.sent.last?.frame.contains(#""data":{"cause":"audio_watch","transport":"rtc"}"#) == true)
    }
}

@Suite struct CallAudioWatchAtOpenTests {
    /// The other suspect: no SDK timer ends a call that carries the agent's voice in its first seconds.
    @Test func aCallOnWebRtcIsNeverWaitedOnItsMediaRunsOnlyOnceItsAudioDoes() {
        #expect(CallAudioWatch.runningAtOpen(callKitActivated: false, transport: .webrtc), "its media path is up only once its audio runs")
        #expect(CallAudioWatch.runningAtOpen(callKitActivated: true, transport: .gateway))
        #expect(!CallAudioWatch.runningAtOpen(callKitActivated: false, transport: .gateway), "the voice socket opens before its audio")
        #expect(!CallAudioWatch.runningAtOpen(callKitActivated: false, transport: .direct))
        var steps: [CallAudioWatch.Step] = []
        var pending: [() -> Void] = []
        let watch = CallAudioWatch(schedule: { _, fire in pending.append(fire); return {} }, act: { steps.append($0) })
        watch.opened(audioRunning: CallAudioWatch.runningAtOpen(callKitActivated: false, transport: .webrtc))
        #expect(steps == [.connect] && pending.isEmpty, "connected at once: no timer armed, nothing that could end it")
    }
}

@Suite struct CallAudioRouteTests {
    @Test func theLoudspeakerByDefaultNeverOffTheCustomersOwnDeviceUnasked() {
        #expect(CallAudioRoute.choice(speaker: true, chosen: false, outputs: ["Receiver"]) == .speaker, "the default: the loudspeaker")
        #expect(CallAudioRoute.choice(speaker: true, chosen: false, outputs: ["Speaker"]) == .speaker)
        for own in ["Headphones", "BluetoothHFP", "BluetoothA2DPOutput", "BluetoothLE", "CarAudio", "USBAudio", "AirPlay"] {
            #expect(CallAudioRoute.choice(speaker: true, chosen: false, outputs: [own]) == .leave, "\(own): the default leaves it be")
            #expect(CallAudioRoute.choice(speaker: true, chosen: true, outputs: [own]) == .speaker, "\(own): asked for, the speaker")
        }
        #expect(CallAudioRoute.choice(speaker: false, chosen: true, outputs: ["Speaker"]) == .receiver, "setSpeaker(false): the earpiece")
        #expect(CallAudioRoute.choice(speaker: false, chosen: false, outputs: ["Headphones"]) == .receiver, "no override: back to the headset")
        #expect(CallAudioRoute.onSpeaker(["Speaker"]) && !CallAudioRoute.onSpeaker(["Receiver"]) && !CallAudioRoute.onSpeaker(["Headphones"]))
    }
}

@Suite struct ChatAfterTheAgentEndsItTests {
    private let welcome: [String: Any] = ["type": "text", "data": "<beginning_of_stream>Hi! How can I help?<end_of_stream>"]

    /// Every SDK says the same: the agent ended the conversation — the chat is idle, not offline or failed.
    @Test func theChatIsIdleOnceTheAgentEndedItAndTheServerClosed() throws {
        let rig = ChatRig()
        let socket = rig.online()
        socket.frame(welcome)
        socket.frame(["type": "conversation_end"])
        #expect(rig.chat.ended && rig.chat.status == .online, "the socket stays open a moment, for a rating")
        socket.serverClose(1000, reason: "conversation ended")
        #expect(rig.chat.status == .idle, "over, not offline")
        #expect(!rig.chat.disconnected && rig.chat.ended)
        #expect(ObjCBridge.chatStatus(rig.chat.status, disconnected: rig.chat.disconnected).word == "idle")
        rig.scheduler.advance(60)
        #expect(rig.network.sockets.count == 1, "not dialled again on its own")
        rig.chat.send("One more thing")
        #expect(rig.network.sockets.count == 2, "the customer's next message starts another")
    }

    @Test func anyOtherCloseByTheServerIsStillOffline() throws {
        let rig = ChatRig()
        let socket = rig.online()
        socket.serverClose(1000, reason: "closed")
        #expect(rig.chat.status == .offline, "unchanged: closed with nothing ended")
    }
}

@Suite @MainActor struct CallEndObjCAndHostTests {
    /// JSON text a facade handed back, read as Foundation reads it.
    private func parse(_ text: String?) -> Any? {
        text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
    }

    @Test func theOutcomesCarryWhoEndedTheCall() throws {
        let objc = GraineObjCCallOutcome(ObjCBridge.outcome(.ended(.local), callId: "c1", busy: false, connectedSeconds: 4, hosted: false, cause: "audio_watch"))
        #expect(objc.cause == "audio_watch")
        #expect((parse(objc.json) as? [String: Any])?["cause"] as? String == "audio_watch")
        let failed = GraineObjCCallOutcome(ObjCBridge.outcome(.failed(CallAudioWatch.failure), callId: "c1", busy: false, connectedSeconds: nil, hosted: false, cause: "audio_watch"))
        #expect(failed.cause == "audio_watch")
        let answered = GraineObjCCallOutcome(ObjCBridge.outcome(.answered, callId: "c1", busy: false, connectedSeconds: nil, hosted: false, cause: "local_end"))
        #expect(answered.cause == nil, "only on the outcome that ends the call")
        let host = CallsHostEvent.outcomePayload(.ended(.remote), callId: "c1", cause: .remoteBye)
        #expect(host["cause"] as? String == "remote_bye")
        #expect(CallsHostEvent.outcomePayload(.declined, callId: "c2", cause: .localEnd)["cause"] == nil)
    }

    @Test func theObjectiveCCallsSayTheCauseAndTheSpeakerDefault() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        let calls = GraineObjC(graine: rig.graine).calls
        let snapshot = try #require(parse(calls.snapshotJSON) as? [String: Any])
        #expect(snapshot["endCause"] is NSNull)
        #expect(snapshot["speakerByDefault"] as? Bool == true, "the loudspeaker unless the app says otherwise")
        #expect(calls.endCause == nil && calls.speakerByDefault)
        let cls = try #require(NSClassFromString("GraineObjCCalls") as? NSObject.Type)
        for s in ["speakerByDefault", "setSpeakerByDefault:", "endCause"] {
            #expect(cls.instancesRespond(to: NSSelectorFromString(s)), "-[GraineObjCCalls \(s)]")
        }
        #expect((NSClassFromString("GraineObjCCallOutcome") as? NSObject.Type)?.instancesRespond(to: NSSelectorFromString("cause")) == true)
    }
}
