import Foundation
import Testing
@testable import GraineInApp

/*
 * 0.14.3, HOW LONG A CHAT NO SCREEN SHOWS IS KEPT: the chat starts with
 * `GraineConfig.chatCloseDelaySeconds` (15 by default, kept within 0…300) and
 * `GraineChat.closeDelaySeconds` changes it. With no screen showing it, the
 * conversation closes normally — as close() closes it: the stop frame, no
 * reconnect, never "Disconnected" — that long after the later of the moment the
 * last screen left and the last message either way. A screen back in time calls
 * the close off; a message meanwhile starts the wait again; a new length set
 * during the wait applies to it. (Five minutes of quiet in 0.14.0–0.14.1.)
 */

private let welcome: [String: Any] = ["type": "text", "data": "<beginning_of_stream>Hi! How can I help?<end_of_stream>"]

@Suite @MainActor struct ChatCloseDelayTests {
    /// The chat on a screen, connected, the welcome said.
    private func onScreen(_ rig: PlatformRig) throws -> FakeSocket {
        rig.session()
        rig.graine.chat.shown(true)
        let socket = try #require(rig.network.socket)
        socket.open()
        socket.frame(welcome)
        return socket
    }

    private func stillUp(_ socket: FakeSocket, _ rig: PlatformRig) -> Bool {
        rig.graine.chat.status == .online && rig.graine.chat.isOpen && !socket.sent.contains(CallWire.stopFrame)
    }

    /// Closed as close() closes it: the stop frame, idle, not Disconnected — and nothing dials it again.
    private func expectClosedNormally(_ socket: FakeSocket, _ rig: PlatformRig, _ comment: Comment) {
        #expect(socket.sent.last == CallWire.stopFrame, comment)
        #expect(rig.graine.chat.status == .idle && !rig.graine.chat.isOpen, comment)
        #expect(!rig.graine.chat.disconnected, comment)
        rig.scheduler.advance(60)
        #expect(rig.network.sockets.count == 1, comment)
    }

    @Test func theDefaultIsFifteenSeconds() throws {
        #expect(GraineConfig(baseUrl: "https://www.graine.ai", publishableKey: "pk_test_delay").chatCloseDelaySeconds == 15)
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        #expect(rig.graine.chat.closeDelaySeconds == 15, "the chat starts with the config's")
        let socket = try onScreen(rig)
        rig.graine.chat.shown(false)
        rig.scheduler.advance(14.9)
        #expect(stillUp(socket, rig), "kept a moment after the screen left")
        rig.scheduler.advance(0.2)
        expectClosedNormally(socket, rig, "15 seconds after the last screen left")
        #expect(rig.graine.chat.turns.map(\.text) == ["Hi! How can I help?"], "the lines stay")
        rig.graine.chat.shown(true)
        #expect(rig.network.sockets.count == 2, "a screen later connects again")
    }

    @Test func zeroClosesItAsTheLastScreenLeaves() throws {
        let rig = PlatformRig(chatCloseDelaySeconds: 0)
        defer { rig.sandbox.clean() }
        #expect(rig.graine.chat.closeDelaySeconds == 0)
        let socket = try onScreen(rig)
        rig.graine.chat.shown(true)
        rig.graine.chat.shown(false)
        #expect(stillUp(socket, rig), "another screen still shows it")
        rig.graine.chat.shown(false)
        expectClosedNormally(socket, rig, "closed as the last screen left")
    }

    @Test func aDelayOfFortySecondsKeepsItFortySeconds() throws {
        let rig = PlatformRig(chatCloseDelaySeconds: 40)
        defer { rig.sandbox.clean() }
        #expect(rig.graine.chat.closeDelaySeconds == 40)
        let socket = try onScreen(rig)
        rig.graine.chat.shown(false)
        rig.scheduler.advance(39)
        #expect(stillUp(socket, rig), "still connected at 39 seconds")
        rig.scheduler.advance(1)
        expectClosedNormally(socket, rig, "closed at 40 seconds")
    }

    @Test func aDelayOutsideZeroToThreeHundredIsClamped() throws {
        for (given, kept) in [(-5, 0), (301, 300), (1000, 300), (0, 0), (300, 300), (40, 40)] {
            #expect(GraineConfig(baseUrl: "https://www.graine.ai", publishableKey: "pk_test_delay", chatCloseDelaySeconds: given).chatCloseDelaySeconds == kept, "init \(given)")
            var config = GraineConfig(baseUrl: "https://www.graine.ai", publishableKey: "pk_test_delay")
            config.chatCloseDelaySeconds = given
            #expect(config.chatCloseDelaySeconds == kept, "assigned \(given)")
            let bridged = GraineObjC.config(
                baseUrl: "https://www.graine.ai", publishableKey: "pk_test_delay", appVersion: nil, debug: false,
                endOnBackground: true, captureTaps: true, transport: nil, variablesJSON: nil, chatSize: nil, chatCloseDelaySeconds: given
            )
            #expect(bridged.chatCloseDelaySeconds == kept, "Objective-C configure \(given)")

            let rig = PlatformRig(chatCloseDelaySeconds: given)
            defer { rig.sandbox.clean() }
            #expect(rig.graine.chat.closeDelaySeconds == kept, "the chat starts with \(given) as \(kept)")
            rig.graine.chat.closeDelaySeconds = 15
            rig.graine.chat.closeDelaySeconds = given
            #expect(rig.graine.chat.closeDelaySeconds == kept, "set to \(given)")
            let facade = GraineObjC(graine: rig.graine)
            facade.chat.closeDelaySeconds = 15
            facade.chat.closeDelaySeconds = given
            #expect(facade.chat.closeDelaySeconds == kept, "Objective-C, set to \(given)")
        }
    }

    @Test func aNewDelaySetDuringTheWaitAppliesToIt() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        let socket = try onScreen(rig)
        rig.graine.chat.shown(false)
        rig.scheduler.advance(10)
        rig.graine.chat.closeDelaySeconds = 40
        rig.scheduler.advance(29)
        #expect(stillUp(socket, rig), "40 seconds from when the screen left, not 15")
        rig.scheduler.advance(1)
        expectClosedNormally(socket, rig, "closed at 40 seconds")

        let shorter = PlatformRig()
        defer { shorter.sandbox.clean() }
        let other = try onScreen(shorter)
        shorter.graine.chat.closeDelaySeconds = 0
        #expect(stillUp(other, shorter), "on screen: a new delay closes nothing")
        shorter.graine.chat.closeDelaySeconds = 15
        shorter.graine.chat.shown(false)
        shorter.scheduler.advance(10)
        shorter.graine.chat.closeDelaySeconds = 5
        expectClosedNormally(other, shorter, "5 seconds were over already: closed at once")
    }

    @Test func aMessageEitherWayDuringTheWaitStartsItAgain() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        let socket = try onScreen(rig)
        rig.graine.chat.shown(false)
        rig.scheduler.advance(10)
        socket.frame(["type": "text", "data": "<beginning_of_stream>Anything else?<end_of_stream>"])
        rig.scheduler.advance(14)
        #expect(stillUp(socket, rig), "15 seconds from the agent's message, not from when the screen left")
        rig.graine.chat.send("No, thanks")
        rig.scheduler.advance(14.9)
        #expect(stillUp(socket, rig), "and from the customer's")
        rig.scheduler.advance(0.2)
        expectClosedNormally(socket, rig, "15 seconds after the last message")
    }

    @Test func aScreenComingBackCallsTheCloseOff() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        let socket = try onScreen(rig)
        rig.graine.chat.shown(false)
        rig.scheduler.advance(10)
        rig.graine.chat.shown(true)
        rig.scheduler.advance(600)
        #expect(stillUp(socket, rig), "on screen again: never closed for being quiet")
        #expect(rig.network.sockets.count == 1, "the same conversation")
        rig.graine.chat.shown(false)
        rig.scheduler.advance(14.9)
        #expect(stillUp(socket, rig), "the wait starts afresh when it leaves again")
        rig.scheduler.advance(0.2)
        expectClosedNormally(socket, rig, "15 seconds after it left again")
    }
}
