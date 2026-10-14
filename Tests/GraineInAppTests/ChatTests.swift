import Foundation
import Testing
@testable import GraineInApp

/*
 * The chat, frame by frame on a clock the test moves: the wire (the React
 * Native client's text path), the turns (one bubble per agent turn), the
 * connection (reconnects, waiting messages, holds), the surfaces, and the
 * instance routing components and events to the conversation that is live.
 */

@Suite struct ChatWireTests {
    @Test func aCustomerTurnIsATextFrame() {
        #expect(ChatWire.textFrame("Why was my card \"declined\"?") == #"{"type":"text","data":"Why was my card \"declined\"?"}"#)
    }

    @Test func aComponentAnswerIsTheStructuredResult() {
        #expect(ChatWire.widgetResultFrame(widgetId: "cars:1", data: ["ids": ["creta", "seltos"], "count": 2]) ==
                #"{"type":"widget_result","widget_id":"cars:1","data":{"count":2,"ids":["creta","seltos"]}}"#)
    }

    @Test func anAppEventCarriesItsOwnKeysAtItsLevelAndTheRestInData() {
        #expect(ChatWire.appEventFrame(name: "stalled_on_step", detail: "Stuck on PAN", data: ["cooldown_seconds": 20, "max_per_session": 3]) ==
                #"{"type":"app_event","event":{"name":"stalled_on_step","detail":"Stuck on PAN","cooldown_seconds":20,"max_per_session":3}}"#)
        #expect(ChatWire.appEventFrame(name: "component_dismissed", detail: nil, data: ["quiet": true, "data": ["kind": "choices"]]) ==
                #"{"type":"app_event","event":{"name":"component_dismissed","quiet":true,"data":{"kind":"choices"}}}"#)
        #expect(ChatWire.appEventFrame(name: "x", detail: "", data: ["screen": "kyc"]) ==
                #"{"type":"app_event","event":{"name":"x","data":{"screen":"kyc"}}}"#)
    }

    @Test func inboundFramesAreTyped() throws {
        guard case .widget(let w)? = ChatInbound.parse(#"{"type":"widget","widget":{"widget_id":"w1","kind":"choices"}}"#) else {
            Issue.record("widget"); return
        }
        #expect(w["widget_id"] as? String == "w1")
        guard case .widgetPending(let h)? = ChatInbound.parse(#"{"type":"widget_pending","widget":{"kind":"product_list"}}"#) else {
            Issue.record("pending"); return
        }
        #expect(h["kind"] as? String == "product_list")
        guard case .widgetPending(let empty)? = ChatInbound.parse(#"{"type":"widget_pending"}"#) else { Issue.record("bare pending"); return }
        #expect(empty.isEmpty)
        guard case .text("Hi")? = ChatInbound.parse(#"{"type":"text","data":"Hi"}"#) else { Issue.record("text"); return }
        guard case .endOfStream? = ChatInbound.parse(#"{"type":"end_of_stream"}"#) else { Issue.record("end"); return }
        guard case let .appAction(id, name, _)? = ChatInbound.parse(#"{"type":"app_action","action":{"action_id":"a1","name":"open","arguments":{}}}"#) else {
            Issue.record("action"); return
        }
        #expect(id == "a1" && name == "open")
        guard case .ignored? = ChatInbound.parse(#"{"type":"pong"}"#) else { Issue.record("pong"); return }
        guard case .ignored? = ChatInbound.parse(#"{"type":"widget"}"#) else { Issue.record("widget with no body"); return }
        #expect(ChatInbound.parse("nope") == nil)
    }
}

@Suite struct ChatTranscriptTests {
    private let now = Date(timeIntervalSince1970: 1_000)

    @Test func oneBubblePerAgentTurn() {
        var t = ChatTranscript()
        t.agentChunk("Hello! ", now: now)
        t.agentChunk("How can I help?", now: now)
        #expect(t.turns.count == 1)
        #expect(t.turns[0].text == "Hello! How can I help?")
        #expect(t.turns[0].live)
        let done = t.agentTurnEnded()
        #expect(done?.text == "Hello! How can I help?")
        #expect(t.turns[0].live == false, "settled on its end marker, not when the customer next speaks")
        t.agentChunk("By the way…", now: now)
        #expect(t.turns.count == 2, "the next reply is its own bubble")
        #expect(t.agentTurnEnded() != nil)
        #expect(t.agentTurnEnded() == nil, "nothing open, nothing to settle")
    }

    @Test func aTurnThatDoesNotFollowTheCustomersIsProactive() {
        var t = ChatTranscript()
        #expect(t.agentChunk("Welcome", now: now).turn.proactive)
        t.agentTurnEnded()
        _ = t.customerSaid("Hi", delivery: .sent, now: now)
        #expect(!t.agentChunk("Hello Asha", now: now).turn.proactive)
        t.agentTurnEnded()
        #expect(t.agentChunk("Your PAN looks wrong", now: now).turn.proactive, "speaking up unasked")
    }

    @Test func theCustomerSpeakingEndsWhateverTheAgentWasSaying() {
        var t = ChatTranscript()
        t.agentChunk("Let me", now: now)
        let mine = t.customerSaid("stop", delivery: .sending, now: now)
        #expect(t.turns[0].live == false)
        #expect(mine.delivery == .sending)
        t.setDelivery(mine.id, .sent)
        #expect(t.turns[1].delivery == .sent)
        t.agentChunk("Sure", now: now)
        #expect(t.turns.count == 3)
    }

    @Test func theTranscriptIsBounded() {
        var t = ChatTranscript()
        for i in 0..<(ChatTranscript.cap + 10) { _ = t.customerSaid("m\(i)", delivery: .sent, now: now) }
        #expect(t.turns.count == ChatTranscript.cap)
        #expect(t.turns.first?.text == "m10")
        #expect(Set(t.turns.map { $0.id }).count == t.turns.count, "ids stay unique")
    }
}

@Suite struct SurfacePolicyTests {
    private func policy(_ a: [String: Any]?, _ prefer: GraineSurface? = nil) -> SurfacePolicy {
        SurfacePolicy.resolve(appearance: a, prefer: prefer)
    }

    @Test func absentOrUnreadableMeansBoth() {
        #expect(policy(nil) == SurfacePolicy(allowed: [.voice, .chat], start: .voice))
        #expect(policy(["mode": NSNull()]).canSwitch)
        #expect(policy(["mode": "both"]).allowed == [.voice, .chat])
        #expect(policy(["mode": 7]).allowed == [.voice, .chat])
    }

    @Test func aSurfaceTheBrandWithheldIsNeverOffered() {
        #expect(policy(["mode": "chat"], .voice) == SurfacePolicy(allowed: [.chat], start: .chat))
        #expect(policy(["mode": "Voice"], .chat) == SurfacePolicy(allowed: [.voice], start: .voice))
        #expect(!policy(["mode": "chat"]).canSwitch)
    }

    @Test func thePreferencePicksAmongTheAllowedThenTheDashboardsStart() {
        #expect(policy(["start": "chat"]).start == .chat)
        #expect(policy(["start": "chat"], .voice).start == .voice)
        #expect(policy(["mode": "voice", "start": "chat"]).start == .voice, "a start that is not allowed is the first allowed")
        #expect(policy(["start": "video"]).start == .voice)
    }
}

/// One chat connection with every seam replaced.
private final class ChatRig {
    let scheduler = ManualScheduler()
    let network = RoutedNetwork()
    var session: GraineSessionConfig? = GraineSessionConfig(agentId: "agent-1", webcallAgentId: "web-1")
    var contextFrame: [String: Any]?
    var variables: [(String, String)] = [("name", "Asha")]
    var identity: IdentityWire.Fields? = IdentityWire.Fields(value: "P-1", installId: "i-1", memory: true, timezone: "Asia/Kolkata", callId: nil)
    var actionRunner: (String, [String: Any], @escaping (GraineActionResult) -> Void) -> Void = { _, _, answer in answer(.ok("done")) }
    private(set) var events: [ChatConnection.Event] = []
    lazy var chat: ChatConnection = ChatConnection(
        setup: ChatConnection.Setup(
            publishableKey: "pk_test_chat",
            baseUrl: "https://www.graine.ai",
            variables: { [unowned self] in self.variables },
            identity: { [unowned self] in self.identity },
            contextFrame: { [unowned self] in self.contextFrame },
            session: { [unowned self] done in done(self.session) },
            runAction: { [unowned self] name, args, answer in self.actionRunner(name, args, answer) },
            now: { Date(timeIntervalSince1970: 2_000) }
        ),
        network: network,
        scheduler: scheduler,
        onEvent: { [unowned self] in self.events.append($0) }
    )

    /// Open and let the socket come up; forget the opening frames.
    @discardableResult
    func online(clearOpening: Bool = true) -> FakeSocket {
        chat.open()
        let socket = network.socket!
        socket.open()
        if clearOpening { socket.clearSent() }
        return socket
    }

    var ended: [GraineChatTurn] {
        events.compactMap { if case .agentTurnEnded(let t) = $0 { return t }; return nil }
    }

    var widgets: [[String: Any]] {
        events.compactMap { if case .widget(let w) = $0 { return w }; return nil }
    }
}

@Suite struct ChatConnectionTests {
    @Test func itOpensAsATextConversationWithWhoTheCustomerIs() throws {
        let rig = ChatRig()
        rig.contextFrame = ["context": ["screen": "cards"], "seq": 1]
        rig.chat.open()
        #expect(rig.chat.status == .connecting)
        let ticket = try #require(rig.network.posts.first)
        #expect(ticket.path == "/api/embed/ticket")
        #expect(ticket.body["mode"] as? String == "text", "a text ticket: a typed conversation has no transcriber")
        #expect(ticket.body["metadata"] as? [String: String] == ["name": "Asha"])
        #expect((ticket.body["identity"] as? [String: Any])?["value"] as? String == "P-1")
        #expect(ticket.body["installId"] as? String == "i-1")
        #expect(ticket.body["memory"] as? Bool == true)
        #expect(ticket.body["timezone"] as? String == "Asia/Kolkata")
        #expect(ticket.body["callId"] == nil)

        let socket = try #require(rig.network.socket)
        #expect(socket.protocols == ["graine.embed.v1", "tkt-1"])
        #expect(socket.url.absoluteString == "wss://ws.graine.ai/v1/embed", "the gateway reads the ticket's variables; a query would only reach the access logs")
        #expect(!socket.url.absoluteString.contains("P-1"), "the identifier never rides a URL")

        socket.open()
        #expect(rig.chat.status == .online)
        #expect(socket.sentTypes == ["init", "app_context"])
        rig.scheduler.advance(25.1)
        #expect(socket.sentTypes.last == "ping")
    }

    @Test func noTicketMeansTheDirectTextSocket() throws {
        let rig = ChatRig()
        rig.network.ticket = (503, nil)
        rig.chat.open()
        let socket = try #require(rig.network.socket)
        #expect(socket.protocols.isEmpty)
        #expect(socket.url.absoluteString.hasPrefix("wss://ws.graine.ai/chat/v1/web-1?text_chat=1&context_token="))
        let token = try #require(CallWire.contextToken([("name", "Asha")], callType: "text_chat"))
        #expect(socket.url.absoluteString == "wss://ws.graine.ai/chat/v1/web-1?text_chat=1&context_token=" + GraineProtocol.encode(token))
    }

    @Test func aReplyStreamsIntoOneBubbleAndSettlesOnItsEndMarker() throws {
        let rig = ChatRig()
        let socket = rig.online()
        rig.chat.send("  Hi there  ")
        #expect(socket.sent == [ChatWire.textFrame("Hi there")])
        #expect(rig.chat.typing, "typing from the customer's message until the first words")
        socket.frame(["type": "text", "data": "<beginning_of_stream>"])
        #expect(rig.chat.typing)
        socket.frame(["type": "text", "data": "Hello "])
        #expect(!rig.chat.typing)
        socket.frame(["type": "text", "data": "Asha!"])
        socket.frame(["type": "text", "data": "<end_of_stream>"])
        let turns = rig.chat.transcript.turns
        #expect(turns.map { $0.text } == ["Hi there", "Hello Asha!"])
        #expect(turns.last?.live == false)
        #expect(rig.ended.map { $0.text } == ["Hello Asha!"])
        socket.frame(["type": "text", "data": "Anything else?"])
        #expect(rig.chat.transcript.turns.count == 3, "a second reply is its own bubble")
    }

    @Test func aMessageTypedOfflineWaitsAndGoesWhenTheChatIsUp() throws {
        let rig = ChatRig()
        rig.chat.send("first")
        rig.chat.send("second")
        #expect(rig.chat.transcript.turns.map { $0.delivery } == [.sending, .sending])
        let socket = try #require(rig.network.socket, "a message connects the chat")
        #expect(rig.network.sockets.count == 1)
        socket.open()
        #expect(socket.sentTypes == ["init", "text", "text"])
        #expect(Array(socket.sent.suffix(2)) == [ChatWire.textFrame("first"), ChatWire.textFrame("second")])
        #expect(rig.chat.transcript.turns.map { $0.delivery } == [.sent, .sent])
    }

    @Test func aDropReconnectsUpTheLadderThenGivesUpAndRetryTriesAgain() throws {
        let rig = ChatRig()
        let first = rig.online()
        first.fail("network lost")
        #expect(rig.chat.status == .reconnecting(attempt: 1))
        rig.scheduler.advance(0.9)
        #expect(rig.network.sockets.count == 1)
        rig.scheduler.advance(0.2)
        #expect(rig.network.sockets.count == 2, "again after a second")
        rig.network.socket!.open()
        #expect(rig.chat.status == .online)

        // Down for good: every attempt fails.
        rig.network.socket!.fail("gone")
        var waited = 0.0
        for delay in ChatWire.reconnectDelays {
            rig.scheduler.advance(delay + 0.01)
            waited += delay
            rig.network.socket!.fail("still gone")
        }
        #expect(rig.chat.status == .offline)
        rig.chat.send("are you there?")
        // Sending reconnects at once rather than sitting offline.
        #expect(rig.chat.status == .connecting)
        rig.network.socket!.fail("no")
        for delay in ChatWire.reconnectDelays {
            rig.scheduler.advance(delay + 0.01)
            rig.network.socket!.fail("no")
        }
        #expect(rig.chat.status == .offline)
        #expect(rig.chat.transcript.turns.last?.delivery == .failed, "never shown as sent, never silently lost")
        rig.chat.retry()
        #expect(rig.chat.transcript.turns.last?.delivery == .sending)
        rig.network.socket!.open()
        #expect(rig.network.socket!.sent.contains(ChatWire.textFrame("are you there?")))
        #expect(rig.chat.transcript.turns.last?.delivery == .sent)
        _ = waited
    }

    @Test func aConversationTheServerEndedIsNotDialledAgainUntilTheCustomerSpeaks() throws {
        let rig = ChatRig()
        let socket = rig.online()
        socket.serverClose()
        #expect(rig.chat.status == .offline)
        rig.scheduler.advance(60)
        #expect(rig.network.sockets.count == 1)
        rig.chat.send("hello again")
        #expect(rig.network.sockets.count == 2)
    }

    @Test func leavingHangsUpWithAStopAndStaysDown() throws {
        let rig = ChatRig()
        let socket = rig.online()
        rig.chat.close()
        #expect(socket.sent.last == CallWire.stopFrame)
        #expect(!socket.closed)
        rig.scheduler.advance(0.25)
        #expect(socket.closed)
        #expect(rig.chat.status == .idle)
        rig.scheduler.advance(60)
        #expect(rig.network.sockets.count == 1)
    }

    @Test func aHoldHangsUpAndTheReleaseComesBack() throws {
        let rig = ChatRig()
        rig.online()
        rig.chat.hold("background")
        #expect(rig.chat.status == .idle)
        rig.chat.hold("native-call")
        rig.chat.release("background")
        #expect(rig.network.sockets.count == 1, "still held by the call")
        rig.chat.release("native-call")
        #expect(rig.network.sockets.count == 2)
        rig.network.socket!.open()
        #expect(rig.chat.status == .online)
    }

    @Test func aHoldOnAChatNobodyIsInBringsNothingBack() throws {
        let rig = ChatRig()
        rig.online()
        rig.chat.close()
        rig.chat.hold("background")
        rig.chat.release("background")
        #expect(rig.network.sockets.count == 1)
    }

    @Test func componentsAndActionsArriveOnTheChat() throws {
        let rig = ChatRig()
        var asked: [String] = []
        rig.actionRunner = { name, _, answer in asked.append(name); answer(.ok("Opened")) }
        let socket = rig.online()
        socket.frame(["type": "widget_pending", "widget": ["kind": "choices"]])
        socket.frame(["type": "widget", "widget": ["widget_id": "w1", "kind": "choices"]])
        #expect(rig.widgets.first?["widget_id"] as? String == "w1")
        socket.frame(["type": "app_action", "action": ["action_id": "a1", "name": "open_cards", "arguments": [:]]])
        #expect(asked == ["open_cards"])
        let answer = try #require(socket.sentFrames.last)
        #expect(answer["type"] as? String == "app_action_result")
        #expect(answer["action_id"] as? String == "a1")
        #expect(answer["status"] as? String == "ok")
    }

    @Test func aSilentActionIsAnsweredAnywayInsideTheDeadline() throws {
        let rig = ChatRig()
        rig.actionRunner = { _, _, _ in }
        let socket = rig.online()
        socket.frame(["type": "app_action", "action": ["action_id": "a2", "name": "slow", "arguments": [:]]])
        rig.scheduler.advance(5.7)
        let answer = try #require(socket.sentFrames.last)
        #expect(answer["status"] as? String == "error")
        #expect(answer["message"] as? String == "\"slow\" did not finish in time.")
    }

    @Test func answeringAComponentSendsTheResultAndTheSentence() throws {
        let rig = ChatRig()
        let socket = rig.online()
        rig.chat.submitWidget(widgetId: "w1", data: ["id": "creta"], summary: "The Creta, please.")
        #expect(socket.sent == [
            ChatWire.widgetResultFrame(widgetId: "w1", data: ["id": "creta"]),
            ChatWire.textFrame("The Creta, please."),
        ])
        #expect(rig.chat.transcript.turns.last?.text == "The Creta, please.")
    }

    @Test func eventsAndScreensGoOnlyOnALiveChat() throws {
        let rig = ChatRig()
        rig.chat.sendEvent(name: "stalled_on_step", detail: nil, data: [:])
        rig.chat.sendContext(["context": ["screen": "a"]])
        #expect(rig.network.sockets.isEmpty, "an event never opens a conversation")
        let socket = rig.online()
        rig.chat.sendEvent(name: "stalled_on_step", detail: "stuck", data: [:])
        rig.chat.sendContext(["context": ["screen": "b"], "seq": 2])
        #expect(socket.sentTypes == ["app_event", "app_context"])
    }

    @Test func aSocketThatNeverOpensIsRetried() throws {
        let rig = ChatRig()
        rig.chat.open()
        rig.scheduler.advance(15.1)
        #expect(rig.chat.status == .reconnecting(attempt: 1))
        #expect(rig.network.sockets.first?.closed == true)
    }

    @Test func noSessionIsRetriedLikeADrop() {
        let rig = ChatRig()
        rig.session = nil
        rig.chat.open()
        #expect(rig.chat.status == .reconnecting(attempt: 1))
        #expect(rig.network.posts.isEmpty)
    }
}

/// The instance: the chat on its fakes, components and events routed to it.
@Suite @MainActor struct ChatInstanceTests {
    @Test func theChatCarriesTheIdentityAndTheTicketOrderKeepsThePerson() throws {
        let rig = PlatformRig(variables: Dictionary(uniqueKeysWithValues: (0..<14).map { ("build\($0)", "v\($0)") }))
        defer { rig.sandbox.clean() }
        rig.session(["identity": ["field": "user_id"]])
        rig.graine.identify(["user_id": "P-9", "name": "Asha"], memory: false)
        rig.graine.chat.open()
        let ticket = try #require(rig.network.bodies("/api/embed/ticket").first)
        let metadata = try #require(ticket["metadata"] as? [String: String])
        #expect(metadata["name"] == "Asha", "the person survives a dozen build-time variables")
        #expect(metadata["user_id"] == nil)
        #expect((ticket["identity"] as? [String: Any])?["value"] as? String == "P-9")
        #expect(ticket["memory"] as? Bool == false)
        #expect(ticket["mode"] as? String == "text")
    }

    @Test func aComponentFromTheChatIsAnsweredOnTheChat() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session()
        let heard = HeardListener()
        rig.graine.addListener(heard)
        rig.graine.chat.open()
        let socket = try #require(rig.network.socket)
        socket.open()
        socket.clearSent()
        socket.frame(["type": "widget", "widget": ["widget_id": "w7", "kind": "choices"]])
        #expect(heard.widgets.first?["widget_id"] as? String == "w7")
        let shown = try #require(rig.graine.componentFrame)
        #expect(GraineInApp.componentId(shown) == "w7")
        rig.graine.answerComponent(widgetId: "w7", data: ["choice": "yes"], summary: "Yes")
        #expect(socket.sentTypes == ["widget_result", "text"])
        #expect(rig.graine.componentFrame == nil)
    }

    @Test func aClosedComponentComesBackExactlyAsItWas() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        let heard = HeardListener()
        rig.graine.addListener(heard)
        #expect(!rig.graine.reopenComponent(), "nothing to reopen")
        rig.graine.componentArrived(["widget_id": "w1", "kind": "info_card"])
        rig.graine.componentDismissed()
        #expect(rig.graine.componentFrame == nil)
        #expect(rig.graine.reopenComponent())
        #expect(heard.widgets.count == 2)
        let back = try #require(rig.graine.componentFrame)
        #expect(GraineInApp.componentId(back) == "w1")
        #expect(!rig.graine.reopenComponent(), "once")
    }

    @Test func frictionReachesTheChatWhileItIsLive() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session()
        rig.graine.chat.open()
        let socket = try #require(rig.network.socket)
        socket.open()
        socket.clearSent()
        rig.graine.reportEvent("stalled_on_step", detail: "Stuck on PAN", data: ["cooldown_seconds": 20])
        let frame = try #require(socket.sentFrames.last)
        #expect(frame["type"] as? String == "app_event")
        #expect((frame["event"] as? [String: Any])?["name"] as? String == "stalled_on_step")
    }

    @Test func theAgentFinishingAMessageIsHeard() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session()
        let heard = HeardListener()
        rig.graine.addListener(heard)
        rig.graine.chat.open()
        let socket = try #require(rig.network.socket)
        socket.open()
        socket.frame(["type": "text", "data": "Welcome!<end_of_stream>"])
        #expect(heard.messages.map { $0.text } == ["Welcome!"])
        #expect(heard.messages.first?.proactive == true)
        #expect(rig.graine.chat.turns.count == 1)
        #expect(rig.graine.chat.status == .online)
    }

    @Test func anotherCustomerOnThisPhoneStartsWithAnEmptyChat() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session()
        rig.graine.identify(["user_id": "A"])
        rig.graine.chat.send("my card number is …")
        #expect(rig.graine.chat.turns.count == 1)
        rig.graine.identify(["user_id": "B"])
        #expect(rig.graine.chat.turns.isEmpty)
    }
}

/// The chat window's upcoming-calls card: fetched when the chat opens, cancelled from its rows.
@Suite @MainActor struct ChatUpcomingCallsTests {
    private func settle() async throws {
        // The answers are applied on the main queue's next turns.
        try await Task.sleep(nanoseconds: 60_000_000)
    }

    @Test func openingTheChatFetchesTheCustomersBookedCalls() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session(["calls": ["hosted": true]])
        rig.graine.identify(["user_id": "P-1"])
        let soon = Date().addingTimeInterval(3_600)
        let later = soon.addingTimeInterval(86_400)
        rig.network.replies["/api/embed/calls/list"] = (200, """
        {"calls":[{"id":"late","at":"\(Scheduling.isoTime(later))","status":"scheduled","source":"agent","reason":null},
                  {"id":"soon","at":"\(Scheduling.isoTime(soon))","status":"scheduled","source":"sdk","reason":"KYC"},
                  {"id":"done","at":"\(Scheduling.isoTime(soon))","status":"completed","source":"sdk","reason":null}]}
        """)
        rig.graine.chat.open()
        try await settle()
        #expect(rig.graine.chat.upcomingCalls.map { $0.id } == ["soon", "late"], "still to ring, soonest first")
        let body = try #require(rig.network.bodies("/api/embed/calls/list").first)
        #expect((body["identity"] as? [String: Any])?["value"] as? String == "P-1")
    }

    @Test func noCardWhereGraineDoesNotRingTheApp() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session(["calls": ["hosted": false]])
        rig.graine.chat.open()
        try await settle()
        #expect(rig.network.bodies("/api/embed/calls/list").isEmpty)
        #expect(rig.graine.chat.upcomingCalls.isEmpty)
    }

    @Test func aCancelledCallLeavesTheCardAndAFailedOneSaysSo() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session(["calls": ["hosted": true]])
        let at = Scheduling.isoTime(Date().addingTimeInterval(7_200))
        rig.network.replies["/api/embed/calls/list"] = (200, #"{"calls":[{"id":"a","at":"\#(at)","status":"scheduled"},{"id":"b","at":"\#(at)","status":"scheduled"}]}"#)
        rig.graine.chat.open()
        try await settle()
        #expect(rig.graine.chat.upcomingCalls.count == 2)
        rig.graine.chat.cancelUpcomingCall(id: "a")
        try await settle()
        #expect(rig.graine.chat.upcomingCalls.map { $0.id } == ["b"])
        #expect(rig.network.bodies("/api/embed/calls/cancel").first?["callId"] as? String == "a")
        rig.network.replies["/api/embed/calls/cancel"] = (503, #"{"error":"Try again shortly.","code":"unavailable"}"#)
        rig.graine.chat.cancelUpcomingCall(id: "b")
        try await settle()
        #expect(rig.graine.chat.upcomingCalls.map { $0.id } == ["b"], "kept, to try again")
        #expect(rig.graine.chat.cancelFailed.contains("b"))
        #expect(!rig.graine.chat.cancelling.contains("b"))
    }

    @Test func bookingACallShowsItOnTheCard() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session(["calls": ["hosted": true, "scheduling": ["usersCanBook": true]]])
        let at = Date().addingTimeInterval(5_400)
        rig.network.replies["/api/embed/calls/schedule"] = (201, #"{"call":{"id":"n1","at":"\#(Scheduling.isoTime(at))","status":"scheduled","source":"sdk","reason":null}}"#)
        rig.network.replies["/api/embed/calls/list"] = (200, #"{"calls":[{"id":"n1","at":"\#(Scheduling.isoTime(at))","status":"scheduled","source":"sdk","reason":null}]}"#)
        _ = try await rig.graine.scheduleCall(at: at)
        try await settle()
        #expect(rig.graine.chat.upcomingCalls.map { $0.id } == ["n1"])
    }

    @Test func theStartersWaitForTheCustomersFirstWords() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session()
        #expect(rig.graine.chat.awaitingFirstMessage)
        rig.graine.chat.send("hello")
        #expect(!rig.graine.chat.awaitingFirstMessage)
    }
}
