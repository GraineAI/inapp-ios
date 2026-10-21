import Foundation
import Testing
@testable import GraineInApp

/*
 * 0.14.0, CHAT SESSIONS (sdk/contract/PUBLIC-STATE.md; history.json
 * `sessionFrame` and `sessions`, whose vectors HistoryContractTests runs): the
 * server's `{"type":"session","id","at"}` frame, once as a connection starts,
 * names the chat's session; every turn carries the session it was said in —
 * a line typed before the chat connected, or said before the frame arrived,
 * takes the session of the connection that carries it once the frame
 * arrives, never a stray one with no id; a new connection starts without
 * one; an identity change clears it, and the lines it keeps join the next.
 */

private func sessionFrame(_ id: Any?) -> [String: Any] {
    ["type": "session", "id": id ?? NSNull(), "at": "2026-10-21T12:00:00Z"]
}

private func says(_ socket: FakeSocket, _ words: String) {
    socket.frame(["type": "text", "data": "<beginning_of_stream>\(words)<end_of_stream>"])
}

private func person(_ value: String?) -> IdentityWire.Fields {
    IdentityWire.Fields(value: value, installId: "i-1", memory: true, timezone: "Asia/Kolkata", callId: nil)
}

@Suite struct ChatSessionConnectionTests {
    private func sessions(_ rig: ChatRig) -> [GraineChatSession] {
        ChatSessions.of(rig.chat.transcript.turns, sessionId: rig.chat.sessionId)
    }

    @Test func theSessionFrameNamesTheConnectionsSessionAndEveryTurnSaidInIt() throws {
        let rig = ChatRig()
        let socket = rig.online()
        #expect(rig.chat.sessionId == nil, "until the server names it")
        socket.frame(sessionFrame("s-1"))
        #expect(rig.chat.sessionId == "s-1")
        says(socket, "Hi!")
        rig.chat.send("Hello")
        #expect(rig.chat.transcript.turns.map(\.session) == ["s-1", "s-1"])
        #expect(sessions(rig).map(\.id) == ["s-1"] && sessions(rig).map(\.current) == [true])
        socket.frame(sessionFrame(""))
        #expect(rig.chat.sessionId == nil, "an empty id is no session")
    }

    @Test func linesSaidBeforeTheFrameTakeTheConnectionsSessionWhenItComes() throws {
        let rig = ChatRig()
        rig.chat.open()
        rig.chat.send("Typed before it connected")
        let socket = try #require(rig.network.socket)
        socket.open()
        says(socket, "Welcome!")
        #expect(rig.chat.transcript.turns.map(\.session) == [nil, nil], "the frame has not come")
        socket.frame(sessionFrame("s-9"))
        #expect(rig.chat.transcript.turns.map(\.session) == ["s-9", "s-9"], "never a stray session with no id")
        #expect(sessions(rig).count == 1 && sessions(rig).first?.turns == 2)
    }

    @Test func aNewConnectionHasNoSessionUntilItsFrameAndItsTurnsAreItsOwn() throws {
        let rig = ChatRig()
        let first = rig.online()
        first.frame(sessionFrame("s-1"))
        says(first, "Hi!")
        rig.chat.send("Where is my order?")
        first.fail("The network went away.")
        rig.scheduler.advance(ChatWire.reconnectDelays[0] + 0.1)
        let second = try #require(rig.network.socket)
        second.open()
        #expect(rig.chat.sessionId == nil, "a new connection: its session is its own, unknown until its frame")
        second.frame(sessionFrame("s-2"))
        says(second, "Welcome back!")
        #expect(rig.chat.transcript.turns.map(\.session) == ["s-1", "s-1", "s-2"])
        #expect(sessions(rig).map(\.id) == ["s-1", "s-2"])
        #expect(sessions(rig).map(\.current) == [false, true])
    }

    @Test func aServerThatSendsNoSessionsMakesOneSessionWithNoIdNeverCurrent() throws {
        let rig = ChatRig()
        let socket = rig.online()
        says(socket, "Hello!")
        rig.chat.send("Hi")
        #expect(rig.chat.sessionId == nil)
        #expect(sessions(rig) == [GraineChatSession(
            id: nil, startedAt: Date(timeIntervalSince1970: 2_000), endedAt: Date(timeIntervalSince1970: 2_000),
            channel: .chat, turns: 2, current: false
        )])
    }

    @Test func restoredTurnsKeepTheSessionTheyWereSaidIn() throws {
        let rig = ChatRig()
        let socket = rig.online()
        socket.frame(sessionFrame("s-9"))
        socket.frame(["type": "history", "turns": [
            ["id": "h1", "role": "user", "text": "Hi", "at": "2026-10-20T10:00:00Z", "session": "s-7"],
            ["id": "h2", "role": "assistant", "text": "Hello!", "at": "2026-10-20T10:00:03Z", "session": "s-7"],
            ["id": "h3", "role": "assistant", "text": "Sure.", "at": "2026-10-21T08:00:02Z", "channel": "voice", "session": "c-3"],
        ]])
        rig.chat.send("Back again")
        #expect(rig.chat.transcript.turns.map(\.session) == ["s-7", "s-7", "c-3", "s-9"])
        #expect(sessions(rig).map(\.id) == ["s-7", "c-3", "s-9"])
        #expect(sessions(rig).map(\.channel) == [.chat, .voice, .chat])
        #expect(sessions(rig).map(\.current) == [false, false, true])
    }

    @Test func anIdentityChangeClearsTheSessionAndTheLinesItKeepsJoinTheNextOne() throws {
        let rig = ChatRig()
        rig.identity = person(nil)
        let first = rig.online()
        first.frame(sessionFrame("s-anon"))
        says(first, "Hi!")
        first.fail("The network went away.")
        rig.chat.send("Still there?")
        rig.identity = person("P-1")
        rig.chat.identityChanged(to: "P-1")
        #expect(rig.chat.sessionId == nil, "the identity before's session is not this one's")
        #expect(rig.chat.transcript.turns.map(\.text) == ["Still there?"])
        #expect(rig.chat.transcript.turns.map(\.session) == [nil])
        let next = try #require(rig.network.socket)
        next.open()
        next.frame(sessionFrame("s-user"))
        #expect(rig.chat.transcript.turns.map(\.session) == ["s-user"], "the line kept joins the next session")
        #expect(rig.chat.sessionId == "s-user")
    }
}

@Suite @MainActor struct ChatSessionPublicStateTests {
    private func parse(_ text: String?) -> Any? {
        text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
    }

    @Test func theChatPublishesItsSessionsAndTheObjectiveCFacadeMirrorsThem() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session()
        rig.graine.chat.open()
        let socket = try #require(rig.network.socket)
        socket.open()
        #expect(rig.graine.chat.sessionId == nil && rig.graine.chat.sessions.isEmpty)
        socket.frame(sessionFrame("s-9f2c"))
        says(socket, "Hello!")
        #expect(rig.graine.chat.sessionId == "s-9f2c")
        #expect(rig.graine.chat.turns.map(\.session) == ["s-9f2c"])
        #expect(rig.graine.chat.sessions.map(\.id) == ["s-9f2c"] && rig.graine.chat.sessions.first?.current == true)

        let objc = GraineObjC(graine: rig.graine).chat
        #expect(objc.sessionId == "s-9f2c")
        #expect(objc.turns.first?.session == "s-9f2c")
        let snapshot = try #require(parse(objc.snapshotJSON) as? [String: Any])
        #expect(snapshot["sessionId"] as? String == "s-9f2c")
        let turns = try #require(snapshot["turns"] as? [[String: Any]])
        #expect(turns.first?["session"] as? String == "s-9f2c")
        let listed = try #require(snapshot["sessions"] as? [[String: Any]])
        #expect(listed.first?["id"] as? String == "s-9f2c" && listed.first?["current"] as? Bool == true && listed.first?["turns"] as? Int == 1)
        let json = try #require(parse(objc.sessionsJSON) as? [[String: Any]])
        #expect(json.count == 1 && json.first?["channel"] as? String == "chat" && json.first?["startedAt"] is NSNumber)

        // The selectors Kotlin Multiplatform's iOS side calls.
        let chat = try #require(NSClassFromString("GraineObjCChat") as? NSObject.Type)
        for name in ["sessionId", "sessionsJSON"] { #expect(chat.instancesRespond(to: NSSelectorFromString(name)), "\(name)") }
        #expect((NSClassFromString("GraineObjCChatTurn") as? NSObject.Type)?.instancesRespond(to: NSSelectorFromString("session")) == true)
    }

    @Test func withNoSessionTheKeysAreNull() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session()
        rig.graine.chat.open()
        let socket = try #require(rig.network.socket)
        socket.open()
        says(socket, "Hello!")
        let objc = GraineObjC(graine: rig.graine).chat
        let snapshot = try #require(parse(objc.snapshotJSON) as? [String: Any])
        #expect(snapshot["sessionId"] is NSNull, "null, never absent")
        let turns = try #require(snapshot["turns"] as? [[String: Any]])
        #expect(turns.first?["session"] is NSNull)
        let listed = try #require(snapshot["sessions"] as? [[String: Any]])
        #expect(listed.count == 1 && listed.first?["id"] is NSNull && listed.first?["current"] as? Bool == false)
    }
}
