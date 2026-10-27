#if os(iOS)
import AVFoundation
import Foundation

/**
 * THE CALL'S AUDIO ON iOS — the app's own process, the platform's echo
 * canceller.
 *
 * AVAudioEngine with voice processing on the input (echo cancellation, noise
 * suppression, gain — the same unit a phone call uses), which the SDK's echo
 * guard then runs on top of, not instead of:
 *
 *   microphone  the input node's tap, at whatever the hardware gives, converted
 *               to 16 kHz mono PCM16 and cut into 20 ms frames
 *   speaker     an AVAudioPlayerNode at the agent's rate (24 kHz today) into the
 *               main mixer, which resamples; buffers are handed to it exactly
 *               as PlayoutPolicy says, and `bufferedSeconds` is the policy's
 *
 * It never touches the session's activation: under CallKit the system activates
 * it, and `startCapture` is called from `provider(_:didActivate:)`. Agent audio
 * that arrives before then (the welcome, usually) is held and played on start.
 * An interruption pauses the engine and its end restarts it; a route change
 * rebuilds it; a restart that fails ends the call (`onFailure`). A rebuild
 * plays again what had not been heard when the old engine stopped
 * (PlayoutPolicy.takeUnplayed): a headset connecting as the greeting starts
 * never cuts it. A CallKit deactivation while the call goes on suspends it
 * (`suspend`): what was not heard is held and plays when the audio is back.
 */
final class GraineCallAudioIO: CallAudioIO {
    /// The audio cannot go on (an engine that will not restart). The owner ends the call.
    var onFailure: ((String) -> Void)?

    /// The microphone's frames, as the socket takes them.
    static let captureFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: Double(CallWire.captureRate), channels: 1, interleaved: true
    )!

    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var playerRate = AgentAudio.fallbackPcmRate
    private var policy = PlayoutPolicy()
    private var running = false
    /// Agent audio that arrived before the audio was handed over.
    private var early: [PlayoutPolicy.Chunk] = []
    private var earlySeconds = 0.0
    private var drainItem: DispatchWorkItem?
    private let timers = DispatchQueue(label: "ai.graine.calls.playout", qos: .userInitiated)
    private var observers: [NSObjectProtocol] = []
    /// Where the microphone's frames go. Each engine's tap gets its own converter carrying it.
    private var onFrame: ((Data) -> Void)?
    /// The most agent audio held before the audio session is handed over.
    static let earlyCapSeconds = 20.0
    /// When the system interrupted the audio (nothing plays from then until it ends): what the rebuild at its end plays again.
    private var interruptedAt: Double?

    deinit {
        for token in observers { NotificationCenter.default.removeObserver(token) }
    }

    // MARK: - CallAudioIO

    func startCapture(_ onFrame: @escaping (Data) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }
        self.onFrame = onFrame
        try build()
        running = true
        let now = Self.clock()
        let held = early
        early = []
        earlySeconds = 0
        for chunk in held { hand(policy.push(chunk, now: now)) }
        armDrain()
        observe()
    }

    func play(_ pcm: [Int16], sampleRate: Int) {
        guard !pcm.isEmpty, sampleRate > 0 else { return }
        let chunk = PlayoutPolicy.Chunk(samples: pcm, sampleRate: sampleRate)
        lock.lock()
        defer { lock.unlock() }
        guard running else {
            // Held for the start, but not without end: a session that never activates must not grow without bound.
            early.append(chunk)
            earlySeconds += chunk.seconds
            while earlySeconds > GraineCallAudioIO.earlyCapSeconds, early.count > 1 {
                earlySeconds -= early.removeFirst().seconds
            }
            return
        }
        hand(policy.push(chunk, now: Self.clock()))
        armDrain()
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        policy.clear(now: Self.clock())
        early = []
        earlySeconds = 0
        drainItem?.cancel()
        drainItem = nil
        // stop() drops every scheduled buffer at once; play() readies the node for the next turn.
        if let player = player {
            player.stop()
            if engine?.isRunning == true { player.play() }
        }
    }

    func bufferedSeconds() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return running ? policy.bufferedSeconds(now: Self.clock()) : earlySeconds
    }

    /**
     * CallKit took the audio back while the call goes on: the engine and the microphone are released, and the agent's
     * audio not yet heard — from where it stopped (PlayoutPolicy.takeUnplayed) — is held, ahead of anything held
     * already, to play when `startCapture` runs again. Audio that arrives meanwhile is held too, within the same cap.
     */
    func suspend() {
        lock.lock()
        let unheard = running ? policy.takeUnplayed(at: Self.clock()) : []
        let oldEngine = engine
        let oldPlayer = player
        engine = nil
        player = nil
        running = false
        drainItem?.cancel()
        drainItem = nil
        policy.clear(now: Self.clock())
        early = unheard + early
        earlySeconds = early.reduce(0) { $0 + $1.seconds }
        while earlySeconds > GraineCallAudioIO.earlyCapSeconds, early.count > 1 {
            earlySeconds -= early.removeLast().seconds
        }
        interruptedAt = nil
        let tokens = observers
        observers = []
        onFrame = nil
        lock.unlock()
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        oldEngine?.inputNode.removeTap(onBus: 0)
        oldPlayer?.stop()
        oldEngine?.stop()
    }

    func stop() {
        lock.lock()
        let oldEngine = engine
        let oldPlayer = player
        engine = nil
        player = nil
        running = false
        drainItem?.cancel()
        drainItem = nil
        policy.clear(now: Self.clock())
        early = []
        earlySeconds = 0
        interruptedAt = nil
        let tokens = observers
        observers = []
        onFrame = nil
        lock.unlock()
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        oldEngine?.inputNode.removeTap(onBus: 0)
        oldPlayer?.stop()
        oldEngine?.stop()
    }

    // MARK: - The engine

    private struct AudioError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// A fresh engine, running. Lock held.
    private func build() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // The platform's echo canceller: on before the engine starts, never after.
        try input.setVoiceProcessingEnabled(true)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioError(message: "No microphone is available for the call.")
        }
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: Self.playbackFormat(playerRate))
        // A fresh converter per engine: a tap still finishing on the old one never shares its state.
        let converter = CaptureConverter(deliver: onFrame)
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            converter.convert(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        player.play()
        self.engine = engine
        self.player = player
    }

    /// Hand the player what the policy released. Lock held.
    private func hand(_ chunks: [PlayoutPolicy.Chunk]) {
        guard !chunks.isEmpty, let engine = engine, let player = player else { return }
        for chunk in chunks {
            if chunk.sampleRate != playerRate {
                // A stream at another rate (mu-law at 8 kHz): the player is reconnected at it, the mixer resamples.
                player.stop()
                engine.disconnectNodeOutput(player)
                engine.connect(player, to: engine.mainMixerNode, format: Self.playbackFormat(chunk.sampleRate))
                playerRate = chunk.sampleRate
            }
            guard let buffer = Self.buffer(chunk) else { continue }
            player.scheduleBuffer(buffer, completionHandler: nil)
        }
        if engine.isRunning && !player.isPlaying { player.play() }
    }

    /// The drain path: held audio plays once nothing new has arrived for 120 ms. Lock held.
    private func armDrain() {
        drainItem?.cancel()
        drainItem = nil
        guard let due = policy.drainDue else { return }
        let item = DispatchWorkItem { [weak self] in self?.drain() }
        drainItem = item
        timers.asyncAfter(deadline: .now() + max(0.005, due - Self.clock()), execute: item)
    }

    private func drain() {
        lock.lock()
        defer { lock.unlock() }
        drainItem = nil
        guard running else { return }
        hand(policy.tick(now: Self.clock()))
        armDrain()
    }

    // MARK: - Interruptions and route changes

    /// Every notification is handled on our own queue, never on the thread that posted it (which may hold the engine).
    private func observe() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] note in
            let changed = note.object as AnyObject?
            // The engine stopped here: what had not been heard by now plays on the rebuilt one.
            let at = GraineCallAudioIO.clock()
            self?.timers.async {
                guard let self = self else { return }
                self.lock.lock()
                let ours = changed === self.engine
                self.lock.unlock()
                // The engine stopped itself (a new route, a new format): rebuild it on the new hardware.
                if ours { self.rebuild(since: at) }
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: nil
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                // The system has paused the engine; nothing plays until it ends — remembered for the rebuild then.
                let at = GraineCallAudioIO.clock()
                self?.timers.async {
                    guard let self = self else { return }
                    self.lock.lock()
                    if self.interruptedAt == nil { self.interruptedAt = at }
                    self.lock.unlock()
                }
            case .ended:
                self?.timers.async {
                    guard let self = self else { return }
                    self.lock.lock()
                    let since = self.interruptedAt
                    self.interruptedAt = nil
                    self.lock.unlock()
                    self.rebuild(since: since)
                }
            @unknown default:
                break
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil
        ) { [weak self] _ in
            let at = GraineCallAudioIO.clock()
            self?.timers.async { self?.rebuild(since: at) }
        })
    }

    /**
     * Tear the engine down and build it again, the call going on; fails the call if it cannot. What had not been
     * heard by `at` — when the old engine stopped (now, without one) — is played again on the new engine, from where
     * it stopped: the agent's words, the greeting above all, are never cut by a route change.
     */
    private func rebuild(since at: Double? = nil) {
        lock.lock()
        guard running else {
            lock.unlock()
            return
        }
        if let old = engine {
            old.inputNode.removeTap(onBus: 0)
            player?.stop()
            old.stop()
        }
        engine = nil
        player = nil
        let unheard = policy.takeUnplayed(at: min(at ?? Self.clock(), Self.clock()))
        drainItem?.cancel()
        drainItem = nil
        var failure: String?
        do {
            try build()
            let now = Self.clock()
            for chunk in unheard { hand(policy.push(chunk, now: now)) }
            armDrain()
        } catch {
            running = false
            failure = "The call's audio could not restart: \(GraineInApp.describe(error))"
        }
        let fail = onFailure
        lock.unlock()
        if let failure = failure { fail?(failure) }
    }

    // MARK: - Helpers

    static func clock() -> Double {
        ProcessInfo.processInfo.systemUptime
    }

    static func playbackFormat(_ rate: Int) -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1)!
    }

    /// PCM16 → the player's mono float buffer.
    static func buffer(_ chunk: PlayoutPolicy.Chunk) -> AVAudioPCMBuffer? {
        let format = playbackFormat(chunk.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(chunk.samples.count)
        chunk.samples.withUnsafeBufferPointer { source in
            for i in 0..<source.count { channel[i] = Float(source[i]) / 32_768 }
        }
        return buffer
    }
}

/**
 * The input tap's buffers → 16 kHz mono PCM16 → 20 ms frames. One per engine,
 * touched on its tap's thread only.
 */
private final class CaptureConverter {
    private let deliver: ((Data) -> Void)?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var carry: [Int16] = []

    init(deliver: ((Data) -> Void)?) {
        self.deliver = deliver
    }

    func convert(_ buffer: AVAudioPCMBuffer) {
        if converter == nil || inputFormat != buffer.format {
            inputFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: GraineCallAudioIO.captureFormat)
            // Voice processing can report extra channels; the processed voice is the first.
            if buffer.format.channelCount > 1 { converter?.channelMap = [0] }
        }
        guard let converter = converter, buffer.frameLength > 0 else { return }
        let ratio = GraineCallAudioIO.captureFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: GraineCallAudioIO.captureFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        // One input per call, then "no data now" — never end-of-stream, which would reset the resampler.
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0, let samples = out.int16ChannelData?[0] else { return }
        carry.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(out.frameLength)))
        let size = CallWire.captureFrameSamples
        var start = 0
        while carry.count - start >= size {
            let frame = carry[start..<start + size]
            start += size
            let data = frame.withUnsafeBufferPointer { Data(buffer: $0) }
            deliver?(data)
        }
        if start > 0 { carry.removeFirst(start) }
    }
}
#endif
