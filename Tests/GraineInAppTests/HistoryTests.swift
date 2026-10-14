import Foundation
import Testing
@testable import GraineInApp

/*
 * CONVERSATIONS CONTINUE (contract §2.6; vectors sdk/contract/history.json,
 * hand-written from CONTINUITY.md and run by every SDK): the history frame
 * read, folded into the turns on screen, and laid out as the chat window draws
 * it — then the same through the real connection and the instance, and a new
 * conversation started over.
 */

private func isoDate(_ s: String) -> Date? { ChatHistory.time(s) }
private func isoDate(_ raw: Any?) -> Date? { (raw as? String).flatMap { ChatHistory.time($0) } }
private func ms(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }

@Suite struct HistoryContractTests {
    private func contract() throws -> [String: Any] { try ContractFile.load("history.json") }

    private func section(_ name: String) throws -> [[String: Any]] {
        let list = try #require(try contract()[name] as? [[String: Any]], "section \(name) is missing from history.json")
        #expect(!list.isEmpty, "section \(name) is empty")
        return list
    }

    @Test func framesAreReadAsTheContractSays() throws {
        for c in try section("frames") {
            let name = c["name"] as? String ?? "?"
            let frame = try #require(c["frame"] as? [String: Any], "\(name): frame")
            let got = ChatHistory.read(frame)
            guard let want = c["turns"] as? [[String: Any]] else {
                #expect(got == nil, "\(name): the frame must be ignored")
                continue
            }
            let turns = try #require(got, "\(name): a readable frame")
            #expect(turns.count == want.count, "\(name): \(turns.map { $0.text })")
            for (i, w) in want.enumerated() where i < turns.count {
                let t = turns[i]
                #expect(t.id == w["id"] as? String, "\(name) #\(i) id")
                #expect(t.role.rawValue == w["role"] as? String, "\(name) #\(i) role")
                #expect(t.text == w["text"] as? String, "\(name) #\(i) text")
                let at = try #require(isoDate(w["at"]), "\(name) #\(i): the contract's at")
                #expect(ms(t.at) == ms(at), "\(name) #\(i) at")
                #expect(t.channel.rawValue == (w["channel"] as? String ?? "chat"), "\(name) #\(i) channel")
                #expect(t.restored && !t.live && !t.proactive && t.delivery == .sent, "\(name) #\(i): delivered, restored")
            }
        }
    }

    @Test func restoreFollowsTheContractsSteps() throws {
        for c in try section("restore") {
            let name = c["name"] as? String ?? "?"
            var t = ChatTranscript()
            var clock = 0.0
            for step in try #require(c["steps"] as? [[String: Any]]) {
                clock += 1
                let now = Date(timeIntervalSince1970: clock)
                if let words = step["agent"] as? String {
                    t.agentChunk(words, now: now)
                    t.agentTurnEnded()
                } else if let words = step["customer"] as? String {
                    let delivery = GraineChatTurn.Delivery(rawValue: step["delivery"] as? String ?? "sent") ?? .sent
                    _ = t.customerSaid(words, delivery: delivery, now: now)
                } else if step["opened"] as? Bool == true {
                    t.opened()
                    for turn in t.turns where turn.delivery == .sending { t.setDelivery(turn.id, .sent) }
                } else if let frame = step["history"] as? [String: Any] {
                    if let restored = ChatHistory.read(frame) { t.restore(restored) }
                } else {
                    Issue.record("\(name): unknown step \(step)")
                }
            }
            let want = try #require(c["turns"] as? [[String: Any]])
            #expect(t.turns.count == want.count, "\(name): \(t.turns.map { "\($0.role.rawValue):\($0.text)" })")
            for (i, w) in want.enumerated() where i < t.turns.count {
                let got = t.turns[i]
                #expect(got.role.rawValue == w["role"] as? String, "\(name) #\(i) role")
                #expect(got.text == w["text"] as? String, "\(name) #\(i) text")
                #expect(got.restored == (w["restored"] as? Bool ?? false), "\(name) #\(i) restored")
                #expect(got.channel.rawValue == (w["channel"] as? String ?? "chat"), "\(name) #\(i) channel")
                if got.role == .customer {
                    #expect(got.delivery.rawValue == (w["delivery"] as? String ?? "sent"), "\(name) #\(i) delivery")
                }
                if let id = w["id"] as? String { #expect(got.id == id, "\(name) #\(i) id") }
                if let at = isoDate(w["at"]) { #expect(ms(got.at) == ms(at), "\(name) #\(i) at") }
                if got.restored { #expect(!got.live && !got.proactive, "\(name) #\(i): restored turns are not live, not volunteered") }
            }
        }
    }

    @Test func rowsAreLaidOutAsTheContractSays() throws {
        for c in try section("rows") {
            let name = c["name"] as? String ?? "?"
            var calendar = Calendar(identifier: .gregorian)
            let zone = try #require(c["timeZone"] as? String)
            calendar.timeZone = try #require(TimeZone(identifier: zone))
            let now = try #require(isoDate(c["now"]))
            let raw = try #require(c["turns"] as? [[String: Any]])
            let turns = try raw.enumerated().map { i, t -> GraineChatTurn in
                let at = try #require(isoDate(t["at"]))
                return GraineChatTurn(
                    id: "t\(i)", role: (t["role"] as? String) == "agent" ? .agent : .customer, text: t["text"] as? String ?? "",
                    live: false, delivery: .sent, at: at, proactive: false,
                    restored: true, channel: (t["channel"] as? String) == "voice" ? .voice : .chat
                )
            }
            let shape: [String] = ChatRows.build(turns, now: now, calendar: calendar).map { row in
                switch row {
                case .day(let line): return "day:\(line.key)"
                case .voice(let line): return "voice:\(line.first)-\(line.last)"
                case .turn(let turn): return "turn:\(turn.id.dropFirst())"
                }
            }
            let wanted = try #require(c["rows"] as? [[String: Any]])
            let want: [String] = wanted.map { r in
                if let day = r["day"] as? String { return "day:\(day)" }
                if let v = r["voice"] as? [Int] { return "voice:\(v[0])-\(v[1])" }
                return "turn:\(r["turn"] as? Int ?? -1)"
            }
            #expect(shape == want, "\(name)")
        }
    }
}

@Suite struct ChatRowsWordsTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return c
    }
    private let locale = Locale(identifier: "en_US_POSIX")
    private let now = ChatHistory.time("2026-10-14T06:30:00Z")!

    @Test func todayYesterdayAndADateWithTheYearWhenItIsNotThisOne() throws {
        let line = { (day: ChatDay, iso: String) in ChatDayLine(day: day, date: "", at: ChatHistory.time(iso)!) }
        #expect(ChatRows.dayLabel(line(.today, "2026-10-14T05:00:00Z"), now: now, calendar: calendar, locale: locale) == "Today")
        #expect(ChatRows.dayLabel(line(.yesterday, "2026-10-13T05:00:00Z"), now: now, calendar: calendar, locale: locale) == "Yesterday")
        let thisYear = ChatRows.dayLabel(line(.date, "2026-10-10T08:00:00Z"), now: now, calendar: calendar, locale: locale)
        #expect(thisYear.contains("Sat") && thisYear.contains("10") && thisYear.contains("Oct") && !thisYear.contains("2026"), "\(thisYear)")
        let lastYear = ChatRows.dayLabel(line(.date, "2025-12-31T08:00:00Z"), now: now, calendar: calendar, locale: locale)
        #expect(lastYear.contains("2025") && lastYear.contains("Dec"), "\(lastYear)")
    }

    @Test func aCallIsOneRowWithItsTime() throws {
        let call = ChatCallLine(id: "voice-h1", at: ChatHistory.time("2026-10-14T12:35:00Z")!, first: 0, last: 2)
        // The system writes the time its own way — a narrow no-break space before PM, on newer systems.
        let plain = { (s: String) in s.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ") }
        #expect(plain(ChatRows.callLabel(call, calendar: calendar, locale: locale)) == "Voice call · 6:05 PM")
        #expect(plain(ChatRows.callSpoken(call, calendar: calendar, locale: locale)) == "Voice call at 6:05 PM")
    }

    @Test func rowsHaveStableIdsForTheWindow() {
        let at = ChatHistory.time("2026-10-13T10:00:00Z")!
        let turns = [
            GraineChatTurn(id: "a1", role: .agent, text: "Hi", live: false, delivery: .sent, at: at, proactive: false, restored: true, channel: .voice),
            GraineChatTurn(id: "a2", role: .customer, text: "Yo", live: false, delivery: .sent, at: at, proactive: false, restored: true, channel: .voice),
            GraineChatTurn(id: "t1", role: .customer, text: "Now", live: false, delivery: .sent, at: now, proactive: false),
        ]
        #expect(ChatRows.build(turns, now: now, calendar: calendar).map(\.id) == ["day-2026-10-13", "voice-a1", "day-2026-10-14", "t1"])
    }

    @Test func theStartersAndTheNewConversationControlFollowTheHistory() {
        let welcome = GraineChatTurn(id: "t1", role: .agent, text: "Hi!", live: false, delivery: .sent, at: now, proactive: true)
        let earlier = GraineChatTurn(id: "h1", role: .agent, text: "It ships today.", live: false, delivery: .sent, at: now, proactive: false, restored: true)
        #expect(ChatRows.offersStarters([]) && ChatRows.offersStarters([welcome]), "a new chat offers its starters")
        #expect(!ChatRows.offersStarters([earlier]), "never on a conversation that continues")
        #expect(!ChatRows.offersNewConversation([welcome]), "a live conversation is not an earlier one")
        #expect(ChatRows.offersNewConversation([earlier, welcome]))
    }
}

@Suite struct HistoryWidgetCopyTests {
    @Test func aMultiSelectSaysHowManyMoreAndNeverReadsTheLabelAsAVerb() {
        #expect(WidgetRules.manyButtonLabel(chosen: 0, selectLabel: "Taken") == "Pick 2 more")
        #expect(WidgetRules.manyButtonLabel(chosen: 1, selectLabel: "Compare") == "Pick 1 more")
        #expect(WidgetRules.manyButtonLabel(chosen: 2, selectLabel: "Taken") == "Taken 2")
    }

    @Test func stillListeningIsACallsWord() throws {
        let spoken = try #require(WidgetRules.screenFooter(prompt: "", typed: false))
        #expect(spoken.label == "STILL LISTENING" && spoken.line == "Tap one, or just say it.")
        #expect(WidgetRules.screenFooter(prompt: "Pick a car", typed: false)?.line == "Pick a car")
        #expect(WidgetRules.screenFooter(prompt: "Pick a car", typed: true) == nil, "a typed chat has no call to be on")
        #expect(WidgetRules.closeLabel(typed: false) == "Close and keep talking")
        #expect(WidgetRules.closeLabel(typed: true) == "Close")
    }
}

/// The real connection, frame by frame.
@Suite struct HistoryConnectionTests {
    private func rig() -> (ChatConnection, RoutedNetwork, ManualScheduler) {
        let network = RoutedNetwork()
        let scheduler = ManualScheduler()
        let chat = ChatConnection(
            setup: ChatConnection.Setup(
                publishableKey: "pk_test_chat", baseUrl: "https://www.graine.ai",
                variables: { [] }, identity: { nil }, contextFrame: { nil },
                session: { done in done(GraineSessionConfig(agentId: "agent-1", webcallAgentId: "web-1")) },
                runAction: { _, _, answer in answer(.ok("done")) },
                now: { Date(timeIntervalSince1970: 2_000) }
            ),
            network: network, scheduler: scheduler, onEvent: { _ in }
        )
        return (chat, network, scheduler)
    }

    private let history: [String: Any] = [
        "type": "history", "continued": true,
        "turns": [
            ["id": "f1", "role": "user", "text": "Is my order shipped?", "at": "2026-10-13T09:30:00Z", "channel": "chat"],
            ["id": "f2", "role": "assistant", "text": "Yes, it left this morning.", "at": "2026-10-13T09:30:04Z", "channel": "chat"],
            ["id": "f3", "role": "assistant", "text": "Hi, this is Asha.", "at": "2026-10-13T11:00:00Z", "channel": "fax"],
        ],
    ]

    @Test func aHistoryFrameBecomesTheTurnsBeforeAnyAgentMessage() throws {
        let (chat, network, _) = rig()
        chat.open()
        let socket = try #require(network.socket)
        socket.open()
        socket.frame(history)
        #expect(chat.transcript.turns.map { $0.text } == ["Is my order shipped?", "Yes, it left this morning.", "Hi, this is Asha."])
        #expect(chat.transcript.turns.allSatisfy { $0.restored })
        #expect(chat.transcript.turns.last?.channel == .chat, "a channel this build does not know is the chat")
        #expect(!chat.typing)
        // The conversation continues: the next message and the reply come after it.
        chat.send("Where is it now?")
        socket.frame(["type": "text", "data": "<beginning_of_stream>In Pune.<end_of_stream>"])
        #expect(chat.transcript.turns.suffix(2).map { $0.text } == ["Where is it now?", "In Pune."])
        #expect(chat.transcript.turns.last?.proactive == false)
    }

    @Test func whatWentOutAsTheChatOpenedStaysAfterTheHistory() throws {
        let (chat, network, _) = rig()
        chat.send("Typed in the tunnel")
        let socket = try #require(network.socket)
        socket.open()
        #expect(socket.sentTypes.contains("text"), "the waiting message went out on open")
        socket.frame(["type": "history", "turns": [["id": "g1", "role": "assistant", "text": "Hello!", "at": "2026-10-14T05:00:00Z"]], "continued": true])
        #expect(chat.transcript.turns.map { "\($0.restored):\($0.text)" } == ["true:Hello!", "false:Typed in the tunnel"],
                "the message the history cannot hold yet was lost, or shown twice")
    }

    @Test func aMalformedHistoryIsNoNews() throws {
        let (chat, network, _) = rig()
        chat.open()
        let socket = try #require(network.socket)
        socket.open()
        socket.frame(["type": "text", "data": "<beginning_of_stream>Hi!<end_of_stream>"])
        socket.frame(["type": "history", "turns": "none"])
        socket.frame(["type": "history", "turns": [["role": "robot", "text": "x", "at": "2026-10-13T09:30:00Z"]]])
        #expect(chat.transcript.turns.map { $0.text } == ["Hi!"])
        #expect(!chat.transcript.turns.contains { $0.restored })
    }
}

/// The instance: forgetting, the starters, and a new conversation.
@Suite @MainActor struct HistoryInstanceTests {
    private let history: [String: Any] = [
        "type": "history", "continued": true,
        "turns": [
            ["id": "f1", "role": "user", "text": "Is my order shipped?", "at": "2026-10-13T09:30:00Z", "channel": "chat"],
            ["id": "f2", "role": "assistant", "text": "Yes, it left this morning.", "at": "2026-10-13T09:30:04Z", "channel": "chat"],
        ],
    ]

    private func continuing(_ rig: PlatformRig) throws -> FakeSocket {
        rig.session(["identity": ["field": "user_id"]])
        rig.graine.identify(["user_id": "P-1"])
        rig.graine.chat.open()
        let socket = try #require(rig.network.socket)
        socket.open()
        socket.frame(history)
        return socket
    }

    @Test func aContinuedChatIsNotANewOneAndIsNeverAnnouncedAsNewMessages() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        let heard = HeardListener()
        rig.graine.addListener(heard)
        rig.session()
        rig.graine.chat.open()
        #expect(rig.graine.chat.awaitingFirstMessage, "a new chat offers its starters")
        let socket = try #require(rig.network.socket)
        socket.open()
        socket.frame(history)
        #expect(rig.graine.chat.turns.count == 2)
        #expect(!rig.graine.chat.awaitingFirstMessage, "no starters on a conversation that continues")
        #expect(heard.messages.isEmpty, "restored turns are not the agent speaking now")
    }

    @Test func aForgetClearsTheChatOnScreenAndARefusalLeavesIt() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        _ = try continuing(rig)
        rig.network.replies["/api/embed/memory/forget"] = (503, #"{"error":"Try again soon.","code":"unavailable"}"#)
        await #expect(throws: GraineServiceError.self) { try await rig.graine.forgetMemory() }
        #expect(rig.graine.chat.turns.count == 2, "a forget that did not complete took the conversation off the screen")
        rig.network.replies["/api/embed/memory/forget"] = (200, #"{"deleted":2}"#)
        #expect(try await rig.graine.forgetMemory() == 2)
        #expect(rig.graine.chat.turns.isEmpty, "the forgotten conversation is still on screen")
    }

    @Test func aNewConversationHangsUpLetsGoClearsAndOpensFresh() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        let first = try continuing(rig)
        rig.network.replies["/api/embed/conversation/new"] = (200, #"{"ok":true}"#)
        try await rig.graine.chat.newConversation()
        #expect(first.sentTypes.contains("stop"), "the conversation let go of was not hung up")
        let body = try #require(rig.network.bodies("/api/embed/conversation/new").first)
        #expect((body["identity"] as? [String: Any])?["value"] as? String == "P-1")
        #expect(body["installId"] as? String == "3f2504e0-4f89-11d3-9a0c-0305e82c3301")
        #expect(rig.network.bodies("/api/embed/memory/forget").isEmpty, "memories are untouched")
        #expect(rig.graine.chat.turns.isEmpty)
        #expect(rig.graine.chat.awaitingFirstMessage, "the starters are offered again")
        let fresh = try #require(rig.network.socket)
        #expect(fresh !== first, "no fresh chat was opened")
        fresh.open()
        fresh.frame(["type": "text", "data": "<beginning_of_stream>Hi! How can I help?<end_of_stream>"])
        #expect(rig.graine.chat.turns.map { $0.text } == ["Hi! How can I help?"])
    }

    @Test func aRefusedNewConversationLeavesTheChatAsItWasConnectedAgain() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        let first = try continuing(rig)
        rig.network.replies["/api/embed/conversation/new"] = (403, #"{"error":"Not one of your devices.","code":"device_limit"}"#)
        do {
            try await rig.graine.chat.newConversation()
            Issue.record("expected a refusal")
        } catch let error as GraineServiceError {
            #expect(error.code == .deviceLimit)
        }
        #expect(rig.graine.chat.turns.count == 2, "a refused new conversation took the old one off the screen")
        #expect(rig.network.socket !== first, "the chat was left hung up")
    }

    @Test func anonymousStartsOverWithoutAskingGraine() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session()
        rig.graine.chat.open()
        let socket = try #require(rig.network.socket)
        socket.open()
        socket.frame(["type": "text", "data": "<beginning_of_stream>Hello!<end_of_stream>"])
        try await rig.graine.chat.newConversation()
        #expect(rig.network.bodies("/api/embed/conversation/new").isEmpty, "nothing was kept for an anonymous customer")
        #expect(rig.graine.chat.turns.isEmpty)
        #expect(rig.network.socket !== socket)
    }
}
