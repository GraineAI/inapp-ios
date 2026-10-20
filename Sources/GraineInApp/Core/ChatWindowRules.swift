import Foundation

/*
 * CHAT WINDOW v2 — what the agent sends, what the customer answers, and what
 * the window decides to draw (contract/DESIGN.md "Chat window v2"; vectors
 * sdk/contract/chat-window.json). The React Native SDK's protocol.ts rules
 * (`readQuickReplies`, `chatRating`, `chatRatingFrame`, `chatRatingLayout`,
 * `chatGroups`, `chatShowsTime`), ported, and the window's own decisions —
 * which composer, which corners, whose time, where the chips go — kept here,
 * pure, so a Mac proves them and the views only draw.
 */

// MARK: - Quick replies

/// One reply the agent suggests for its latest turn: the words on the chip, and what a tap sends as the customer's message.
public struct GraineQuickReply: Equatable, Hashable, Sendable {
    public let label: String
    public let text: String

    public init(label: String, text: String) {
        self.label = label
        self.text = text
    }
}

/**
 * The agent's suggested replies: `{"type":"quick_replies","replies":[…]}`, each
 * a string or `{label, text}` (`text` absent: the label). Cleaned as the
 * reference cleans them: one line, a label at most 40 characters, a text at
 * most 200, a blank one skipped, a repeat (the same label, ignoring case)
 * dropped, at most six. `[]` takes them away.
 */
enum QuickReplies {
    static let max = 6
    static let labelMax = 40
    static let textMax = 200

    /// The replies the frame suggests, in order — or nil when it is not one (`replies` is not a list), which is ignored.
    static func read(_ frame: Any?) -> [GraineQuickReply]? {
        guard let o = JSON.unwrap(frame) as? [String: Any], let list = JSON.unwrap(o["replies"]) as? [Any] else { return nil }
        var out: [GraineQuickReply] = []
        var seen = Set<String>()
        for item in list {
            let raw = JSON.unwrap(item)
            let object = raw as? [String: Any]
            let label = line(object.map { $0["label"] } ?? raw, max: labelMax)
            guard !label.isEmpty, !seen.contains(label.lowercased()) else { continue }
            let given = object.map { line($0["text"], max: textMax) } ?? ""
            seen.insert(label.lowercased())
            out.append(GraineQuickReply(label: label, text: given.isEmpty ? label : given))
            if out.count == max { break }
        }
        return out
    }

    /**
     * One line of words as it may be drawn (protocol.ts `chatLine`): composed,
     * control and direction-override characters as spaces, spaces collapsed,
     * at most `max` characters (code points, as `Array.from` counts them).
     */
    static func line(_ value: Any?, max: Int) -> String {
        guard let s = JSON.unwrap(value) as? String else { return "" }
        var units: [UInt16] = []
        var lastSpace = true
        for c in s.precomposedStringWithCanonicalMapping.utf16 {
            let blank = ChatMarkdown.isSpace(c) || c <= 0x1F || (0x7F...0x9F).contains(c)
                || (0x202A...0x202E).contains(c) || (0x2066...0x2069).contains(c)
            if blank {
                if !lastSpace { units.append(0x20) }
                lastSpace = true
            } else {
                units.append(c)
                lastSpace = false
            }
        }
        if units.last == 0x20 { units.removeLast() }
        let clean = String(decoding: units, as: UTF16.self)
        let scalars = clean.unicodeScalars
        guard scalars.count > max else { return clean }
        var cut = String.UnicodeScalarView()
        cut.append(contentsOf: scalars.prefix(max))
        return String(cut).trimmingCharacters(in: CharacterSet(charactersIn: " "))
    }
}

// MARK: - The end-of-chat rating

/// The customer's answer to the end-of-chat rating: thumbs 0 or 1 out of 1, stars and emoji 1–5 out of 5.
public struct GraineChatRating: Equatable, Sendable {
    public enum Style: String, Sendable, CaseIterable {
        case thumbs
        case stars
        case emoji
    }

    /// Thumbs: 1 up, 0 down. Stars and emoji: 1–5.
    public let value: Int
    /// 1 for thumbs, 5 otherwise.
    public let scale: Int
    public let style: Style

    /// A rating as it may be sent: a value out of range is brought into it.
    public init(style: Style, value: Int) {
        self = ChatRatings.make(style: style.rawValue, value: value)
    }

    init(value: Int, scale: Int, style: Style) {
        self.value = value
        self.scale = scale
        self.style = style
    }
}

enum ChatRatings {
    /// The app event a rating is recorded as.
    static let event = "chat_rating"
    /// What each choice says to a screen reader (stars and emoji: 1–5).
    static let labels: [GraineChatRating.Style: [String]] = [
        .thumbs: ["Thumbs down", "Thumbs up"],
        .stars: ["1 star", "2 stars", "3 stars", "4 stars", "5 stars"],
        .emoji: ["Very unhappy", "Unhappy", "Neutral", "Happy", "Very happy"],
    ]
    /// The faces of the emoji rating, 1–5. Drawn as text: every platform has them.
    static let emoji = ["😞", "🙁", "😐", "🙂", "😄"]
    /// The line under a rating once it is given.
    static let thanks = "Thanks for your feedback"
    /// The card's question when the brand wrote none.
    static let defaultPrompt = "How was this chat?"

    /// protocol.ts `chatRating`: a style this build does not know is thumbs; a value that is not a number is 0.
    static func make(style: Any?, value: Any?) -> GraineChatRating {
        let word = JSON.unwrap(style) as? String
        let s: GraineChatRating.Style = word == "stars" ? .stars : word == "emoji" ? .emoji : .thumbs
        var n = 0.0
        if let v = JSON.unwrap(value), let number = JSON.number(v), number.doubleValue.isFinite { n = number.doubleValue }
        if s == .thumbs { return GraineChatRating(value: n >= 1 ? 1 : 0, scale: 1, style: s) }
        return GraineChatRating(value: Int(max(1, min(5, JSON.jsRound(n)))), scale: 5, style: s)
    }

    /// The words the agent's record carries for a rating — plain, so a person reading the conversation understands it.
    static func detail(_ r: GraineChatRating) -> String {
        if r.style == .thumbs {
            return r.value >= 1 ? "The customer gave this chat a thumbs up." : "The customer gave this chat a thumbs down."
        }
        return "The customer rated this chat \(r.value) out of \(r.scale)."
    }

    /// The frame a rating is sent as: a quiet app event, recorded on the conversation, never a nudge.
    static func frame(_ rating: GraineChatRating) -> String {
        let r = make(style: rating.style.rawValue, value: rating.value)
        return ChatWire.appEventFrame(name: event, detail: detail(r), data: [
            "quiet": true,
            "data": ["value": r.value, "scale": r.scale, "style": r.style.rawValue] as [String: Any],
        ])
    }

    /// The choices the card offers, in order: thumbs up then down; stars and faces 1–5.
    static func choices(_ style: GraineChatRating.Style) -> [Int] {
        style == .thumbs ? [1, 0] : [1, 2, 3, 4, 5]
    }

    /// What a choice says to a screen reader.
    static func label(_ style: GraineChatRating.Style, value: Int) -> String {
        let list = labels[style] ?? []
        let index = style == .thumbs ? (value >= 1 ? 1 : 0) : value - 1
        return list.indices.contains(index) ? list[index] : "\(value)"
    }
}

// MARK: - Groups

/// Where a row sits in its group of messages.
enum ChatGroupPosition: String, Equatable {
    case single, first, middle, last
}

/**
 * MESSAGES IN A ROW from one side, each said within two minutes of the one
 * before, are ONE group (protocol.ts `chatGroups`): drawn closer, their inner
 * corners tight, a tail on the last, a time under the last. A day separator,
 * an earlier call's row, a component, or the other side ends a group; a turn
 * with no time joins the group before it.
 */
enum ChatGroups {
    static let gapMs = 120_000.0

    struct Item: Equatable {
        var role: GraineRole?
        /// Milliseconds since the epoch; nil for a turn with no time.
        var at: Double?
        /// A day separator, a voice-call row, a component: ends any group.
        var breaks = false
    }

    static func positions(_ items: [Item]) -> [ChatGroupPosition] {
        var out = Array(repeating: ChatGroupPosition.single, count: items.count)
        var start = -1
        func close(_ end: Int) {
            guard start >= 0 else { return }
            if end > start {
                out[start] = .first
                if end - start > 1 { for i in (start + 1)..<end { out[i] = .middle } }
                out[end] = .last
            }
            start = -1
        }
        var prevAt: Double?
        for (i, item) in items.enumerated() {
            guard !item.breaks, item.role != nil else {
                close(i - 1)
                prevAt = nil
                continue
            }
            let at = item.at.flatMap { $0.isFinite ? $0 : nil }
            let prev = i > 0 ? items[i - 1] : nil
            let joins = start >= 0 && prev != nil && !(prev!.breaks) && prev!.role == item.role
                && (at == nil || prevAt == nil || abs(at! - prevAt!) <= gapMs)
            if !joins {
                close(i - 1)
                start = i
            }
            if at != nil { prevAt = at }
        }
        close(items.count - 1)
        return out
    }

    /// Whether a row's time is drawn: every message for `always`, the last of each group for `group`, none for `never`.
    static func showsTime(_ show: String, _ position: ChatGroupPosition) -> Bool {
        switch show {
        case "always": return true
        case "group": return position == .single || position == .last
        default: return false
        }
    }
}

// MARK: - The context card the app pins

/**
 * WHAT THE CONVERSATION IS ABOUT, pinned by your app — an item, an account,
 * a case — drawn under the chat's header or atop its thread, where the design
 * says (`chat.header.contextCard`). Never sent to the agent: describe the
 * screen to it with the screen context, as always.
 *
 *     graine.chat.pin(GraineChatPin(title: "Your plan", subtitle: "Renews on 14 Nov", badge: "Active"))
 *     graine.chat.pin(nil)   // take it away
 *
 * Each line is one line: the title at most 60 characters, the subtitle 80, the badge 24.
 */
public struct GraineChatPin: Equatable, Sendable {
    public let title: String
    public let subtitle: String?
    /// A picture, filled and cropped into the card's thumbnail; nil draws the title's first letter.
    public let imageUrl: URL?
    public let badge: String?

    public init(title: String, subtitle: String? = nil, imageUrl: URL? = nil, badge: String? = nil) {
        self.title = QuickReplies.line(title, max: 60)
        self.subtitle = subtitle.map { QuickReplies.line($0, max: 80) }.flatMap { $0.isEmpty ? nil : $0 }
        self.imageUrl = imageUrl
        self.badge = badge.map { QuickReplies.line($0, max: 24) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// What a screen reader says: "Pinned: {title}, {subtitle}, {badge}".
    var spoken: String {
        (["Pinned: " + title] + [subtitle, badge].compactMap { $0 }).joined(separator: ", ")
    }
}

// MARK: - What the window draws

/**
 * THE WINDOW'S DECISIONS — which pieces show, where, and in what shape —
 * from the tokens and the conversation's state. The views in UI/ draw what
 * these say.
 */
enum ChatWindowRules {

    // MARK: Header

    /// The header's status line: nothing, the loader with words, or words (after the online dot or not).
    enum HeaderStatus: Equatable {
        case none
        case waiting(String)
        case words(String, dot: Bool)
    }

    /**
     * First match wins (DESIGN.md "Header"): connecting, reconnecting, the
     * agent typing (where the status says so), no line at all, then the dot
     * and the subtitle (or "Online"), or the words alone. A chat that is not
     * connected says so rather than "Online".
     */
    static func headerStatus(
        _ header: GraineChatTokens.Header, status: GraineChatStatus, typing: Bool,
        subtitle: String, typingText: String, loader: GraineLoaderText = Loaders.defaultText
    ) -> HeaderStatus {
        switch status {
        case .connecting: return .waiting(loader.connecting ?? "Connecting…")
        case .reconnecting: return .waiting(loader.reconnecting ?? "Reconnecting…")
        default: break
        }
        if typing && header.typingStatus { return .words(typingText.isEmpty ? "Typing…" : typingText, dot: false) }
        if header.status == "none" { return .none }
        guard status == .online else { return .words("Not connected", dot: false) }
        let words = subtitle.isEmpty ? "Online" : subtitle
        return .words(words, dot: header.status == "online")
    }

    /// The header's call button: the design asks for it there, and the agent takes calls this SDK can start from the chat.
    static func headerCall(_ escalation: GraineChatTokens.Escalation, takesCalls: Bool) -> Bool {
        takesCalls && escalation.call == "header"
    }

    // MARK: The context card

    enum PinPlace: Equatable {
        case bar
        case card
    }

    /// Nothing until the app pins one, nor where the design has no place for it.
    static func pinPlace(_ header: GraineChatTokens.Header, pin: GraineChatPin?) -> PinPlace? {
        guard let pin = pin, !pin.title.isEmpty else { return nil }
        switch header.contextCard {
        case "bar": return .bar
        case "card": return .card
        default: return nil
        }
    }

    // MARK: The reconnect banner

    enum Banner: Equatable {
        /// The chat lost a connection it had and is making it again.
        case reconnecting
        /// Offline with a message waiting to go.
        case offline
    }

    /// Calm, never red: only after the chat was connected, or while a message waits with nothing connecting it.
    static func banner(status: GraineChatStatus, wasOnline: Bool, turns: [GraineChatTurn]) -> Banner? {
        if case .reconnecting = status, wasOnline { return .reconnecting }
        let waiting = turns.contains { $0.role == .customer && $0.delivery == .sending }
        if waiting && (status == .offline || status == .idle) { return .offline }
        return nil
    }

    // MARK: Bubbles

    /// One bubble's corners in reading terms (leading is the left in a left-to-right language), and whether it carries a tail.
    struct Corners: Equatable {
        var topLeading: Double
        var topTrailing: Double
        var bottomLeading: Double
        var bottomTrailing: Double
        /// Continuous (iOS's own) corners rather than circular ones.
        var continuous: Bool
        /// The tail at the bottom speaker-side corner (that corner is square).
        var tail: Bool
    }

    /**
     * DESIGN.md "Bubbles" → Groups. The speaker's side is the trailing side for
     * the customer, the leading side for the agent. A bare bubble has no box.
     */
    static func corners(_ b: GraineChatTokens.Bubbles, role: GraineRole, position: ChatGroupPosition) -> Corners {
        let r = b.radius
        let tight = b.tightRadius
        let p = b.grouping ? position : .single
        var top = r, bottom = r
        var continuous = false
        var tail = false
        switch b.shape {
        case "squircle", "tail":
            continuous = true
            if p == .middle || p == .last { top = tight }
            if p == .first || p == .middle { bottom = tight }
            if b.shape == "tail" && (p == .single || p == .last) {
                bottom = 0
                tail = true
            }
        case "flat":
            break
        default:
            // rounded (v1): the bottom speaker-side corner is always tight, the top one in a group's middle and end.
            bottom = tight
            if p == .middle || p == .last { top = tight }
        }
        let customer = role == .customer
        return Corners(
            topLeading: customer ? r : top,
            topTrailing: customer ? top : r,
            bottomLeading: customer ? r : bottom,
            bottomTrailing: customer ? bottom : r,
            continuous: continuous, tail: tail
        )
    }

    /// The bubble's padding: `padY` × `padX`, or 2 × 2 for a bare one.
    static func padding(_ side: GraineChatTokens.BubbleSide, density: GraineChatTokens.Density) -> (h: Double, v: Double) {
        side.bare ? (2, 2) : (density.padX, density.padY)
    }

    // MARK: Times and status

    /// Where a row's time is drawn, if anywhere.
    enum TimePlace: Equatable {
        case below
        case inside
    }

    static func timePlace(_ t: GraineChatTokens.Timestamps, side: GraineChatTokens.BubbleSide, position: ChatGroupPosition, turn: GraineChatTurn) -> TimePlace? {
        // A reply still arriving has no time yet; a message waiting shows one only beside its tick.
        guard !turn.live, ChatGroups.showsTime(t.show, position) else { return nil }
        if turn.role == .customer && turn.delivery != .sent && !t.ticks { return nil }
        return t.style == "inside" && !side.bare ? .inside : .below
    }

    /// The mark beside a customer's time.
    static func tick(_ t: GraineChatTokens.Timestamps, turn: GraineChatTurn) -> GraineIconName? {
        guard t.ticks, turn.role == .customer else { return nil }
        switch turn.delivery {
        case .sending: return .clock
        case .sent: return .check
        case .failed: return .alert
        }
    }

    /// What a screen reader says for a bubble: "{name}: {plain words}" or "You: {plain words}", then its time and its status.
    static func spoken(_ turn: GraineChatTurn, plain: String, name: String, time: String?) -> String {
        var parts = [(turn.role == .customer ? "You" : name) + ": " + plain]
        if let time = time { parts.append(time) }
        switch turn.delivery {
        case .sending: parts.append("waiting to send")
        case .failed: parts.append("not sent. Double-tap to retry.")
        case .sent: break
        }
        return parts.joined(separator: ", ")
    }

    // MARK: Chips and starters

    enum StarterPlace: Equatable {
        /// Above the composer, on the customer's side.
        case docked
        /// In the thread, at the end of the welcome (or of what the agent has said so far).
        case thread
    }

    /// The brand's starters: a list always in the thread; chips placed `inline` in it; otherwise docked.
    static func starterPlace(_ chips: GraineChatTokens.Chips, welcome: GraineChatTokens.Welcome) -> StarterPlace {
        if welcome.starters == "list" || chips.placement == "inline" { return .thread }
        return .docked
    }

    /// The agent's quick replies: docked above the composer for `above-composer`, else under the turn they follow.
    static func repliesDocked(_ chips: GraineChatTokens.Chips) -> Bool {
        chips.placement == "above-composer"
    }

    // MARK: Welcome

    enum WelcomeKind: Equatable {
        case centered
        case card
        case hero
    }

    /**
     * The welcome of a conversation that began here (nothing restored on
     * screen): a card or a hero stays at the top of its thread as it grows —
     * the starters inside it go by their own rule — while `centered` is v1's
     * empty chat, before any message; `minimal` has none. A restored
     * conversation has no welcome.
     */
    static func welcome(_ w: GraineChatTokens.Welcome, turns: [GraineChatTurn]) -> WelcomeKind? {
        guard !turns.contains(where: { $0.restored }) else { return nil }
        switch w.layout {
        case "card": return .card
        case "hero": return .hero
        case "minimal": return nil
        default: return turns.isEmpty ? .centered : nil
        }
    }

    // MARK: Composer

    struct ComposerPieces: Equatable {
        /// The paperclip: the design draws one and the app handles attachments.
        var attach: Bool
        /// The call button beside the field.
        var call: Bool
        /// The microphone in the send button's place while the field is empty.
        var mic: Bool
    }

    static func composerPieces(_ c: GraineChatTokens.Composer, escalation: GraineChatTokens.Escalation, attachHandler: Bool, takesCalls: Bool) -> ComposerPieces {
        let mic = c.mic && takesCalls
        return ComposerPieces(
            attach: c.attach && attachHandler,
            call: takesCalls && escalation.call == "composer" && !mic,
            mic: mic
        )
    }

    // MARK: Scroll to latest

    /// The thread follows new rows while it is this close to the bottom.
    static let followDistance = 120.0

    /// "N new" once something new has arrived since the customer scrolled away; "9+" past nine.
    static func newCount(_ n: Int) -> String? {
        guard n > 0 else { return nil }
        return (n > 9 ? "9+" : "\(n)") + " new"
    }

    // MARK: Cards

    /// A component's large image height for `width`: its own (`auto`), as tall as wide, 3:4, or 9:16 — always 100–260.
    static func imageHeight(_ image: String, width: Double, auto: Double) -> Double {
        let h: Double
        switch image {
        case "square": h = width
        case "landscape": h = width * 0.75
        case "wide": h = width * 9 / 16
        default: return auto
        }
        return min(260, max(100, h))
    }

    // MARK: The rating card

    /// The rating card's width: `min(ratingMaxWidth, ratingShare × the thread)`, wider where its choices need it.
    static let ratingMaxWidth = 300.0
    static let ratingShare = 0.84
    /// Between two of the rating's choices.
    static let ratingGap = 8.0

    /// Each style's choices at full size: how many, the target, the icon or face inside it.
    static func ratingChoices(_ style: GraineChatRating.Style) -> (count: Int, size: Double, glyph: Double) {
        switch style {
        case .thumbs: return (2, 44, 22)
        case .stars: return (5, 36, 28)
        case .emoji: return (5, 44, 24)
        }
    }

    /// How the rating card is laid out in a thread of a given width.
    struct RatingLayout: Equatable {
        /// The card's width.
        var width: Double
        /// How many choices: 2 thumbs, or 5 stars or faces.
        var count: Int
        /// Each choice's square target.
        var size: Double
        /// The icon or face inside a target, scaled with it.
        var glyph: Double
        /// Between two choices.
        var gap: Double
    }

    /**
     * The rating card in a thread `thread` wide (its rows' width, inside the
     * thread's own padding), with `padding` inside the card — the SAME numbers
     * on every renderer (protocol.ts `chatRatingLayout`, DESIGN.md "Rating"):
     * `min(300, 84% of the thread)` wide, wider — up to the thread's own width —
     * where the choices would not fit inside its padding; the choices at full
     * size (thumbs and faces 44, stars 36), 8 apart, made smaller together only
     * where even the whole thread is too narrow for them. A narrow phone or a
     * large display setting never pushes a choice out of its card. A style this
     * build does not know is thumbs; a width or padding that is not a number is 0.
     */
    static func ratingLayout(style: String, thread: Double, padding: Double) -> RatingLayout {
        let s: GraineChatRating.Style = style == "stars" ? .stars : style == "emoji" ? .emoji : .thumbs
        let full = ratingChoices(s)
        let count = Double(full.count)
        let room = thread.isFinite ? max(0, thread) : 0
        let pad = padding.isFinite ? max(0, padding) : 0
        let row = count * full.size + (count - 1) * ratingGap
        let width = min(ratingMaxWidth, max(room * ratingShare, min(room, row + 2 * pad)))
        let inner = max(0, width - 2 * pad)
        let size = max(0, min(full.size, (inner - (count - 1) * ratingGap) / count))
        return RatingLayout(width: width, count: full.count, size: size, glyph: full.glyph * size / full.size, gap: ratingGap)
    }
}
