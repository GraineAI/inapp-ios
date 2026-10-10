import Foundation

/**
 * STOPS THE AGENT FROM HEARING ITSELF — the React Native SDK's EchoGuard,
 * line for line, for the native call engine.
 *
 * On a phone the agent's voice comes out two inches from the microphone and
 * some of it comes straight back in. The platform's echo canceller cuts it
 * down; nothing removes it. Sent upstream, that residue is transcribed as the
 * customer, the runtime reads it as a barge-in, and the agent interrupts
 * itself after a word or two — a call that looks broken while every log is
 * clean.
 *
 * A fixed threshold cannot work (the echo's loudness depends on the speaker,
 * the volume and the room), so the guard MEASURES the echo while the agent is
 * audible — the first frames of each utterance are taken as echo by
 * definition, peak not average — and a real interruption must stand well above
 * it, for long enough. The floor never learns from speech, or a talking
 * customer would teach it that their own voice is echo. Held frames are kept
 * in a short ring and flushed ahead of the first frame that passes, so the
 * transcriber never gets a decapitated word.
 *
 * It fails open by construction: with the agent not audible every frame passes.
 * The vectors in contract/native-calls.json ("echoGuard") pin it frame by frame.
 *
 * `Tag` is whatever the caller sends for a frame (the TypeScript passes its
 * base64; the call engine passes the frame's bytes).
 */
struct EchoGuard<Tag> {
    struct Options {
        /// Level must beat the measured echo by this much.
        var overEcho = 2.2
        /// ...and the ambient room by this much.
        var overNoise = 4.0
        /// Absolute floor, so a silent room cannot make the threshold meaningless.
        var minLevel = 0.012
        /// ...and be sustained this long. One transient is not an interruption.
        var sustainMs = 240.0
        /// How much held audio to flush ahead of a confirmed interruption.
        var preRollFrames = 12
        /// Frames at the start of each agent utterance spent measuring its echo.
        var warmupFrames = 10
    }

    let options: Options
    private var echoFloor = 0.0
    private var noiseFloor = 0.0
    private var heldMs = 0.0
    private var preRoll: [Tag] = []
    /// Frames since the agent started being audible.
    private var audibleFrames = 0

    init(options: Options = Options()) {
        self.options = options
    }

    /// The level a frame must reach right now to count as the customer.
    var threshold: Double {
        max(options.minLevel, echoFloor * options.overEcho, noiseFloor * options.overNoise)
    }

    /// True once the level has stood above the threshold long enough to be real.
    var interrupting: Bool {
        heldMs >= options.sustainMs
    }

    /// A new call starts with no idea what its echo sounds like.
    mutating func reset() {
        echoFloor = 0
        noiseFloor = 0
        heldMs = 0
        preRoll = []
        audibleFrames = 0
    }

    /**
     * Decide what to send for one captured frame.
     *
     * - Parameters:
     *   - tag: the frame, as it will be sent
     *   - pcm: the same frame as samples
     *   - agentAudible: is agent audio reaching the speaker right now
     *   - frameMs: how much audio this frame is
     * - Returns: the frames to send, oldest first — empty while it is echo.
     */
    mutating func filter(_ tag: Tag, pcm: [Int16], agentAudible: Bool, frameMs: Double) -> [Tag] {
        var sum = 0
        for s in pcm { sum += abs(Int(s)) }
        let level = pcm.isEmpty ? 0 : Double(sum) / Double(pcm.count) / 32768

        if agentAudible {
            audibleFrames += 1

            if audibleFrames <= options.warmupFrames {
                // Warm-up: this IS the echo. Learn its peak unconditionally; declare nothing yet.
                echoFloor = max(echoFloor, level)
                heldMs = 0
                hold(tag)
                return []
            }

            // Past warm-up only levels at or under the bar may move the floor, so a talking
            // customer never raises it against themselves; it decays when the echo quietens.
            if level > echoFloor && level <= threshold {
                echoFloor = level
            } else {
                echoFloor *= 0.999
            }
            heldMs = level >= threshold ? heldMs + frameMs : 0
        } else {
            noiseFloor = noiseFloor == 0 ? level : noiseFloor * 0.95 + level * 0.05
            heldMs = 0
            audibleFrames = 0
            preRoll = []
            return [tag]
        }

        if level < threshold || !interrupting {
            hold(tag)
            return []
        }

        let out = preRoll.isEmpty ? [tag] : preRoll + [tag]
        preRoll = []
        return out
    }

    private mutating func hold(_ tag: Tag) {
        preRoll.append(tag)
        if preRoll.count > options.preRollFrames { preRoll.removeFirst() }
    }
}
