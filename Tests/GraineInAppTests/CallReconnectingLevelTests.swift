import Foundation
import Testing
@_spi(GraineRTC) @testable import GraineInApp

/*
 * THE CALL SCREEN'S TWO LIVE SIGNALS — reconnecting, and the agent's voice
 * level — from where they are measured to what GraineCalls hears: the voice
 * socket's level (the RMS of what the speaker plays, when it plays it), the
 * easing `agentLevel` follows, and the WebRTC leg's events through the
 * conversation. The socket never reconnects.
 */

/// The signals among a call's events, as words: reconnecting, the level and the end.
private func signals(_ events: [CallEngine.Event]) -> [String] {
    events.compactMap { event in
        switch event {
        case .reconnecting(let on): return "reconnecting(\(on))"
        case .level(let value): return "level(\(value))"
        case .ended(let ending): return "ended(\(ending))"
        default: return nil
        }
    }
}

private func levels(_ events: [CallEngine.Event]) -> [Double] {
    events.compactMap { if case .level(let value) = $0 { return value }; return nil }
}

/// `ms` of a square wave at ±`amp`: its RMS is exactly amp / 32768.
private func square(ms: Int, amp: Int16, rate: Int = 24_000) -> [Int16] {
    let n = rate * ms / 1_000
    return (0..<n).map { $0 % 2 == 0 ? amp : -amp }
}

/// An agent audio frame as the server sends it, declared PCM at `rate`.
private func audioFrame(_ pcm: [Int16], rate: Int = 24_000) -> [String: Any] {
    let data = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
    return ["type": "audio", "data": data.base64EncodedString(), "meta_info": ["format": "pcm", "sample_rate": rate]]
}

@Suite struct HeardLevelsTests {
    @Test func theRmsOfAKnownFrameIsItsShareOfFullScale() {
        #expect(HeardLevels.rms(square(ms: 20, amp: 16_384)) == 0.5)
        #expect(HeardLevels.rms(square(ms: 20, amp: 8_192)) == 0.25)
        let sine = (0..<16_000).map { Int16((16_384 * sin(2 * Double.pi * 440 * Double($0) / 16_000)).rounded()) }
        #expect(abs(HeardLevels.rms(sine) - 0.5 / 2.squareRoot()) < 0.001, "a sine's RMS is its peak over √2")
        #expect(HeardLevels.rms([Int16](repeating: 0, count: 480)) == 0, "silence is 0")
        #expect(HeardLevels.rms([]) == 0)
        #expect(HeardLevels.rms([Int16](repeating: .min, count: 10)) == 1, "never past full scale")
        #expect(HeardLevels.rms(square(ms: 20, amp: 8_192) + [Int16](repeating: 0, count: 480), from: 480) == 0, "a slice")
    }

    @Test func eachHundredMillisecondsIsDueWhenItStartsToPlay() {
        var heard = HeardLevels()
        // 250 ms at 8 kHz from t = 10: windows at 10.0, 10.1 and 10.2 (the last one 50 ms).
        let pcm = square(ms: 100, amp: 8_192, rate: 8_000) + square(ms: 100, amp: 16_384, rate: 8_000) + [Int16](repeating: 0, count: 400)
        heard.add(pcm, sampleRate: 8_000, startsAt: 10)
        #expect(heard.due(9.99) == nil, "nothing is heard before it plays")
        #expect(heard.due(10) == 0.25)
        #expect(heard.due(10.05) == nil, "each window once")
        #expect(heard.due(10.1) == 0.5)
        #expect(!heard.isEmpty)
        #expect(heard.due(11) == 0, "late, the latest of what is due")
        #expect(heard.isEmpty)
        heard.add(pcm, sampleRate: 8_000, startsAt: 20)
        heard.add(pcm, sampleRate: 8_000, startsAt: 20.25)
        #expect(heard.due(20.3) == 0.25, "the second chunk's first window, played on from the first")
        heard.clear()
        #expect(heard.isEmpty)
        #expect(heard.due(100) == nil)
    }

    @Test func digitalSilenceIsSilentWhateverItSamples() {
        var heard = HeardLevels()
        heard.add([Int16](repeating: -32_124, count: 2_400), sampleRate: 8_000, startsAt: 0, silent: true)
        #expect(heard.due(0) == 0)
        #expect(heard.due(0.25) == 0)
        #expect(heard.isEmpty)
    }

    @Test func nothingToMeasureAddsNothing() {
        var heard = HeardLevels()
        heard.add([], sampleRate: 24_000, startsAt: 0)
        heard.add(square(ms: 20, amp: 100), sampleRate: 0, startsAt: 0)
        #expect(heard.isEmpty)
    }
}

@Suite struct AgentLevelEasingTests {
    @Test func tenStepsASecondUpOverSixtyMillisecondsDownOverTwoForty() {
        #expect(AgentLevelEasing.stepSeconds == 0.1)
        var easing = AgentLevelEasing()
        #expect(easing.settled)
        #expect(!easing.heard)
        easing.hear(1)
        #expect(easing.heard)
        #expect(!easing.settled)
        let up = easing.step(dtMs: 100)
        #expect(up == ((1 - exp(-100.0 / 60)) * 1_000).rounded() / 1_000)
        #expect(up > 0.8, "most of the way up in one step")
        easing.hear(0)
        let down = easing.step(dtMs: 100)
        #expect(down == ((up * exp(-100.0 / 240)) * 1_000).rounded() / 1_000)
        #expect(down > 0.5, "a third of the way down in one step: the release is slower than the attack")
    }

    @Test func itSettlesExactlyOnWhatWasHeard() {
        var easing = AgentLevelEasing()
        easing.hear(0.42)
        var steps = 0
        while !easing.settled && steps < 100 { _ = easing.step(dtMs: 100); steps += 1 }
        #expect(easing.value == 0.42)
        #expect(steps < 10)
        easing.hear(0)
        steps = 0
        while !easing.settled && steps < 100 { _ = easing.step(dtMs: 100); steps += 1 }
        #expect(easing.value == 0, "silence is exactly 0, and the steps stop")
        #expect(steps < 40)
    }

    @Test func levelsAreClampedAndTheEndForgetsThem() {
        var easing = AgentLevelEasing()
        easing.hear(7)
        #expect(easing.target == 1)
        easing.hear(-1)
        #expect(easing.target == 0)
        easing.hear(.nan)
        #expect(easing.target == 0)
        easing.hear(0.5)
        _ = easing.step(dtMs: 100)
        easing.reset()
        #expect(easing.value == 0)
        #expect(easing.target == 0)
        #expect(!easing.heard, "the next call starts on the speaking movement again")
        #expect(easing.step(dtMs: -5) == 0, "no time, no movement")
    }
}

@Suite struct SocketLevelTests {
    @Test func theLevelIsTheRmsOfEachHundredMillisecondsAsItIsHeard() {
        let rig = EngineRig()
        let socket = rig.open()
        let pcm = square(ms: 100, amp: 8_192) + square(ms: 100, amp: 16_384) + [Int16](repeating: 0, count: 2_400)
        socket.frame(audioFrame(pcm))
        #expect(rig.audio.played.first?.samples == pcm, "what is played is what came: the level only listens")
        rig.scheduler.advance(0)
        #expect(levels(rig.events) == [0.25])
        rig.scheduler.advance(0.1)
        #expect(levels(rig.events) == [0.25, 0.5])
        rig.scheduler.advance(0.1)
        #expect(levels(rig.events) == [0.25, 0.5, 0], "the quiet window")
        rig.scheduler.advance(2)
        #expect(levels(rig.events) == [0.25, 0.5, 0], "silence while silent says nothing new")
    }

    @Test func itWaitsForWhatTheSpeakerAlreadyHolds() {
        let rig = EngineRig()
        let socket = rig.open()
        rig.audio.buffered = 1.0
        socket.frame(audioFrame(square(ms: 200, amp: 8_192)))
        rig.scheduler.advance(0.95)
        #expect(levels(rig.events).isEmpty, "a reply arrives far faster than it is spoken")
        rig.scheduler.advance(0.1)
        #expect(levels(rig.events) == [0.25])
        rig.scheduler.advance(0.1)
        #expect(levels(rig.events) == [0.25, 0.25])
        rig.scheduler.advance(0.1)
        #expect(levels(rig.events) == [0.25, 0.25, 0], "played out: 0, once")
        rig.scheduler.advance(1)
        #expect(levels(rig.events) == [0.25, 0.25, 0])
    }

    @Test func digitalSilenceIsSilentAndPlaysAsBefore() throws {
        let rig = EngineRig()
        let socket = rig.open()
        let bytes = [UInt8](repeating: 0, count: 9_600)
        socket.frame(["type": "audio", "data": Data(bytes).base64EncodedString()])
        let expected = try #require(AgentAudio.decode(bytes, declaredFormat: nil, declaredRate: nil, latched: nil))
        #expect(rig.audio.played.first?.samples == expected.pcm16, "played exactly as it was")
        rig.scheduler.advance(2)
        #expect(levels(rig.events).isEmpty, "silence moves nothing (its mu-law reading is a DC step nobody hears)")
    }

    @Test func aClearSilencesTheLevelAtOnce() {
        let rig = EngineRig()
        let socket = rig.open()
        socket.frame(audioFrame(square(ms: 500, amp: 8_192)))
        rig.scheduler.advance(0)
        #expect(levels(rig.events) == [0.25])
        socket.frame(["type": "clear"])
        #expect(levels(rig.events) == [0.25, 0], "the customer interrupted: what was queued is not heard")
        rig.scheduler.advance(1)
        #expect(levels(rig.events) == [0.25, 0])
    }

    @Test func theEndStopsTheLevels() {
        let rig = EngineRig()
        let socket = rig.open()
        socket.frame(audioFrame(square(ms: 500, amp: 8_192)))
        rig.scheduler.advance(0)
        socket.serverClose()
        #expect(rig.scheduler.waiting == 0, "no level timer outlives the call")
        rig.scheduler.advance(1)
        #expect(levels(rig.events) == [0.25])
    }

    /// One socket carries the whole call: losing it ends the call; it is never reconnected inside it.
    @Test func theSocketNeverReconnects() throws {
        let rig = EngineRig()
        let socket = rig.open()
        socket.frame(audioFrame(square(ms: 100, amp: 8_192)))
        socket.fail("The network connection was lost.")
        #expect(rig.endings == [.dropped("The network connection was lost.")])
        #expect(!signals(rig.events).contains { $0.hasPrefix("reconnecting") })
        #expect(rig.network.sockets.count == 1, "no second socket")

        let conversation = ConversationRig()
        conversation.make(.websocket).start()
        let carried = try #require(conversation.network.socket)
        carried.open()
        carried.fail("gone")
        #expect(conversation.endings == [.dropped("gone")])
        #expect(!signals(conversation.events).contains { $0.hasPrefix("reconnecting") })
    }
}

@Suite struct RtcSignalsThroughTheConversationTests {
    @Test func reconnectingAndTheLevelReachTheCallOnlyAfterMedia() throws {
        let rig = ConversationRig()
        rig.make().start()
        let call = try #require(rig.module.call)
        call.emit(.reconnecting(true))
        call.emit(.level(0.5))
        #expect(signals(rig.events).isEmpty, "never for a call whose media never flowed")
        call.emit(.connected)
        call.emit(.level(0.4))
        call.emit(.reconnecting(true))
        call.emit(.reconnecting(true))
        call.emit(.level(0))
        call.emit(.reconnecting(false))
        #expect(signals(rig.events) == ["level(0.4)", "reconnecting(true)", "level(0.0)", "reconnecting(false)"], "each change once")
    }

    @Test func theEndClearsReconnectingBeforeItsEnd() throws {
        let hungUp = ConversationRig()
        let conversation = hungUp.make()
        conversation.start()
        let call = try #require(hungUp.module.call)
        call.emit(.connected)
        call.emit(.reconnecting(true))
        conversation.hangUp()
        #expect(signals(hungUp.events) == ["reconnecting(true)", "reconnecting(false)", "ended(local)"])

        let dropped = ConversationRig()
        dropped.make().start()
        let leg = try #require(dropped.module.call)
        leg.emit(.connected)
        leg.emit(.reconnecting(true))
        leg.emit(.ended(.dropped("the media path did not come back within 10 s")))
        #expect(signals(dropped.events) == [
            "reconnecting(true)", "reconnecting(false)", "ended(dropped(\"the media path did not come back within 10 s\"))",
        ])

        let plain = ConversationRig()
        plain.make().start()
        plain.module.call?.emit(.connected)
        plain.module.call?.emit(.ended(.remote))
        #expect(signals(plain.events) == ["ended(remote)"], "a call that never lost its path says nothing about it")
    }
}
