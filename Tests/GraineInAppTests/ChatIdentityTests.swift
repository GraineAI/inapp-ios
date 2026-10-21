import Foundation
import Testing
@testable import GraineInApp

/*
 * 0.14.0, WHO A CHAT BELONGS TO (sdk/contract/DESIGN.md): a chat connection
 * belongs to whoever was identified when its ticket was asked for — nobody,
 * before identify(). When the identity changes — nobody to a user, a user to
 * another, a user to nobody — the turns go (markers and history with them),
 * the lines that have not gone out (still sending, or failed) stay and go on
 * the next connection, and a chat that was connected or connecting is closed
 * normally and connects again at once with a ticket for the new identity
 * while the customer is in it; one that was not connects at the next open or
 * message, never "Disconnected". The same identity changes nothing. The first
 * suite is Android's ChatIdentityTest, case for case, on a real instance; the
 * second drives the connection alone for what only its seams can show.
 */

private let field: [String: Any] = ["identity": ["field": "user_id"]]

private func says(_ socket: FakeSocket, _ words: String) {
    socket.frame(["type": "text", "data": "<beginning_of_stream>\(words)<end_of_stream>"])
}

/// Who a ticket was for: the identity's value, nil for nobody.
private func whose(_ ticket: [String: Any]?) -> String? {
    (ticket?["identity"] as? [String: Any])?["value"] as? String
}

/// Android's ChatIdentityTest, on this SDK: the instance, its chat and `identify`, the network and sockets faked.
@Suite @MainActor struct ChatIdentityTests {
    private func tickets(_ rig: PlatformRig) -> [[String: Any]] { rig.network.bodies("/api/embed/ticket") }

    /// A window shows the chat, and its socket opens.
    private func shownOnline(_ rig: PlatformRig) throws -> FakeSocket {
        rig.graine.chat.shown(true)
        let socket = try #require(rig.network.socket)
        socket.open()
        #expect(rig.graine.chat.status == .online)
        return socket
    }

    /// The connection the identity change closed: normally, with the stop frame — never as a drop.
    private func expectClosedNormally(_ old: FakeSocket, _ rig: PlatformRig) {
        #expect(old.sentTypes.last == "stop", "the stop frame: this side ended it")
        rig.scheduler.advance(CallWire.closeGraceSeconds + 0.05)
        #expect(old.closed, "then closed")
        #expect(!rig.graine.chat.disconnected, "no Disconnected")
        #expect(rig.graine.chat.status != .offline, "not a failure")
        #expect(!rig.graine.chat.wasOnline, "no reconnect banner: a first connect for the new identity")
    }

    @Test func signingInAfterTheChatOpenedClosesTheAnonymousConversationAndConnectsAgainAsTheUser() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session(field)
        let anonymous = try shownOnline(rig)
        #expect(whose(tickets(rig).last) == nil, "opened before identify(): nobody's")
        says(anonymous, "Hi! How can I help?")
        rig.graine.identify(["user_id": "u-1"])
        expectClosedNormally(anonymous, rig)
        #expect(rig.graine.chat.turns.isEmpty, "the anonymous turns are not the user's")
        #expect(rig.network.sockets.count == 2, "connecting again at once")
        #expect(rig.graine.chat.status == .connecting)
        #expect(whose(tickets(rig).last) == "u-1", "with a ticket for the user")
        try #require(rig.network.socket).open()
        #expect(rig.graine.chat.status == .online)
        #expect(rig.network.bodies("/api/embed/identity/signout").isEmpty, "signing in signs nobody out")
    }

    @Test func anotherUserAndSigningOutCloseTheConversationAndConnectAgainAsTheNewIdentity() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session(field)
        rig.graine.identify(["user_id": "u-1"])
        let first = try shownOnline(rig)
        #expect(whose(tickets(rig).last) == "u-1")
        says(first, "Welcome back, Meera.")
        rig.graine.chat.send("Where is my order?")

        rig.graine.identify(["user_id": "u-2"])
        expectClosedNormally(first, rig)
        #expect(rig.graine.chat.turns.isEmpty, "u-1's conversation is not u-2's")
        #expect(whose(tickets(rig).last) == "u-2")
        #expect(rig.network.bodies("/api/embed/identity/signout").count == 1)
        let second = try #require(rig.network.socket)
        second.open()
        says(second, "Hi there!")

        rig.graine.identify(nil)
        expectClosedNormally(second, rig)
        #expect(rig.graine.chat.turns.isEmpty)
        #expect(rig.network.sockets.count == 3, "connecting again as nobody")
        #expect(tickets(rig).last?["identity"] == nil, "an anonymous ticket")
    }

    @Test func theSameIdentityChangesNothingOnAnOpenChat() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session(field)
        rig.graine.identify(["user_id": "u-1"])
        let socket = try shownOnline(rig)
        says(socket, "Hello Meera.")
        rig.graine.identify(["user_id": "u-1", "name": "Meera", "plan": "Gold"], memory: false)
        rig.graine.setMemory(true)
        #expect(rig.network.sockets.count == 1, "still the one connection")
        #expect(!socket.sentTypes.contains("stop"), "never stopped")
        #expect(rig.graine.chat.status == .online)
        #expect(rig.graine.chat.turns.map(\.text) == ["Hello Meera."])
    }

    @Test func aLineTypedAndNotYetSentStaysAndGoesOnTheNextConnection() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session(field)
        rig.graine.chat.shown(true)
        let connecting = try #require(rig.network.socket)
        #expect(rig.graine.chat.status == .connecting, "connecting: the socket is not open yet")
        rig.graine.chat.send("I need help with my order")
        #expect(rig.graine.chat.turns.map(\.delivery) == [.sending])

        rig.graine.identify(["user_id": "u-1"])
        #expect(rig.graine.chat.turns.map(\.text) == ["I need help with my order"], "the line typed stays")
        #expect(rig.graine.chat.turns.map(\.delivery) == [.sending], "still waiting")
        #expect(!connecting.sent.contains { $0.contains("I need help with my order") }, "the closed connection never carried it")
        #expect(whose(tickets(rig).last) == "u-1")

        let next = try #require(rig.network.socket)
        next.open()
        #expect(next.sent.contains(ChatWire.textFrame("I need help with my order")), "sent on the user's connection")
        #expect(rig.graine.chat.turns.map(\.delivery) == [.sent])
    }

    @Test func aChatThatIsNotConnectedForgetsItsTurnsAndConnectsAtTheNextOpen() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session(field)
        let socket = try shownOnline(rig)
        says(socket, "Hi! How can I help?")
        rig.graine.chat.close()
        rig.graine.identify(["user_id": "u-1"])
        #expect(rig.network.sockets.count == 1, "nothing reconnects a chat nobody wants")
        #expect(rig.graine.chat.turns.isEmpty, "its turns are nobody's, not the user's")
        #expect(rig.graine.chat.status == .idle)
        rig.graine.chat.open()
        #expect(rig.network.sockets.count == 2)
        #expect(whose(tickets(rig).last) == "u-1", "the next open is the user's")
    }

    @Test func aConversationGraineEndedIsNotDisconnectedForTheNewIdentity() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session(field)
        let socket = try shownOnline(rig)
        says(socket, "Hi! How can I help?")
        socket.serverClose(4408, reason: "idle_timeout")
        #expect(rig.graine.chat.disconnected)
        rig.graine.identify(["user_id": "u-1"])
        #expect(!rig.graine.chat.disconnected, "the Disconnected line was the conversation before")
        #expect(rig.graine.chat.status == .idle, "not offline either")
        #expect(rig.graine.chat.turns.isEmpty)
        #expect(rig.network.sockets.count == 1, "it was not connected: nothing reconnects by itself")
        rig.graine.chat.send("Hello?")
        #expect(whose(tickets(rig).last) == "u-1", "the customer's next message connects, as the user")
    }

    @Test func whereANewConversationBeganIsForgottenWithTheTurns() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session(field)
        rig.graine.identify(["user_id": "u-1"])
        let first = try shownOnline(rig)
        says(first, "Hi Meera.")
        rig.graine.chat.send("Thanks")
        says(first, "Anything else?")
        first.fail("The network went away.")
        rig.scheduler.advance(ChatWire.reconnectDelays[0] + 0.1)
        let second = try #require(rig.network.socket)
        #expect(second !== first)
        second.open()
        says(second, "Hi Meera.")
        #expect(rig.graine.chat.newConversationBefore.count == 1)
        rig.graine.identify(["user_id": "u-2"])
        #expect(rig.graine.chat.newConversationBefore.isEmpty, "its marker rows go with the turns")
        #expect(rig.graine.chat.turns.isEmpty)
    }

    /// The booked calls on the card are the identity's: gone at once, and fetched again for the new one.
    @Test func theBookedCallsShownGoAndAreFetchedAgainForTheNewIdentity() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session(["calls": ["hosted": true], "identity": ["field": "user_id"]])
        rig.graine.identify(["user_id": "u-1"])
        let at = Scheduling.isoTime(Date().addingTimeInterval(3_600))
        rig.network.replies["/api/embed/calls/list"] = (200, #"{"calls":[{"id":"u1-call","at":"\#(at)","status":"scheduled"}]}"#)
        rig.graine.chat.open()
        try await Task.sleep(nanoseconds: 60_000_000)
        #expect(rig.graine.chat.upcomingCalls.map(\.id) == ["u1-call"])
        rig.network.replies["/api/embed/calls/list"] = (200, #"{"calls":[]}"#)
        rig.graine.identify(["user_id": "u-2"])
        #expect(rig.graine.chat.upcomingCalls.isEmpty, "at once")
        try await Task.sleep(nanoseconds: 60_000_000)
        #expect(whose(rig.network.bodies("/api/embed/calls/list").last) == "u-2", "fetched again, for u-2")
        #expect(rig.graine.chat.upcomingCalls.isEmpty)
    }
}

/// The connection alone: what only its seams show — a ticket still on its way, failed lines, nobody in the chat.
@Suite struct ChatIdentityConnectionTests {
    private func person(_ value: String?, memory: Bool = true) -> IdentityWire.Fields {
        IdentityWire.Fields(value: value, installId: "i-1", memory: memory, timezone: "Asia/Kolkata", callId: nil)
    }

    private func tickets(_ rig: ChatRig) -> [[String: Any]] { rig.network.bodies("/api/embed/ticket") }

    private func letGo(_ rig: ChatRig) -> Bool {
        rig.events.contains { if case .letGo = $0 { return true }; return false }
    }

    @Test func aTicketStillOnItsWayIsAskedForAgainForTheNewIdentity() throws {
        let rig = ChatRig()
        rig.network.holdTickets = true
        rig.chat.open()
        #expect(tickets(rig).count == 1 && rig.network.sockets.isEmpty, "the ticket is on its way")
        rig.identity = person("P-2")
        rig.chat.identityChanged(to: "P-2")
        #expect(tickets(rig).count == 2)
        #expect(whose(tickets(rig).last) == "P-2")
        rig.network.releaseTickets()
        #expect(rig.network.sockets.count == 1, "the first ticket's answer came too late to be used")
        try #require(rig.network.socket).open()
        #expect(rig.chat.status == .online)
    }

    @Test func aSocketNotYetOpenIsLetGoAndItsLateOpenIsNotTheChats() throws {
        let rig = ChatRig()
        rig.chat.open()
        let first = try #require(rig.network.socket)
        rig.identity = person("P-2")
        rig.chat.identityChanged(to: "P-2")
        #expect(first.closed && first.sent.isEmpty, "never opened: closed, nothing to stop")
        first.open()
        #expect(first.sent.isEmpty, "its late open is not this chat's")
        #expect(rig.chat.status == .connecting)
        let second = try #require(rig.network.socket)
        #expect(second !== first)
        second.open()
        #expect(rig.chat.status == .online)
    }

    @Test func failedLinesStayAndGoOnTheNextConnectionAsTheSendingOnesDo() throws {
        let rig = ChatRig()
        rig.chat.open()
        rig.chat.send("Hello?")
        // Every reconnect refused: the chat gives up, and the line could not be sent.
        for delay in ChatWire.reconnectDelays {
            rig.network.socket?.fail("refused")
            rig.scheduler.advance(delay + 0.1)
        }
        rig.network.socket?.fail("refused")
        #expect(rig.chat.status == .offline)
        #expect(rig.chat.transcript.turns.map(\.delivery) == [.failed])
        let sockets = rig.network.sockets.count

        rig.identity = person("P-2")
        rig.chat.identityChanged(to: "P-2")
        #expect(rig.chat.transcript.turns.map(\.text) == ["Hello?"], "a failed line stays")
        #expect(rig.chat.transcript.turns.map(\.delivery) == [.sending], "waiting for the next connection")
        #expect(rig.chat.status == .idle, "not offline: nothing has failed for the new identity")
        #expect(rig.network.sockets.count == sockets, "it was not connected: the next open connects")

        rig.chat.send("Anyone?")
        let socket = try #require(rig.network.socket)
        #expect(whose(tickets(rig).last) == "P-2")
        socket.open()
        #expect(socket.sent.filter { $0.contains(#""type":"text""#) } == [ChatWire.textFrame("Hello?"), ChatWire.textFrame("Anyone?")], "in the order typed")
        #expect(rig.chat.transcript.turns.map(\.delivery) == [.sent, .sent])
    }

    @Test func aChatNoWindowShowsIsClosedAndConnectsAtTheNextOpen() throws {
        let rig = ChatRig()
        let socket = rig.online()
        says(socket, "Hi! How can I help?")
        rig.chat.shown(false)
        rig.identity = person("P-2")
        rig.chat.identityChanged(to: "P-2")
        #expect(socket.sentTypes.last == "stop", "closed normally")
        #expect(rig.chat.transcript.turns.isEmpty)
        #expect(rig.chat.status == .idle)
        #expect(rig.network.sockets.count == 1, "nobody is in the chat: not now")
        #expect(letGo(rig), "the chat was let go, as an idle one is")
        rig.chat.shown(true)
        rig.chat.open()
        #expect(whose(tickets(rig).last) == "P-2", "the next open is for the new identity")
    }

    @Test func aReconnectStillWaitingConnectsAtOnceForTheNewIdentity() throws {
        let rig = ChatRig()
        let socket = rig.online()
        says(socket, "Hi! How can I help?")
        socket.fail("The network went away.")
        #expect(rig.chat.status == .reconnecting(attempt: 1))
        rig.identity = person("P-2")
        rig.chat.identityChanged(to: "P-2")
        #expect(tickets(rig).count == 2, "not after the backoff: now")
        #expect(whose(tickets(rig).last) == "P-2")
        #expect(rig.chat.status == .connecting && !rig.chat.wasOnline, "a first connect, not the reconnect banner")
        #expect(rig.chat.transcript.turns.isEmpty)
        rig.scheduler.advance(ChatWire.reconnectDelays[0] + 0.1)
        #expect(tickets(rig).count == 2, "the old backoff dials nothing")
        #expect(!letGo(rig))
    }

    @Test func theSameIdentityOrOneBeforeAnyTicketChangesNothing() throws {
        let rig = ChatRig()
        rig.identity = person(nil)
        rig.chat.identityChanged(to: "P-1")
        rig.identity = person("P-1")
        #expect(rig.network.posts.isEmpty, "no ticket yet: nothing is anybody's, nothing connects")
        let socket = rig.online()
        says(socket, "Hello!")
        rig.identity = person("P-1", memory: false)
        rig.chat.identityChanged(to: "P-1")
        #expect(rig.network.sockets.count == 1 && !socket.sentTypes.contains("stop"))
        #expect(rig.chat.transcript.turns.map(\.text) == ["Hello!"])
        rig.chat.close()
        rig.chat.open()
        #expect(tickets(rig).last?["memory"] as? Bool == false, "the memory choice: from the next connection")
    }

    @Test func theUsersConversationContinuesUnderTheLineStillToSend() throws {
        let rig = ChatRig()
        rig.identity = person(nil)
        rig.chat.open()
        rig.chat.send("Is my refund through?")
        rig.identity = person("P-1")
        rig.chat.identityChanged(to: "P-1")
        let socket = try #require(rig.network.socket)
        socket.open()
        socket.frame(["type": "history", "turns": [
            ["id": "h1", "role": "assistant", "text": "Your refund was approved.", "at": "2026-10-20T09:00:00Z"],
        ]])
        #expect(rig.chat.transcript.turns.map(\.text) == ["Your refund was approved.", "Is my refund through?"])
        #expect(rig.chat.transcript.marks.isEmpty, "a conversation that continues: no marker")
    }
}
