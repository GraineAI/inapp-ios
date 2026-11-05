import Testing
@testable import GraineInApp

@Suite struct CallAudioWatchRescueRuleTests {
    @Test func aCallTheyAnsweredIsRescuedAsItAlwaysWas() {
        #expect(CallAudioWatch.rescuesDeactivation(answered: true, hadAudio: true))
        #expect(CallAudioWatch.rescuesDeactivation(answered: true, hadAudio: false))
    }

    @Test func aCallTheyTappedIsRescuedOnlyOnceItHadItsAudio() {
        #expect(CallAudioWatch.rescuesDeactivation(answered: false, hadAudio: true), "its audio was taken back")
        #expect(!CallAudioWatch.rescuesDeactivation(answered: false, hadAudio: false), "the call before's: nothing of this call's was lost")
    }
}
