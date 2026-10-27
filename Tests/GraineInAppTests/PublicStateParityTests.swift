import Foundation
import Testing
@_spi(GraineRTC) @testable import GraineInApp

/*
 * 0.14.5 — THE PUBLIC STATE IN THE CONTRACT'S WORDS (sdk/contract/PUBLIC-STATE.md):
 * the chat's status (§1), a native call's phase (§3), and the size an app event
 * is held to, with the native call that now hears it (§8). The rules are React
 * Native's and Flutter's (`chatStatusFrom`, `GraineChatSession.status`;
 * `phaseOf`, `GraineCallPhase.of`), word for word.
 */

@Suite struct ChatStatusWordsTests {
    @Test func everyStatusSaysTheWordEverySDKUses() {
        let all: [GraineChatStatus] = [.idle, .connecting, .connected, .reconnecting(attempt: 2), .offline, .failed, .disconnected]
        #expect(all.map(\.wire) == ["idle", "connecting", "connected", "reconnecting", "offline", "failed", "disconnected"])
    }

    @Test func onlineIsConnectedByItsOldName() {
        #expect(GraineChatStatus.online == .connected)
        #expect(GraineChatStatus.online.wire == "connected")
        let status: GraineChatStatus = .connected
        switch status {
        case .online: break
        default: Issue.record("`case .online` still matches a connected chat")
        }
    }

    /// The contract's rule, first match wins — React Native's `chatStatusFrom`, Flutter's `status`.
    @Test func theStatusIsTheContractsFirstMatch() {
        let rows: [(link: GraineChatStatus, disconnected: Bool, waiting: Bool, expected: GraineChatStatus)] = [
            (.connected, true, true, .connected),
            (.reconnecting(attempt: 3), true, true, .reconnecting(attempt: 3)),
            (.connecting, true, true, .connecting),
            (.failed, true, true, .disconnected),
            (.idle, true, false, .disconnected),
            (.failed, false, true, .failed),
            (.failed, false, false, .failed),
            (.idle, false, true, .offline),
            (.idle, false, false, .idle),
        ]
        for row in rows {
            #expect(GraineChatStatus.of(link: row.link, disconnected: row.disconnected, waiting: row.waiting) == row.expected,
                    "\(row.link.wire) disconnected=\(row.disconnected) waiting=\(row.waiting)")
        }
    }
}

@Suite @MainActor struct ChatStatusOnTheWireTests {
    private let welcome: [String: Any] = ["type": "text", "data": "<beginning_of_stream>Hi! How can I help?<end_of_stream>"]

    @Test func aChatThatGaveUpSaysFailedNotOffline() throws {
        let rig = ChatRig()
        rig.chat.open()
        for delay in ChatWire.reconnectDelays {
            rig.network.socket?.fail("refused")
            rig.scheduler.advance(delay + 0.1)
        }
        rig.network.socket?.fail("refused")
        #expect(rig.chat.publicStatus == .failed)
        rig.chat.retry()
        #expect(rig.chat.publicStatus == .connecting, "a retry connects again")
    }

    @Test func graineEndingItSaysDisconnected() throws {
        for code in [4408, 4410] {
            let rig = ChatRig()
            let socket = rig.online()
            #expect(rig.chat.publicStatus == .connected)
            socket.frame(welcome)
            socket.serverClose(code, reason: "ended")
            #expect(rig.chat.publicStatus == .disconnected, "\(code)")
            rig.chat.send("Hello?")
            #expect(rig.chat.publicStatus == .connecting, "\(code): the next message connects again")
        }
    }

    @Test func aMessageWaitingWithNothingConnectingItIsOffline() throws {
        let rig = ChatRig()
        rig.online()
        rig.chat.hold("background")
        #expect(rig.chat.publicStatus == .idle, "held down, nothing waiting")
        rig.chat.send("Are you there?")
        #expect(rig.chat.publicStatus == .offline, "in the chat, a message waiting, nothing connecting it")
        rig.chat.release("background")
        #expect(rig.chat.publicStatus == .connecting)
        rig.network.socket?.open()
        #expect(rig.chat.publicStatus == .connected)
    }

    @Test func theAgentEndingItIsIdleNeverFailed() throws {
        let rig = ChatRig()
        let socket = rig.online()
        socket.frame(welcome)
        socket.frame(["type": "conversation_end"])
        socket.serverClose(1000, reason: "conversation ended")
        #expect(rig.chat.publicStatus == .idle)
    }

    @Test func theInstanceSaysTheContractsWordAndTheFacadeKeepsItsOwn() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session()
        rig.graine.chat.open()
        let socket = try #require(rig.network.socket)
        socket.open()
        #expect(rig.graine.chat.status == .connected)
        #expect(rig.graine.chat.online)
        let facade = GraineObjCChat(graine: rig.graine)
        #expect(facade.status == "online", "a bridge built before 0.14.5 reads the words it always read")
        #expect(facade.phase == "connected")
        let snapshot = try #require(JSON.object(from: facade.snapshotJSON))
        #expect(JSON.string(snapshot["status"]) == "online")
        #expect(JSON.string(snapshot["phase"]) == "connected")
    }
}

@Suite @MainActor struct CallPhaseWordTests {
    /// Flutter's `GraineCallPhase.of` and React Native's `phaseOf`, with the missed ring only the calls can know.
    @Test func thePhaseIsTheWordEverySDKUses() {
        #expect(GraineCallPhase.allCases.map(\.rawValue) == ["idle", "ringing", "calling", "connecting", "active", "reconnecting", "ended", "missed"])
        let rows: [(GraineCallState, GraineCallDirection?, Bool, Bool, GraineCallPhase)] = [
            (.idle, nil, false, false, .idle),
            (.idle, nil, false, true, .missed),
            (.idle, .incoming, true, true, .missed),
            (.ringing, .incoming, false, false, .ringing),
            (.ringing, .incoming, true, true, .ringing),
            (.connecting, .outgoing, false, false, .calling),
            (.connecting, .incoming, false, false, .connecting),
            (.connecting, nil, false, false, .connecting),
            (.connecting, .outgoing, true, false, .calling),
            (.active, .outgoing, false, false, .active),
            (.active, .incoming, true, false, .reconnecting),
            (.active, .outgoing, true, true, .reconnecting),
            (.ended(.local), .outgoing, false, false, .ended),
            (.ended(.missed), .incoming, false, true, .ended),
            (.ended(.failed), .incoming, true, false, .ended),
        ]
        for (state, direction, reconnecting, missed, expected) in rows {
            #expect(GraineCallPhase.of(state, direction: direction, reconnecting: reconnecting, missed: missed) == expected,
                    "\(state) \(String(describing: direction)) reconnecting=\(reconnecting) missed=\(missed)")
        }
    }

    @Test func theFacadeSaysThePhase() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        let facade = GraineObjCCalls(graine: rig.graine)
        #expect(facade.phase == "idle")
        let snapshot = try #require(JSON.object(from: facade.snapshotJSON))
        #expect(JSON.string(snapshot["phase"]) == "idle")
    }
}

/// Hears what the instance says is wrong.
private final class ErrorListener: GraineListener {
    var errors: [String] = []
    func onError(_ message: String) { errors.append(message) }
}

@Suite @MainActor struct AppEventSizeTests {
    /// The event, as JSON, exactly at the limit — every byte counted, a two-byte character as two.
    private func data(bytes: Int, unit: String = "a") -> [String: Any] {
        let base = ChatWire.appEventBytes(name: "n", detail: nil, data: ["blob": ""])
        let count = (bytes - base) / unit.utf8.count
        return ["blob": String(repeating: unit, count: count)]
    }

    @Test func theLimitIsEightKilobytesOfTheEventAsJSON() {
        #expect(GraineInApp.reportEventMaxBytes == 8_192)
        #expect(ChatWire.appEventBytes(name: "n", detail: nil, data: ["blob": ""]) == #"{"name":"n","data":{"blob":""}}"#.utf8.count)
        #expect(ChatWire.appEventBytes(name: "n", detail: nil, data: data(bytes: 8_192)) == 8_192)
        let twoByte = data(bytes: 8_191, unit: "é")
        #expect(ChatWire.appEventBytes(name: "n", detail: nil, data: twoByte) == 8_191, "bytes, not characters")
        #expect((twoByte["blob"] as? String)?.count == (8_191 - 31) / 2)
        // The frame is the event and its envelope, nothing else.
        let frame = ChatWire.appEventFrame(name: "n", detail: nil, data: data(bytes: 8_192))
        #expect(frame.utf8.count == 8_192 + #"{"type":"app_event","event":}"#.utf8.count)
    }

    @Test func anEventAtTheLimitIsSentAndOneByteMoreNeverIs() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session()
        let heard = ErrorListener()
        rig.graine.addListener(heard)
        rig.graine.chat.open()
        let socket = try #require(rig.network.socket)
        socket.open()
        socket.clearSent()

        rig.graine.reportEvent("n", data: data(bytes: 8_192))
        #expect(socket.sentTypes == ["app_event"], "at the limit: sent")
        #expect(heard.errors.isEmpty)

        socket.clearSent()
        var over = data(bytes: 8_192)
        over["blob"] = (over["blob"] as! String) + "a"
        rig.graine.reportEvent("n", data: over)
        #expect(socket.sent.isEmpty, "one byte over: never sent")
        #expect(socket.closed == false, "and the conversation goes on")
        let error = try #require(heard.errors.first)
        #expect(error.contains("8193 bytes") && error.contains("8192"), "it says how big it was, and the limit")
        #expect(error.contains(#"reportEvent("n")"#))

        heard.errors = []
        rig.graine.reportEvent("n", detail: String(repeating: "d", count: 9_000))
        #expect(socket.sent.isEmpty, "the detail counts too")
        #expect(heard.errors.count == 1)
    }

    @Test func aLiveNativeCallTakesTheEventBeforeTheChat() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session()
        rig.graine.chat.open()
        let socket = try #require(rig.network.socket)
        socket.open()
        socket.clearSent()

        var taken: [String] = []
        var takes = true
        let stop = rig.graine.onAppEvent { frame in
            taken.append(frame)
            return takes
        }
        rig.graine.reportEvent("reminder_opened", detail: "From the breakfast reminder")
        #expect(taken == [ChatWire.appEventFrame(name: "reminder_opened", detail: "From the breakfast reminder", data: [:])])
        #expect(socket.sent.isEmpty, "the call took it")

        takes = false
        rig.graine.reportEvent("reminder_opened")
        #expect(socket.sentTypes == ["app_event"], "a call that is not connected leaves it to the chat")

        stop()
        socket.clearSent()
        taken = []
        rig.graine.reportEvent("reminder_opened")
        #expect(taken.isEmpty && socket.sentTypes == ["app_event"])

        // Over the limit, nothing reaches a call either.
        takes = true
        let again = rig.graine.onAppEvent { frame in taken.append(frame); return true }
        rig.graine.reportEvent("n", data: data(bytes: 8_193))
        #expect(taken.isEmpty)
        again()
    }

    @Test func theCallSendsItOnItsOwnChannel() throws {
        let frame = ChatWire.appEventFrame(name: "reminder_opened", detail: nil, data: ["quiet": true])

        // WebRTC: the control channel, never coalesced with another event.
        let rtc = ConversationRig()
        let conversation = rtc.make()
        conversation.start()
        let call = try #require(rtc.module.call)
        conversation.sendEvent(frame)
        conversation.sendEvent(frame)
        #expect(call.sent.filter { $0.frame == frame }.count == 2)
        #expect(call.sent.last?.kind == nil)

        // The WebSocket: on the open socket, and nothing before it opens.
        let ws = ConversationRig()
        let onSocket = ws.make(.websocket)
        onSocket.start()
        let socket = try #require(ws.network.sockets.last)
        onSocket.sendEvent(frame)
        #expect(!socket.sent.contains(frame), "not before the socket opens")
        socket.open()
        onSocket.sendEvent(frame)
        #expect(socket.sent.contains(frame))
    }
}
