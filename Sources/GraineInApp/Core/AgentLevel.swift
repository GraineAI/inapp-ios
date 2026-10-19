import Foundation

/*
 * THE AGENT'S VOICE LEVEL — what the call screen's visualiser moves with.
 *
 * Measured on either road: on WebRTC the receiver's own level, five readings
 * a second (GraineInAppRTC); on the voice socket the audio decoded for the
 * speaker, the RMS of every 100 ms of it, due when the speaker reaches it
 * (HeardLevels) — the server sends a reply far faster than it is spoken, so a
 * level read on arrival would run seconds ahead of the voice and stop before
 * it does. GraineCalls eases what arrives into `agentLevel` ten times a second
 * (AgentLevelEasing): up over 60 ms, down over 240 ms. Foundation only.
 */

/// The voice socket's levels: each window of decoded agent audio, due when it is heard.
struct HeardLevels {
    /// One level per this much audio, and at most one report per this long: about ten a second.
    static let windowSeconds = 0.1
    /// Due times are sums of sample durations; a microsecond early is on time.
    private static let tolerance = 1e-6

    /// (due at, level), in the order they play.
    private var queue: [(at: Double, level: Double)] = []

    var isEmpty: Bool { queue.isEmpty }

    /// `pcm` at `sampleRate`, heard from `startsAt` on: one level per window, each due when it starts to play. `silent`: every window 0.
    mutating func add(_ pcm: [Int16], sampleRate: Int, startsAt: Double, silent: Bool = false) {
        guard !pcm.isEmpty, sampleRate > 0 else { return }
        let window = max(1, Int(Double(sampleRate) * Self.windowSeconds))
        var from = 0
        var at = startsAt
        while from < pcm.count {
            let to = min(pcm.count, from + window)
            queue.append((at, silent ? 0 : Self.rms(pcm, from: from, to: to)))
            at += Double(to - from) / Double(sampleRate)
            from = to
        }
    }

    /// Takes every level due by `now` and returns the latest of them; nil when none is due yet.
    mutating func due(_ now: Double) -> Double? {
        var taken = 0
        while taken < queue.count, queue[taken].at <= now + Self.tolerance { taken += 1 }
        guard taken > 0 else { return nil }
        let latest = queue[taken - 1].level
        queue.removeFirst(taken)
        return latest
    }

    /// What was queued will not be heard (the customer interrupted).
    mutating func clear() {
        queue = []
    }

    /// The root mean square of `pcm[from..<to]`, as a share of full scale (0–1).
    static func rms(_ pcm: [Int16], from: Int = 0, to: Int? = nil) -> Double {
        let end = min(to ?? pcm.count, pcm.count)
        guard end > from, from >= 0 else { return 0 }
        var sum = 0.0
        for i in from..<end {
            let d = Double(pcm[i])
            sum += d * d
        }
        return min(1, (sum / Double(end - from)).squareRoot() / 32_768)
    }
}

/// `GraineCalls.agentLevel`: eased toward the last level heard, one step every `stepSeconds`.
struct AgentLevelEasing {
    /// Ten steps a second.
    static let stepSeconds = 0.1
    /// Closer than this to the level heard, it is that level, and the steps stop.
    static let settleWithin = 0.001

    /// What is drawn now, 0–1, to three decimals.
    private(set) var value = 0.0
    /// The last level heard, 0–1.
    private(set) var target = 0.0
    /// A level arrived on this call: the screen draws it rather than the speaking movement.
    private(set) var heard = false

    /// Nothing left to move: no more steps until a level arrives.
    var settled: Bool { value == target }

    mutating func hear(_ level: Double) {
        target = level.isFinite ? min(1, max(0, level)) : 0
        heard = true
    }

    /// One step, `dtMs` after the last: returns the value to draw.
    mutating func step(dtMs: Double) -> Double {
        let next = CallScreen.smoothLevel(value, toward: target, dtMs: min(1_000, max(0, dtMs)))
        value = abs(next - target) < Self.settleWithin ? target : (next * 1_000).rounded() / 1_000
        return value
    }

    /// The call is over.
    mutating func reset() {
        self = AgentLevelEasing()
    }
}
