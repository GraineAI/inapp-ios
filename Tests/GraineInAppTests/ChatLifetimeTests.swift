import Foundation
import Testing
@testable import GraineInApp

/*
 * HOW LONG A CONVERSATION LASTS (contract/DESIGN.md): closing the chat window
 * does not end the conversation at once. With no window showing it, the chat
 * closes — normally, as close() closes it — 15 seconds (the close delay, 0.14.3;
 * five minutes of quiet in 0.14.0–0.14.1) after the later of the moment the last
 * window left and the last message either way; a window back in time continues
 * it. When Graine ends it itself — idle (4408) or at the session's time limit
 * (4410) — it is not dialled again on its own and the header says
 * "Disconnected"; any other dropped connection reconnects as before. On the
 * fake clock: nothing here waits.
 */

/// The close delay a chat starts with: 15 seconds.
private let delay = Double(ChatWire.closeDelaySeconds)

private let welcome: [String: Any] = ["type": "text", "data": "<beginning_of_stream>Hi! How can I help?<end_of_stream>"]

private func letGo(_ events: [ChatConnection.Event]) -> Bool {
    events.contains { if case .letGo = $0 { return true }; return false }
}

@Suite struct ChatLifetimeTests {
    @Test func aChatNoWindowShowsIsLetGoFifteenSecondsAfterItLeft() throws {
        #expect(ChatWire.closeDelaySeconds == 15)
        let rig = ChatRig()
        let socket = rig.online()
        socket.frame(welcome)
        rig.chat.shown(false)
        rig.scheduler.advance(delay - 0.1)
        #expect(rig.chat.status == .connected && !socket.sent.contains(CallWire.stopFrame), "kept a moment after it left the screen")
        rig.scheduler.advance(0.2)
        #expect(socket.sent.last == CallWire.stopFrame, "hung up as close() hangs up: the stop frame first")
        #expect(rig.chat.status == .idle)
        #expect(letGo(rig.events))
        #expect(rig.chat.transcript.turns.map { $0.text } == ["Hi! How can I help?"], "the lines stay")
        rig.scheduler.advance(60)
        #expect(rig.network.sockets.count == 1, "not dialled again on its own")
        rig.chat.send("Back again")
        #expect(rig.network.sockets.count == 2, "the next message connects again")
    }

    @Test func somethingSaidWhileUnseenStartsTheWaitAgain() throws {
        let rig = ChatRig()
        let socket = rig.online()
        rig.chat.shown(false)
        rig.scheduler.advance(10)
        socket.frame(["type": "text", "data": "<beginning_of_stream>Still there?<end_of_stream>"])
        rig.scheduler.advance(10)
        #expect(rig.chat.status == .connected, "the agent's message started the wait again")
        socket.frame(["type": "quick_replies", "replies": [["label": "Yes", "text": "Yes"]]])
        rig.scheduler.advance(10)
        #expect(rig.chat.status == .connected, "so did its suggested replies")
        rig.chat.send("Yes")
        rig.scheduler.advance(delay - 1)
        #expect(rig.chat.status == .connected, "so did the customer's message")
        rig.scheduler.advance(1.1)
        #expect(rig.chat.status == .idle)
        #expect(socket.sent.last == CallWire.stopFrame)
    }

    @Test func aWindowShowingItAgainContinuesTheSameConversation() throws {
        let rig = ChatRig()
        let socket = rig.online()
        socket.frame(welcome)
        rig.chat.shown(false)
        rig.scheduler.advance(delay - 1)
        // What a window does as it comes on screen.
        rig.chat.shown(true)
        rig.chat.open()
        #expect(rig.network.sockets.count == 1, "a new connection for a conversation that was still up")
        rig.scheduler.advance(900)
        #expect(rig.chat.status == .connected, "a chat on screen is never let go for being quiet")
        #expect(!socket.sent.contains(CallWire.stopFrame))
        #expect(rig.chat.transcript.turns.count == 1, "nothing on screen changed, no second welcome")
        #expect(!letGo(rig.events))
    }

    @Test func closeStillHangsUpAtOnceAndNothingIsLeftWatching() throws {
        let rig = ChatRig()
        let socket = rig.online()
        rig.chat.shown(false)
        rig.chat.close()
        #expect(socket.sent.last == CallWire.stopFrame)
        #expect(rig.chat.status == .idle)
        rig.scheduler.advance(600)
        #expect(!letGo(rig.events), "a chat already closed is not let go again")
        #expect(rig.network.sockets.count == 1)
    }

    @Test func aChatHeldInTheBackgroundPastItsQuietMinutesIsNotDialledAgain() throws {
        let rig = ChatRig()
        rig.online()
        rig.chat.shown(false)
        rig.chat.hold("background")
        rig.scheduler.advance(delay + 1)
        rig.chat.release("background")
        #expect(rig.network.sockets.count == 1, "let go while away: back in the foreground it stays down")
        #expect(rig.chat.status == .idle)
    }

    @Test func graineEndingItIdleOrAtItsTimeLimitIsNotDialledAgainAndSaysDisconnected() throws {
        let header = DesignTokens.classic(dark: false, accent: "#318CE7").chatOrClassic.header
        for (code, reason) in [(4408, "idle_timeout"), (4410, "session_limit")] {
            let rig = ChatRig()
            let socket = rig.online()
            socket.frame(welcome)
            socket.serverClose(code, reason: reason)
            #expect(rig.chat.status == .failed, "\(code)")
            #expect(rig.chat.publicStatus == .disconnected, "\(code): the chat says disconnected (0.14.5), as every SDK says it")
            #expect(rig.chat.disconnected, "\(code)")
            let line = ChatWindowRules.headerStatus(
                header, status: rig.chat.status, typing: false, subtitle: "", typingText: "", disconnected: rig.chat.disconnected
            )
            #expect(line == .words("Disconnected", dot: false), "\(code): the header says so, never Online")
            rig.scheduler.advance(60)
            #expect(rig.network.sockets.count == 1, "\(code): dialled again on its own")
            #expect(rig.chat.transcript.turns.map { $0.text } == ["Hi! How can I help?"], "\(code): the lines stay")
            rig.chat.send("Hello?")
            #expect(rig.network.sockets.count == 2, "\(code): the next message connects again")
            #expect(!rig.chat.disconnected, "\(code): connecting again is no longer Disconnected")
        }
    }

    @Test func graineEndingItCountsEvenWhenTheSocketReportsAnErrorAfterTheCloseFrame() throws {
        let rig = ChatRig()
        let socket = rig.online()
        socket.fail("Socket is not connected", code: 4408)
        #expect(rig.chat.status == .failed)
        #expect(rig.chat.publicStatus == .disconnected)
        #expect(rig.chat.disconnected)
        rig.scheduler.advance(60)
        #expect(rig.network.sockets.count == 1)
    }

    @Test func anyOtherDropStillReconnectsAndIsNotDisconnected() throws {
        let rig = ChatRig()
        let socket = rig.online()
        socket.fail("network lost")
        #expect(rig.chat.status == .reconnecting(attempt: 1))
        #expect(!rig.chat.disconnected)
        rig.scheduler.advance(1.01)
        #expect(rig.network.sockets.count == 2, "a dropped connection is made again, as before")
        let header = DesignTokens.classic(dark: false, accent: "#318CE7").chatOrClassic.header
        rig.network.socket!.open()
        rig.network.socket!.fail("gone again", code: 1006)
        #expect(rig.chat.status == .reconnecting(attempt: 1), "an abnormal closure is a drop too")
        let line = ChatWindowRules.headerStatus(header, status: .offline, typing: false, subtitle: "", typingText: "", disconnected: false)
        #expect(line == .words("Not connected", dot: false), "the words for any other offline chat are unchanged")
    }
}

/// The chat model: the SDK's windows coming and going, as `GraineChatView` and the bar report them.
@Suite @MainActor struct ChatWindowLifetimeTests {
    @Test func closingTheChatScreenKeepsTheConversationForTheNextOne() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session()
        rig.graine.chat.shown(true)
        let socket = try #require(rig.network.socket)
        socket.open()
        socket.frame(welcome)
        rig.graine.chat.shown(false)
        rig.scheduler.advance(delay - 1)
        #expect(rig.graine.chat.isOpen && rig.graine.chat.status == .connected, "kept a moment after the screen went")
        rig.graine.chat.shown(true)
        #expect(rig.network.sockets.count == 1, "opened again: the same conversation, no new welcome")
        #expect(rig.graine.chat.turns.map { $0.text } == ["Hi! How can I help?"])
        rig.graine.chat.shown(false)
        rig.scheduler.advance(delay)
        #expect(!rig.graine.chat.isOpen, "let go 15 seconds after the screen went")
        #expect(rig.graine.chat.status == .idle)
        rig.graine.chat.shown(true)
        #expect(rig.network.sockets.count == 2, "the next window connects again")
    }

    @Test func twoWindowsKeepItUntilTheLastOneGoes() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session()
        rig.graine.chat.shown(true)
        try #require(rig.network.socket).open()
        rig.graine.chat.shown(true)
        rig.graine.chat.shown(false)
        rig.scheduler.advance(600)
        #expect(rig.graine.chat.status == .connected, "a window still shows it")
        rig.graine.chat.shown(false)
        rig.scheduler.advance(delay)
        #expect(rig.graine.chat.status == .idle)
        #expect(rig.network.sockets.count == 1)
    }

    @Test func anAppThatOpensTheChatItselfClosesItItself() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session()
        rig.graine.chat.open()
        try #require(rig.network.socket).open()
        rig.scheduler.advance(600)
        #expect(rig.graine.chat.isOpen && rig.graine.chat.status == .connected, "an app's own chat is never let go behind its back")
        rig.graine.chat.close()
        #expect(rig.graine.chat.status == .idle)
    }

    @Test func goingToTheBackgroundStillEndsItAsBefore() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session()
        rig.graine.chat.shown(true)
        let socket = try #require(rig.network.socket)
        socket.open()
        rig.graine.setForeground(false)
        #expect(socket.sent.last == CallWire.stopFrame, "hung up at once in the background")
        #expect(rig.graine.chat.status == .idle)
        rig.graine.setForeground(true)
        #expect(rig.network.sockets.count == 2, "and back with the app")
    }

    @Test func theWindowSaysDisconnectedWhenGraineEndsIt() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session()
        rig.graine.chat.shown(true)
        let socket = try #require(rig.network.socket)
        socket.open()
        socket.serverClose(4408, reason: "idle_timeout")
        #expect(rig.graine.chat.disconnected)
        rig.scheduler.advance(60)
        #expect(rig.network.sockets.count == 1)
        // Opening the chat again connects again.
        rig.graine.chat.shown(false)
        rig.graine.chat.shown(true)
        #expect(rig.network.sockets.count == 2)
        #expect(!rig.graine.chat.disconnected)
    }
}
