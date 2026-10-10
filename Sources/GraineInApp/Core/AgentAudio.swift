import Foundation

/*
 * THE AGENT'S VOICE, AS BYTES A SPEAKER CAN PLAY — for the native call engine.
 *
 * The agent's audio frames usually say nothing about themselves: no container,
 * no `format`, no `sample_rate`, just base64. On a voice session today they are
 * headerless PCM16 at 24 kHz (9600-byte frames, 200 ms each); some agents send
 * mu-law at 8000. Read one as the other and the voice comes out at the wrong
 * width and speed — squeaky, broken, and nothing a buffer can fix.
 *
 * So: a declared format is believed. Otherwise both readings are measured and
 * the one with fewer zero crossings wins (speech crosses zero 2–15% of the
 * time, bytes misread approach 50%), and the answer is LATCHED for the rest of
 * the call — but only on a frame loud enough to be evidence, and never on a tie
 * (digital silence reads the same both ways and must decide nothing).
 *
 * A port of the React Native SDK's decodeAgentAudio, held to the vectors in
 * contract/native-calls.json ("mulaw", "decode"). Foundation only.
 */

/// What a stream of agent audio turned out to be. Decided once per call, then held.
struct AgentAudioFormat: Equatable {
    enum Kind: String {
        case mulaw
        case pcm
    }

    let kind: Kind
    let sampleRate: Int
}

/// One decoded frame.
struct DecodedAgentAudio {
    let pcm16: [Int16]
    let sampleRate: Int
    let kind: AgentAudioFormat.Kind
    /// Non-nil once the stream is known. Store it and pass it back as `latched`.
    let latch: AgentAudioFormat?
}

enum AgentAudio {
    /// Headerless PCM on a voice session is 24 kHz (measured on the production socket).
    static let fallbackPcmRate = 24_000

    /**
     * Below this (the rms of the PCM reading) a frame is not evidence. The
     * React Native SDK's CONFIDENT_RMS: silence reads 0 there, real mu-law
     * speech ~17600, real PCM speech thousands.
     */
    static let confidentRms = 500.0

    /// Every mu-law byte, decoded once.
    static let muLawTable: [Int16] = (0...255).map { decodeMuLaw(byte: UInt8($0)) }

    /// ITU-T G.711 mu-law → PCM16, one byte.
    static func decodeMuLaw(byte: UInt8) -> Int16 {
        let bias = 0x84
        let mu = Int(~byte)
        let sign = mu & 0x80
        let exponent = (mu >> 4) & 0x07
        let mantissa = mu & 0x0f
        let t = ((mantissa << 3) + bias) << exponent
        return Int16(sign != 0 ? bias - t : t - bias)
    }

    static func decodeMuLaw(_ bytes: [UInt8]) -> [Int16] {
        bytes.map { muLawTable[Int($0)] }
    }

    /// Little-endian PCM16. An odd trailing byte is a truncated sample: dropped, because playing it would be a click.
    static func decodePcm16(_ bytes: [UInt8]) -> [Int16] {
        let count = bytes.count / 2
        var out = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            out[i] = Int16(bitPattern: UInt16(bytes[2 * i]) | (UInt16(bytes[2 * i + 1]) << 8))
        }
        return out
    }

    /// Fraction of adjacent sample pairs that change sign. Fewer than two samples: 1.
    static func zeroCrossingRate(_ pcm: [Int16]) -> Double {
        if pcm.count < 2 { return 1 }
        var crossings = 0
        for i in 1..<pcm.count where (pcm[i] < 0) != (pcm[i - 1] < 0) {
            crossings += 1
        }
        return Double(crossings) / Double(pcm.count - 1)
    }

    static func rms(_ pcm: [Int16]) -> Double {
        if pcm.isEmpty { return 0 }
        var sum = 0.0
        for s in pcm {
            let d = Double(s)
            sum += d * d
        }
        return (sum / Double(pcm.count)).squareRoot()
    }

    /**
     * Decode one agent audio frame.
     *
     * - Parameters:
     *   - declaredFormat: `meta_info.format`, if the server said one.
     *   - declaredRate: `meta_info.sample_rate`, if the server said one.
     *   - latched: what this call's stream was already decided to be.
     * - Returns: nil for an empty frame.
     */
    static func decode(
        _ bytes: [UInt8],
        declaredFormat: String?,
        declaredRate: Int?,
        latched: AgentAudioFormat?,
        fallbackPcmRate: Int = AgentAudio.fallbackPcmRate
    ) -> DecodedAgentAudio? {
        if bytes.isEmpty { return nil }
        let rate = declaredRate.flatMap { $0 > 0 ? $0 : nil }

        // 1. The server said. Nothing to guess.
        switch declaredFormat?.lowercased() {
        case "mulaw", "ulaw", "g711_ulaw", "pcmu":
            let sampleRate = rate ?? 8_000
            let format = AgentAudioFormat(kind: .mulaw, sampleRate: sampleRate)
            return DecodedAgentAudio(pcm16: decodeMuLaw(bytes), sampleRate: sampleRate, kind: .mulaw, latch: format)
        case "pcm", "linear16", "raw":
            let sampleRate = rate ?? fallbackPcmRate
            let format = AgentAudioFormat(kind: .pcm, sampleRate: sampleRate)
            return DecodedAgentAudio(pcm16: decodePcm16(bytes), sampleRate: sampleRate, kind: .pcm, latch: format)
        default:
            break
        }

        // 2. This stream already answered the question. Do not re-open it.
        if let latched = latched {
            let pcm = latched.kind == .mulaw ? decodeMuLaw(bytes) : decodePcm16(bytes)
            return DecodedAgentAudio(pcm16: pcm, sampleRate: latched.sampleRate, kind: latched.kind, latch: latched)
        }

        // 3. Nothing declared, nothing decided: measure. A tie goes to mu-law.
        let asMuLaw = decodeMuLaw(bytes)
        let asPcm = decodePcm16(bytes)
        let muZcr = zeroCrossingRate(asMuLaw)
        let pcmZcr = zeroCrossingRate(asPcm)
        let muLawWins = muZcr <= pcmZcr
        let kind: AgentAudioFormat.Kind = muLawWins ? .mulaw : .pcm
        let sampleRate = muLawWins ? 8_000 : (rate ?? fallbackPcmRate)

        // Latch only on evidence: the RAW energy (the PCM reading — silence is 0 there, while
        // mu-law byte 0x00 decodes loud) and two readings that actually disagree.
        let confident = rms(asPcm) >= confidentRms && muZcr != pcmZcr
        return DecodedAgentAudio(
            pcm16: muLawWins ? asMuLaw : asPcm,
            sampleRate: sampleRate,
            kind: kind,
            latch: confident ? AgentAudioFormat(kind: kind, sampleRate: sampleRate) : nil
        )
    }
}
