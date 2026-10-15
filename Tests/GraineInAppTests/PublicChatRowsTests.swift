import Foundation
import Testing
import GraineInApp   // not @testable: only what an app can reach

/// The rows a chat window draws, as an app drawing its own chat reaches them — public, by their Graine names.
@Suite struct PublicChatRowsTests {
    @Test func anAppLaysOutItsOwnChatAsTheSdksWindowDoes() {
        let (turns, now) = ChatRowFixtures.callThenToday()
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let rows: [GraineChatRow] = GraineChatRows.build(turns, now: now, calendar: utc)
        #expect(rows.map(\.id) == ["day-2025-10-13", "voice-a1", "day-2025-10-14", "t1"])
        guard case .day(let day) = rows[0], case .voice(let call) = rows[1] else {
            Issue.record("a day line, then the call")
            return
        }
        #expect(day.day == .yesterday && day.key == "yesterday" && day.date == "2025-10-13")
        #expect(GraineChatRows.dayLabel(day, now: now, calendar: utc, locale: Locale(identifier: "en_US")) == "Yesterday")
        #expect(call.first == 0 && call.last == 1, "one row for the run of voice turns, never their words")
        #expect(GraineChatRows.callLabel(call, calendar: utc, locale: Locale(identifier: "en_US")).hasPrefix("Voice call · "))
        #expect(GraineChatRows.offersNewConversation(turns), "restored turns are on screen")
        #expect(!GraineChatRows.offersStarters(turns))
    }
}
