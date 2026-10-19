import Foundation
import Testing
@_spi(GraineRTC) @testable import GraineInApp

/*
 * THE CALL ANALYTICS ROWS (v1) — the one pure function that makes them, held
 * to sdk/contract/call-analytics.json byte for byte (read IN ORDER: a row's
 * keys are sent in the contract's order), and the rows a call's conversation
 * sends: on WebRTC, the transport row handed to the call for its control
 * channel; on the WebSocket (a fallback's included), the transport, connect
 * and voice rows on the voice socket, only once it is open. Never an id or an
 * identity; never more than twelve keys.
 */

/// The analytics rows among a list of sent frames: name, detail, data and the frame itself.
func analyticsRows(_ frames: [String]) -> [(name: String, detail: String, data: [String: Any], text: String)] {
    frames.compactMap { text in
        guard let object = JSON.object(from: text), JSON.string(object["type"]) == "app_event",
              let event = object["event"] as? [String: Any], event["telemetry"] as? Bool == true else { return nil }
        return (JSON.string(event["name"]), JSON.string(event["detail"]), event["data"] as? [String: Any] ?? [:], text)
    }
}

extension OrderedJSON {
    /// As JSON.stringify writes it: no spaces, keys in their order, strings escaped its way, numbers as the file spells them (its own digits).
    var compact: String {
        switch self {
        case .string(let s):
            var out = ""
            WireJSON.quote(s, into: &out)
            return out
        case .number(let text): return text
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array(let items): return "[" + items.map(\.compact).joined(separator: ",") + "]"
        case .object(let fields):
            return "{" + fields.map { field -> String in
                var key = ""
                WireJSON.quote(field.0, into: &key)
                return key + ":" + field.1.compact
            }.joined(separator: ",") + "}"
        }
    }
}

@Suite("sdk/contract/call-analytics.json: the rows, byte for byte")
struct CallAnalyticsVectorTests {
    static func contract() throws -> OrderedJSON {
        try OrderedJSON.parse(try ContractFile.text("call-analytics.json"))
    }

    /// A case's measurements as Swift hands them over: Int, Double, String, Bool — and a JSON null as NSNull.
    static func swiftValues(_ data: OrderedJSON?) -> [String: Any?] {
        var out: [String: Any?] = [:]
        for (key, value) in data?.fields ?? [] { out.updateValue(value.isNull ? NSNull() : value.foundation, forKey: key) }
        return out
    }

    /// The same measurements as Foundation's JSON reader hands them over: NSNumber (true as CFBoolean), NSNull.
    static func foundationValues(_ data: OrderedJSON?) throws -> [String: Any?] {
        let parsed = try JSONSerialization.jsonObject(with: Data((data ?? .object([])).compact.utf8)) as? [String: Any] ?? [:]
        return parsed.mapValues { Optional($0) }
    }

    @Test("every case's event, byte for byte — from Swift values and from Foundation's")
    func everyCase() throws {
        let cases = try #require(try Self.contract()["cases"]?.array)
        #expect(cases.count >= 17)
        var rowsCovered = Set<String>()
        for item in cases {
            let title = try #require(item["name"]?.string)
            let input = try #require(item["input"])
            let name = try #require(input["name"]?.string)
            let expected = try #require(item["event"])
            let want: String? = expected.isNull ? nil : expected.compact
            #expect(GraineCallTelemetry.event(name, Self.swiftValues(input["data"])) == want, "\(title)")
            #expect(GraineCallTelemetry.event(name, try Self.foundationValues(input["data"])) == want, "\(title) (Foundation's values)")
            // The frame is the event in its app_event envelope, nothing more.
            let frame = GraineCallTelemetry.frame(name, Self.swiftValues(input["data"]))
            #expect(frame == want.map { #"{"type":"app_event","event":"# + $0 + "}" }, "\(title) (frame)")
            if want != nil { rowsCovered.insert(name) }
        }
        #expect(rowsCovered == Set(GraineCallTelemetry.rows.keys), "a case for every row")
    }

    @Test("the rows, their keys and types, the enums, the limits and the key cap are the contract's")
    func tables() throws {
        let contract = try Self.contract()
        #expect(contract["version"]?.int == GraineCallTelemetry.version)
        #expect(contract["max_keys"]?.int == GraineCallTelemetry.maxKeys)
        let rows = try #require(contract["rows"]?.fields)
        #expect(Set(rows.map(\.0)) == Set(GraineCallTelemetry.rows.keys))
        for (name, row) in rows {
            let mine = try #require(GraineCallTelemetry.rows[name], "\(name)")
            let keys = try #require(row["keys"]?.array).compactMap(\.string)
            #expect(mine.map(\.key) == keys, "\(name): the keys, in order")
            let types = try #require(row["types"]?.fields)
            #expect(types.count == mine.count, "\(name)")
            for (key, type) in types {
                #expect(mine.first { $0.key == key }?.type == type.string, "\(name).\(key)")
            }
            #expect(mine.count <= GraineCallTelemetry.maxKeys, "\(name) is wider than \(GraineCallTelemetry.maxKeys)")
        }
        #expect(GraineCallTelemetry.rows["connect"]?.count == 12, "connect uses all twelve")
        let enums = try #require(contract["enums"]?.fields)
        #expect(Set(enums.map(\.0)) == Set(GraineCallTelemetry.enums.keys))
        for (name, list) in enums {
            #expect(GraineCallTelemetry.enums[name] == list.array?.compactMap(\.string), "enums.\(name), in order")
        }
        let limits = try #require(contract["limits"]?.fields)
        #expect(limits.count == GraineCallTelemetry.limits.count)
        for (name, value) in limits {
            #expect(GraineCallTelemetry.limits[name] == value.double, "limits.\(name)")
        }
    }
}

@Suite struct CallTelemetryRowTests {
    private func data(_ name: String, _ input: [String: Any?]) -> [String: Any]? {
        GraineCallTelemetry.event(name, input).flatMap { JSON.object(from: $0)?["data"] as? [String: Any] }
    }

    private func detail(_ name: String, _ input: [String: Any?]) -> String? {
        GraineCallTelemetry.event(name, input).flatMap { JSON.object(from: $0) }.map { JSON.string($0["detail"]) }
    }

    @Test func aRowIsAQuietTelemetryAppEventItsKeysInTheContractsOrder() {
        let frame = GraineCallTelemetry.frame("transport", ["fallback_reason": "no_answer", "requested": "auto", "transport": "ws"])
        #expect(frame == #"{"type":"app_event","event":{"name":"transport","detail":"WebSocket (fallback: no_answer)","quiet":true,"telemetry":true,"data":{"transport":"ws","requested":"auto","fallback_reason":"no_answer"}}}"#)
    }

    @Test func aBooleanIsNotANumberAndANumberIsNotABoolean() {
        // Swift's own values: true bridges to NSNumber, 1 and 0 to NSNumber — neither may pass for the other.
        #expect(data("connect", ["warm": 1, "total_ms": true, "setup_ms": false, "redials": 0])?.keys.sorted() == ["redials"])
        #expect(data("connect", ["warm": 0])?.isEmpty == true)
        #expect(data("connect", ["warm": NSNumber(value: true)])?["warm"] as? Bool == true, "the boolean JSON reads")
        #expect(data("connect", ["warm": NSNumber(value: 1)])?.isEmpty == true, "a number JSON reads")
    }

    @Test func whatDoesNotFitIsLeftOutNeverGuessedAt() {
        let measured: Int? = nil
        let row = data("quality", [
            "duration_s": "64",                    // a numeric string
            "loss_pct": -0.5,                      // a negative
            "jitter_avg_ms": Double.nan,
            "jitter_max_ms": Double.infinity,
            "rtt_avg_ms": measured,                // not measured
        ])
        #expect(row?.isEmpty == true)
        #expect(data("voice", ["tap_to_voice_ms": NSNull(), "first_audio_ms": -0.0])?["first_audio_ms"] as? Int == 0, "-0 is not negative: 0")
        #expect(data("recovery", ["what": "REDIAL"])?.isEmpty == true, "an enum exactly as the list writes it")
        #expect(data("transport", ["transport": "rtc ", "requested": "Auto"])?.isEmpty == true)
        #expect(GraineCallTelemetry.event("lunch", [:]) == nil, "no such row: nothing to send")
    }

    @Test func integersRoundHalfUpAndStopAtTheirCeilings() {
        let row = data("connect", ["total_ms": 1893.5, "setup_ms": 1288.49, "dial_ms": 0.5, "mint_ms": 1e300, "redials": 20.5, "prepared_age_s": 86_400.4])
        #expect(row?["total_ms"] as? Int == 1894)
        #expect(row?["setup_ms"] as? Int == 1288)
        #expect(row?["dial_ms"] as? Int == 1)
        #expect(row?["mint_ms"] as? Int == 600_000, "held at ten minutes")
        #expect(row?["redials"] as? Int == 20)
        #expect(row?["prepared_age_s"] as? Int == 86_400)
        let quality = GraineCallTelemetry.event("quality", ["loss_pct": 0.125, "duration_s": 3])
        #expect(quality?.contains(#""loss_pct":0.13"#) == true, "two decimals, half up (0.125 is exact in binary)")
        #expect(GraineCallTelemetry.event("quality", ["loss_pct": 0.285])?.contains(#""loss_pct":0.28"#) == true, "0.285 is 0.28499… as a double: down, as JavaScript rounds it")
        #expect(GraineCallTelemetry.event("quality", ["loss_pct": 140])?.contains(#""loss_pct":100}"#) == true, "held at 100, written as JavaScript writes 100")
    }

    @Test func aCodecIsWrittenTheSdpWay() {
        func codec(_ text: Any) -> String? { data("voice", ["codec": text])?["codec"] as? String }
        #expect(codec("audio/PCMU/8000") == "PCMU/8000", "what the WebRTC stats say, with the clock rate")
        #expect(codec("AUDIO/OPUS/48000/2") == "opus/48000", "any case; the channel count dropped")
        #expect(codec("pcma") == "PCMA")
        #expect(codec("L16/16000") == "L16/16000", "the voice socket's linear audio")
        #expect(codec("opus/2") == "opus", "a channel count alone")
        #expect(codec("  ilbc/8000\n") == "iLBC/8000", "surrounding space trimmed")
        #expect(codec("\u{FEFF}g722/16000") == "G722/16000", "JavaScript's trim takes a BOM")
        #expect(codec("\u{85}opus") == nil, "and not a NEL, which Foundation's would")
        for bad in ["speex/16000", "opus/123", "opus/1234567", "audio/", "opus/48000/123", "opus/48000/", "o", "opus 48000", "ｏpus"] {
            #expect(codec(bad) == nil, "\(bad)")
        }
        #expect(codec(8000) == nil, "only text")
    }

    @Test func theDetailsAreWrittenExactly() {
        #expect(detail("voice", ["tap_to_voice_ms": 905, "answer_to_voice_ms": 693]) == "agent's voice 0.9s after the tap (0.7s after the answer)")
        #expect(detail("voice", ["first_audio_ms": 120]) == "agent's voice heard")
        #expect(detail("quality", ["duration_s": 63.6, "loss_pct": 0.26, "jitter_avg_ms": 11.7]) == "64s · loss 0.3% · jitter 12 ms")
        #expect(detail("quality", ["rtt_avg_ms": 88]) == "call quality")
        #expect(detail("recovery", ["what": "ice_restart", "after_ms": 3120]) == "ice restart after 3.1s")
        #expect(detail("recovery", ["what": "socket_replaced"]) == "socket replaced")
        #expect(detail("recovery", ["after_ms": 50]) == "recovered after 0.1s")
        #expect(detail("connect", ["warm": false, "dial_ms": 605]) == "cold (answer 0.6s)", "mode from warm when mode is absent")
        #expect(detail("transport", ["fallback_reason": "dashboard"]) == "fallback: dashboard")
        #expect(detail("transport", ["requested": "ws"]) == "transport")
        #expect(detail("media", ["transport": "rtc"]) == "no audio path")
        #expect(GraineCallTelemetry.seconds(1250) == "1.3s", "tenths = floor((ms + 50) / 100)")
        #expect(GraineCallTelemetry.seconds(1249) == "1.2s")
        #expect(GraineCallTelemetry.seconds(0) == "0.0s")
        #expect(GraineCallTelemetry.seconds(600_000) == "600.0s")
        #expect(GraineCallTelemetry.percent(0.05) == "0.1%")
        #expect(GraineCallTelemetry.percent(0.04) == "0.0%")
    }

    @Test func theEnginesMillisecondsRoundAsTheRowsDo() {
        #expect(GraineCallTelemetry.milliseconds(from: 1_000, to: 1_000.2124) == 212)
        #expect(GraineCallTelemetry.milliseconds(from: 0, to: 0.0625) == 63, "half up (62.5 ms, exact in binary)")
        #expect(GraineCallTelemetry.milliseconds(from: 1_000, to: 999) == nil, "time ran backwards")
        #expect(GraineCallTelemetry.milliseconds(from: nil, to: 3) == nil)
        #expect(GraineCallTelemetry.milliseconds(from: 0, to: 1e12) == 600_000, "held at the ceiling, never a trap")
    }
}

@Suite struct CallConversationAnalyticsTests {
    /// Nothing that names the call or who is on it may ride in a row.
    private func expectNoIdentity(_ rows: [(name: String, detail: String, data: [String: Any], text: String)]) {
        for row in rows {
            for secret in ["call_1", "customer-1", "install-1", "pk_test_rig", "agent-1", "web-1", "Asia/Kolkata", "card_blocked"] {
                #expect(!row.text.contains(secret), "\(row.name) carries \(secret)")
            }
            #expect(row.data.count <= GraineCallTelemetry.maxKeys)
        }
    }

    @Test func theWebRtcLegIsHandedItsTransportRowNothingIsSentAhead() throws {
        let rig = ConversationRig()
        let conversation = rig.make()
        conversation.start()
        let call = try #require(rig.module.call)
        #expect(call.preparedAhead == false, "made at the tap: cold")
        #expect(call.steps.last == "begin")
        let rows = analyticsRows(call.transportRow.map { [$0] } ?? [])
        #expect(rows.count == 1)
        #expect(rows.first?.name == "transport" && rows.first?.detail == "WebRTC")
        #expect(rows.first?.text == #"{"type":"app_event","event":{"name":"transport","detail":"WebRTC","quiet":true,"telemetry":true,"data":{"transport":"rtc","requested":"auto"}}}"#)
        conversation.startAudio()
        call.emit(.ready)
        call.emit(.connected)
        #expect(analyticsRows(call.sent.map(\.frame)).isEmpty, "the leg sends it at media, before its connect row — the conversation sends nothing itself")
        expectNoIdentity(rows)
    }

    @Test func aLegPreparedAheadIsDialledAsPrepared() throws {
        let rig = ConversationRig()
        let prepared = FakeRtcCall()
        rig.prepared = prepared
        rig.make(.webrtc).start()
        #expect(prepared.preparedAhead, "its connect row will say prepared")
        #expect(analyticsRows([prepared.transportRow ?? ""]).first?.data["requested"] as? String == "rtc")
    }

    /// A WebRTC attempt that fell back says so on the WebSocket conversation it continues on — and only once that is open.
    @Test func aFallbackSendsItsRowsOnTheSocketItContinuesOnOnceItIsOpen() throws {
        let rig = ConversationRig()
        let conversation = rig.make()
        conversation.start()
        rig.scheduler.advance(1.2)
        let call = try #require(rig.module.call)
        call.emit(.unreachable(.noAnswer, detail: "not answered"))
        let socket = try #require(rig.network.socket)
        #expect(socket.sent.isEmpty, "nothing before the conversation starts")
        rig.scheduler.advance(0.3)
        socket.open()
        var rows = analyticsRows(socket.sent)
        #expect(rows.map(\.name) == ["transport", "connect"])
        #expect(rows.first?.text == #"{"type":"app_event","event":{"name":"transport","detail":"WebSocket (fallback: no_answer)","quiet":true,"telemetry":true,"data":{"transport":"ws","requested":"auto","fallback_reason":"no_answer"}}}"#)
        let first = try #require(JSON.object(from: socket.sent.first)?["type"] as? String)
        #expect(first != "app_event", "after the conversation's own opening frames")
        let connect = rows[1].data
        #expect(connect["mode"] as? String == "cold" && connect["warm"] as? Bool == false)
        #expect(connect["total_ms"] as? Int == 1500, "counted from the tap, the WebRTC attempt included")
        #expect(connect["setup_ms"] as? Int == 1200 && connect["dial_ms"] as? Int == 300, "total = setup + dial: to the socket asked for, then its opening")
        #expect(connect["mint_route"] as? String == "web" && connect["mint_ms"] as? Int == 0, "the web app's ticket")
        rig.scheduler.advance(0.4)
        socket.frame(["type": "audio", "data": NativeAudioFixtures.agentFrame()])
        socket.frame(["type": "audio", "data": NativeAudioFixtures.agentFrame()])
        rows = analyticsRows(socket.sent)
        #expect(rows.map(\.name) == ["transport", "connect", "voice"], "the voice row once")
        #expect(rows[2].data["tap_to_voice_ms"] as? Int == 1900)
        #expect(rows[2].data["answer_to_voice_ms"] as? Int == 400)
        #expect(rows[2].data["codec"] as? String != nil)
        expectNoIdentity(rows)
    }

    @Test func aSocketThatNeverOpensSendsNoRows() throws {
        let rig = ConversationRig()
        rig.make(.websocket).start()
        let socket = try #require(rig.network.socket)
        socket.fail("refused")
        #expect(analyticsRows(socket.sent).isEmpty)
    }

    @Test func aTicketFromTheWebAppIsTheSocketsMintAndNoTicketIsNoMint() throws {
        let rig = ConversationRig()
        rig.network.ticketReply = (200, Data(#"{"ticket":"t-1","wsUrl":"wss://gw.example.test/v1/ws"}"#.utf8))
        rig.network.holdPosts = true
        let conversation = rig.make(.websocket)
        conversation.start()
        rig.scheduler.advance(0.25)
        rig.network.releasePosts()
        let socket = try #require(rig.network.socket)
        socket.open()
        let connect = try #require(analyticsRows(socket.sent).first { $0.name == "connect" })
        #expect(connect.data["mint_route"] as? String == "web")
        #expect(connect.data["mint_ms"] as? Int == 250)
        #expect(connect.data["setup_ms"] as? Int == 250 && connect.data["total_ms"] as? Int == 250)
        #expect(!connect.text.contains("t-1") && !connect.text.contains("gw.example.test"), "never the ticket or its address")

        let direct = ConversationRig()
        direct.network.ticketReply = (503, nil)
        direct.make(.websocket).start()
        let open = try #require(direct.network.socket)
        open.open()
        let row = try #require(analyticsRows(open.sent).first { $0.name == "connect" })
        #expect(row.data["mint_route"] == nil && row.data["mint_ms"] == nil, "the direct socket: nothing was minted")
    }

    @Test func askedForTheWebSocketNothingFellBack() throws {
        let rig = ConversationRig()
        rig.make(.websocket).start()
        let socket = try #require(rig.network.socket)
        socket.open()
        let rows = analyticsRows(socket.sent)
        #expect(rows.first?.text == #"{"type":"app_event","event":{"name":"transport","detail":"WebSocket","quiet":true,"telemetry":true,"data":{"transport":"ws","requested":"ws"}}}"#)
        expectNoIdentity(rows)
    }

    @Test func theDashboardsSwitchAndABuildWithoutWebRtcSayWhy() throws {
        let dashboard = ConversationRig()
        dashboard.session(audioTransport: "websocket")
        dashboard.make().start()
        let one = try #require(dashboard.network.socket)
        one.open()
        #expect(analyticsRows(one.sent).first?.detail == "WebSocket (fallback: dashboard)")

        let without = ConversationRig()
        without.installed = false
        without.make(.webrtc).start()
        let two = try #require(without.network.socket)
        two.open()
        let row = try #require(analyticsRows(two.sent).first)
        #expect(row.data["requested"] as? String == "rtc" && row.data["fallback_reason"] as? String == "unavailable")
        #expect(without.reports.last?.reason == nil, "the call screen shows no fallback for it")
    }
}
