import Foundation
import Testing
@_spi(GraineRTC) @testable import GraineInApp

/*
 * PUBLIC STATE FOR SCREENS OF YOUR OWN (sdk/contract/PUBLIC-STATE.md, 0.14.0):
 * everything the SDK's own chat window, voice bar, call screen, booking sheet
 * and component views read is public — and mirrored for Objective-C, which
 * the Kotlin Multiplatform SDK's iOS side calls. On fakes: nothing here waits
 * or reaches a host.
 */

private let welcome: [String: Any] = ["type": "text", "data": "<beginning_of_stream>Hi Meera, I'm Asha, your care coach.<end_of_stream>"]

/// JSON text a facade handed back, read as Foundation reads it.
private func parse(_ text: String?) -> Any? {
    text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8), options: [.fragmentsAllowed]) }
}

// MARK: - 1. Chat

@Suite @MainActor struct ChatPublicStateTests {
    @Test func aNewConversationUnderEarlierLinesIsPublicInTheTurnsOrder() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session()
        let chat = rig.graine.chat
        chat.open()
        let first = try #require(rig.network.socket)
        first.open()
        first.frame(welcome)
        chat.send("I take metformin twice a day.")
        first.frame(["type": "text", "data": "<beginning_of_stream>Thanks, I'll keep that in mind.<end_of_stream>"])
        #expect(chat.newConversationBefore.isEmpty)
        // A dropped connection, made again: the server could not continue the conversation and greets again.
        first.fail("network lost")
        #expect(chat.wasOnline, "the drop is a reconnect: the window's banner")
        rig.scheduler.advance(1.01)
        let second = try #require(rig.network.socket)
        #expect(second !== first)
        second.open()
        second.frame(welcome)
        let turns = chat.turns
        #expect(turns.count == 4)
        #expect(chat.newConversationBefore == [turns[3].id], "before the new welcome, as history.json → fresh says")
        #expect(chat.marks == [turns[3].id], "the SDK's own windows read the same")
        let rows = GraineChatRows.build(turns, newConversationBefore: chat.newConversationBefore)
        #expect(rows.map(\.id).suffix(2) == ["fresh-\(turns[3].id)", turns[3].id])
        chat.clear()
        #expect(chat.newConversationBefore.isEmpty, "the markers go with the lines")
    }

    @Test func theWindowRowsPutTheMarkerAfterItsDayLineWithItsWords() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let now = try #require(ChatHistory.time("2026-10-14T06:30:00Z"))
        func turn(_ id: String, _ role: GraineRole, _ at: String) throws -> GraineChatTurn {
            GraineChatTurn(id: id, role: role, text: id, live: false, delivery: .sent, at: try #require(ChatHistory.time(at)), proactive: false)
        }
        let turns = [
            try turn("t1", .agent, "2026-10-13T09:30:00Z"),
            try turn("t2", .customer, "2026-10-13T09:31:00Z"),
            try turn("t3", .agent, "2026-10-14T05:00:00Z"),
        ]
        let rows = GraineChatRows.build(turns, newConversationBefore: ["t3"], now: now, calendar: calendar)
        #expect(rows.map(\.id) == ["day-2026-10-13", "t1", "t2", "day-2026-10-14", "fresh-t3", "t3"], "after the turn's day line")
        guard case .newConversation(let line) = rows[4] else {
            Issue.record("the marker is its own row kind")
            return
        }
        #expect(line == GraineChatNewConversationLine(before: "t3", label: "Disconnected · new conversation", spoken: "Disconnected. A new conversation started."))
        #expect(line.id == "fresh-t3")
        let plain = GraineChatRows.build(turns, newConversationBefore: [], now: now, calendar: calendar)
        #expect(plain.map(\.id) == GraineChatRows.build(turns, now: now, calendar: calendar).map(\.id), "no markers: exactly build(_:)'s rows")
        let first = GraineChatRows.build(turns, newConversationBefore: ["t1"], now: now, calendar: calendar)
        #expect(!first.map(\.id).contains("fresh-t1"), "never above everything: nothing earlier to set apart")
        #expect(GraineChatRows.build(turns, newConversationBefore: ["gone"], now: now, calendar: calendar).count == plain.count)
    }

    @Test func graineEndingTheConversationIsPublicAndSaidToObjectiveC() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session()
        let facade = GraineObjC(graine: rig.graine)
        facade.chat.setShown(true)
        let socket = try #require(rig.network.socket, "a screen of the app's own that appears connects")
        socket.open()
        socket.frame(welcome)
        var snapshot = try #require(parse(facade.chat.snapshotJSON) as? [String: Any])
        #expect(snapshot["status"] as? String == "online")
        #expect(snapshot["disconnected"] as? Bool == false)
        #expect(snapshot["newConversationBefore"] as? [String] == [])
        socket.serverClose(4408, reason: "idle_timeout")
        #expect(rig.graine.chat.disconnected)
        snapshot = try #require(parse(facade.chat.snapshotJSON) as? [String: Any])
        #expect(snapshot["status"] as? String == "disconnected", "the status word KMP's iOS side reads")
        #expect(snapshot["disconnected"] as? Bool == true)
        #expect(facade.chat.status == "disconnected" && facade.chat.disconnected)
        #expect(facade.chat.reconnectAttempt == 0)
        // The next screen connects again, and it is no longer Disconnected.
        facade.chat.setShown(false)
        facade.chat.setShown(true)
        #expect(rig.network.sockets.count == 2)
        #expect(!facade.chat.disconnected && facade.chat.status == "connecting")
    }

    @Test func aScreenOfYourOwnKeepsTheConversationFifteenSecondsAfterItGoes() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session()
        let chat = rig.graine.chat
        chat.shown(true)
        try #require(rig.network.socket).open()
        chat.shown(false)
        rig.scheduler.advance(Double(chat.closeDelaySeconds) - 1)
        #expect(chat.status == .online && chat.isOpen, "kept for the close delay with no screen")
        rig.scheduler.advance(1.1)
        #expect(chat.status == .idle && !chat.isOpen, "closed after")
        chat.shown(true)
        #expect(rig.network.sockets.count == 2, "shown again: connected again")
    }

    @Test func theObjectiveCChatAnswersItsNewSelectors() throws {
        let cls = try #require(NSClassFromString("GraineObjCChat") as? NSObject.Type)
        for s in ["setShown:", "disconnected", "wasOnline", "newConversationBefore", "dismissWidgetWithId:"] {
            #expect(cls.instancesRespond(to: NSSelectorFromString(s)), "-[GraineObjCChat \(s)]")
        }
    }
}

// MARK: - 2. Voice

@Suite struct VoicePublicStateTests {
    @Test func theStatusIsPhaseWithMutedFailedAndEnded() {
        func status(_ phase: GrainePhase, calling: Bool = true, connected: Bool = true, muted: Bool = false, failed: Bool = false, ended: Bool = false) -> GraineVoiceStatus {
            GraineVoiceStatus.of(phase: phase, calling: calling, connected: connected, muted: muted, failed: failed, ended: ended)
        }
        #expect(status(.idle, connected: false) == .idle)
        #expect(status(.idle, connected: false, ended: true) == .ended)
        #expect(status(.connecting, connected: false) == .connecting)
        #expect(status(.reconnecting) == .reconnecting)
        #expect(status(.listening) == .listening)
        #expect(status(.thinking) == .thinking)
        #expect(status(.speaking) == .speaking)
        #expect(status(.speaking, muted: true) == .muted, "muted is said over the conversation, as the bar says it")
        #expect(status(.connecting, connected: false, muted: true) == .connecting, "a wait is said over muted")
        #expect(status(.speaking, failed: true) == .failed, "a failure first")
        #expect(status(.idle, connected: false, failed: true, ended: true) == .failed)
        #expect(GraineVoiceStatus.allWords == ["idle", "connecting", "listening", "thinking", "speaking", "reconnecting", "muted", "failed", "ended"])
    }

    /// The demo's bug: before Talk starts the engine page is not loaded, and `phase` says connecting — the status must not.
    @Test func beforeACallStartsAndAfterItEndsThePagesLoadingIsNobodysWait() {
        func status(_ phase: GrainePhase, calling: Bool, ended: Bool = false, failed: Bool = false) -> GraineVoiceStatus {
            GraineVoiceStatus.of(phase: phase, calling: calling, connected: false, muted: false, failed: failed, ended: ended)
        }
        #expect(status(.connecting, calling: false) == .idle, "the page loading before anyone started Talk")
        #expect(status(.reconnecting, calling: false) == .idle, "the page retrying its load in the background")
        #expect(status(.connecting, calling: false, ended: true) == .ended, "right after an end, while the page reloads")
        #expect(status(.connecting, calling: true) == .connecting, "Talk started: the page loading is its wait")
        #expect(status(.reconnecting, calling: true) == .reconnecting)
        #expect(status(.connecting, calling: false, failed: true) == .failed, "a page that could not load is still said")
        // As GrainePhase reads a page not loaded yet: connecting, while every call flag is false.
        let phase = GrainePhase.of(reconnecting: false, connectivity: .loading, connecting: false, ready: false, connected: false,
                                   agentSpeaking: false, awaitingAgent: false)
        #expect(phase == .connecting && status(phase, calling: false) == .idle)
    }

    @Test func theErrorIsTheBarsFirstFailureInASentence() {
        #expect(VoiceFailure.sentence(fault: nil, micDenied: false, connectivity: .ready, callFailed: false) == nil)
        #expect(VoiceFailure.sentence(fault: "This app is not allowed.", micDenied: true, connectivity: .failed, callFailed: true) == "This app is not allowed.")
        #expect(VoiceFailure.sentence(fault: nil, micDenied: true, connectivity: .failed, callFailed: true) == VoiceFailure.micDenied)
        #expect(VoiceFailure.sentence(fault: nil, micDenied: false, connectivity: .failed, callFailed: true) == VoiceFailure.loadFailed)
        #expect(VoiceFailure.sentence(fault: nil, micDenied: false, connectivity: .retrying, callFailed: true) == VoiceFailure.connectFailed)
        for sentence in [VoiceFailure.micDenied, VoiceFailure.loadFailed, VoiceFailure.connectFailed] {
            #expect(sentence.hasSuffix("."), "a sentence")
        }
    }

    @Test func levelsAreReadWhenThePageSendsThem() throws {
        let both = try #require(VoiceLevels.parse(#"{"type":"graine:levels","agent":0.42,"mic":0.1}"#))
        #expect(both.agent == 0.42 && both.mic == 0.1)
        let held = try #require(VoiceLevels.parse(#"{"type":"graine:levels","agent":3,"mic":-1}"#))
        #expect(held.agent == 1 && held.mic == 0, "held to 0–1")
        let partial = try #require(VoiceLevels.parse(#"{"type":"graine:levels","agent":"loud"}"#))
        #expect(partial.agent == nil && partial.mic == nil, "a level that is not a number is not one")
        #expect(VoiceLevels.parse(#"{"type":"graine:caption","role":"agent","text":"Hi"}"#) == nil, "any other message is not levels")
        #expect(VoiceLevels.parse("not json") == nil)
        #expect(GraineProtocol.parse(#"{"type":"graine:levels","agent":0.4}"#) == nil, "never a PageMessage: an older reader ignores it")
    }

    @Test @MainActor func theObjectiveCVoiceSaysItsNewKeys() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        let voice = GraineObjC(graine: rig.graine).voice
        let snapshot = try #require(parse(voice.snapshotJSON) as? [String: Any])
        for key in ["connected", "connecting", "muted", "captionsOn", "captions", "status", "error", "agentLevel", "micLevel", "transport", "transportFallbackReason", "micDenied"] {
            #expect(snapshot[key] != nil, "\(key)")
        }
        #expect(snapshot["status"] as? String == "idle")
        #expect(snapshot["error"] is NSNull && snapshot["transport"] is NSNull)
        #expect((snapshot["agentLevel"] as? NSNumber)?.doubleValue == 0 && (snapshot["micLevel"] as? NSNumber)?.doubleValue == 0)
        #expect(voice.status == "idle" && voice.error == nil && voice.agentLevel == 0 && voice.micLevel == 0 && voice.transport == nil && !voice.micDenied)
        #expect(ObjCBridge.transportWord(.webrtc) == "webrtc" && ObjCBridge.transportWord(.websocket) == "websocket")
        let cls = try #require(NSClassFromString("GraineObjCVoice") as? NSObject.Type)
        for s in ["status", "error", "agentLevel", "micLevel", "transport", "transportFallbackReason", "micDenied"] {
            #expect(cls.instancesRespond(to: NSSelectorFromString(s)), "-[GraineObjCVoice \(s)]")
        }
    }
}

private extension GraineVoiceStatus {
    static let allWords = [GraineVoiceStatus.idle, .connecting, .listening, .thinking, .speaking, .reconnecting, .muted, .failed, .ended].map(\.rawValue)
}

// MARK: - 3. Calls: the connection report

private func row(_ name: String, _ data: [String: Any?]) -> String {
    GraineCallTelemetry.frame(name, data) ?? ""
}

@Suite struct CallConnectionReportTests {
    @Test func nothingBeforeARowAndOnlyRowsCount() {
        var fold = CallConnectionFold()
        #expect(fold.report == nil)
        let notJSON = fold.read("not json")
        let notARow = fold.read(#"{"type":"app_event","event":{"name":"connection_quality","data":{"rtt_ms":40}}}"#)
        let notAnEvent = fold.read(#"{"type":"text","data":"hello"}"#)
        #expect(!notJSON && !notARow && !notAnEvent, "only the contract's rows")
        #expect(fold.report == nil)
        let first = fold.read(row("transport", ["transport": "rtc", "requested": "auto"]))
        let again = fold.read(row("transport", ["transport": "rtc", "requested": "auto"]))
        #expect(first && !again, "the same row again changes nothing")
        #expect(fold.report == GraineCallConnection(transport: .webrtc, recoveries: 0))
    }

    @Test func aColdCallSplitsItsLoginOutOfItsSetupAsTheCardDoes() {
        var fold = CallConnectionFold()
        fold.read(row("transport", ["transport": "rtc", "requested": "auto"]))
        fold.read(row("connect", [
            "mode": "cold", "warm": false, "total_ms": 1645, "setup_ms": 1040, "dial_ms": 605, "mint_ms": 640, "mint_route": "web",
            "gather_ms": 120, "register_ms": 300, "redials": 0, "ice_ms": 30,
        ]))
        fold.read(row("voice", ["tap_to_voice_ms": 2245, "answer_to_voice_ms": 600, "first_audio_ms": 380, "codec": "opus/48000", "candidate": "relay"]))
        #expect(fold.report == GraineCallConnection(
            transport: .webrtc, prepared: false, preparedAgeSeconds: nil, credential: .web,
            setupMs: 740, loginMs: 300, answerMs: 605, firstWordsMs: 600, tapToVoiceMs: 2245, audio: nil, recoveries: 0
        ))
        var longer = CallConnectionFold()
        longer.read(row("connect", ["mode": "cold", "setup_ms": 200, "register_ms": 300, "dial_ms": 50]))
        #expect(longer.report?.loginMs == 200 && longer.report?.setupMs == 0, "a login longer than its setup is held to it")
    }

    @Test func aPreparedCallSignedInBeforeTheTap() {
        var fold = CallConnectionFold()
        // The contract's own prepared case (call-analytics.json).
        fold.read(row("connect", [
            "mode": "prepared", "warm": true, "total_ms": 812, "setup_ms": 96, "dial_ms": 716, "mint_ms": 188, "mint_route": "direct",
            "gather_ms": 41, "register_ms": 930, "redials": 0, "prepared_age_s": 75, "ice_ms": 38,
        ]))
        let report = fold.report
        #expect(report?.prepared == true && report?.preparedAgeSeconds == 75 && report?.credential == .direct)
        #expect(report?.setupMs == 96 && report?.loginMs == nil, "its login is not part of the tap's wait")
        #expect(report?.answerMs == 716)
        #expect(report?.transport == nil, "no transport row yet")
    }

    @Test func recoveriesAreCountedAndTheAudioIsTheQualityRows() {
        var fold = CallConnectionFold()
        fold.read(row("transport", ["transport": "rtc", "requested": "auto"]))
        fold.read(row("connect", ["mode": "cold", "setup_ms": 900, "dial_ms": 600]))
        // Measured while the call goes: rounded and held as the row would hold them.
        let measured = fold.audio(lossPct: 0.12345, jitterAvgMs: 12.4, jitterMaxMs: 40.6, rttAvgMs: 47.5)
        #expect(measured)
        #expect(fold.report?.audio == GraineCallConnection.Audio(lossPct: 0.12, jitterAvgMs: 12, jitterPeakMs: 41, rttMs: 48))
        #expect(fold.report?.audio?.quality == .good)
        fold.read(row("recovery", ["what": "ice_restart", "after_ms": 3100]))
        fold.read(row("recovery", ["what": "socket_replaced", "after_ms": 2350]))
        #expect(fold.report?.recoveries == 2)
        fold.read(row("quality", ["duration_s": 64, "loss_pct": 2.5, "jitter_avg_ms": 12, "jitter_max_ms": 40, "rtt_avg_ms": 48]))
        #expect(fold.report?.audio == GraineCallConnection.Audio(lossPct: 2.5, jitterAvgMs: 12, jitterPeakMs: 40, rttMs: 48), "the end's row says it for the whole call")
        #expect(fold.report?.audio?.quality == .fair)
    }

    @Test func theQualityWordIsTheCardsVerdict() {
        func quality(_ loss: Double?, _ jitter: Int?, _ rtt: Int?) -> GraineCallConnection.Quality? {
            GraineCallConnection.Audio(lossPct: loss, jitterAvgMs: jitter, rttMs: rtt).quality
        }
        #expect(quality(nil, nil, nil) == nil, "nothing measured, no verdict")
        #expect(quality(0.3, 12, 48) == .good)
        #expect(quality(1.99, 29, 149) == .good)
        #expect(quality(2, nil, nil) == .fair)
        #expect(quality(nil, 30, nil) == .fair)
        #expect(quality(nil, nil, 150) == .fair)
        #expect(quality(8, nil, nil) == .poor)
        #expect(quality(nil, 80, nil) == .poor)
        #expect(quality(nil, nil, 400) == .poor)
        #expect(quality(0, 0, 399) == .fair)
    }

    @Test func aFallbackIsReadFromTheSocketsOwnRows() {
        var fold = CallConnectionFold()
        fold.read(row("media", ["reason": "ice_failed", "transport": "rtc"]))
        fold.read(row("transport", ["transport": "ws", "requested": "auto", "fallback_reason": "ice_timeout"]))
        fold.read(row("connect", ["mode": "cold", "warm": false, "total_ms": 1500, "setup_ms": 1200, "dial_ms": 300, "mint_ms": 0, "mint_route": "web"]))
        #expect(fold.report == GraineCallConnection(transport: .websocket, prepared: false, credential: .web, setupMs: 1200, answerMs: 300, recoveries: 0))
    }

    @Test func theJSONHasEveryKeyNullUntilKnown() throws {
        let empty = GraineCallConnection().json
        #expect(Set(empty.keys) == ["transport", "prepared", "preparedAgeSeconds", "credential", "setupMs", "loginMs", "answerMs", "firstWordsMs", "tapToVoiceMs", "audio", "recoveries"])
        #expect(empty.values.allSatisfy { $0 is NSNull })
        let full = GraineCallConnection(
            transport: .webrtc, prepared: true, preparedAgeSeconds: 75, credential: .direct, setupMs: 96, loginMs: nil, answerMs: 716,
            firstWordsMs: 600, tapToVoiceMs: 1412, audio: .init(lossPct: 0.3, jitterAvgMs: 12, jitterPeakMs: 40, rttMs: 48), recoveries: 1
        ).json
        #expect(JSONSerialization.isValidJSONObject(full))
        #expect(full["transport"] as? String == "webrtc" && full["credential"] as? String == "direct" && full["prepared"] as? Bool == true)
        #expect(full["loginMs"] is NSNull && full["setupMs"] as? Int == 96 && full["recoveries"] as? Int == 1)
        let audio = try #require(full["audio"] as? [String: Any])
        #expect(JSON.canonical(audio) == #"{"jitterAvgMs":12,"jitterPeakMs":40,"lossPct":0.3,"quality":"good","rttMs":48}"#)
        let unmeasured = try #require(GraineCallConnection(audio: .init(jitterPeakMs: 40)).json["audio"] as? [String: Any])
        #expect(unmeasured["quality"] is NSNull && unmeasured["lossPct"] is NSNull)
    }

    @Test func eitherRoadsRowsComeUpFromTheConversation() throws {
        // The voice socket: its transport and connect rows as it opens, each sent and handed up.
        let socketRig = ConversationRig()
        socketRig.make(.websocket).start()
        let socket = try #require(socketRig.network.socket)
        socket.open()
        let handed = socketRig.events.compactMap { event -> String? in if case .row(let frame) = event { return frame }; return nil }
        #expect(analyticsRows(handed).map(\.name) == ["transport", "connect"])
        #expect(handed == analyticsRows(socket.sent).map(\.text), "exactly what went on the socket")
        var fold = CallConnectionFold()
        handed.forEach { fold.read($0) }
        #expect(fold.report?.transport == .websocket && fold.report?.prepared == false)

        // WebRTC: the leg's rows and, once it is connected, its audio.
        let rtcRig = ConversationRig()
        let conversation = rtcRig.make()
        conversation.start()
        let call = try #require(rtcRig.module.call)
        call.emit(.audio(lossPct: 1, jitterAvgMs: 10, jitterMaxMs: 20, rttAvgMs: 30))
        call.emit(.ready)
        call.emit(.connected)
        call.emit(.row(row("connect", ["mode": "cold", "setup_ms": 800, "dial_ms": 400])))
        call.emit(.audio(lossPct: 1, jitterAvgMs: 10, jitterMaxMs: 20, rttAvgMs: 30))
        let up = rtcRig.events.compactMap { event -> String? in
            switch event {
            case .row(let frame): return analyticsRows([frame]).first?.name
            case .audio: return "audio"
            default: return nil
            }
        }
        #expect(up == ["connect", "audio"], "audio before the media path is up is nobody's")
    }

    @Test func theNativeCallsHostCarriesTheReportOnItsSnapshotAndItsOutcomes() throws {
        let report = GraineCallConnection(transport: .websocket, prepared: false, setupMs: 1200, answerMs: 300, recoveries: 0)
        let live = CallsHostSnapshot(state: .active, callId: "c1", direction: .outgoing, connection: report).json
        let connection = try #require(live["connection"] as? [String: Any])
        #expect(connection["transport"] as? String == "websocket" && connection["setupMs"] as? Int == 1200 && connection["audio"] is NSNull)
        #expect(JSONSerialization.isValidJSONObject(live))
        #expect(CallsHostSnapshot(state: .idle, callId: "c1", connection: report).json["connection"] is NSNull, "at idle nothing of a call shows")
        #expect(CallsHostSnapshot(state: .connecting, callId: "c1").json["connection"] is NSNull, "null until known")
        let ended = CallsHostEvent.outcomePayload(.ended(.remote), callId: "c1", durationSeconds: 64, connection: report)
        #expect((ended["connection"] as? [String: Any])?["answerMs"] as? Int == 300)
        #expect(CallsHostEvent.outcomePayload(.missed, callId: "c2")["connection"] == nil, "said only when anything of it was known")
    }

    @Test @MainActor func theObjectiveCCallsCarryTheNewKeys() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        let calls = GraineObjC(graine: rig.graine).calls
        let snapshot = try #require(parse(calls.snapshotJSON) as? [String: Any])
        for key in ["reason", "agentLevel", "agentLevelHeard", "connectedAt", "transcript", "connection", "endReason"] {
            #expect(snapshot[key] != nil, "\(key)")
        }
        #expect(snapshot["connection"] is NSNull && snapshot["reason"] is NSNull && snapshot["connectedAt"] is NSNull)
        #expect((snapshot["agentLevel"] as? NSNumber)?.doubleValue == 0)
        #expect(calls.connectionJSON == nil && calls.reason == nil && calls.connectedAt == nil && calls.agentLevel == 0 && !calls.agentLevelHeard)
        // An outcome carries the report it had.
        let report = GraineCallConnection(transport: .webrtc, prepared: true, preparedAgeSeconds: 75, credential: .direct, setupMs: 96, answerMs: 716, recoveries: 0)
        let outcome = GraineObjCCallOutcome(ObjCBridge.outcome(.ended(.local), callId: "c1", busy: false, connectedSeconds: 64, hosted: false, connection: report))
        let json = try #require(parse(outcome.json) as? [String: Any])
        #expect((json["connection"] as? [String: Any])?["preparedAgeSeconds"] as? Int == 75)
        let connection = try #require(parse(outcome.connectionJSON) as? [String: Any])
        #expect(connection["credential"] as? String == "direct" && connection["loginMs"] is NSNull)
        #expect(GraineObjCCallOutcome(ObjCBridge.outcome(.missed, callId: "c2", busy: true, connectedSeconds: nil, hosted: false)).connectionJSON == nil)
        let cls = try #require(NSClassFromString("GraineObjCCalls") as? NSObject.Type)
        for s in ["reason", "agentLevel", "agentLevelHeard", "connectedAt", "connectionJSON"] {
            #expect(cls.instancesRespond(to: NSSelectorFromString(s)), "-[GraineObjCCalls \(s)]")
        }
        #expect((NSClassFromString("GraineObjCCallOutcome") as? NSObject.Type)?.instancesRespond(to: NSSelectorFromString("connectionJSON")) == true)
    }
}

// MARK: - 4. Booking

@Suite struct BookingPublicStateTests {
    private func calls(hosted: Bool = true, platforms: [String] = [], usersCanBook: Bool = true) -> GraineHostedCallsSettings? {
        GraineHostedCallsSettings.parse(["hosted": hosted, "platforms": platforms, "scheduling": ["usersCanBook": usersCanBook]])
    }

    @Test func whyNotIsTheFirstRuleThatFails() {
        #expect(Booking.unavailableReason(calls: nil, loaded: false, identified: true) == "not_loaded")
        #expect(Booking.unavailableReason(calls: nil, loaded: true, identified: true) == "rings_not_set_up")
        #expect(Booking.unavailableReason(calls: calls(hosted: false), loaded: true, identified: true) == "rings_not_set_up")
        #expect(Booking.unavailableReason(calls: calls(platforms: ["android"]), loaded: true, identified: true) == "rings_not_set_up")
        #expect(Booking.unavailableReason(calls: calls(usersCanBook: false), loaded: true, identified: false) == "scheduling_off")
        #expect(Booking.unavailableReason(calls: calls(), loaded: true, identified: false) == "not_identified")
        #expect(Booking.unavailableReason(calls: calls(platforms: ["ios"]), loaded: true, identified: true) == nil)
        // The same rule bookingAvailable follows.
        for settings in [nil, calls(hosted: false), calls(usersCanBook: false), calls()] {
            for identified in [false, true] {
                #expect(Booking.available(calls: settings, identified: identified) == (Booking.unavailableReason(calls: settings, loaded: true, identified: identified) == nil))
            }
        }
    }

    @Test @MainActor func theInstanceSaysWhyNotAndTheObjectiveCFacadeToo() {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        let facade = GraineObjC(graine: rig.graine)
        #expect(rig.graine.bookingUnavailableReason == "not_loaded")
        rig.session(["calls": ["hosted": true, "platforms": ["ios"], "scheduling": ["usersCanBook": true]]])
        #expect(rig.graine.bookingUnavailableReason == "not_identified")
        #expect(facade.bookingUnavailableReason == "not_identified" && !facade.bookingAvailable)
        rig.graine.identify(["user_id": "P-1"])
        #expect(rig.graine.bookingUnavailableReason == nil && rig.graine.bookingAvailable)
        #expect(facade.bookingUnavailableReason == nil)
    }

    @Test func theSlotsAreTheSheetsFiveMinuteMarks() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let rules = GraineSchedulingRules(usersCanBook: true, minLeadMinutes: 5, maxDaysAhead: 2)
        // 14 Oct 2026, 18:02 in Kolkata.
        let now = try #require(ChatHistory.time("2026-10-14T12:32:00Z"))
        let today = Booking.slots(rules, day: now, now: now, calendar: calendar)
        #expect(today.first == ChatHistory.time("2026-10-14T18:10:00+05:30"), "now + 5 minutes, on the next 5-minute mark")
        #expect(today.last == ChatHistory.time("2026-10-14T23:55:00+05:30"))
        #expect(zip(today, today.dropFirst()).allSatisfy { $1.timeIntervalSince($0) == 300 }, "every 5 minutes")
        let tomorrow = Booking.slots(rules, day: now.addingTimeInterval(86_400), now: now, calendar: calendar)
        #expect(tomorrow.count == 288 && tomorrow.first == ChatHistory.time("2026-10-15T00:00:00+05:30"))
        let last = Booking.slots(rules, day: now.addingTimeInterval(2 * 86_400), now: now, calendar: calendar)
        #expect(last.last == ChatHistory.time("2026-10-16T18:00:00+05:30"), "the latest, on a 5-minute mark at or before it")
        #expect(Booking.slots(rules, day: now.addingTimeInterval(3 * 86_400), now: now, calendar: calendar).isEmpty, "beyond maxDaysAhead")
        #expect(Booking.slots(rules, day: now.addingTimeInterval(-86_400), now: now, calendar: calendar).isEmpty, "before today")
        // What the sheet itself offers on those days.
        let days = Booking.days(rules, now: now, calendar: calendar)
        #expect(days.map { Booking.slots(rules, day: $0.start, now: now, calendar: calendar).first } == days.map(\.first))
        #expect(days.map { Booking.slots(rules, day: $0.start, now: now, calendar: calendar).last } == days.map(\.last))
    }

    @Test @MainActor func theObjectiveCSlotsAreISOTimesForADayInTheDevicesZone() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session(["calls": ["hosted": true, "scheduling": ["usersCanBook": true, "maxDaysAhead": 3, "minLeadMinutes": 10]]])
        let facade = GraineObjC(graine: rig.graine)
        // Two days on: wholly inside the rules, whatever the time is now.
        let later = try #require(Calendar.current.date(byAdding: .day, value: 2, to: Date()))
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: later)
        let isoDay = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        let slots = try #require(parse(facade.bookingSlotsJSON(forDay: isoDay)) as? [String])
        let expected = rig.graine.bookingSlots(day: later).map { Scheduling.isoTime($0) }
        #expect(!slots.isEmpty && slots == expected)
        #expect(slots.allSatisfy { Scheduling.date($0) != nil }, "ISO-8601, with the device's offset")
        #expect(Scheduling.date(slots[0]).map { Calendar.current.isDate($0, inSameDayAs: later) } == true)
        #expect(facade.bookingSlotsJSON(forDay: "2026-02-30") == "[]", "a date that does not exist")
        #expect(facade.bookingSlotsJSON(forDay: "tomorrow") == "[]")
        #expect(facade.bookingSlotsJSON(forDay: "1999-01-01") == "[]", "a day the sheet does not offer")
        #expect(ObjCBridge.day("2026-10-21", calendar: Calendar(identifier: .gregorian)) != nil)
        let cls = try #require(NSClassFromString("GraineObjC") as? NSObject.Type)
        for s in ["bookingUnavailableReason", "bookingSlotsJSONForDay:"] {
            #expect(cls.instancesRespond(to: NSSelectorFromString(s)), "-[GraineObjC \(s)]")
        }
    }
}

// MARK: - 5. Components

@Suite @MainActor struct ComponentsPublicStateTests {
    private let frame: [String: Any] = [
        "widget_id": "show_plans:1", "kind": "plan_comparison", "fallback_text": "Gold or Silver?",
        "data": ["title": "Plans", "items": [["id": "gold", "title": "Gold"]]],
    ]

    @Test func theComponentAndItsLoadingArePublic() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        let components = rig.graine.components
        #expect(components.current == nil && !components.pending && components.pendingKind == "")
        rig.graine.componentPending(["kind": "plan_comparison"])
        #expect(components.pending && components.pendingKind == "plan_comparison")
        rig.graine.componentArrived(frame)
        #expect(!components.pending && components.pendingKind == "", "arrived: no longer loading")
        let current = try #require(components.current)
        #expect(current.id == "show_plans:1" && current.kind == "plan_comparison" && current.fallbackText == "Gold or Silver?")
        #expect(JSON.string(current.data["title"]) == "Plans")
        rig.graine.answerComponent(widgetId: "show_plans:1", data: ["id": "gold"], summary: "Gold, please")
        #expect(components.current == nil, "answered")
        // A loader that nothing follows stops when the runtime's own wait does.
        rig.graine.componentPending([:])
        #expect(components.pending && components.pendingKind == "")
        rig.scheduler.advance(Double(WidgetRules.pendingWidgetMs) / 1_000 - 0.1)
        #expect(components.pending)
        rig.scheduler.advance(0.2)
        #expect(!components.pending)
        rig.graine.componentPending(["kind": "choices"])
        rig.graine.forgetComponents()
        #expect(!components.pending, "a new conversation ends it")
    }

    @Test func closingOneTellsTheAgentQuietlyAndKeepsItToShowAgain() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session()
        rig.graine.chat.open()
        let socket = try #require(rig.network.socket)
        socket.open()
        socket.clearSent()
        rig.graine.componentArrived(frame)
        rig.graine.dismissComponent(widgetId: "someone_else:9")
        #expect(rig.graine.components.current != nil && socket.sent.isEmpty, "not the component on screen: nothing")
        rig.graine.dismissComponent(widgetId: "show_plans:1")
        #expect(rig.graine.components.current == nil)
        let event = try #require(socket.sentFrames.first { JSON.string($0["type"]) == "app_event" }?["event"] as? [String: Any])
        #expect(event["name"] as? String == "component_dismissed" && event["quiet"] as? Bool == true)
        #expect(((event["data"] as? [String: Any])?["answered"] as? Bool) == false)
        #expect(rig.graine.reopenComponent(), "kept, to be shown again")
        #expect(rig.graine.components.current?.id == "show_plans:1")
    }

    @Test func theObjectiveCFacadeReadsItAndDismissesItByItsId() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        let facade = GraineObjC(graine: rig.graine)
        let registration = facade.observeComponent {}
        #expect(facade.componentJSON == nil && !facade.componentPending && facade.componentPendingKind == "")
        rig.graine.componentPending(["kind": "choices"])
        #expect(facade.componentPending && facade.componentPendingKind == "choices")
        rig.graine.componentArrived(frame)
        let component = try #require(parse(facade.componentJSON) as? [String: Any])
        #expect(component["id"] as? String == "show_plans:1" && component["kind"] as? String == "plan_comparison")
        #expect(component["fallbackText"] as? String == "Gold or Silver?" && (component["data"] as? [String: Any])?["title"] as? String == "Plans")
        facade.chat.dismissWidget(id: "show_plans:1")
        #expect(facade.componentJSON == nil, "-[GraineObjCChat dismissWidgetWithId:]")
        registration.unregister()
        let cls = try #require(NSClassFromString("GraineObjC") as? NSObject.Type)
        for s in ["componentJSON", "componentPending", "componentPendingKind", "observeComponent:"] {
            #expect(cls.instancesRespond(to: NSSelectorFromString(s)), "-[GraineObjC \(s)]")
        }
    }
}
