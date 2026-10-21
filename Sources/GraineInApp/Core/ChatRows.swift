import Foundation

/*
 * WHAT A CHAT WINDOW DRAWS, in order (DESIGN.md "Chat window"; contract §2.6,
 * the `rows` of sdk/contract/history.json): a bubble per chat turn; ONE
 * "Voice call · 6:05 PM" row for a run of voice turns on one day — that a call
 * happened and when, never its transcript; and a day separator — Today,
 * Yesterday, a date — before the first row when it is not from today, and
 * wherever the device's day changes between rows. A conversation all from
 * today draws exactly what it always did. The React Native SDK's chatRows
 * (protocol.ts), ported. Foundation only: `swift test` proves it on a Mac.
 *
 * Public for a chat of your own, drawn from `GraineChat.turns`:
 *
 *     ForEach(GraineChatRows.build(chat.turns)) { row in
 *         switch row {
 *         case .day(let line): Text(GraineChatRows.dayLabel(line))
 *         case .voice(let call): Text(GraineChatRows.callLabel(call))
 *         case .turn(let turn): MyBubble(turn)
 *         }
 *     }
 *
 * With `newConversationBefore:` (`GraineChat.newConversationBefore`) the rows
 * are the window's own (`GraineChatWindowRow`), the "Disconnected · new
 * conversation" marker among them.
 */

/// Which day a separator names: the contract's "today", "yesterday", or the local date.
public enum GraineChatDay: Equatable, Sendable {
    case today
    case yesterday
    case date
}

/// A day separator: which day, the local date (YYYY-MM-DD), and the first message's time on it.
public struct GraineChatDayLine: Equatable, Sendable {
    public let day: GraineChatDay
    /// The device's date, YYYY-MM-DD.
    public let date: String
    public let at: Date

    /// The contract's word for it: "today", "yesterday" or the local date.
    public var key: String {
        switch day {
        case .today: return "today"
        case .yesterday: return "yesterday"
        case .date: return date
        }
    }
}

/// An earlier call: when its first turn was said, and which turns (indices into the transcript) it stands for — never their words.
public struct GraineChatCallLine: Equatable, Sendable {
    public let id: String
    public let at: Date
    public let first: Int
    public let last: Int
}

/// One row of a chat window: a day separator, an earlier call, or a message.
public enum GraineChatRow: Equatable, Identifiable {
    case day(GraineChatDayLine)
    case voice(GraineChatCallLine)
    case turn(GraineChatTurn)

    /// Stable while the conversation grows: a separator by its date, a call by its first turn, a bubble by its turn.
    public var id: String {
        switch self {
        case .day(let line): return "day-\(line.date)"
        case .voice(let line): return line.id
        case .turn(let turn): return turn.id
        }
    }
}

typealias ChatDay = GraineChatDay
typealias ChatDayLine = GraineChatDayLine
typealias ChatCallLine = GraineChatCallLine
typealias ChatRow = GraineChatRow
typealias ChatRows = GraineChatRows

/**
 * The "Disconnected · new conversation" row (DESIGN.md "A new conversation
 * under earlier lines"): Graine began a new conversation under earlier lines.
 * The window's own row — never a turn, never sent.
 */
public struct GraineChatNewConversationLine: Equatable, Sendable {
    /// The id of the turn it goes before.
    public let before: String
    /// What it says: "Disconnected · new conversation".
    public let label: String
    /// What a screen reader says for it: "Disconnected. A new conversation started."
    public let spoken: String

    /// Stable while the conversation grows: `fresh-` and the turn's id.
    public var id: String { "fresh-\(before)" }
}

/**
 * One row of the SDK's own chat window, for a chat of your own:
 * `GraineChatRows.build(_:newConversationBefore:now:calendar:)` — the rows
 * `GraineChatRow` lists, and the "Disconnected · new conversation" marker
 * where Graine began a new conversation under earlier lines.
 */
public enum GraineChatWindowRow: Equatable, Identifiable {
    case day(GraineChatDayLine)
    case voice(GraineChatCallLine)
    case turn(GraineChatTurn)
    /// The marker: drawn like a day line, after the day line of the turn it goes before.
    case newConversation(GraineChatNewConversationLine)

    /// Stable while the conversation grows: as `GraineChatRow.id`, and the marker by the turn it goes before.
    public var id: String {
        switch self {
        case .day(let line): return GraineChatRow.day(line).id
        case .voice(let line): return line.id
        case .turn(let turn): return turn.id
        case .newConversation(let line): return line.id
        }
    }
}

/**
 * A row of the SDK's own chat window: one of the rows above, or its
 * "Disconnected · new conversation" marker (DESIGN.md "A new conversation
 * under earlier lines") — the window's own row, never a turn; public as
 * `GraineChatWindowRow`.
 */
enum ChatThreadRow: Equatable, Identifiable {
    case row(GraineChatRow)
    /// The marker, before the turn with this id.
    case newConversation(before: String)

    var id: String {
        switch self {
        case .row(let row): return row.id
        case .newConversation(let turn): return "fresh-\(turn)"
        }
    }
}

/**
 * THE ROWS A CHAT WINDOW DRAWS, for a chat of your own: a bubble per chat
 * turn, one "Voice call" row for a run of voice turns on one day, and a day
 * separator before the first row when it is not from today and wherever the
 * device's day changes. The SDK's own chat window draws exactly these.
 */
public enum GraineChatRows {
    /// The rows for `turns` (oldest first), on the device's days as `calendar` counts them. Rebuild whenever `turns` changes.
    public static func build(_ turns: [GraineChatTurn], now: Date = Date(), calendar: Calendar = .current) -> [GraineChatRow] {
        let today = localDate(now, calendar)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now).map { localDate($0, calendar) }
        var rows: [ChatRow] = []
        var lastDay: String?
        var openCall: (row: Int, day: String)?
        for (index, turn) in turns.enumerated() {
            let day = localDate(turn.at, calendar)
            // One call, one row — until the day turns: a separator never sits inside a row.
            if turn.channel == .voice, let call = openCall, call.day == day, case .voice(let line) = rows[call.row] {
                rows[call.row] = .voice(ChatCallLine(id: line.id, at: line.at, first: line.first, last: index))
                continue
            }
            if lastDay.map({ day != $0 }) ?? (day != today) {
                let kind: ChatDay = day == today ? .today : day == yesterday ? .yesterday : .date
                rows.append(.day(ChatDayLine(day: kind, date: day, at: turn.at)))
            }
            lastDay = day
            if turn.channel == .voice {
                rows.append(.voice(ChatCallLine(id: "voice-\(turn.id)", at: turn.at, first: index, last: index)))
                openCall = (rows.count - 1, day)
            } else {
                rows.append(.turn(turn))
                openCall = nil
            }
        }
        return rows
    }

    /// "Today", "Yesterday", else the date in the device's words ("Tue 14 Oct"), with the year when it is not this one.
    public static func dayLabel(_ line: GraineChatDayLine, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        switch line.day {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .date:
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = calendar.timeZone
            let sameYear = calendar.component(.year, from: line.at) == calendar.component(.year, from: now)
            formatter.setLocalizedDateFormatFromTemplate(sameYear ? "EEEdMMM" : "EEEdMMMy")
            return formatter.string(from: line.at)
        }
    }

    /// "Voice call · 6:05 PM" — the call's first turn, in the device's short time.
    public static func callLabel(_ line: GraineChatCallLine, calendar: Calendar = .current, locale: Locale = .current) -> String {
        "Voice call · " + clock(line.at, calendar: calendar, locale: locale)
    }

    /// What a screen reader says for the row: "Voice call at 6:05 PM".
    public static func callSpoken(_ line: GraineChatCallLine, calendar: Calendar = .current, locale: Locale = .current) -> String {
        "Voice call at " + clock(line.at, calendar: calendar, locale: locale)
    }

    /**
     * The rows the SDK's own chat window draws: `build(_:now:calendar:)`'s,
     * with a "Disconnected · new conversation" marker before each turn in
     * `newConversationBefore` (`GraineChat.newConversationBefore`), after that
     * turn's day line — and never above everything: with nothing earlier drawn
     * there is nothing to set apart. Rebuild whenever either changes.
     */
    public static func build(
        _ turns: [GraineChatTurn], newConversationBefore: [String], now: Date = Date(), calendar: Calendar = .current
    ) -> [GraineChatWindowRow] {
        thread(build(turns, now: now, calendar: calendar), marks: Set(newConversationBefore)).map { row in
            switch row {
            case .row(.day(let line)): return .day(line)
            case .row(.voice(let line)): return .voice(line)
            case .row(.turn(let turn)): return .turn(turn)
            case .newConversation(let turn):
                return .newConversation(GraineChatNewConversationLine(before: turn, label: newConversationLabel, spoken: newConversationSpoken))
            }
        }
    }

    /// The window's marker where the server began a new conversation under earlier lines.
    static let newConversationLabel = "Disconnected · new conversation"
    /// What a screen reader says for it.
    static let newConversationSpoken = "Disconnected. A new conversation started."

    /**
     * The window's rows: `rows` with the marker before each turn in `marks`,
     * after that turn's day separator. Never above everything: with nothing
     * earlier drawn (earlier messages hidden) there is nothing to set apart.
     */
    static func thread(_ rows: [GraineChatRow], marks: Set<String>) -> [ChatThreadRow] {
        var out: [ChatThreadRow] = []
        var earlier = false
        for row in rows {
            switch row {
            case .day:
                break
            case .voice:
                earlier = true
            case .turn(let turn):
                if earlier && marks.contains(turn.id) { out.append(.newConversation(before: turn.id)) }
                earlier = true
            }
            out.append(.row(row))
        }
        return out
    }

    /// A time in the device's short words: "6:05 PM".
    public static func clock(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// The header's "New conversation" belongs to a conversation that continues: offered while restored turns are on screen.
    public static func offersNewConversation(_ turns: [GraineChatTurn]) -> Bool {
        turns.contains { $0.restored }
    }

    /// The brand's starters belong to a new chat: not once the customer has said something, nor on a conversation that continues.
    public static func offersStarters(_ turns: [GraineChatTurn]) -> Bool {
        !turns.contains { $0.role == .customer || $0.restored }
    }

    /// The local date of an instant, as the contract writes it: YYYY-MM-DD.
    static func localDate(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/*
 * THE PIECES A CHAT WINDOW DRAWS of those the design can leave out (DESIGN.md
 * "Chat window" → Booked calls, Earlier messages, New conversation): the React
 * Native SDK's chatPieces, ported, and pinned for every SDK by
 * sdk/contract/history.json → `display`. With earlier messages hidden the
 * window opens like a new chat — the restored turns are not drawn (the agent
 * still has them), the starters may show, and the compose control, which
 * belongs to earlier messages on screen, does not.
 */
struct ChatPieces: Equatable {
    /// The turns to draw, oldest first.
    let turns: [GraineChatTurn]
    /// The brand's starters may show: nothing restored on screen, nothing said by the customer.
    let starters: Bool
    /// The header's compose control: kept by the design, and earlier messages on screen.
    let newConversation: Bool
    /// The booked-calls card: kept by the design, and at least one booked call.
    let upcoming: Bool
    /// The card's title: the brand's words, else "Upcoming call" / "Upcoming calls".
    let upcomingTitle: String
    /**
     * "Book a call" (BOOKING-SHEET.md §4): the agent can be booked from the app
     * (`bookingAvailable`) and the design keeps the booked-calls card — in the
     * card under its calls, or as a compact row in its place when there are none.
     */
    var book: Bool = false

    /// For `turns` and `upcomingCount` booked calls, under the design's chat tokens (nil, an older server: everything on).
    static func of(_ turns: [GraineChatTurn], chat: GraineChatTokens?, upcomingCount: Int = 0, bookable: Bool = false) -> ChatPieces {
        let shown = (chat?.showHistory ?? true) ? turns : turns.filter { !$0.restored }
        let words = (chat?.upcomingTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cardKept = chat?.showUpcomingCalls ?? true
        return ChatPieces(
            turns: shown,
            starters: ChatRows.offersStarters(shown),
            newConversation: (chat?.newConversation ?? true) && ChatRows.offersNewConversation(shown),
            upcoming: cardKept && upcomingCount > 0,
            upcomingTitle: words.isEmpty ? UpcomingCalls.title(count: upcomingCount) : words,
            book: cardKept && bookable
        )
    }
}
