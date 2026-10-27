import Foundation
import Testing
@testable import GraineInApp

/*
 * What the native call tests stand on: the vectors (read IN ORDER — the
 * context token and the ticket's twelve keys depend on a JavaScript object's
 * key order, which JSONSerialization does not keep), a clock the test moves by
 * hand, and stand-ins for the socket, the network and the audio.
 */

// MARK: - The vectors, in order

/// A JSON value that remembers its keys' order.
indirect enum OrderedJSON {
    case string(String)
    case number(String)
    case bool(Bool)
    case null
    case array([OrderedJSON])
    case object([(String, OrderedJSON)])

    subscript(key: String) -> OrderedJSON? {
        guard case .object(let fields) = self else { return nil }
        return fields.first { $0.0 == key }?.1
    }

    var array: [OrderedJSON]? {
        if case .array(let items) = self { return items }
        return nil
    }

    var fields: [(String, OrderedJSON)]? {
        if case .object(let fields) = self { return fields }
        return nil
    }

    var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    var double: Double? {
        if case .number(let text) = self { return Double(text) }
        return nil
    }

    var int: Int? {
        if case .number(let text) = self { return Int(text) ?? Double(text).map { Int($0) } }
        return nil
    }

    /// As Foundation would hold it: String, Int or Double, Bool, nil for null, dictionaries and arrays.
    var foundation: Any? {
        switch self {
        case .string(let s): return s
        case .number(let text):
            if !text.contains(where: { ".eE".contains($0) }), let i = Int(text) { return i }
            return Double(text)
        case .bool(let b): return b
        case .null: return nil
        case .array(let items): return items.map { $0.foundation as Any }
        case .object(let fields):
            var out: [String: Any] = [:]
            for (k, v) in fields { out[k] = v.foundation ?? NSNull() }
            return out
        }
    }

    /// An object's entries as the SDK's ordered variables take them.
    var orderedPairs: [(String, Any?)] {
        (fields ?? []).map { ($0.0, $0.1.foundation) }
    }

    struct ParseError: Error, CustomStringConvertible {
        let at: Int
        var description: String { "JSON parse error at scalar \(at)" }
    }

    static func parse(_ text: String) throws -> OrderedJSON {
        var parser = Parser(scalars: Array(text.unicodeScalars))
        let value = try parser.value()
        parser.skipSpace()
        guard parser.index == parser.scalars.count else { throw ParseError(at: parser.index) }
        return value
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var index = 0

        mutating func skipSpace() {
            while index < scalars.count, [" ", "\n", "\r", "\t"].contains(scalars[index]) { index += 1 }
        }

        mutating func value() throws -> OrderedJSON {
            skipSpace()
            guard index < scalars.count else { throw ParseError(at: index) }
            switch scalars[index] {
            case "{":
                index += 1
                var fields: [(String, OrderedJSON)] = []
                skipSpace()
                if index < scalars.count, scalars[index] == "}" { index += 1; return .object(fields) }
                while true {
                    skipSpace()
                    let key = try string()
                    skipSpace()
                    guard index < scalars.count, scalars[index] == ":" else { throw ParseError(at: index) }
                    index += 1
                    fields.append((key, try value()))
                    skipSpace()
                    guard index < scalars.count else { throw ParseError(at: index) }
                    if scalars[index] == "," { index += 1; continue }
                    if scalars[index] == "}" { index += 1; return .object(fields) }
                    throw ParseError(at: index)
                }
            case "[":
                index += 1
                var items: [OrderedJSON] = []
                skipSpace()
                if index < scalars.count, scalars[index] == "]" { index += 1; return .array(items) }
                while true {
                    items.append(try value())
                    skipSpace()
                    guard index < scalars.count else { throw ParseError(at: index) }
                    if scalars[index] == "," { index += 1; continue }
                    if scalars[index] == "]" { index += 1; return .array(items) }
                    throw ParseError(at: index)
                }
            case "\"":
                return .string(try string())
            case "t":
                try literal("true"); return .bool(true)
            case "f":
                try literal("false"); return .bool(false)
            case "n":
                try literal("null"); return .null
            default:
                let start = index
                while index < scalars.count, "+-0123456789.eE".unicodeScalars.contains(scalars[index]) { index += 1 }
                guard index > start else { throw ParseError(at: index) }
                return .number(String(String.UnicodeScalarView(scalars[start..<index])))
            }
        }

        mutating func literal(_ word: String) throws {
            for s in word.unicodeScalars {
                guard index < scalars.count, scalars[index] == s else { throw ParseError(at: index) }
                index += 1
            }
        }

        mutating func string() throws -> String {
            guard index < scalars.count, scalars[index] == "\"" else { throw ParseError(at: index) }
            index += 1
            var out = String.UnicodeScalarView()
            while index < scalars.count {
                let s = scalars[index]
                index += 1
                if s == "\"" { return String(out) }
                if s != "\\" { out.append(s); continue }
                guard index < scalars.count else { throw ParseError(at: index) }
                let e = scalars[index]
                index += 1
                switch e {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "/": out.append("/")
                case "b": out.append("\u{08}")
                case "f": out.append("\u{0C}")
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "u":
                    var unit = try hex4()
                    if (0xD800...0xDBFF).contains(unit), index + 1 < scalars.count, scalars[index] == "\\", scalars[index + 1] == "u" {
                        index += 2
                        let low = try hex4()
                        unit = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                    }
                    guard let scalar = Unicode.Scalar(unit) else { throw ParseError(at: index) }
                    out.append(scalar)
                default:
                    throw ParseError(at: index)
                }
            }
            throw ParseError(at: index)
        }

        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= scalars.count, let v = UInt32(String(String.UnicodeScalarView(scalars[index..<index + 4])), radix: 16) else {
                throw ParseError(at: index)
            }
            index += 4
            return v
        }
    }
}

/// contract/native-calls.json, in order.
enum NativeVectors {
    static func load() throws -> OrderedJSON {
        try OrderedJSON.parse(try ContractFile.text("native-calls.json"))
    }
}

// MARK: - A clock the test moves

final class ManualTimer: CallTimer {
    private let onCancel: () -> Void
    init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    func cancel() { onCancel() }
}

/// Runs everything inline; timers fire, in order, when the test advances the clock.
final class ManualScheduler: CallScheduler {
    private(set) var now: Double = 1_000
    private var pending: [(id: Int, due: Double, block: () -> Void)] = []
    private var cancelled = Set<Int>()
    private var seq = 0

    func run(_ block: @escaping () -> Void) {
        block()
    }

    func after(_ seconds: Double, _ block: @escaping () -> Void) -> CallTimer {
        seq += 1
        let id = seq
        pending.append((id, now + max(0, seconds), block))
        return ManualTimer { [weak self] in self?.cancelled.insert(id) }
    }

    /// Move the clock, firing every timer that falls due on the way, each at its own time.
    func advance(_ seconds: Double) {
        let target = now + seconds
        while true {
            let due = pending.enumerated()
                .filter { $0.element.due <= target + 1e-9 && !cancelled.contains($0.element.id) }
                .min { ($0.element.due, $0.element.id) < ($1.element.due, $1.element.id) }
            guard let next = due else { break }
            pending.remove(at: next.offset)
            now = max(now, next.element.due)
            next.element.block()
        }
        now = target
        pending.removeAll { cancelled.contains($0.id) }
    }

    /// Timers still waiting (not cancelled).
    var waiting: Int { pending.filter { !cancelled.contains($0.id) }.count }
}

// MARK: - The socket and the network

final class FakeSocket: CallSocket {
    let url: URL
    let protocols: [String]
    let events: CallSocketEvents
    private(set) var sent: [String] = []
    private(set) var closed = false

    init(url: URL, protocols: [String], events: CallSocketEvents) {
        self.url = url
        self.protocols = protocols
        self.events = events
    }

    func send(_ text: String) {
        sent.append(text)
    }

    func close() {
        closed = true
    }

    // The other end.
    func open() { events.opened() }
    func frame(_ object: [String: Any]) { events.received(JSON.string(from: object) ?? "{}") }
    /// A close frame from the server, with its code (and its reason, which then stands for the detail).
    func serverClose(_ code: Int = 1000, reason: String? = nil) { events.closed(true, reason ?? "closed (\(code))", code) }
    /// An error; `code` when a close frame had arrived just before it.
    func fail(_ detail: String, code: Int? = nil) { events.closed(false, detail, code) }

    var sentFrames: [[String: Any]] { sent.compactMap { JSON.object(from: $0) } }
    var sentTypes: [String] { sentFrames.map { JSON.string($0["type"]) } }
    func clearSent() { sent.removeAll() }
}

final class FakeNetwork: CallNetwork {
    private(set) var posts: [(url: URL, body: Data)] = []
    private(set) var sockets: [FakeSocket] = []
    /// What the ticket endpoint answers: status and body.
    var ticketReply: (Int, Data?) = (200, Data(#"{"ticket":"tkt-1","wsUrl":"wss://ws.graine.ai/v1/embed"}"#.utf8))
    /// Hold the answers until the test releases them (`releasePosts`), so a test can say how long one took.
    var holdPosts = false
    private var heldPosts: [() -> Void] = []

    func post(_ url: URL, body: Data, completion: @escaping (Int, Data?) -> Void) {
        posts.append((url, body))
        let reply = ticketReply
        if holdPosts {
            heldPosts.append { completion(reply.0, reply.1) }
        } else {
            completion(reply.0, reply.1)
        }
    }

    func releasePosts() {
        let held = heldPosts
        heldPosts = []
        for answer in held { answer() }
    }

    func openSocket(_ url: URL, protocols: [String], events: CallSocketEvents) -> CallSocket {
        let socket = FakeSocket(url: url, protocols: protocols, events: events)
        sockets.append(socket)
        return socket
    }

    var socket: FakeSocket? { sockets.last }
}

// MARK: - The audio

/// Audio whose depth the test sets, as the React Native tests set their playout clock.
final class ScriptedAudio: CallAudioIO {
    var buffered = 0.0
    private(set) var played: [(samples: [Int16], rate: Int)] = []
    private(set) var clears = 0
    private(set) var stopped = false
    private(set) var started = false
    var startError: Error?
    private var onFrame: ((Data) -> Void)?

    private(set) var starts = 0

    func startCapture(_ onFrame: @escaping (Data) -> Void) throws {
        if let error = startError { throw error }
        started = true
        starts += 1
        stopped = false
        self.onFrame = onFrame
    }

    func play(_ pcm: [Int16], sampleRate: Int) { played.append((pcm, sampleRate)) }
    func clear() { clears += 1; buffered = 0 }
    func bufferedSeconds() -> Double { buffered }
    func stop() { stopped = true }
    /// The system took the audio back: released, what was not heard kept for the restart.
    private(set) var suspends = 0
    func suspend() { suspends += 1 }

    /// The customer's microphone: one 20 ms frame of a 220 Hz tone at `amp`.
    func speak(amp: Double) {
        onFrame?(NativeAudioFixtures.micFrame(amp: amp))
    }
}

enum NativeAudioFixtures {
    /// The vectors' microphone frame: 320 samples, `Math.round(amp · sin(2π·220·i/16000))`.
    static func micSamples(amp: Double) -> [Int16] {
        (0..<320).map { i in Int16(JSON.jsRound(amp * sin(2 * Double.pi * 220 * Double(i) / 16_000))) }
    }

    static func micFrame(amp: Double) -> Data {
        micSamples(amp: amp).withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// The vectors' voiced frame: a 140 Hz voice with eight harmonics.
    static func voice(rate: Int, ms: Int, amp: Double = 9_000) -> [Int16] {
        let n = Int((Double(rate) * Double(ms) / 1_000).rounded())
        return (0..<n).map { i in
            let t = Double(i) / Double(rate)
            var s = 0.0
            for h in 1...8 { s += sin(2 * Double.pi * 140 * Double(h) * t) / Double(h) }
            return Int16(max(-32_768, min(32_767, JSON.jsRound(s * amp * 0.5))))
        }
    }

    /// An agent audio frame as the server sends it: headerless PCM16 at 24 kHz, base64.
    static func agentFrame(ms: Int = 200) -> String {
        voice(rate: 24_000, ms: ms).withUnsafeBufferPointer { Data(buffer: $0) }.base64EncodedString()
    }
}

// MARK: - An engine on the bench

/// One engine with every seam replaced and every event recorded.
final class EngineRig {
    let scheduler = ManualScheduler()
    let network = FakeNetwork()
    let audio = ScriptedAudio()
    var session: GraineSessionConfig? = GraineSessionConfig(agentId: "agent-1", webcallAgentId: "web-1")
    var contextFrame: [String: Any]?
    var actionRunner: (String, [String: Any], @escaping (GraineActionResult) -> Void) -> Void = { name, _, answer in
        answer(.refused("This app build does not implement \"\(name)\"."))
    }
    private(set) var events: [CallEngine.Event] = []
    private(set) lazy var engine: CallEngine = makeEngine()
    var variables: [(String, String)] = [("who_called", "agent"), ("call_reason", "payment_due")]
    /// The identity fields on the ticket; none by default, as before identity existed.
    var identity: IdentityWire.Fields?
    /// The agent's server tokens; none by default, as before server tokens existed.
    var tokens: ClientTokens?

    private func makeEngine() -> CallEngine {
        CallEngine(
            setup: CallEngine.Setup(
                publishableKey: "pk_test_rig",
                baseUrl: "https://www.graine.ai",
                variables: variables,
                contextFrame: { [unowned self] in self.contextFrame },
                session: { [unowned self] done in done(self.session) },
                runAction: { [unowned self] name, args, answer in self.actionRunner(name, args, answer) },
                identity: identity,
                tokens: tokens
            ),
            audio: audio,
            network: network,
            scheduler: scheduler,
            onEvent: { [unowned self] event in self.events.append(event) }
        )
    }

    /// Start, let the socket open, forget the opening frames.
    @discardableResult
    func open(clearOpening: Bool = true) -> FakeSocket {
        engine.start()
        let socket = network.socket!
        socket.open()
        engine.startAudio()
        if clearOpening { socket.clearSent() }
        return socket
    }

    var speaking: [Bool] {
        events.compactMap { if case .speaking(let s) = $0 { return s }; return nil }
    }

    var captions: [GraineCaption] {
        events.compactMap { if case .caption(let c) = $0 { return c }; return nil }
    }

    var endings: [CallEngine.Ending] {
        events.compactMap { if case .ended(let e) = $0 { return e }; return nil }
    }

    var formats: [AgentAudioFormat] {
        events.compactMap { if case .format(let f) = $0 { return f }; return nil }
    }

    var transports: [CallEngine.Transport] {
        events.compactMap { if case .opened(let t) = $0 { return t }; return nil }
    }
}
