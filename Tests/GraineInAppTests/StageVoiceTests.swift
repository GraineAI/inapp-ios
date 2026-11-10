#if os(iOS)
import Foundation
import Testing
@testable import GraineInApp

/*
 * THE FACE STAGE READS THE CALL AS THE CUSTOMER HAS IT — driven by the page's
 * own messages. A misconfiguration the call survived (`not_configured`: the
 * call carries on over the other transport, and `voice.error` keeps saying so
 * for the developer) never turns a live call into "Couldn’t connect" with no
 * End button; a call that really could not start still shows as failed; and a
 * call taken down mid-recovery leaves no clock behind for the next one. Runs
 * on an iOS simulator with AvatarLayeringTests.
 */
@MainActor
@Suite(.serialized) struct StageVoiceTests {
    private func graine() -> GraineInApp {
        GraineInApp(config: GraineConfig(baseUrl: "https://example.invalid", publishableKey: "pk_test"))
    }

    private let live = #"{"type":"graine:call","connected":true,"connecting":false}"#
    private let misconfigured = #"{"type":"graine:transport","transport":"ws","requested":"rtc","reason":"not_configured","message":"WebRTC is not set up for this agent"}"#

    @Test func aMisconfigurationTheCallSurvivedNeverTakesItsEndButtonAway() {
        let graine = graine()
        defer { withExtendedLifetime(graine) {} }
        let voice = graine.voice
        // The page loaded (until it says so, a call reads as still connecting).
        voice.receiveForTests(#"{"type":"graine:ready"}"#)
        voice.receiveForTests(live)
        voice.receiveForTests(misconfigured)
        // The developer still hears it, as before.
        #expect(voice.error == "WebRTC is not set up for this agent")
        #expect(voice.status == .failed)
        // The stage keeps the call.
        #expect(voice.stageStatus == .listening)
        graine.stage.recompute()
        let on = graine.stage.state
        #expect(on.call == .voice)
        #expect(on.phase == .live)
        #expect(on.live)
        #expect(on.status == "")
        #expect(on.shows(.end) && on.canUse(.end), "a call the customer is on can always be hung up")
        #expect(!on.shows(.call))

        // The call comes back from a drop, then ends: an end, never "Couldn’t connect".
        voice.receiveForTests(#"{"type":"graine:reconnecting","active":true}"#)
        #expect(voice.stageStatus == .reconnecting)
        voice.receiveForTests(live)
        voice.receiveForTests(#"{"type":"graine:ended"}"#)
        #expect(voice.stageStatus == .ended)
        graine.stage.recompute()
        #expect(graine.stage.state.phase == .ended)
        #expect(graine.stage.state.status == "Call ended")
        #expect(graine.stage.state.shows(.call))
    }

    @Test func aCallThatCouldNotStartStillShowsAsFailed() {
        let graine = graine()
        defer { withExtendedLifetime(graine) {} }
        let voice = graine.voice
        voice.receiveForTests(#"{"type":"graine:mic-denied","reason":"denied"}"#)
        #expect(voice.stageStatus == .failed)
        graine.stage.recompute()
        #expect(graine.stage.state.phase == .failed)
        #expect(graine.stage.state.status == "Couldn’t connect")
        #expect(graine.stage.state.shows(.call))
    }

    /// The same as Android's (GraineVoice.setSpeaker there): the choice is the call's.
    @Test func theLoudspeakerChoiceIsTheCallsAndTheNextStartsOnTheLoudspeaker() {
        let graine = graine()
        defer { withExtendedLifetime(graine) {} }
        let voice = graine.voice
        #expect(voice.speaker, "a call starts on the loudspeaker")
        voice.setSpeaker(false)
        #expect(!voice.speaker, "chosen before the call: it waits for it")
        voice.receiveForTests(#"{"type":"graine:call","connected":false,"connecting":true}"#)
        voice.receiveForTests(live)
        voice.receiveForTests(#"{"type":"graine:reconnecting","active":true}"#)
        voice.receiveForTests(live)
        #expect(!voice.speaker, "a recovery inside the call keeps it")
        voice.receiveForTests(#"{"type":"graine:ended"}"#)
        #expect(voice.speaker, "the call is over: the next one starts on the loudspeaker")
    }

    @Test func aCallTakenDownMidRecoveryLeavesNoClockForTheNext() {
        let graine = graine()
        defer { withExtendedLifetime(graine) {} }
        let voice = graine.voice
        voice.receiveForTests(live)
        #expect(voice.startedAt != nil)
        voice.receiveForTests(#"{"type":"graine:reconnecting","active":true}"#)
        voice.receiveForTests(#"{"type":"graine:call","connected":false,"connecting":false}"#)
        #expect(voice.startedAt != nil, "a recovery keeps the clock")
        voice.detach()
        #expect(!voice.reconnecting)
        #expect(voice.startedAt == nil, "nothing is coming back: the next call's clock starts at 0:00")
    }
}
#endif
