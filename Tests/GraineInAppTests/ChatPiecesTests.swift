import Foundation
import Testing
@testable import GraineInApp

/*
 * THE PIECES THE GARAGE SETS (contract/DESIGN.md "Chat window" → Booked
 * calls, Earlier messages, New conversation): the four chat tokens as the
 * session serves them — on, and the SDK's words, when absent or of the wrong
 * type — and what the chat window draws of them, run against
 * sdk/contract/history.json → `display`, the same cases every SDK runs.
 */

private let palette = GraineThemeTokens.Colors(
    background: "#FFFFFF", surface: "#F7F7F5", surfaceRaised: "#FFFFFF", text: "#101318", textMuted: "#5F6672",
    border: "#E5E4E0", accent: "#318CE7", onAccent: "#FFFFFF", accentSoft: "#E3EEFB", success: "#1FAD5B",
    warning: "#F5A524", danger: "#E5484D", userBubble: "#318CE7", userBubbleText: "#FFFFFF",
    agentBubble: "#F1F1EF", agentBubbleText: "#101318", scrim: "#000000"
)

@Suite struct ChatPiecesTests {
    @Test func theSessionsTokensAreReadAsServedTheSameInLightAndDark() throws {
        let cases = try #require(try ContractFile.load("design.json")["cases"] as? [[String: Any]])
        var hidden = (calls: false, history: false, compose: false, title: false)
        for c in cases {
            let raw = try #require(c["design"] as? [String: Any])
            let design = try #require(GraineDesign.parse(raw))
            for (scheme, tokens) in [("light", design.light), ("dark", design.dark)] {
                let served = try #require((raw[scheme] as? [String: Any])?["chat"] as? [String: Any])
                let chat = try #require(tokens.chat, "\(scheme) chat")
                #expect(chat.showUpcomingCalls == served["showUpcomingCalls"] as? Bool)
                #expect(chat.upcomingTitle == served["upcomingTitle"] as? String)
                #expect(chat.showHistory == served["showHistory"] as? Bool)
                #expect(chat.newConversation == served["newConversation"] as? Bool)
                hidden.calls = hidden.calls || !chat.showUpcomingCalls
                hidden.history = hidden.history || !chat.showHistory
                hidden.compose = hidden.compose || !chat.newConversation
                hidden.title = hidden.title || !chat.upcomingTitle.isEmpty
            }
            #expect(design.light.chat?.showHistory == design.dark.chat?.showHistory, "not a colour: one value for both schemes")
        }
        #expect(hidden.calls && hidden.history && hidden.compose && hidden.title, "the contract turns each away from its default")
    }

    @Test func absentOrTheWrongTypeIsOnAndTheSDKsWords() throws {
        let older = try #require(SurfaceTokens.chat([:], colors: palette))
        #expect(older.showUpcomingCalls && older.showHistory && older.newConversation && older.upcomingTitle.isEmpty, "an older server says nothing")
        for odd: Any in ["false", 0, NSNull(), ["off"], ["showHistory": false]] {
            let t = try #require(SurfaceTokens.chat(["showUpcomingCalls": odd, "showHistory": odd, "newConversation": odd], colors: palette))
            #expect(t.showUpcomingCalls && t.showHistory && t.newConversation, "\(odd): never read as off")
        }
        for odd: Any in [7, false, NSNull(), ["Calls"], "   "] {
            let t = try #require(SurfaceTokens.chat(["upcomingTitle": odd], colors: palette))
            #expect(t.upcomingTitle.isEmpty, "\(odd): the SDK's words")
        }
        let off = try #require(SurfaceTokens.chat(
            ["showUpcomingCalls": false, "showHistory": false, "newConversation": false, "upcomingTitle": "  Your calls  "], colors: palette))
        #expect(!off.showUpcomingCalls && !off.showHistory && !off.newConversation)
        #expect(off.upcomingTitle == "Your calls")
    }

    @Test func whatTheWindowDrawsIsTheContractsDisplay() throws {
        let cases = try #require(try ContractFile.load("history.json")["display"] as? [[String: Any]])
        #expect(cases.count >= 8)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            var calendar = Calendar(identifier: .gregorian)
            let zone = try #require(c["timeZone"] as? String)
            calendar.timeZone = try #require(TimeZone(identifier: zone))
            let now = try #require((c["now"] as? String).flatMap { ChatHistory.time($0) })
            let chat = try #require(SurfaceTokens.chat(c["chat"] ?? [:], colors: palette), "\(name): chat")
            let turns = try (c["turns"] as? [[String: Any]] ?? []).map { t -> GraineChatTurn in
                let at = try #require((t["at"] as? String).flatMap { ChatHistory.time($0) })
                return GraineChatTurn(
                    id: t["id"] as? String ?? "", role: (t["role"] as? String) == "agent" ? .agent : .customer,
                    text: t["text"] as? String ?? "", live: false, delivery: .sent,
                    at: at, proactive: false,
                    restored: t["restored"] as? Bool ?? false, channel: (t["channel"] as? String) == "voice" ? .voice : .chat
                )
            }
            let p = ChatPieces.of(turns, chat: chat, upcomingCount: c["upcoming"] as? Int ?? 0)
            #expect(p.turns.map(\.id) == (c["shown"] as? [String] ?? []), "\(name): the turns drawn")
            let rows: [String] = ChatRows.build(p.turns, now: now, calendar: calendar).map { row in
                switch row {
                case .day(let line): return "day:\(line.key)"
                case .voice(let line): return "voice:\(line.first)-\(line.last)"
                case .turn(let turn): return "turn:\(p.turns.firstIndex { $0.id == turn.id } ?? -1)"
                }
            }
            let want: [String] = (c["rows"] as? [[String: Any]] ?? []).map { r in
                if let day = r["day"] as? String { return "day:\(day)" }
                if let v = r["voice"] as? [Int] { return "voice:\(v[0])-\(v[1])" }
                return "turn:\(r["turn"] as? Int ?? -1)"
            }
            #expect(rows == want, "\(name): rows")
            #expect(p.starters == c["starters"] as? Bool, "\(name): starters")
            #expect(p.newConversation == c["newConversation"] as? Bool, "\(name): New conversation")
            #expect(p.upcoming == c["card"] as? Bool, "\(name): the booked-calls card")
            #expect(p.upcomingTitle == c["cardTitle"] as? String, "\(name): its title")
        }
    }

    @Test func anOlderServerWithNoChatTokensDrawsEverything() {
        let restored = GraineChatTurn(
            id: "h1", role: .customer, text: "Hi", live: false, delivery: .sent, at: Date(), proactive: false, restored: true, channel: .chat
        )
        let p = ChatPieces.of([restored], chat: nil, upcomingCount: 2)
        #expect(p.turns.count == 1 && p.newConversation && !p.starters && p.upcoming)
        #expect(p.upcomingTitle == "Upcoming calls")
        #expect(ChatPieces.of([], chat: nil, upcomingCount: 1).upcomingTitle == "Upcoming call")
    }
}
