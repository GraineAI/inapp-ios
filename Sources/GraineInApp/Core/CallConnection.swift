import Foundation

/*
 * THE CONNECTION REPORT — how a native call connected and how its audio held
 * up, read from the call's own analytics rows (GraineCallTelemetry, contract
 * v1) the way Execution Logs' Connection card reads them
 * (lib/call-connection.ts): the latest row of each name, the recoveries
 * counted. Live while the call goes — the transport and connect rows at media,
 * the voice row at the agent's first words, a recovery each time it heals, the
 * audio as it is measured — and final at its end. Timings and network figures
 * only: a row never carries an id, a number or anything said, and neither does
 * this. Foundation only, so a Mac proves every fold.
 */

/**
 * HOW A NATIVE CALL CONNECTED, AND HOW ITS AUDIO HELD UP — the same facts as
 * Execution Logs' Connection card: `GraineCalls.connection`, live while the
 * call goes and final at its end (also handed to
 * `GraineCallsListener.onCallOutcome(_:callId:connection:)`). A figure nobody
 * has measured yet is nil.
 */
public struct GraineCallConnection: Equatable, Sendable {
    /// Where the call's credential came from.
    public enum Credential: String, Sendable {
        /// Issued directly by the call server (a WebRTC call that asked for it ahead).
        case direct
        /// Issued through the web app.
        case web
    }

    /// How the audio held up, in a word — on the Connection card's thresholds.
    public enum Quality: String, Sendable {
        case good
        case fair
        case poor
    }

    /// The audio as this device received it: what was lost, how uneven it arrived, how far away the other end is.
    public struct Audio: Equatable, Sendable {
        /// Packets lost, in percent (0–100, two decimals).
        public let lossPct: Double?
        /// Jitter on average, in milliseconds.
        public let jitterAvgMs: Int?
        /// The worst jitter measured, in milliseconds.
        public let jitterPeakMs: Int?
        /// The round trip, in milliseconds.
        public let rttMs: Int?

        public init(lossPct: Double? = nil, jitterAvgMs: Int? = nil, jitterPeakMs: Int? = nil, rttMs: Int? = nil) {
            self.lossPct = lossPct
            self.jitterAvgMs = jitterAvgMs
            self.jitterPeakMs = jitterPeakMs
            self.rttMs = rttMs
        }

        /**
         * `poor` at 8% lost, 80 ms of jitter or a 400 ms round trip; `fair` at
         * 2%, 30 ms or 150 ms; `good` below; nil with none of the three
         * measured. The Connection card's verdict, and the voice bar's "Weak
         * connection".
         */
        public var quality: Quality? {
            if lossPct == nil && jitterAvgMs == nil && rttMs == nil { return nil }
            let loss = lossPct ?? 0, jitter = jitterAvgMs ?? 0, rtt = rttMs ?? 0
            if loss >= 8 || jitter >= 80 || rtt >= 400 { return .poor }
            if loss >= 2 || jitter >= 30 || rtt >= 150 { return .fair }
            return .good
        }
    }

    /// The road the call ran on: `.webrtc` or `.websocket`.
    public let transport: GraineCallTransport?
    /// The call was prepared before the tap (`GraineCalls.prepareCall`, or as it rang) rather than set up at it.
    public let prepared: Bool?
    /// How long before the tap a prepared call was prepared, in seconds.
    public let preparedAgeSeconds: Int?
    /// Where its credential came from.
    public let credential: Credential?
    /**
     * From the tap to the call being placed — the credential, the microphone
     * and the network path; on a call set up after the tap, without its login
     * (`loginMs`). The card's "Setup".
     */
    public let setupMs: Int?
    /// The device signing in to the call server, on a call set up after the tap; nil on a prepared call, which signed in before the tap.
    public let loginMs: Int?
    /// From the call being placed to it being answered.
    public let answerMs: Int?
    /// From the answer to the agent's voice reaching the device.
    public let firstWordsMs: Int?
    /// From the tap to the agent's voice — the one number a customer feels.
    public let tapToVoiceMs: Int?
    /// The audio as received; on WebRTC only, measured while the call goes.
    public let audio: Audio?
    /// How many times the connection healed itself — a redial, a restarted audio path, a socket replaced: the call's recovery rows, 0 when it has not.
    public let recoveries: Int?

    public init(
        transport: GraineCallTransport? = nil, prepared: Bool? = nil, preparedAgeSeconds: Int? = nil, credential: Credential? = nil,
        setupMs: Int? = nil, loginMs: Int? = nil, answerMs: Int? = nil, firstWordsMs: Int? = nil, tapToVoiceMs: Int? = nil,
        audio: Audio? = nil, recoveries: Int? = nil
    ) {
        self.transport = transport
        self.prepared = prepared
        self.preparedAgeSeconds = preparedAgeSeconds
        self.credential = credential
        self.setupMs = setupMs
        self.loginMs = loginMs
        self.answerMs = answerMs
        self.firstWordsMs = firstWordsMs
        self.tapToVoiceMs = tapToVoiceMs
        self.audio = audio
        self.recoveries = recoveries
    }

    /**
     * The report for a bridge: `{transport, prepared, preparedAgeSeconds,
     * credential, setupMs, loginMs, answerMs, firstWordsMs, tapToVoiceMs,
     * audio: {lossPct, jitterAvgMs, jitterPeakMs, rttMs, quality} | null,
     * recoveries}` — every key present, null until known. `transport` is
     * `webrtc` or `websocket`.
     */
    var json: [String: Any] {
        func or(_ value: Any?) -> Any { value ?? NSNull() }
        var o: [String: Any] = [
            "transport": or(transport?.rawValue),
            "prepared": or(prepared),
            "preparedAgeSeconds": or(preparedAgeSeconds),
            "credential": or(credential?.rawValue),
            "setupMs": or(setupMs),
            "loginMs": or(loginMs),
            "answerMs": or(answerMs),
            "firstWordsMs": or(firstWordsMs),
            "tapToVoiceMs": or(tapToVoiceMs),
            "recoveries": or(recoveries),
        ]
        o["audio"] = audio.map { a -> Any in
            [
                // In its shortest decimal form: Foundation's writer spells 0.3 with seventeen digits.
                "lossPct": or(a.lossPct.map { NSDecimalNumber(string: "\($0)") }),
                "jitterAvgMs": or(a.jitterAvgMs),
                "jitterPeakMs": or(a.jitterPeakMs),
                "rttMs": or(a.rttMs),
                "quality": or(a.quality?.rawValue),
            ] as [String: Any]
        } ?? NSNull()
        return o
    }
}

/**
 * ONE CALL'S ROWS, FOLDED INTO ITS REPORT. Fed every row the call sends
 * (`read`) — whichever engine sent it: a WebRTC call that fell back to the
 * WebSocket says so in the socket's own rows, which replace the attempt's —
 * and, on WebRTC, the audio as measured so far (`audio`), until the quality
 * row at the end says it for the whole call. A fold per call; nothing to
 * report until a row has come.
 */
struct CallConnectionFold {
    /// The latest row of each name: its cleaned data.
    private var latest: [String: [String: Any]] = [:]
    private var recoveries = 0
    /// The audio as measured so far, before (or without) a quality row.
    private var measured: GraineCallConnection.Audio?

    /// A row exactly as the call sent it (`{"type":"app_event","event":{name, data, …}}`). True when the report changed.
    @discardableResult
    mutating func read(_ frame: String) -> Bool {
        guard let object = JSON.object(from: frame), JSON.string(object["type"]) == "app_event",
              let event = object["event"] as? [String: Any], let name = event["name"] as? String,
              GraineCallTelemetry.rows[name] != nil else { return false }
        let before = report
        latest[name] = event["data"] as? [String: Any] ?? [:]
        if name == "recovery" { recoveries += 1 }
        return report != before
    }

    /**
     * The audio as measured so far — the figures the call's quality row will
     * carry at its end — rounded and held as that row's are. True when the
     * report changed.
     */
    @discardableResult
    mutating func audio(lossPct: Double?, jitterAvgMs: Double?, jitterMaxMs: Double?, rttAvgMs: Double?) -> Bool {
        let before = report
        measured = GraineCallConnection.Audio(
            lossPct: CallConnectionFold.figure("percent", lossPct),
            jitterAvgMs: CallConnectionFold.figure("ms", jitterAvgMs).map { Int($0) },
            jitterPeakMs: CallConnectionFold.figure("ms", jitterMaxMs).map { Int($0) },
            rttMs: CallConnectionFold.figure("ms", rttAvgMs).map { Int($0) }
        )
        return report != before
    }

    /// The report so far; nil before any row or measurement.
    var report: GraineCallConnection? {
        guard !latest.isEmpty || measured != nil else { return nil }
        let transportRow = latest["transport"] ?? [:]
        let connect = latest["connect"]
        let voice = latest["voice"] ?? [:]
        let mode = CallConnectionFold.word(connect?["mode"])
        var prepared: Bool?
        if mode == "prepared" || mode == "cold" { prepared = mode == "prepared" } else if let warm = connect?["warm"].flatMap({ JSON.bool($0) }) { prepared = warm }

        // THE TAP'S WAIT, IN ORDER (the card's connectionSegments): a cold call's login is inside its setup, so it is
        // split out of it rather than added to it, and held to it; a prepared call signed in before the tap.
        let setupRaw = CallConnectionFold.whole(connect?["setup_ms"])
        let login = prepared == true ? nil : CallConnectionFold.whole(connect?["register_ms"])
        var setup = setupRaw
        var loginShown = login
        if let all = setupRaw, let login = login {
            let inSetup = min(login, all)
            loginShown = inSetup
            setup = all - inSetup
        }

        var audio = measured
        if let quality = latest["quality"] {
            audio = GraineCallConnection.Audio(
                lossPct: CallConnectionFold.decimal(quality["loss_pct"]),
                jitterAvgMs: CallConnectionFold.whole(quality["jitter_avg_ms"]),
                jitterPeakMs: CallConnectionFold.whole(quality["jitter_max_ms"]),
                rttMs: CallConnectionFold.whole(quality["rtt_avg_ms"])
            )
        }
        let transport: GraineCallTransport?
        switch CallConnectionFold.word(transportRow["transport"]) {
        case "rtc"?: transport = .webrtc
        case "ws"?: transport = .websocket
        default: transport = nil
        }
        return GraineCallConnection(
            transport: transport,
            prepared: prepared,
            preparedAgeSeconds: prepared == true ? CallConnectionFold.whole(connect?["prepared_age_s"]) : nil,
            credential: CallConnectionFold.word(connect?["mint_route"]).flatMap { GraineCallConnection.Credential(rawValue: $0) },
            setupMs: setup,
            loginMs: loginShown,
            answerMs: CallConnectionFold.whole(connect?["dial_ms"]),
            firstWordsMs: CallConnectionFold.whole(voice["answer_to_voice_ms"]),
            tapToVoiceMs: CallConnectionFold.whole(voice["tap_to_voice_ms"]),
            audio: audio,
            recoveries: recoveries
        )
    }

    // MARK: - Reading a row's values (already cleaned by the row's builder)

    private static func word(_ value: Any?) -> String? {
        guard let v = JSON.unwrap(value) as? String, !v.isEmpty else { return nil }
        return v
    }

    private static func whole(_ value: Any?) -> Int? {
        guard let v = JSON.unwrap(value), let n = JSON.number(v), n.doubleValue.isFinite, n.doubleValue >= 0 else { return nil }
        return Int(GraineCallTelemetry.roundHalfUp(n.doubleValue))
    }

    private static func decimal(_ value: Any?) -> Double? {
        guard let v = JSON.unwrap(value), let n = JSON.number(v), n.doubleValue.isFinite, n.doubleValue >= 0 else { return nil }
        return n.doubleValue
    }

    /// A measured figure as a row of `type` would hold it (rounded half up, held at its ceiling), or nil.
    private static func figure(_ type: String, _ value: Double?) -> Double? {
        switch GraineCallTelemetry.clean(type, value) {
        case .int(let i)?: return Double(i)
        case .double(let d)?: return d
        default: return nil
        }
    }
}
