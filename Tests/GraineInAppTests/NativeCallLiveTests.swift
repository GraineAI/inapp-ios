import Foundation
import Testing
@testable import GraineInApp

/**
 * A REAL CALL WITH A REAL AGENT — opt-in, never in the default run.
 *
 *     GRAINE_LIVE_E2E=1 GRAINE_E2E_KEY=<publishable key> swift test --filter NativeCallLiveTests
 *
 * The native call engine exactly as a phone runs it — the SDK's session,
 * the ticket, the socket, the decoder, the echo guard, the player policy, the
 * mark acks — with the microphone and the speaker replaced: the microphone
 * "speaks" a 16 kHz WAV (`GRAINE_E2E_WAV`, or one `/usr/bin/say` makes), the
 * speaker records the agent and plays out on the policy's clock.
 *
 * It asserts the socket opened, the agent's welcome arrived as audio (PCM at
 * 24 kHz, or mu-law at 8 kHz), its marks were acked at playout, and after the
 * spoken question the agent replied. The key comes from the environment only.
 */
@Suite struct NativeCallLiveTests {
    static var enabled: Bool { ProcessInfo.processInfo.environment["GRAINE_LIVE_E2E"] == "1" }

    @Test(.enabled(if: NativeCallLiveTests.enabled), .timeLimit(.minutes(3)))
    func aCallWithTheAgentAgainstProduction() async throws {
        let env = ProcessInfo.processInfo.environment
        let key = try #require(env["GRAINE_E2E_KEY"].flatMap { $0.isEmpty ? nil : $0 }, "GRAINE_E2E_KEY is not set")
        let question = try LiveWav.question(path: env["GRAINE_E2E_WAV"])
        let log = LiveLog()

        let graine = GraineInApp(config: GraineConfig(baseUrl: "https://" + "www.graine.ai", publishableKey: key, appVersion: "ios-e2e"))
        graine.setScreen(GraineScreen(screen: "e2e_home", title: "Home"))
        let audio = LiveAudio(question: question, log: log)
        let network = RecordingNetwork(log: log)
        let engine = CallEngine(
            setup: CallEngine.Setup(
                publishableKey: key,
                baseUrl: graine.config.baseUrl,
                variables: CallEngine.variables(sdk: graine.currentVariables(), whoCalled: "customer", reason: "sdk_e2e_test", own: [:]),
                contextFrame: { graine.currentContextFrame() },
                session: { done in graine.loadSession(done) },
                runAction: CallEngine.actionRunner(graine)
            ),
            audio: audio,
            network: network,
            scheduler: DispatchCallScheduler(),
            onEvent: { log.event($0) }
        )

        let began = Date()
        engine.start()
        engine.startAudio()

        // The socket opens.
        let opened = await LiveLog.wait(20) { log.transport != nil || log.ending != nil }
        try #require(opened && log.transport != nil, "the socket did not open: \(String(describing: log.ending))")
        print("[e2e] open via \(log.transport!.rawValue) after \(LiveLog.ms(since: began)) ms")

        // The welcome arrives as audio, and is heard to its end.
        let welcomed = await LiveLog.wait(20) { log.audioFrames > 0 }
        try #require(welcomed, "no agent audio arrived")
        print("[e2e] first agent audio after \(LiveLog.ms(since: began)) ms")
        _ = await LiveLog.wait(40) { log.speakingTurns >= 1 && !log.speaking }
        let welcome = log.agentLines.joined(separator: " | ")
        let welcomeFrames = log.audioFrames
        let welcomeSeconds = audio.receivedSeconds
        let welcomeMarks = (received: log.marksReceived, acked: log.marksAcked)
        print("[e2e] welcome: \"\(welcome)\" — \(welcomeFrames) frames, \(String(format: "%.2f", welcomeSeconds)) s of audio, marks \(welcomeMarks.received) in / \(welcomeMarks.acked) acked")

        // The customer asks. The WAV opens with three seconds of silence.
        let asked = Date()
        let speechStarts = Date(timeIntervalSinceNow: 3.0)
        audio.speak()
        let replied = await LiveLog.wait(45) {
            log.textChunks(after: speechStarts) > 0 || log.audioFrames(after: speechStarts) > 0
        }
        // Let the reply finish — its audio heard, its marks acked — and any second turn the
        // server's endpointing splits off ("Hi." answered first, then the question): done once
        // the agent has been quiet for four seconds after the question, within reason.
        let settled = Date(timeIntervalSinceNow: 40)
        var quietSince: Date?
        while Date() < settled {
            let quiet = audio.finishedSpeaking && log.audioFrames(after: speechStarts) > 0 && !log.speaking
            if quiet {
                if quietSince == nil { quietSince = Date() }
                if Date().timeIntervalSince(quietSince!) >= 4 { break }
            } else {
                quietSince = nil
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let replyChunks = log.textChunks(after: speechStarts)
        let replyFrames = log.audioFrames(after: speechStarts)
        print("[e2e] question sent: \(audio.framesSent) mic frames (\(String(format: "%.2f", question.seconds)) s), the customer heard as: \"\(log.customerFinal ?? "(no final transcript)")\"")
        print("[e2e] reply after \(LiveLog.ms(since: asked)) ms: \(replyChunks) text chunks, \(replyFrames) audio frames")
        print("[e2e] agent said: \(log.agentLines.map { "\"\($0)\"" }.joined(separator: " / "))")

        engine.hangUp()
        _ = await LiveLog.wait(5) { log.ending != nil }
        try? await Task.sleep(nanoseconds: 400_000_000)

        let format = log.format
        print("[e2e] agent audio format: \(format.map { "\($0.kind.rawValue) at \($0.sampleRate) Hz" } ?? "never latched"); frame sizes \(log.frameSizes.sorted())")
        print("[e2e] marks: \(log.marksReceived) received, \(log.marksAcked) acked at playout; barge_in sent \(log.sentCount("barge_in")) time(s)")
        print("[e2e] sent: \(log.sentSummary)")
        print("[e2e] received: \(log.receivedSummary)")
        print("[e2e] ended: \(String(describing: log.ending)); total \(LiveLog.ms(since: began)) ms")
        print("[e2e] reply audio: \(String(format: "%.2f", audio.receivedSeconds - welcomeSeconds)) s of speech, arriving \(log.audioArrival(after: speechStarts, from: began))")
        print("[e2e] question speech began at \(String(format: "%.2f", speechStarts.timeIntervalSince(began))) s; timeline:")
        for line in log.timeline(from: began) { print("[e2e]   \(line)") }

        #expect(log.sentCount("init") == 1, "init frame")
        #expect(log.sentCount("app_context") >= 1, "the screen on open")
        #expect(welcomeFrames > 0, "the welcome arrived as audio")
        #expect(format == AgentAudioFormat(kind: .pcm, sampleRate: 24_000) || format == AgentAudioFormat(kind: .mulaw, sampleRate: 8_000))
        #expect(log.marksReceived > 0, "the agent sent marks")
        #expect(log.marksAcked > 0, "marks were acked")
        #expect(log.marksAcked <= log.marksReceived)
        #expect(audio.framesSent > 0, "the microphone went up")
        #expect(replied, "the agent replied to the question")
        #expect(log.ending == .local)
    }
}

// MARK: - The microphone and the speaker, faked

/// The question, as 16 kHz mono PCM16.
struct LiveWav {
    let samples: [Int16]
    var seconds: Double { Double(samples.count) / 16_000 }

    static func question(path: String?) throws -> LiveWav {
        if let path = path, !path.isEmpty { return try read(URL(fileURLWithPath: path)) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("graine-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("q.wav")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", file.path, "--data-format=LEI16@16000", "[[slnc 3000]] Hi. What can you help me with in this app?"]
        try say.run()
        say.waitUntilExit()
        try #require(say.terminationStatus == 0, "say failed")
        return try read(file)
    }

    /// RIFF/WAVE: walk the chunks to "fmt " and "data". 16 kHz mono PCM16 only.
    static func read(_ url: URL) throws -> LiveWav {
        let bytes = [UInt8](try Data(contentsOf: url))
        func u32(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24 }
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        try #require(bytes.count > 12 && String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF", "not a WAV")
        var at = 12
        var format: (channels: Int, rate: Int, bits: Int)?
        while at + 8 <= bytes.count {
            let id = String(decoding: bytes[at..<at + 4], as: UTF8.self)
            let size = u32(at + 4)
            let body = at + 8
            if id == "fmt " {
                format = (u16(body + 2), u32(body + 4), u16(body + 14))
            } else if id == "data" {
                let fmt = try #require(format, "no fmt chunk")
                try #require(fmt.channels == 1 && fmt.rate == 16_000 && fmt.bits == 16, "the WAV must be 16 kHz mono PCM16")
                let end = min(bytes.count, body + size)
                return LiveWav(samples: AgentAudio.decodePcm16(Array(bytes[body..<end])))
            }
            at = body + size + (size & 1)
        }
        throw LiveFailure("no data chunk")
    }
}

struct LiveFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/**
 * The microphone: a 20 ms clock sending silence, then the question, then
 * silence. The speaker: records the agent and plays out on the player
 * policy's clock, so `bufferedSeconds` — and so the mark acks — are what a
 * phone's would be.
 */
final class LiveAudio: CallAudioIO {
    private let lock = NSLock()
    private let question: LiveWav
    private let log: LiveLog
    private let queue = DispatchQueue(label: "graine.e2e.audio")
    private var timer: DispatchSourceTimer?
    private var onFrame: ((Data) -> Void)?
    private var cursor: Int?
    private var policy = PlayoutPolicy()
    private var drain: DispatchWorkItem?
    private(set) var framesSent = 0
    private var received = 0.0

    init(question: LiveWav, log: LiveLog) {
        self.question = question
        self.log = log
    }

    var receivedSeconds: Double { lock.lock(); defer { lock.unlock() }; return received }
    var finishedSpeaking: Bool { lock.lock(); defer { lock.unlock() }; return cursor.map { $0 >= question.samples.count } ?? false }

    /// Start saying the question.
    func speak() {
        lock.lock()
        cursor = 0
        lock.unlock()
    }

    func startCapture(_ onFrame: @escaping (Data) -> Void) throws {
        lock.lock()
        self.onFrame = onFrame
        lock.unlock()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    private func tick() {
        lock.lock()
        var frame = [Int16](repeating: 0, count: CallWire.captureFrameSamples)
        if let at = cursor, at < question.samples.count {
            let end = min(question.samples.count, at + frame.count)
            for i in at..<end { frame[i - at] = question.samples[i] }
            cursor = end
            framesSent += 1
        }
        let deliver = onFrame
        lock.unlock()
        deliver?(frame.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    func play(_ pcm: [Int16], sampleRate: Int) {
        lock.lock()
        defer { lock.unlock() }
        let chunk = PlayoutPolicy.Chunk(samples: pcm, sampleRate: sampleRate)
        received += chunk.seconds
        _ = policy.push(chunk, now: LiveAudio.clock())
        armDrain()
    }

    private func armDrain() {
        drain?.cancel()
        guard let due = policy.drainDue else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            _ = self.policy.tick(now: LiveAudio.clock())
            self.armDrain()
            self.lock.unlock()
        }
        drain = item
        queue.asyncAfter(deadline: .now() + max(0.005, due - LiveAudio.clock()), execute: item)
    }

    func clear() {
        lock.lock()
        policy.clear(now: LiveAudio.clock())
        drain?.cancel()
        lock.unlock()
        log.note("clear")
    }

    func bufferedSeconds() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return policy.bufferedSeconds(now: LiveAudio.clock())
    }

    func stop() {
        timer?.cancel()
        timer = nil
        lock.lock()
        drain?.cancel()
        onFrame = nil
        lock.unlock()
    }

    static func clock() -> Double { ProcessInfo.processInfo.systemUptime }
}

// MARK: - What went over the wire

/// The real network, with every frame noted on the way past.
final class RecordingNetwork: CallNetwork {
    private let real = URLSessionCallNetwork()
    private let log: LiveLog

    init(log: LiveLog) { self.log = log }

    func post(_ url: URL, body: Data, completion: @escaping (Int, Data?) -> Void) {
        real.post(url, body: body) { [log] status, data in
            log.note("ticket \(status)")
            completion(status, data)
        }
    }

    func openSocket(_ url: URL, protocols: [String], events: CallSocketEvents) -> CallSocket {
        log.note("socket \(url.scheme ?? "")://\(url.host ?? "")\(url.path) protocols=\(protocols.count)")
        let log = self.log
        let watched = CallSocketEvents(
            opened: events.opened,
            received: { text in
                log.received(text)
                events.received(text)
            },
            closed: { byServer, detail, code in
                log.note("closed byServer=\(byServer) code=\(code.map(String.init) ?? "-") \(detail ?? "")")
                events.closed(byServer, detail, code)
            }
        )
        return RecordingSocket(real.openSocket(url, protocols: protocols, events: watched), log: log)
    }
}

final class RecordingSocket: CallSocket {
    private let real: CallSocket
    private let log: LiveLog

    init(_ real: CallSocket, log: LiveLog) {
        self.real = real
        self.log = log
    }

    func send(_ text: String) {
        log.sent(text)
        real.send(text)
    }

    func close() { real.close() }
}

/// Everything the call did, thread-safe.
final class LiveLog {
    private let lock = NSLock()
    private var events: [(at: Date, kind: String, detail: String)] = []
    private var sentTypes: [String] = []
    private var receivedTypes: [String] = []
    private var audioTimes: [Date] = []
    private var textTimes: [Date] = []
    private(set) var frameSizes = Set<Int>()
    private var lines: [String] = []
    private var openLine: String?
    private var customer: String?
    private var turns = 0
    private var speakingNow = false
    private var transportValue: CallEngine.Transport?
    private var formatValue: AgentAudioFormat?
    private var endingValue: CallEngine.Ending?
    private var marksIn = 0
    private var marksOut = 0

    func event(_ event: CallEngine.Event) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .opened(let t): transportValue = t
        case .speaking(let s):
            if s && !speakingNow { turns += 1 }
            speakingNow = s
            events.append((Date(), "engine", s ? "agent speaking" : "agent finished (heard)"))
        case .caption(let c):
            if c.role == .agent {
                if c.live { openLine = c.text } else { lines.append(c.text); openLine = nil }
            } else if !c.live {
                customer = c.text
            }
        case .format(let f): formatValue = f
        case .ended(let e): endingValue = e
        case .reconnecting, .level, .row, .audio: break
        }
    }

    func sent(_ text: String) {
        let type = JSON.string(JSON.object(from: text)?["type"])
        lock.lock()
        sentTypes.append(type)
        if type == "mark" { marksOut += 1 }
        if type == "barge_in" || type == "stop" || type == "init" { events.append((Date(), "sent", type)) }
        if type == "audio" && sentTypes.filter({ $0 == "audio" }).count == 1 { events.append((Date(), "sent", "first microphone frame")) }
        lock.unlock()
    }

    func received(_ text: String) {
        let o = JSON.object(from: text)
        let type = JSON.string(o?["type"])
        lock.lock()
        receivedTypes.append(type)
        let now = Date()
        switch type {
        case "audio":
            if let last = audioTimes.last, now.timeIntervalSince(last) < 1.0 {
                // part of the same burst
            } else {
                events.append((now, "received", "agent audio begins"))
            }
            audioTimes.append(now)
            if let data = o?["data"] as? String { frameSizes.insert(CallWire.base64Bytes(data)?.count ?? -1) }
        case "text":
            let chunk = CallWire.readAgentChunk(JSON.string(o?["data"]))
            if !chunk.text.isEmpty { textTimes.append(now) }
            events.append((now, "received", "text \"\(JSON.string(o?["data"]))\""))
        case "mark":
            marksIn += 1
        case "clear", "interruption", "transcript", "interim_transcript_received":
            events.append((now, "received", type + (o?["data"] != nil ? " \"\(JSON.string(o?["data"]))\"" : "")))
        default:
            break
        }
        lock.unlock()
    }

    func note(_ detail: String) {
        lock.lock()
        events.append((Date(), "note", detail))
        lock.unlock()
    }

    var transport: CallEngine.Transport? { lock.lock(); defer { lock.unlock() }; return transportValue }
    var format: AgentAudioFormat? { lock.lock(); defer { lock.unlock() }; return formatValue }
    var ending: CallEngine.Ending? { lock.lock(); defer { lock.unlock() }; return endingValue }
    var speaking: Bool { lock.lock(); defer { lock.unlock() }; return speakingNow }
    var speakingTurns: Int { lock.lock(); defer { lock.unlock() }; return turns }
    var audioFrames: Int { lock.lock(); defer { lock.unlock() }; return audioTimes.count }
    var marksReceived: Int { lock.lock(); defer { lock.unlock() }; return marksIn }
    var marksAcked: Int { lock.lock(); defer { lock.unlock() }; return marksOut }
    var customerFinal: String? { lock.lock(); defer { lock.unlock() }; return customer }
    var agentLines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return (lines + [openLine].compactMap { $0 }).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    func audioFrames(after: Date) -> Int { lock.lock(); defer { lock.unlock() }; return audioTimes.filter { $0 > after }.count }

    /// When the agent audio after `after` started and stopped ARRIVING (not playing), from `start`.
    func audioArrival(after: Date, from start: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        let times = audioTimes.filter { $0 > after }
        guard let first = times.first, let last = times.last else { return "none" }
        return String(format: "%.2f s – %.2f s", first.timeIntervalSince(start), last.timeIntervalSince(start))
    }
    func textChunks(after: Date) -> Int { lock.lock(); defer { lock.unlock() }; return textTimes.filter { $0 > after }.count }
    func sentCount(_ type: String) -> Int { lock.lock(); defer { lock.unlock() }; return sentTypes.filter { $0 == type }.count }

    /// What happened when, from `start`.
    func timeline(from start: Date) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return events.map { String(format: "%6.2f s  %@ %@", $0.at.timeIntervalSince(start), $0.kind, $0.detail) }
    }

    var sentSummary: String { lock.lock(); defer { lock.unlock() }; return LiveLog.histogram(sentTypes) }
    var receivedSummary: String { lock.lock(); defer { lock.unlock() }; return LiveLog.histogram(receivedTypes) }

    static func histogram(_ types: [String]) -> String {
        var counts: [String: Int] = [:]
        for t in types { counts[t, default: 0] += 1 }
        return counts.keys.sorted().map { "\($0)×\(counts[$0]!)" }.joined(separator: " ")
    }

    static func ms(since: Date) -> Int { Int(Date().timeIntervalSince(since) * 1_000) }

    /// Poll until `condition`, or `seconds` pass. True when it held.
    static func wait(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }
}
