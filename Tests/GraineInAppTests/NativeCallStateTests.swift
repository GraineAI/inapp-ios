import Foundation
import Testing
@testable import GraineInApp

/*
 * The player's rules, the speaking clock, the call's state machine, the
 * microphone an answered call needs, and the push: pure, so every rule that
 * keeps a call taking turns — and every outcome a client's server is told — is
 * proven without a phone.
 */

@Suite struct PlayoutPolicyTests {
    private func chunk(ms: Int, rate: Int = 24_000) -> PlayoutPolicy.Chunk {
        PlayoutPolicy.Chunk(samples: [Int16](repeating: 1, count: rate * ms / 1_000), sampleRate: rate)
    }

    @Test func aRunStartsOnlyOnceOneHundredFiftyMillisecondsIsQueued() {
        var p = PlayoutPolicy()
        #expect(p.push(chunk(ms: 100), now: 0).isEmpty)
        #expect(abs(p.bufferedSeconds(now: 0) - 0.1) < 1e-9)
        let released = p.push(chunk(ms: 60), now: 0.01)
        #expect(released.count == 2, "both chunks go together")
        #expect(abs(p.bufferedSeconds(now: 0.01) - 0.16) < 1e-9)
        #expect(abs(p.bufferedSeconds(now: 0.11) - 0.06) < 1e-9)
    }

    @Test func aProductionFrameStartsARunByItself() {
        var p = PlayoutPolicy()
        #expect(p.push(chunk(ms: 200), now: 0).count == 1)
        #expect(p.running)
    }

    @Test func theDrainPathPlaysAReplyShorterThanTheCushion() {
        var p = PlayoutPolicy()
        #expect(p.push(chunk(ms: 80), now: 0).isEmpty)
        #expect(p.drainDue == 0.12)
        #expect(p.tick(now: 0.119).isEmpty)
        #expect(p.tick(now: 0.12).count == 1)
        #expect(abs(p.bufferedSeconds(now: 0.12) - 0.08) < 1e-9)
        #expect(p.drainDue == nil)
    }

    @Test func eachNewChunkRestartsTheDrainClock() {
        var p = PlayoutPolicy()
        _ = p.push(chunk(ms: 40), now: 0)
        _ = p.push(chunk(ms: 40), now: 0.1)
        #expect(p.tick(now: 0.15).isEmpty, "120 ms from the LAST chunk")
        #expect(p.tick(now: 0.22).count == 2)
    }

    @Test func bufferedLandsAtExactlyZeroWhenEverythingHasPlayed() {
        var p = PlayoutPolicy()
        _ = p.push(chunk(ms: 200), now: 5)
        _ = p.push(chunk(ms: 200), now: 5.1)
        #expect(p.bufferedSeconds(now: 5.3) > 0.09)
        #expect(p.bufferedSeconds(now: 5.401) == 0)
        #expect(p.bufferedSeconds(now: 6) == 0)
        _ = p.push(chunk(ms: 80), now: 7)
        _ = p.tick(now: 7.2)
        #expect(p.bufferedSeconds(now: 7.3) == 0)
        #expect(p.bufferedSeconds(now: 100) == 0)
    }

    @Test func whileARunGoesAudioIsHandedStraightOn() {
        var p = PlayoutPolicy()
        _ = p.push(chunk(ms: 150), now: 0)
        #expect(p.push(chunk(ms: 20), now: 0.05).count == 1)
        #expect(abs(p.bufferedSeconds(now: 0.05) - 0.12) < 1e-9)
    }

    @Test func afterRunningDryItRefillsBeforeResuming() {
        var p = PlayoutPolicy()
        _ = p.push(chunk(ms: 200), now: 0)
        // The run played out at 0.2; at 0.25 a fragment arrives: held, not stuttered out.
        #expect(p.push(chunk(ms: 50), now: 0.25).isEmpty)
        #expect(!p.running)
        #expect(p.push(chunk(ms: 100), now: 0.27).count == 2, "150 ms refilled")
    }

    @Test func clearDropsEverythingAtOnce() {
        var p = PlayoutPolicy()
        _ = p.push(chunk(ms: 200), now: 0)
        _ = p.push(chunk(ms: 200), now: 0.01)
        p.clear(now: 0.05)
        #expect(p.bufferedSeconds(now: 0.05) == 0)
        #expect(p.drainDue == nil)
        #expect(p.push(chunk(ms: 100), now: 0.06).isEmpty, "the next turn fills its cushion again")
    }

    @Test func aMuLawStreamFillsItsCushionToo() {
        var p = PlayoutPolicy()
        var released = 0
        for i in 0..<7 { released += p.push(chunk(ms: 20, rate: 8_000), now: Double(i) * 0.02).count }
        #expect(released == 0, "140 ms is not yet 150")
        #expect(p.push(chunk(ms: 20, rate: 8_000), now: 0.14).count == 8)
    }
}

@Suite struct MarkAckTests {
    @Test func acksWaitForPlayoutAndNoLongerThanTenSeconds() {
        #expect(MarkAck.delay(bufferedSeconds: 0) == 0)
        #expect(MarkAck.delay(bufferedSeconds: -1) == 0)
        #expect(MarkAck.delay(bufferedSeconds: 0.6) == 0.6)
        #expect(MarkAck.delay(bufferedSeconds: 9.99) == 9.99)
        #expect(MarkAck.delay(bufferedSeconds: 42) == 10)
        #expect(MarkAck.delay(bufferedSeconds: .nan) == 0)
        #expect(MarkAck.delay(bufferedSeconds: .infinity) == 10)
    }
}

@Suite struct AgentSpeechTests {
    @Test func speakingEndsOnlyOnceDrainedAndQuietForThreeHundredMilliseconds() {
        #expect(AgentSpeech.recheck(now: 10.3, lastAudioAt: 10, bufferedSeconds: 0) == nil)
        #expect(AgentSpeech.recheck(now: 10.3, lastAudioAt: 10, bufferedSeconds: 0.02) == nil)
        // Still queued: look again when it should have played.
        #expect(AgentSpeech.recheck(now: 10.3, lastAudioAt: 10, bufferedSeconds: 0.6) == 0.6)
        // Too recent: look again when the tail is up (never sooner than 50 ms).
        #expect(abs((AgentSpeech.recheck(now: 10.1, lastAudioAt: 10, bufferedSeconds: 0) ?? 0) - 0.2) < 1e-9)
        #expect(AgentSpeech.recheck(now: 10.29, lastAudioAt: 10, bufferedSeconds: 0) == 0.05)
        // Never more than a second between looks.
        #expect(AgentSpeech.recheck(now: 11, lastAudioAt: 10, bufferedSeconds: 8) == 1)
    }

    @Test func audibleFailsOpenWithoutRecentAgentAudio() {
        #expect(AgentSpeech.audible(now: 10, lastAudioAt: 9, bufferedSeconds: 0.5, speaking: false))
        #expect(AgentSpeech.audible(now: 10, lastAudioAt: 9, bufferedSeconds: 0, speaking: true))
        #expect(!AgentSpeech.audible(now: 10, lastAudioAt: 9, bufferedSeconds: 0.01, speaking: false))
        #expect(!AgentSpeech.audible(now: 10.6, lastAudioAt: 9, bufferedSeconds: 5, speaking: true), "1.5 s without agent audio: the customer is heard")
        #expect(!AgentSpeech.audible(now: 10, lastAudioAt: nil, bufferedSeconds: 5, speaking: true))
        // A reply that arrived in a burst (production: 6.3 s of speech in 0.8 s): 4 s queued
        // at 9.0. At 10.6 — 1.6 s after it ARRIVED, 2.4 s still to play — the agent is audible;
        // 1.5 s after it is due to have played (13.0 + 1.5), the customer is heard again.
        #expect(AgentSpeech.audible(now: 10.6, lastAudioAt: 9, audibleUntil: 13, bufferedSeconds: 2.4, speaking: false),
                "the mic opened with the reply still playing — its echo would go up as the customer")
        #expect(!AgentSpeech.audible(now: 14.6, lastAudioAt: 9, audibleUntil: 13, bufferedSeconds: 0.01, speaking: true),
                "a stalled latch must not keep the customer muted past the projected end")
    }
}

@Suite struct CallMachineTests {
    @Test func anAnsweredCallTheAgentHangsUp() {
        var m = CallMachine()
        #expect(m.handle(.incoming(id: "c1")) == .init(accepted: true, state: .ringing, callId: "c1", outcomes: []))
        #expect(m.handle(.answer).outcomes == [.answered])
        #expect(m.state == .connecting)
        #expect(m.handle(.connected).state == .active)
        #expect(m.handle(.remoteEnded) == .init(accepted: true, state: .ended(.remote), callId: "c1", outcomes: [.ended(.remote)]))
        #expect(m.handle(.settle).state == .idle)
        #expect(m.call == nil)
    }

    @Test func aRingNobodyAnswersIsMissed() {
        var m = CallMachine()
        _ = m.handle(.incoming(id: "c1"))
        #expect(m.handle(.ringTimeout) == .init(accepted: true, state: .ended(.missed), callId: "c1", outcomes: [.missed]))
    }

    @Test func aDeclineIsDeclined() {
        var m = CallMachine()
        _ = m.handle(.incoming(id: "c1"))
        #expect(m.handle(.decline).outcomes == [.declined])
        var n = CallMachine()
        _ = n.handle(.incoming(id: "c2"))
        #expect(n.handle(.hangUp) == .init(accepted: true, state: .ended(.declined), callId: "c2", outcomes: [.declined]))
    }

    @Test func aPushWhileACallIsLiveIsMissedAndTheLiveCallIsUntouched() {
        for live in [CallMachine.Event.incoming(id: "c1"), .outgoing(id: "c1")] {
            var m = CallMachine()
            _ = m.handle(live)
            let before = m.state
            #expect(m.handle(.incoming(id: "c2")) == .init(accepted: false, state: before, callId: "c2", outcomes: [.missed]))
            #expect(m.call?.id == "c1")
            #expect(!m.handle(.outgoing(id: "c3")).accepted, "a second startCall is refused")
        }
    }

    @Test func aCustomersCallTheyHangUp() {
        var m = CallMachine()
        #expect(m.handle(.outgoing(id: "o1")).state == .connecting)
        #expect(m.call?.direction == .outgoing)
        _ = m.handle(.connected)
        #expect(m.handle(.hangUp) == .init(accepted: true, state: .ended(.local), callId: "o1", outcomes: [.ended(.local)]))
    }

    @Test func aCallThatNeverConnectsFailedWithItsReason() {
        var m = CallMachine()
        _ = m.handle(.outgoing(id: "o1"))
        #expect(m.handle(.failed("no network")) == .init(accepted: true, state: .ended(.failed), callId: "o1", outcomes: [.failed("no network")]))
        var n = CallMachine()
        _ = n.handle(.incoming(id: "c1"))
        _ = n.handle(.answer)
        #expect(n.handle(.remoteEnded).outcomes == [.failed("The line closed before the call connected.")])
    }

    @Test func aDroppedLineEndsAsFailed() {
        var m = CallMachine()
        _ = m.handle(.outgoing(id: "o1"))
        _ = m.handle(.connected)
        #expect(m.handle(.dropped).outcomes == [.ended(.failed)])
    }

    @Test func aSystemResetEndsWhateverIsLive() {
        var ringing = CallMachine()
        _ = ringing.handle(.incoming(id: "c1"))
        #expect(ringing.handle(.reset).outcomes == [.missed])
        var connecting = CallMachine()
        _ = connecting.handle(.outgoing(id: "o1"))
        #expect(connecting.handle(.reset).outcomes == [.failed("The system ended the call.")])
        var active = CallMachine()
        _ = active.handle(.outgoing(id: "o2"))
        _ = active.handle(.connected)
        #expect(active.handle(.reset).outcomes == [.ended(.failed)])
        var idle = CallMachine()
        #expect(!idle.handle(.reset).accepted)
    }

    @Test func eventsThatDoNotApplyChangeNothing() {
        var m = CallMachine()
        for event: CallMachine.Event in [.answer, .decline, .ringTimeout, .connected, .hangUp, .remoteEnded, .dropped, .settle] {
            #expect(!m.handle(event).accepted)
            #expect(m.state == .idle)
        }
        _ = m.handle(.outgoing(id: "o1"))
        #expect(!m.handle(.answer).accepted, "nothing is ringing")
        #expect(!m.handle(.ringTimeout).accepted)
        _ = m.handle(.connected)
        #expect(!m.handle(.connected).accepted)
    }

    @Test func aNewCallMayStartWhileTheLastOneIsStillShowingEnded() {
        var m = CallMachine()
        _ = m.handle(.outgoing(id: "o1"))
        _ = m.handle(.hangUp)
        #expect(m.handle(.incoming(id: "c2")).accepted)
        #expect(m.state == .ringing)
        #expect(!m.handle(.settle).accepted, "a stale settle does not end the new call")
    }

    @Test func liveIsRingingConnectingOrActive() {
        #expect(GraineCallState.ringing.isLive)
        #expect(GraineCallState.connecting.isLive)
        #expect(GraineCallState.active.isLive)
        #expect(!GraineCallState.idle.isLive)
        #expect(!GraineCallState.ended(.local).isLive)
    }

    @Test func anAnsweredCallWithoutTheMicrophoneIsAnsweredThenFailed() {
        // What the app's server hears, in order: the same two outcomes Android reports.
        var m = CallMachine()
        _ = m.handle(.incoming(id: "c1"))
        #expect(m.handle(.answer).outcomes == [.answered])
        #expect(m.handle(.failed(CallMicGate.notGranted)) == .init(
            accepted: true, state: .ended(.failed), callId: "c1",
            outcomes: [.failed("The microphone permission was not granted.")]
        ))
    }
}

/*
 * An answered call and the microphone. CallKit's answer is never held for a
 * permission prompt, so whether the conversation opens is decided after it:
 * granted, refused (now or before), or a prompt nobody answered in a minute.
 */
@Suite struct CallMicGateTests {
    /// The system's permission as the test sets it; every prompt kept, and answered by hand.
    private final class FakeMic: MicPermissionSource {
        var permission: MicPermission
        private(set) var prompts: [(Bool) -> Void] = []

        init(_ permission: MicPermission) { self.permission = permission }

        func request(_ done: @escaping (Bool) -> Void) { prompts.append(done) }

        /// The customer answers the newest prompt.
        func answer(_ granted: Bool) { prompts.last?(granted) }
    }

    /// The minute, run by hand: nothing here sleeps.
    private final class HandClock {
        private(set) var armed: [(seconds: TimeInterval, fire: () -> Void, cancelled: Bool)] = []

        func schedule(_ seconds: TimeInterval, _ fire: @escaping () -> Void) -> () -> Void {
            armed.append((seconds, fire, false))
            let index = armed.count - 1
            return { [weak self] in self?.armed[index].cancelled = true }
        }

        /// The wait runs out: every timer still armed fires.
        func runOut() {
            for (i, timer) in armed.enumerated() where !timer.cancelled {
                armed[i].cancelled = true
                timer.fire()
            }
        }

        var live: Int { armed.filter { !$0.cancelled }.count }
    }

    private func gate(_ mic: FakeMic, _ clock: HandClock) -> CallMicGate {
        CallMicGate(source: mic, schedule: clock.schedule)
    }

    @Test func aGrantedMicrophoneConnectsAtOnceWithoutAsking() {
        let mic = FakeMic(.granted)
        let clock = HandClock()
        let g = gate(mic, clock)
        var verdicts: [CallMicGate.Verdict] = []
        g.afterAnswer { verdicts.append($0) }
        #expect(verdicts == [.connect])
        #expect(mic.prompts.isEmpty)
        #expect(clock.armed.isEmpty, "nothing to wait for")
        #expect(!g.asking)
    }

    @Test func aDeniedMicrophoneEndsTheCallAtOnceWithoutAsking() {
        let mic = FakeMic(.denied)
        let clock = HandClock()
        let g = gate(mic, clock)
        var verdicts: [CallMicGate.Verdict] = []
        g.afterAnswer { verdicts.append($0) }
        #expect(verdicts == [.refused])
        #expect(mic.prompts.isEmpty, "the system does not ask twice; only Settings gives it back")
        #expect(clock.armed.isEmpty)
    }

    @Test func neverAskedItAsksAndConnectsOnceGranted() {
        let mic = FakeMic(.undetermined)
        let clock = HandClock()
        let g = gate(mic, clock)
        var verdicts: [CallMicGate.Verdict] = []
        g.afterAnswer { verdicts.append($0) }
        #expect(verdicts.isEmpty, "the call stays connecting while the prompt is up")
        #expect(g.asking)
        #expect(mic.prompts.count == 1)
        #expect(clock.armed.map { $0.seconds } == [60])
        mic.answer(true)
        #expect(verdicts == [.connect])
        #expect(clock.live == 0, "the minute stops once the customer answers")
        #expect(!g.asking)
        clock.runOut()
        mic.answer(false)
        #expect(verdicts == [.connect], "decided once")
    }

    @Test func neverAskedARefusalEndsTheCall() {
        let mic = FakeMic(.undetermined)
        let clock = HandClock()
        let g = gate(mic, clock)
        var verdicts: [CallMicGate.Verdict] = []
        g.afterAnswer { verdicts.append($0) }
        mic.answer(false)
        #expect(verdicts == [.refused])
        #expect(clock.live == 0)
    }

    @Test func aPromptNobodyAnswersWithinAMinuteEndsTheCall() {
        let mic = FakeMic(.undetermined)
        let clock = HandClock()
        let g = gate(mic, clock)
        var verdicts: [CallMicGate.Verdict] = []
        g.afterAnswer { verdicts.append($0) }
        clock.runOut()
        #expect(verdicts == [.unanswered])
        #expect(!g.asking)
        mic.answer(true)
        #expect(verdicts == [.unanswered], "a grant after the call has ended opens nothing")
    }

    @Test func aCallThatIsOverBeforeTheCustomerAnswersDecidesNothing() {
        let mic = FakeMic(.undetermined)
        let clock = HandClock()
        let g = gate(mic, clock)
        var verdicts: [CallMicGate.Verdict] = []
        g.afterAnswer { verdicts.append($0) }
        g.cancel()
        #expect(clock.live == 0)
        mic.answer(true)
        clock.runOut()
        #expect(verdicts.isEmpty)
        // The next call is decided by its own prompt: the last one's late answer is not its answer.
        g.afterAnswer { verdicts.append($0) }
        mic.prompts.first?(false)
        #expect(verdicts.isEmpty)
        mic.answer(true)
        #expect(verdicts == [.connect])
    }

    @Test func aPlacedAndAnAnsweredCallFailWithTheSameWords() {
        #expect(CallMicGate.notGranted == "The microphone permission was not granted.")
        #expect(CallMicGate.answerWaitSeconds == 60)
    }
}

@Suite struct CallPushTests {
    @Test func aPushIsReadWithItsVariables() throws {
        let payload: [AnyHashable: Any] = [
            "aps": ["content-available": 1],
            "type": "agent_call",
            "call_id": "c_123",
            "reason": "payment_due",
            "caller_name": "Acme",
            "variables": #"{"name":"Asha","amount":4999,"vip":true,"nested":{"a":1},"gone":null}"#,
        ]
        let call = try CallPush.parse(payload).get()
        #expect(call == GraineIncomingCall(
            callId: "c_123", reason: "payment_due", callerName: "Acme",
            variables: ["name": "Asha", "amount": "4999", "vip": "true"]
        ))
    }

    @Test func onlyTypeAndCallIdAreRequired() throws {
        let call = try CallPush.parse(["type": "agent_call", "call_id": "c1"]).get()
        #expect(call == GraineIncomingCall(callId: "c1"))
    }

    @Test func variablesMayBeAnObjectAndUnreadableOnesAreIgnored() throws {
        let object = try CallPush.parse(["type": "agent_call", "call_id": "c1", "variables": ["plan": "Pro", "n": 2]]).get()
        #expect(object.variables == ["plan": "Pro", "n": "2"])
        let broken = try CallPush.parse(["type": "agent_call", "call_id": "c1", "variables": "{not json"]).get()
        #expect(broken.variables.isEmpty)
    }

    @Test func theKeysMaySitUnderData() throws {
        let call = try CallPush.parse(["aps": [:], "data": ["type": "agent_call", "call_id": "c9", "reason": "kyc"]]).get()
        #expect(call.callId == "c9")
        #expect(call.reason == "kyc")
    }

    @Test func aPushThatIsNotAnAgentCallIsMalformed() {
        #expect(CallPush.parse([:]) == .failure(.notAnAgentCall))
        #expect(CallPush.parse(["type": "chat_message", "call_id": "c1"]) == .failure(.notAnAgentCall))
        #expect(CallPush.parse(["type": "agent_call"]) == .failure(.missingCallId))
        #expect(CallPush.parse(["type": "agent_call", "call_id": "  "]) == .failure(.missingCallId))
    }
}

/*
 * Every push is reported to CallKit FIRST — malformed, busy, duplicate or
 * fine — because iOS stops delivering VoIP pushes to an app that does not.
 */
@Suite struct PushIntakeTests {
    private let good: [AnyHashable: Any] = ["type": "agent_call", "call_id": "c1", "caller_name": "Acme", "reason": "due"]

    @Test func everyPlanStartsByReportingTheCall() {
        let payloads: [[AnyHashable: Any]] = [good, [:], ["type": "agent_call"], ["type": "x", "call_id": "c5"]]
        for payload in payloads {
            for live in [nil, "c1", "c2"] as [String?] {
                let plan = PushIntake.plan(payload, displayName: "Assistant", liveCallId: live)
                guard case .report? = plan.first else {
                    Issue.record("not reported first: \(plan)")
                    continue
                }
            }
        }
    }

    @Test func aGoodPushRingsUnderItsCallersName() {
        let plan = PushIntake.plan(good, displayName: "Assistant", liveCallId: nil)
        #expect(plan == [.report(callerName: "Acme"), .ring(GraineIncomingCall(callId: "c1", reason: "due", callerName: "Acme"))])
    }

    @Test func aMalformedPushIsReportedThenEndedAtOnce() {
        #expect(PushIntake.plan([:], displayName: "Assistant", liveCallId: nil) == [.report(callerName: "Assistant"), .endAtOnce(.failed)])
        // With a call id, the app's server hears what became of it.
        #expect(PushIntake.plan(["type": "x", "call_id": "c5"], displayName: "Assistant", liveCallId: nil) == [
            .report(callerName: "Assistant"),
            .endAtOnce(.failed),
            .outcome(callId: "c5", .failed("The push was not an agent call this SDK can ring.")),
        ])
    }

    @Test func aPushWhileBusyIsReportedEndedAndMissed() {
        #expect(PushIntake.plan(good, displayName: "Assistant", liveCallId: "c0") == [
            .report(callerName: "Acme"),
            .endAtOnce(.unanswered),
            .outcome(callId: "c1", .missed),
        ])
    }

    @Test func theSameCallPushedTwiceRingsOnce() {
        #expect(PushIntake.plan(good, displayName: "Assistant", liveCallId: "c1") == [.report(callerName: "Acme"), .endAtOnce(.unanswered)])
    }
}

@Suite struct NativeCallOutcomeWireTests {
    @Test func everyOutcomeHasTheWordAndroidReportsForIt() {
        #expect(GraineCallOutcome.answered.wire == "answered")
        #expect(GraineCallOutcome.declined.wire == "declined")
        #expect(GraineCallOutcome.missed.wire == "missed")
        #expect(GraineCallOutcome.ended(.remote).wire == "ended")
        #expect(GraineCallOutcome.ended(.remote).endReason == .remote)
        #expect(GraineCallOutcome.failed("no network").wire == "failed")
        #expect(GraineCallOutcome.failed("no network").error == "no network")
        #expect(GraineCallOutcome.answered.endReason == nil && GraineCallOutcome.answered.error == nil)
    }
}
