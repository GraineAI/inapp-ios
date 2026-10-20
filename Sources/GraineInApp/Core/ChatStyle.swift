import Foundation

/*
 * THE CHAT WINDOW, PIECE BY PIECE (contract/DESIGN.md "Chat window v2") — the
 * header, the bubbles, the times, the wallpaper, the chips, the cards, the
 * composer, the typing indicator, the density, the welcome, the rating and
 * the call button, each resolved on the server and delivered in the token
 * set's `chat` group beside the v1 tokens (Core/SurfaceTokens.swift).
 *
 * Read as every token is read: nothing trusted, nothing thrown. A server that
 * sends none of these groups (an older one) gets CLASSIC — the chat as it was
 * drawn before, derived from the v1 tokens exactly as theme.ts `resolveChat`
 * derives it, so an older session and a classic one draw the same window. A
 * group that is there with a field missing or of the wrong type gets that
 * field's classic value; a word this build does not know gets the first word
 * listed for it — a newer server's style degrades toward the ordinary one,
 * never toward nothing.
 *
 * Pure: Foundation only, so `swift test` proves it against contract/design.json.
 */

extension GraineChatTokens {

    /// A fill — one colour, or a gradient — and the text that reads on all of it.
    public struct Fill: Equatable, Sendable {
        public let color: String
        /// The gradient's far end; nil is one solid colour.
        public let colorTo: String?
        public let text: String
        /// Quieter text on it: a status line, a time inside a bubble.
        public let textMuted: String
    }

    /// The header: its fill, how its title sits, what its status line says, where the app's pin goes.
    public struct Header: Equatable, Sendable {
        /// `surface`, `accent`, `gradient` (leading → trailing) or `plain` (no fill: the wallpaper runs under it).
        public let style: String
        /// `start` or `center`.
        public let align: String
        /// Under the title: `online` (the dot and the words), `text` (the words alone) or `none`.
        public let status: String
        /// While the agent works on a reply the status line says so, even where it is otherwise off.
        public let typingStatus: Bool
        /// Where a pinned context card goes: `bar` (under the header), `card` (atop the thread) or `none`.
        public let contextCard: String
        public let fill: Fill
        /// The online dot.
        public let dot: String
        /// A `borderWidth` hairline in `colors.border` under it.
        public let divider: Bool
    }

    /// One side's bubbles.
    public struct BubbleSide: Equatable, Sendable {
        /// The fill; nil is none (transparent).
        public let color: String?
        /// A gradient's far end, top → bottom; nil is solid.
        public let colorTo: String?
        public let text: String
        /// A time or a mark inside the bubble.
        public let textMuted: String
        /// An outline, `max(1, borderWidth)` wide; nil is none.
        public let border: String?
        /// No bubble at all: the words on the wallpaper.
        public let bare: Bool
        /// Links in the words, always underlined.
        public let link: String
    }

    public struct Bubbles: Equatable, Sendable {
        /// `rounded`, `squircle`, `tail` or `flat`.
        public let shape: String
        public let radius: Double
        /// The corner nearest the speaker (`rounded`), and a group's inner corners.
        public let tightRadius: Double
        /// Messages in a row from one side drawn as one group.
        public let grouping: Bool
        /// The widest a bubble may be, as a share of the thread's width (0.6–0.92).
        public let maxWidth: Double
        public let shadow: GraineThemeTokens.Shadow?
        public let user: BubbleSide
        public let agent: BubbleSide
    }

    public struct Timestamps: Equatable, Sendable {
        /// Whose time is drawn: `never`, `group` (the last of each group) or `always`.
        public let show: String
        /// `below` the bubble, or `inside` it.
        public let style: String
        /// A waiting / sent / not-sent mark beside the customer's times.
        public let ticks: Bool
    }

    /// Behind the thread (and behind a `plain` header and a `floating` composer).
    public struct Wallpaper: Equatable, Sendable {
        /// `solid`, `gradient` or `pattern`.
        public let style: String
        /// The base, or the gradient's top.
        public let color: String
        /// The gradient's bottom; nil unless `gradient`.
        public let colorTo: String?
        /// `none`, `dots`, `grid` or `diagonal`.
        public let pattern: String
        public let patternColor: String
        public let intensity: Double
        /// Words drawn straight on it: a bare bubble, the welcome's title.
        public let text: String
        /// Day separators, times under bubbles, the typing words.
        public let textMuted: String
    }

    /// The brand's starters and the agent's quick replies: one look.
    public struct Chips: Equatable, Sendable {
        /// `outline`, `filled`, `soft` or `elevated`.
        public let style: String
        /// `both` (starters docked, replies in the thread), `inline` or `above-composer`.
        public let placement: String
        /// `wrap` or `row` (one row that scrolls sideways).
        public let scroll: String
        public let height: Double
        public let radius: Double
        public let fill: String
        public let text: String
        /// Nil is no outline.
        public let border: String?
        public let borderWidth: Double
        public let shadow: GraineThemeTokens.Shadow?
    }

    /// The agent's components, the upcoming-calls card, a context card and the rating card.
    public struct Cards: Equatable, Sendable {
        public let radius: Double
        public let shadow: GraineThemeTokens.Shadow?
        /// Draw the design's hard offset instead of a shadow.
        public let hard: Bool
        public let border: Bool
        /// A component's large image: `auto` (its own height), `square`, `landscape` or `wide`.
        public let image: String
        /// A component's main button: `filled`, `outline`, `tonal` or `text`.
        public let button: String
        /// Nil is no fill.
        public let buttonFill: String?
        public let buttonText: String
        public let buttonBorder: String?
    }

    public struct Composer: Equatable, Sendable {
        /// `bar`, `floating` or `pill`.
        public let style: String
        /// A microphone while the field is empty: it calls the agent (where the agent takes calls).
        public let mic: Bool
        /// A paperclip — only where the app handles attachments.
        public let attach: Bool
        /// The send button: `circle`, `rounded` or `icon`.
        public let send: String
        /// The field.
        public let fill: String
        public let text: String
        public let placeholder: String
        public let border: String
        /// The strip behind the field; nil is none (`floating`: the thread shows through).
        public let strip: String?
        public let shadow: GraineThemeTokens.Shadow?
        /// The field's height and corners.
        public let height: Double
        public let radius: Double
        /// The send button's fill; nil is none (`icon`).
        public let sendFill: String?
        public let sendIcon: String
        /// The paperclip and the call button beside (or inside) the field.
        public let icon: String
    }

    public struct Typing: Equatable, Sendable {
        /// `loader`, `dots`, `wave` or `text`.
        public let style: String
        /// Empty is "Typing…".
        public let text: String
        /// The dots, the wave or the words (the loader keeps the accent).
        public let color: String
    }

    public struct Density: Equatable, Sendable {
        /// `comfortable`, `compact` or `spacious`.
        public let name: String
        /// Between rows.
        public let gap: Double
        /// Between two messages of one group.
        public let groupGap: Double
        /// Inside a bubble.
        public let padX: Double
        public let padY: Double
        /// The thread's side margins.
        public let edge: Double
    }

    public struct Welcome: Equatable, Sendable {
        /// `centered`, `card`, `hero` or `minimal`.
        public let layout: String
        /// The starters as `chips` or as a `list`.
        public let starters: String
    }

    public struct Rating: Equatable, Sendable {
        /// Ask at the end of a conversation the agent closes.
        public let show: Bool
        /// `thumbs`, `stars` or `emoji`.
        public let style: String
        /// Empty is "How was this chat?".
        public let prompt: String
    }

    public struct Escalation: Equatable, Sendable {
        /// A button that calls the agent: `none`, `header` or `composer`.
        public let call: String
    }

    /// Frosted pieces over the wallpaper: their colour at `opacity`, the wallpaper blurred.
    public struct Glass: Equatable, Sendable {
        public let blur: Double
        public let opacity: Double
    }
}

/// The v2 groups of one scheme's chat tokens, together: what `GraineChatTokens` carries beside its v1 words.
struct ChatStyle: Equatable, Sendable {
    var preset: String
    var header: GraineChatTokens.Header
    var bubbles: GraineChatTokens.Bubbles
    var timestamps: GraineChatTokens.Timestamps
    var wallpaper: GraineChatTokens.Wallpaper
    var chips: GraineChatTokens.Chips
    var cards: GraineChatTokens.Cards
    var composer: GraineChatTokens.Composer
    var typing: GraineChatTokens.Typing
    var density: GraineChatTokens.Density
    var welcome: GraineChatTokens.Welcome
    var rating: GraineChatTokens.Rating
    var escalation: GraineChatTokens.Escalation
    var glass: GraineChatTokens.Glass?
}

/// What the classic derivation needs of the design beyond the chat's own v1 words.
struct ChatStyleBase: Equatable {
    var radius: GraineThemeTokens.Radius
    var spacing: GraineThemeTokens.Spacing
    var cardShadow: GraineThemeTokens.Shadow?
    var hardOffset: GraineThemeTokens.Offset?
    var borderWidth: Double
    var bubbles: GraineBubbleStyle

    /// Graine Classic's, for a chat set read on its own (tests, a surface with no design).
    static let classicFallback = ChatStyleBase(
        radius: DesignTokens.Fallback.radius, spacing: DesignTokens.Fallback.spacing,
        cardShadow: DesignTokens.Fallback.card, hardOffset: nil,
        borderWidth: DesignTokens.Fallback.borderWidth, bubbles: .filled
    )

    /// A design's own.
    static func of(_ t: GraineThemeTokens) -> ChatStyleBase {
        ChatStyleBase(
            radius: t.shape.radius, spacing: t.spacing, cardShadow: t.elevation.card, hardOffset: t.elevation.hardOffset,
            borderWidth: t.shape.borderWidth, bubbles: t.bubbles
        )
    }
}

extension GraineChatTokens {
    /// The colour the window ends in at its bottom edge: the composer's strip, else the wallpaper's bottom.
    var bottomFill: String { composer.strip ?? wallpaper.colorTo ?? wallpaper.color }
}

extension GraineThemeTokens {
    /**
     * The chat tokens to draw with: the session's, or — from a server older
     * than the chat's tokens — the ones the window always drew from the
     * scheme's colours, classic in every piece.
     */
    var chatOrClassic: GraineChatTokens {
        chat ?? SurfaceTokens.chat([String: Any](), colors: colors, base: .of(self))!
    }
}

/// The v1 chat words the classic groups are derived from, after their own fallbacks.
struct ChatV1Words: Equatable {
    var background: String
    var pattern: String
    var patternColor: String
    var showTimestamps: Bool
    var headerBackground: String
    var headerText: String
    var headerSubtext: String
    var composerBackground: String
    var composerText: String
    var composerPlaceholder: String
    var composerBorder: String
}

enum ChatStyles {
    // The words each knob takes; the first is what a word this build does not know is drawn as (DESIGN.md).
    static let headerStyles = ["surface", "accent", "gradient", "plain"]
    static let headerAligns = ["start", "center"]
    static let statusLines = ["online", "text", "none"]
    static let contextCards = ["bar", "card", "none"]
    static let bubbleShapes = ["rounded", "squircle", "tail", "flat"]
    static let timestampShows = ["never", "group", "always"]
    static let timestampStyles = ["below", "inside"]
    static let wallpaperStyles = ["solid", "gradient", "pattern"]
    /// `none` is a word the tokens carry (no pattern), but an unknown one is `dots`, as DESIGN.md lists it.
    static let patterns = ["dots", "none", "grid", "diagonal"]
    static let chipStyles = ["outline", "filled", "soft", "elevated"]
    static let chipPlacements = ["both", "inline", "above-composer"]
    static let chipScrolls = ["wrap", "row"]
    static let cardImages = ["auto", "square", "landscape", "wide"]
    static let cardButtons = ["filled", "outline", "tonal", "text"]
    static let composerStyles = ["bar", "floating", "pill"]
    static let sendStyles = ["circle", "rounded", "icon"]
    static let typingStyles = ["loader", "dots", "wave", "text"]
    static let densities = ["comfortable", "compact", "spacious"]
    static let welcomeLayouts = ["centered", "card", "hero", "minimal"]
    static let starterLooks = ["chips", "list"]
    static let ratingStyles = ["thumbs", "stars", "emoji"]
    static let callButtons = ["none", "header", "composer"]

    /// The group keys a v2 server sends; with none of them the window is classic.
    static let groupKeys = ["preset", "header", "bubbles", "timestamps", "wallpaper", "chips", "cards", "composer",
                            "typing", "density", "welcome", "rating", "escalation", "glass"]

    // MARK: - Classic, from the v1 tokens

    /**
     * CLASSIC — the chat as it was drawn before v2, from the v1 tokens: the
     * table in DESIGN.md "Chat window v2", computed as theme.ts `resolveChat`
     * computes it for a design with no v2 knobs (the muted words in a bubble,
     * the links, the composer's icon colour and the chips' words keep the
     * resolver's contrast rules), so the groups a classic session carries and
     * the groups derived here are the same values.
     */
    static func classic(_ v1: ChatV1Words, colors c: GraineThemeTokens.Colors, base: ChatStyleBase) -> ChatStyle {
        let surfaceHeader = v1.headerBackground == c.surface
        let header = GraineChatTokens.Header(
            style: surfaceHeader ? "surface" : "accent", align: "start", status: "online", typingStatus: false,
            contextCard: "bar",
            fill: .init(color: v1.headerBackground, colorTo: nil, text: v1.headerText, textMuted: v1.headerSubtext),
            dot: surfaceHeader ? c.success : v1.headerText, divider: true
        )
        func side(_ user: Bool) -> GraineChatTokens.BubbleSide {
            var color: String?
            var text = c.text
            var border: String?
            var bare = false
            switch base.bubbles {
            case .outline:
                color = nil
                border = user ? c.accent : c.border
            case .minimal:
                if user { color = c.accentSoft } else { bare = true }
            case .filled:
                color = user ? c.userBubble : c.agentBubble
                text = user ? c.userBubbleText : c.agentBubbleText
            }
            let under = color ?? v1.background
            let floor = user && color == c.userBubble ? ChatInk.onAccentMin : 4.5
            return .init(
                color: color, colorTo: nil, text: text, textMuted: ChatInk.quietOn(text, under, nil, floor: floor),
                border: border, bare: bare, link: ChatInk.linkOn(text: text, accent: c.accent, under, nil)
            )
        }
        let r = base.radius
        let gap = JSON.jsRound(base.spacing.gap)
        return ChatStyle(
            preset: "classic",
            header: header,
            bubbles: .init(
                shape: "rounded", radius: r.lg, tightRadius: min(r.sm, r.lg), grouping: false, maxWidth: 0.84,
                shadow: nil, user: side(true), agent: side(false)
            ),
            timestamps: .init(show: v1.showTimestamps ? "always" : "never", style: "below", ticks: false),
            wallpaper: .init(
                style: v1.pattern == "dots" ? "pattern" : "solid", color: v1.background, colorTo: nil,
                pattern: v1.pattern, patternColor: v1.patternColor, intensity: 0.5, text: c.text, textMuted: c.textMuted
            ),
            chips: .init(
                style: "outline", placement: "both", scroll: "wrap", height: 34, radius: min(r.xl, 17),
                fill: v1.background, text: ChatInk.ensureContrast(c.text, on: v1.background), border: c.accent,
                borderWidth: max(1, base.borderWidth), shadow: nil
            ),
            cards: .init(
                radius: r.lg, shadow: base.cardShadow, hard: base.hardOffset != nil, border: true, image: "auto",
                button: "filled", buttonFill: c.accent, buttonText: c.onAccent, buttonBorder: nil
            ),
            composer: .init(
                style: "bar", mic: false, attach: false, send: "circle",
                fill: v1.composerBackground, text: v1.composerText, placeholder: v1.composerPlaceholder,
                border: v1.composerBorder, strip: v1.background, shadow: nil, height: 40, radius: r.xl,
                sendFill: c.accent, sendIcon: c.onAccent,
                icon: ChatInk.ensureOnBoth(c.accent, v1.composerBackground, v1.background, min: ChatInk.onAccentMin)
            ),
            typing: .init(style: "loader", text: "", color: c.accent),
            density: .init(
                name: "comfortable", gap: gap, groupGap: max(2, JSON.jsRound(gap * 0.25)),
                padX: JSON.jsRound(base.spacing.cardPadding), padY: JSON.jsRound(base.spacing.cardPadding * 0.75), edge: 12
            ),
            welcome: .init(layout: "centered", starters: "chips"),
            rating: .init(show: false, style: "thumbs", prompt: ""),
            escalation: .init(call: "none"),
            glass: nil
        )
    }

    // MARK: - Reading a v2 server's groups

    /**
     * The groups the session carries, each field over its classic value. With
     * none of the groups (an older server) this is classic itself.
     */
    static func read(_ o: [String: Any], over classic: ChatStyle) -> ChatStyle {
        guard groupKeys.contains(where: { o.keys.contains($0) }) else { return classic }
        var s = classic
        if let p = (JSON.unwrap(o["preset"]) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
            s.preset = p
        }
        if let h = Fields(o["header"]) {
            let k = classic.header
            s.header = .init(
                style: h.word("style", headerStyles, k.style),
                align: h.word("align", headerAligns, k.align),
                status: h.word("status", statusLines, k.status),
                typingStatus: h.bool("typingStatus", k.typingStatus),
                contextCard: h.word("contextCard", contextCards, k.contextCard),
                fill: fill(h.group("fill"), over: k.fill),
                dot: h.color("dot", k.dot),
                divider: h.bool("divider", k.divider)
            )
        }
        if let b = Fields(o["bubbles"]) {
            let k = classic.bubbles
            s.bubbles = .init(
                shape: b.word("shape", bubbleShapes, k.shape),
                radius: b.length("radius", k.radius),
                tightRadius: b.length("tightRadius", k.tightRadius),
                grouping: b.bool("grouping", k.grouping),
                maxWidth: b.number("maxWidth", k.maxWidth, 0.6...0.92),
                shadow: b.shadow("shadow", k.shadow),
                user: side(b.group("user"), over: k.user),
                agent: side(b.group("agent"), over: k.agent)
            )
        }
        if let t = Fields(o["timestamps"]) {
            let k = classic.timestamps
            s.timestamps = .init(
                show: t.word("show", timestampShows, k.show),
                style: t.word("style", timestampStyles, k.style),
                ticks: t.bool("ticks", k.ticks)
            )
        }
        if let w = Fields(o["wallpaper"]) {
            let k = classic.wallpaper
            s.wallpaper = .init(
                style: w.word("style", wallpaperStyles, k.style),
                color: w.color("color", k.color),
                colorTo: w.optionalColor("colorTo", k.colorTo),
                pattern: w.word("pattern", patterns, k.pattern),
                patternColor: w.color("patternColor", k.patternColor),
                intensity: w.number("intensity", k.intensity, 0...1),
                text: w.color("text", k.text),
                textMuted: w.color("textMuted", k.textMuted)
            )
        }
        if let ch = Fields(o["chips"]) {
            let k = classic.chips
            s.chips = .init(
                style: ch.word("style", chipStyles, k.style),
                placement: ch.word("placement", chipPlacements, k.placement),
                scroll: ch.word("scroll", chipScrolls, k.scroll),
                height: ch.positive("height", k.height),
                radius: ch.length("radius", k.radius),
                fill: ch.color("fill", k.fill),
                text: ch.color("text", k.text),
                border: ch.optionalColor("border", k.border),
                borderWidth: ch.number("borderWidth", k.borderWidth, 0...8),
                shadow: ch.shadow("shadow", k.shadow)
            )
        }
        if let cd = Fields(o["cards"]) {
            let k = classic.cards
            s.cards = .init(
                radius: cd.length("radius", k.radius),
                shadow: cd.shadow("shadow", k.shadow),
                hard: cd.bool("hard", k.hard),
                border: cd.bool("border", k.border),
                image: cd.word("image", cardImages, k.image),
                button: cd.word("button", cardButtons, k.button),
                buttonFill: cd.optionalColor("buttonFill", k.buttonFill),
                buttonText: cd.color("buttonText", k.buttonText),
                buttonBorder: cd.optionalColor("buttonBorder", k.buttonBorder)
            )
        }
        if let cp = Fields(o["composer"]) {
            let k = classic.composer
            s.composer = .init(
                style: cp.word("style", composerStyles, k.style),
                mic: cp.bool("mic", k.mic),
                attach: cp.bool("attach", k.attach),
                send: cp.word("send", sendStyles, k.send),
                fill: cp.color("fill", k.fill),
                text: cp.color("text", k.text),
                placeholder: cp.color("placeholder", k.placeholder),
                border: cp.color("border", k.border),
                strip: cp.optionalColor("strip", k.strip),
                shadow: cp.shadow("shadow", k.shadow),
                height: cp.positive("height", k.height),
                radius: cp.length("radius", k.radius),
                sendFill: cp.optionalColor("sendFill", k.sendFill),
                sendIcon: cp.color("sendIcon", k.sendIcon),
                icon: cp.color("icon", k.icon)
            )
        }
        if let ty = Fields(o["typing"]) {
            let k = classic.typing
            s.typing = .init(
                style: ty.word("style", typingStyles, k.style),
                text: ty.words("text", k.text, max: 24),
                color: ty.color("color", k.color)
            )
        }
        if let d = Fields(o["density"]) {
            let k = classic.density
            s.density = .init(
                name: d.word("name", densities, k.name),
                gap: d.length("gap", k.gap),
                groupGap: d.length("groupGap", k.groupGap),
                padX: d.length("padX", k.padX),
                padY: d.length("padY", k.padY),
                edge: d.length("edge", k.edge)
            )
        }
        if let wl = Fields(o["welcome"]) {
            let k = classic.welcome
            s.welcome = .init(layout: wl.word("layout", welcomeLayouts, k.layout), starters: wl.word("starters", starterLooks, k.starters))
        }
        if let rt = Fields(o["rating"]) {
            let k = classic.rating
            s.rating = .init(show: rt.bool("show", k.show), style: rt.word("style", ratingStyles, k.style), prompt: rt.words("prompt", k.prompt, max: 60))
        }
        if let e = Fields(o["escalation"]) {
            s.escalation = .init(call: e.word("call", callButtons, classic.escalation.call))
        }
        if o.keys.contains("glass") {
            // null is no glass; an object is glass (a field it lacks is Graine Classic's frost); anything else is classic.
            let raw = JSON.unwrap(o["glass"])
            if raw == nil || raw is NSNull {
                s.glass = nil
            } else if let g = Fields(raw) {
                s.glass = .init(
                    blur: g.length("blur", DesignTokens.Fallback.glass.blur),
                    opacity: g.number("opacity", DesignTokens.Fallback.glass.surfaceOpacity, 0...1)
                )
            }
        }
        return s
    }

    private static func fill(_ f: Fields?, over k: GraineChatTokens.Fill) -> GraineChatTokens.Fill {
        guard let f = f else { return k }
        return .init(color: f.color("color", k.color), colorTo: f.optionalColor("colorTo", k.colorTo),
                     text: f.color("text", k.text), textMuted: f.color("textMuted", k.textMuted))
    }

    private static func side(_ f: Fields?, over k: GraineChatTokens.BubbleSide) -> GraineChatTokens.BubbleSide {
        guard let f = f else { return k }
        return .init(
            color: f.optionalColor("color", k.color), colorTo: f.optionalColor("colorTo", k.colorTo),
            text: f.color("text", k.text), textMuted: f.color("textMuted", k.textMuted),
            border: f.optionalColor("border", k.border), bare: f.bool("bare", k.bare), link: f.color("link", k.link)
        )
    }

    /// One group's fields, each read on its own over a fallback.
    private struct Fields {
        let o: [String: Any]

        init?(_ raw: Any?) {
            guard let o = JSON.unwrap(raw) as? [String: Any] else { return nil }
            self.o = o
        }

        func group(_ key: String) -> Fields? { Fields(o[key]) }

        /// Missing or not text: the fallback. Text this build does not know: the first word listed.
        func word(_ key: String, _ allowed: [String], _ fallback: String) -> String {
            guard let s = JSON.unwrap(o[key]) as? String else { return fallback }
            let w = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return allowed.contains(w) ? w : allowed[0]
        }

        func bool(_ key: String, _ fallback: Bool) -> Bool {
            JSON.unwrap(o[key]).flatMap { JSON.bool($0) } ?? fallback
        }

        func number(_ key: String, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
            guard let v = JSON.unwrap(o[key]), let n = JSON.number(v), n.doubleValue.isFinite else { return fallback }
            return min(range.upperBound, max(range.lowerBound, n.doubleValue))
        }

        /// A length: 0 or more, capped where no phone could draw it.
        func length(_ key: String, _ fallback: Double) -> Double {
            guard let v = JSON.unwrap(o[key]), let n = JSON.number(v), n.doubleValue.isFinite, n.doubleValue >= 0 else { return fallback }
            return min(n.doubleValue, 200)
        }

        func positive(_ key: String, _ fallback: Double) -> Double {
            let d = length(key, fallback)
            return d > 0 ? d : fallback
        }

        func color(_ key: String, _ fallback: String) -> String {
            DesignTokens.hex(o[key]) ?? fallback
        }

        /// null is none; a colour is that colour; missing or anything else is the fallback.
        func optionalColor(_ key: String, _ fallback: String?) -> String? {
            guard o.keys.contains(key) else { return fallback }
            let raw = JSON.unwrap(o[key])
            if raw == nil || raw is NSNull { return nil }
            return DesignTokens.hex(raw) ?? fallback
        }

        /// The brand's words, already cleaned by the server: one line, bounded. Not text: the fallback.
        func words(_ key: String, _ fallback: String, max: Int) -> String {
            guard let s = JSON.unwrap(o[key]) as? String else { return fallback }
            return QuickReplies.line(s, max: max)
        }

        /// null is no shadow; an object is one (a field it lacks is the fallback's, else none); anything else is the fallback.
        func shadow(_ key: String, _ fallback: GraineThemeTokens.Shadow?) -> GraineThemeTokens.Shadow? {
            guard o.keys.contains(key) else { return fallback }
            let raw = JSON.unwrap(o[key])
            if raw == nil || raw is NSNull { return nil }
            guard let s = Fields(raw) else { return fallback }
            let base = fallback ?? GraineThemeTokens.Shadow(y: 0, blur: 0, spread: 0, opacity: 0, color: "#000000")
            return GraineThemeTokens.Shadow(
                y: s.number("y", base.y, -64...64), blur: s.length("blur", base.blur),
                spread: s.number("spread", base.spread, -64...64), opacity: s.number("opacity", base.opacity, 0...1),
                color: s.color("color", base.color)
            )
        }
    }

    // MARK: - Writing them back (for a bridge, and the round trip the tests prove)

    /// The groups as the contract spells them, keys and words exactly as every SDK reads them.
    static func json(_ s: ChatStyle, number n: (Double) -> Any) -> [String: Any] {
        func opt(_ v: String?) -> Any { v.map { $0 as Any } ?? NSNull() }
        func shadow(_ v: GraineThemeTokens.Shadow?) -> Any {
            guard let v = v else { return NSNull() }
            return ["y": n(v.y), "blur": n(v.blur), "spread": n(v.spread), "opacity": n(v.opacity), "color": v.color] as [String: Any]
        }
        func fill(_ f: GraineChatTokens.Fill) -> [String: Any] {
            ["color": f.color, "colorTo": opt(f.colorTo), "text": f.text, "textMuted": f.textMuted]
        }
        func side(_ b: GraineChatTokens.BubbleSide) -> [String: Any] {
            ["color": opt(b.color), "colorTo": opt(b.colorTo), "text": b.text, "textMuted": b.textMuted,
             "border": opt(b.border), "bare": b.bare, "link": b.link]
        }
        let h = s.header, b = s.bubbles, w = s.wallpaper, ch = s.chips, cd = s.cards, cp = s.composer, d = s.density
        return [
            "preset": s.preset,
            "header": [
                "style": h.style, "align": h.align, "status": h.status, "typingStatus": h.typingStatus,
                "contextCard": h.contextCard, "fill": fill(h.fill), "dot": h.dot, "divider": h.divider,
            ] as [String: Any],
            "bubbles": [
                "shape": b.shape, "radius": n(b.radius), "tightRadius": n(b.tightRadius), "grouping": b.grouping,
                "maxWidth": n(b.maxWidth), "shadow": shadow(b.shadow), "user": side(b.user), "agent": side(b.agent),
            ] as [String: Any],
            "timestamps": ["show": s.timestamps.show, "style": s.timestamps.style, "ticks": s.timestamps.ticks] as [String: Any],
            "wallpaper": [
                "style": w.style, "color": w.color, "colorTo": opt(w.colorTo), "pattern": w.pattern,
                "patternColor": w.patternColor, "intensity": n(w.intensity), "text": w.text, "textMuted": w.textMuted,
            ] as [String: Any],
            "chips": [
                "style": ch.style, "placement": ch.placement, "scroll": ch.scroll, "height": n(ch.height),
                "radius": n(ch.radius), "fill": ch.fill, "text": ch.text, "border": opt(ch.border),
                "borderWidth": n(ch.borderWidth), "shadow": shadow(ch.shadow),
            ] as [String: Any],
            "cards": [
                "radius": n(cd.radius), "shadow": shadow(cd.shadow), "hard": cd.hard, "border": cd.border,
                "image": cd.image, "button": cd.button, "buttonFill": opt(cd.buttonFill), "buttonText": cd.buttonText,
                "buttonBorder": opt(cd.buttonBorder),
            ] as [String: Any],
            "composer": [
                "style": cp.style, "mic": cp.mic, "attach": cp.attach, "send": cp.send, "fill": cp.fill,
                "text": cp.text, "placeholder": cp.placeholder, "border": cp.border, "strip": opt(cp.strip),
                "shadow": shadow(cp.shadow), "height": n(cp.height), "radius": n(cp.radius),
                "sendFill": opt(cp.sendFill), "sendIcon": cp.sendIcon, "icon": cp.icon,
            ] as [String: Any],
            "typing": ["style": s.typing.style, "text": s.typing.text, "color": s.typing.color] as [String: Any],
            "density": [
                "name": d.name, "gap": n(d.gap), "groupGap": n(d.groupGap), "padX": n(d.padX), "padY": n(d.padY), "edge": n(d.edge),
            ] as [String: Any],
            "welcome": ["layout": s.welcome.layout, "starters": s.welcome.starters] as [String: Any],
            "rating": ["show": s.rating.show, "style": s.rating.style, "prompt": s.rating.prompt] as [String: Any],
            "escalation": ["call": s.escalation.call] as [String: Any],
            "glass": s.glass.map { ["blur": n($0.blur), "opacity": n($0.opacity)] as Any } ?? NSNull(),
        ]
    }
}

/**
 * COLOUR ARITHMETIC, AS THE RESOLVER DOES IT — theme.ts `mixHex`,
 * `luminanceOf`, `contrastRatio`, `ensureContrast` and the chat resolver's
 * `quietOn` / `linkOn`, ported number for number (JavaScript's rounding, the
 * same loops), so a value derived here is the value the server would have sent.
 */
enum ChatInk {
    /// The floor for words on the accent (or a gradient of its shades): 3:1, as the v1 accent header always had.
    static let onAccentMin = 3.0

    static func rgb(_ hex: String) -> (r: Double, g: Double, b: Double) {
        let h = DesignTokens.hex(hex) ?? "#000000"
        let n = UInt32(h.dropFirst(), radix: 16) ?? 0
        return (Double((n >> 16) & 255), Double((n >> 8) & 255), Double(n & 255))
    }

    static func hex(_ r: Double, _ g: Double, _ b: Double) -> String {
        func c(_ v: Double) -> Int { Int(max(0, min(255, JSON.jsRound(v)))) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }

    /// `a` mixed toward `b` by `t` (0 is a, 1 is b).
    static func mix(_ a: String, _ b: String, _ t: Double) -> String {
        let x = rgb(a), y = rgb(b)
        return hex(x.r + (y.r - x.r) * t, x.g + (y.g - x.g) * t, x.b + (y.b - x.b) * t)
    }

    /// WCAG relative luminance.
    static func luminance(_ hex: String) -> Double {
        func ch(_ c: Double) -> Double {
            let s = c / 255
            return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        let v = rgb(hex)
        return 0.2126 * ch(v.r) + 0.7152 * ch(v.g) + 0.0722 * ch(v.b)
    }

    /// WCAG contrast ratio, 1–21.
    static func contrast(_ a: String, _ b: String) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// `fg` if it reaches `min` on `bg`; otherwise stepped toward black or white until it does.
    static func ensureContrast(_ fg: String, on bg: String, min: Double = 4.5) -> String {
        if contrast(fg, bg) >= min { return fg }
        let toward = luminance(bg) > 0.5 ? "#000000" : "#FFFFFF"
        var t = 0.1
        while t <= 1.0001 {
            let c = mix(fg, toward, t)
            if contrast(c, bg) >= min { return c }
            t += 0.1
        }
        return toward
    }

    /// `fg` made to read on both of two fills.
    static func ensureOnBoth(_ fg: String, _ a: String, _ b: String, min: Double) -> String {
        ensureContrast(ensureContrast(fg, on: a, min: min), on: b, min: min)
    }

    /// The worst contrast `fg` has against a fill's ends.
    static func worstOn(_ fg: String, _ a: String, _ b: String?) -> Double {
        b.map { Swift.min(contrast(fg, a), contrast(fg, $0)) } ?? contrast(fg, a)
    }

    /// Words quieter than `text` on a fill: mixed toward it as far as they still read on every end.
    static func quietOn(_ text: String, _ a: String, _ b: String?, floor: Double) -> String {
        let least = floor >= 4.5 ? 4.5 : max(onAccentMin, min(4.5, worstOn(text, a, b)))
        for t in [0.3, 0.25, 0.2, 0.15, 0.1, 0.05] {
            let c = mix(text, a, t)
            if worstOn(c, a, b) >= least { return c }
        }
        return text
    }

    /// Links: the accent where it reads at 4.5:1 on all of the fill, else the words' own colour.
    static func linkOn(text: String, accent: String, _ a: String, _ b: String?) -> String {
        worstOn(accent, a, b) >= 4.5 ? accent : text
    }
}
