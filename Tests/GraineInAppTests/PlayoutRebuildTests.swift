import Foundation
import Testing
@testable import GraineInApp

/*
 * A ROUTE CHANGE NEVER CUTS THE AGENT'S WORDS (the voice socket's player).
 * A Bluetooth headset or a car kit connecting as the greeting starts makes iOS
 * stop the audio engine for the new hardware; GraineCallAudioIO rebuilds it.
 * The rebuild used to drop everything queued — the greeting with it. Now
 * PlayoutPolicy.takeUnplayed hands back what had not been heard when the old
 * engine stopped, the chunk playing then from the sample it had reached, and
 * the new engine plays it: never cut, never repeated.
 */
@Suite struct PlayoutRebuildTests {
    /// `ms` of agent audio at 24 kHz whose samples count up from `from`, so a test can tell exactly which played.
    private func chunk(ms: Int, from: Int = 0, rate: Int = 24_000) -> PlayoutPolicy.Chunk {
        let count = rate * ms / 1_000
        return PlayoutPolicy.Chunk(samples: (0..<count).map { Int16(truncatingIfNeeded: from + $0) }, sampleRate: rate)
    }

    @Test func aGreetingCutMidwayByARebuildIsHandedBackFromWhereItStopped() throws {
        var p = PlayoutPolicy()
        let greeting = chunk(ms: 2_000)
        #expect(p.push(greeting, now: 0).count == 1, "2 s queued: the run starts at once")
        let next = chunk(ms: 500, from: 48_000)
        #expect(p.push(next, now: 0.1).count == 1, "handed straight on, after the greeting")
        // The headset connects 0.75 s into the greeting: the engine stops there.
        let left = p.takeUnplayed(at: 0.75)
        #expect(left.count == 2)
        let rest = try #require(left.first)
        #expect(rest.samples.first == Int16(truncatingIfNeeded: 18_000), "from the sample it had reached, nothing heard twice")
        #expect(rest.samples.count == 48_000 - 18_000, "and nothing of it lost")
        #expect(left[1].samples == next.samples, "what came after it, whole")
        #expect(p.bufferedSeconds(now: 0.75) == 0 && p.pending.isEmpty && p.handed.isEmpty && !p.running, "emptied as clear empties it")
    }

    @Test func handedBackItPlaysOnTheNewEngineAsMuchAsWasStillToHear() {
        var p = PlayoutPolicy()
        _ = p.push(chunk(ms: 2_000), now: 0)
        let before = p.bufferedSeconds(now: 0.75)
        let left = p.takeUnplayed(at: 0.75)
        var handedAgain: [PlayoutPolicy.Chunk] = []
        for piece in left { handedAgain += p.push(piece, now: 0.8) }
        #expect(abs(p.bufferedSeconds(now: 0.8) - before) < 1e-9, "the rebuilt player holds exactly what was still to hear")
        #expect(handedAgain.count == left.count, "over 150 ms: played at once")
    }

    @Test func audioStillHeldTowardTheRunIsHandedBackToo() {
        var p = PlayoutPolicy()
        #expect(p.push(chunk(ms: 100), now: 0).isEmpty, "held toward 150 ms")
        let left = p.takeUnplayed(at: 0.05)
        #expect(left.count == 1 && left[0].samples.count == 2_400)
    }

    @Test func whatPlayedOutIsNeverPlayedAgain() {
        var p = PlayoutPolicy()
        _ = p.push(chunk(ms: 200), now: 0)
        #expect(p.takeUnplayed(at: 0.5).isEmpty, "the whole chunk had played")
        _ = p.push(chunk(ms: 200), now: 1)
        _ = p.push(chunk(ms: 200), now: 5)         // the first one played out long ago: forgotten
        #expect(p.handed.count == 1, "only what may still be playing is kept")
    }

    @Test func aBargeInStillDropsEverything() {
        var p = PlayoutPolicy()
        _ = p.push(chunk(ms: 2_000), now: 0)
        p.clear(now: 0.5)
        #expect(p.takeUnplayed(at: 0.6).isEmpty, "the customer interrupted: nothing of it survives")
    }
}
