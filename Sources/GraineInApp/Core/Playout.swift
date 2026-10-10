import Foundation

/**
 * THE PLAYER'S RULES, WITHOUT THE PLAYER — a clock-injected state machine, so
 * the rules that keep a call taking turns are proven on a Mac.
 *
 *   - A run starts only once 150 ms is queued — OR 120 ms have passed with no
 *     new audio (the drain path: the end of a turn never reaches 150 ms, and a
 *     reply shorter than that must still play).
 *   - While a run is going, audio is handed straight on. Once it has run dry,
 *     the next audio refills to 150 ms (or drains) the same way before resuming:
 *     one network hiccup must not become stuttering for the rest of the turn.
 *   - `bufferedSeconds` is exact and lands at ZERO when everything has played.
 *     Mark acks wait on it, and a depth that never returns to zero stops
 *     turn-taking: each turn is acknowledged later than the last until the
 *     agent simply goes quiet.
 *   - `clear()` drops everything queued and unplayed, at once.
 *
 * What has been handed on is accounted on the clock it was handed on: it
 * finishes at `playEnd`, and buffered = what is still held + what is left of
 * the run. The platform player schedules exactly the chunks this returns.
 */
struct PlayoutPolicy {
    /// One piece of agent speech.
    struct Chunk {
        let samples: [Int16]
        let sampleRate: Int

        var seconds: Double { sampleRate > 0 ? Double(samples.count) / Double(sampleRate) : 0 }
    }

    /// Queue this much before a run starts.
    static let startSeconds = 0.15
    /// ...or play what is there once no audio has arrived for this long.
    static let drainAfterSeconds = 0.12
    /// Comparisons on sums of sample durations: equal is equal.
    private static let epsilon = 1e-9

    /// Held back, not yet handed to the player.
    private(set) var pending: [Chunk] = []
    private(set) var pendingSeconds = 0.0
    /// When everything handed to the player will have played, on the injected clock.
    private(set) var playEnd = 0.0
    /// A run is going: new audio is handed straight on.
    private(set) var running = false
    private(set) var lastArrival: Double?

    /**
     * Agent audio arrived. Returns what to hand the player now (possibly
     * nothing — it is being held toward 150 ms).
     */
    mutating func push(_ chunk: Chunk, now: Double) -> [Chunk] {
        settle(now: now)
        lastArrival = now
        if running {
            playEnd = max(playEnd, now) + chunk.seconds
            return [chunk]
        }
        pending.append(chunk)
        pendingSeconds += chunk.seconds
        if pendingSeconds + PlayoutPolicy.epsilon >= PlayoutPolicy.startSeconds { return startRun(now: now) }
        return []
    }

    /// The clock moved: the drain path, when nothing has arrived for 120 ms.
    mutating func tick(now: Double) -> [Chunk] {
        settle(now: now)
        guard !running, !pending.isEmpty, let last = lastArrival,
              now - last + PlayoutPolicy.epsilon >= PlayoutPolicy.drainAfterSeconds else { return [] }
        return startRun(now: now)
    }

    /// When `tick` has something to do, if anything is being held.
    var drainDue: Double? {
        guard !running, !pending.isEmpty, let last = lastArrival else { return nil }
        return last + PlayoutPolicy.drainAfterSeconds
    }

    /// Seconds of agent audio not yet heard. Exactly zero once it all has played.
    func bufferedSeconds(now: Double) -> Double {
        pendingSeconds + max(0, playEnd - now)
    }

    /// The customer interrupted: nothing queued or unplayed survives.
    mutating func clear(now: Double) {
        pending = []
        pendingSeconds = 0
        playEnd = min(playEnd, now)
        running = false
        lastArrival = nil
    }

    /// A run that has played out is over; the next audio refills first.
    private mutating func settle(now: Double) {
        if running && playEnd <= now { running = false }
    }

    private mutating func startRun(now: Double) -> [Chunk] {
        running = true
        var end = max(playEnd, now)
        for chunk in pending { end += chunk.seconds }
        playEnd = end
        let out = pending
        pending = []
        pendingSeconds = 0
        return out
    }
}

/// When a mark is acknowledged: once the audio queued before it has been heard, capped at 10 s.
enum MarkAck {
    /// Seconds to wait; zero means now. An unreadable depth acks now; a runaway one waits the cap.
    static func delay(bufferedSeconds: Double) -> Double {
        if bufferedSeconds.isNaN { return 0 }
        return min(max(0, bufferedSeconds), CallWire.markAckCapSeconds)
    }
}

/**
 * IS THE AGENT SPEAKING — taken from the audio, never from markers.
 *
 * Measured on the production socket: no speech start or end frames arrive, and
 * "<end_of_stream>" ends the TEXT while the audio runs on for seconds. So the
 * agent is speaking from its first audio frame until what was queued has
 * played (buffered ≤ 0.02 s) and no audio arrived for 300 ms. Barge-in and the
 * echo guard both read this.
 */
enum AgentSpeech {
    /// No audio for this long, with the player drained, and the agent has stopped.
    static let tailSeconds = 0.3
    /// Below this the player is drained.
    static let drainedSeconds = 0.02
    /// The echo guard's recency: no agent audio for this long and the customer is always heard.
    static let audibleRecencySeconds = 1.5

    /**
     * The speaking check, run by a timer while the agent is speaking: nil when
     * it has stopped, else how long until the next look (when what is queued
     * should have played, 50 ms to 1 s).
     */
    static func recheck(now: Double, lastAudioAt: Double, bufferedSeconds: Double) -> Double? {
        let quiet = now - lastAudioAt
        if quiet + 1e-9 >= tailSeconds && bufferedSeconds <= drainedSeconds { return nil }
        return min(1.0, max(0.05, bufferedSeconds, tailSeconds - quiet))
    }

    /**
     * "Agent audible", the echo guard's input: within 1.5 s of when the agent
     * audio received so far is due to have been HEARD (its arrival plus what the
     * player held then — `audibleUntil`) AND (the player still holding some OR
     * the agent speaking). Measured from the projected end, not the arrival:
     * production sends a reply far faster than real time (6.3 s of speech in
     * 0.8 s), and "1.5 s since the last frame arrived" let the agent's own voice
     * through as the customer for the seconds still queued. Still fails open: a
     * stalled player cannot move `audibleUntil`.
     */
    static func audible(now: Double, lastAudioAt: Double?, audibleUntil: Double? = nil, bufferedSeconds: Double, speaking: Bool) -> Bool {
        guard let last = lastAudioAt else { return false }
        guard now - max(last, audibleUntil ?? last) <= audibleRecencySeconds else { return false }
        return bufferedSeconds > drainedSeconds || speaking
    }
}
