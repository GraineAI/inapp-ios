#if os(iOS)
import SwiftUI
import UIKit

/**
 * THE CHAT WINDOW (contract/DESIGN.md "Chat window" and "Chat window v2"),
 * above the bar while the customer is in the chat — and, filling the screen,
 * `GraineChatView` (no outline, corners or shadow). Every piece is drawn from
 * the token set's `chat` group; a server older than those tokens gets the
 * window it always drew (classic, Core/ChatStyle.swift).
 *
 * Top to bottom:
 * - **Header** in its style's fill — the surface (frosted with glass), the
 *   accent, a gradient leading → trailing, or none (the wallpaper runs under
 *   it) — the avatar, the title and its status line (`start`, or centred as
 *   one group), the call button where the agent takes calls, New conversation
 *   while earlier messages show, and the chevron. Window chrome replaces it
 *   with a title bar.
 * - **The app's pin** as a bar under the header, and the calm reconnect banner.
 * - **Thread** on the wallpaper (a colour, a gradient, or a pattern standing
 *   still behind it): the welcome (centred, a card, or a hero), the pinned
 *   card, the upcoming calls, then a bubble per message — grouped, shaped
 *   (rounded, squircle, tailed, flat), the agent's words formatted and
 *   revealed smoothly while they arrive, times below or inside with ticks,
 *   "Waiting for connection…" / "Not sent · Tap to retry" — the agent's quick
 *   replies under its turn, the typing indicator, and the rating card once
 *   the agent ends the conversation. Scrolled up, a pill brings back the newest.
 * - **Chips** docked above the composer (the brand's starters, or the agent's
 *   replies), on the customer's side.
 * - **Composer**: a bar, a pill, or a floating capsule the thread scrolls
 *   under — the paperclip where the app handles attachments, the call button
 *   or a microphone in the send button's place where the agent takes calls.
 */
struct GraineChatWindow: View {
    let tokens: GraineThemeTokens
    let type: GraineType
    let accent: Color
    let onAccent: Color
    let heading: String
    let logoUrl: String?
    /// What the logo sits on in the mark (DESIGN.md "The brand's logo").
    var logoPlate: GraineLogoPlate = .accent
    let turns: [GraineChatTurn]
    let status: GraineChatStatus
    /// The agent is working on a reply.
    var typing: Bool = false
    /// The keyboard is up: the messages give way to it.
    let lifted: Bool
    /// Filling a screen of its own (`GraineChatView`) rather than riding above the bar.
    var fills: Bool = false
    /// Filling its space but keeping the whole frame — outline, corners, shadow: an iPad's panel.
    var keepsFrame: Bool = false
    /// The chevron leads the header, before the avatar: a full screen has no corner to close it by.
    var leadingChevron: Bool = false
    /// Drawn in place of the chevron's "Collapse" label — "Close" where the chat is all there is.
    var collapseLabel: String = "Collapse"
    /// The customer's calls still to come, and the agent's call name for their rows.
    var upcoming: [GraineScheduledCall] = []
    var cancelling: Set<String> = []
    var cancelFailed: Set<String> = []
    var callName: String? = nil
    /// The agent can be booked from the app (`bookingAvailable`): "Book a call" in the card, or in its place.
    var bookable: Bool = false
    /// The agent's suggested replies for its latest turn.
    var quickReplies: [GraineQuickReply] = []
    /// The agent ended the conversation: the rating card, where the design asks for one.
    var ended: Bool = false
    var rating: GraineChatRating? = nil
    /// What the conversation is about, as the app pinned it.
    var pin: GraineChatPin? = nil
    /// The chat was connected since the customer came in: a drop is a reconnect (the banner).
    var wasOnline: Bool = false
    /// Graine ended the conversation itself (idle, or its time limit): the header says "Disconnected".
    var disconnected: Bool = false
    /// The turns "Disconnected · new conversation" is drawn before: a new conversation under earlier lines.
    var marks: Set<String> = []
    /// The dashboard's loader, and its words for each moment.
    var loader: GraineLoaderLook = Loaders.resolve(nil)
    let onSend: (String) -> Void
    var onRetry: () -> Void = {}
    var onCancelCall: (String) -> Void = { _ in }
    /// "Book a call": open the booking sheet.
    var onBook: () -> Void = {}
    /// "New conversation" — offered in the header only while earlier messages (restored turns) are on screen.
    var onNewConversation: (() -> Void)? = nil
    var onRate: (GraineChatRating.Style, Int) -> Void = { _, _ in }
    /// The app's attachment handler: the paperclip shows only with one (and where the design draws it).
    var onAttach: (() -> Void)? = nil
    /// Starts a call with the agent exactly as the bar's own call does; nil where none can be started from the chat.
    var onCall: (() -> Void)? = nil
    let onCollapse: () -> Void

    @State private var draft = ""
    /// A logo that would not load: the mark goes back to the glyph or the letter until the logo changes.
    @State private var failedLogo: String? = nil
    @State private var width: CGFloat = 0
    @State private var metrics = ThreadMetrics()
    @State private var viewport: CGFloat = 0
    @State private var following = true
    @State private var unseen = 0
    @State private var rowsSeen = 0
    @State private var floatingHeight: CGFloat = 0
    @State private var topHeight: CGFloat = 0
    @State private var formats = GraineChatFormatCache()
    /// Held, not observed: only the live bubble redraws as its words are revealed.
    @State private var reveal = GraineChatReveal()
    /// Until when the thread is scrolling itself (to its bottom): its moving offset is not the customer scrolling away.
    @State private var selfScrollUntil = Date.distantPast
    @State private var settleScheduled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    /// The system's text size, relative to the default (Dynamic Type).
    @ScaledMetric(relativeTo: .body) private var dynamicScale: CGFloat = 1

    private static let space = "graine-chat-thread"
    private static let bottomId = "graine-chat-bottom"

    // MARK: What it draws from

    private var chat: GraineChatTokens { tokens.chatOrClassic }
    /// The type at the system's text size — capped where a phone's window could still hold the header and composer.
    private var ty: GraineType { type.scaled(min(2, max(0.8, Double(dynamicScale)))) }
    private var online: Bool { status == .online }
    private var pieces: ChatPieces { ChatPieces.of(turns, chat: tokens.chat, upcomingCount: UpcomingCalls.shown(upcoming).count, bookable: bookable) }
    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var title: String { chat.title.isEmpty ? heading : chat.title }
    private var edge: CGFloat { CGFloat(chat.density.edge) }
    /// No fill: the wallpaper runs under it (window chrome's title bar replaces any header).
    private var plainHeader: Bool { chat.header.style == "plain" && tokens.chrome != .window }
    private var floating: Bool { chat.composer.style == "floating" }
    private var chatGlass: GraineThemeTokens.Glass? { chat.glass?.surface }
    private var takesCalls: Bool { onCall != nil }
    private var still: Bool { tokens.motion.effectiveDurationMs(reduceMotion: GraineThemeTokens.Motion.reduced(reduceMotion)) <= 0 }
    private var motion: Animation? { tokens.motion.animation(reduceMotion: reduceMotion) }
    private var welcome: ChatWindowRules.WelcomeKind? { ChatWindowRules.welcome(chat.welcome, turns: pieces.turns) }
    private var heroUnderHeader: Bool { plainHeader && welcome == .hero }
    private var banner: ChatWindowRules.Banner? {
        ended ? nil : ChatWindowRules.banner(status: status, wasOnline: wasOnline, turns: turns)
    }

    /// A header that frosts: a surface one with the chat's glass, else the design's (v1); a plain one only with the chat's.
    private var headerFrost: GraineThemeTokens.Glass? {
        switch chat.header.style {
        case "surface": return chatGlass ?? tokens.glass
        case "plain": return chatGlass
        default: return nil
        }
    }

    /// A design colour, with the app's accent override where the design's accent would be.
    private func ink(_ hex: String) -> Color { hex == tokens.colors.accent ? accent : .graineHex(hex) }
    /// What sits on the accent, with the override's label where the design's would be.
    private func onInk(_ hex: String) -> Color { hex == tokens.colors.onAccent ? onAccent : .graineHex(hex) }

    // MARK: The window

    var body: some View {
        let r = tokens.shape.radius
        let content = window
            .background(GeometryReader { proxy in
                Color.clear.onAppear { width = proxy.size.width }.onChange(of: proxy.size.width) { width = $0 }
            })
            .onAppear(perform: feedReveal)
            .onChange(of: liveKey) { _ in feedReveal() }
        if fills && !keepsFrame {
            // What shows past the window's bottom edge (the home indicator) is the colour the window ends in.
            content.background(Color.graineHex(chat.bottomFill))
        } else {
            content
                .clipShape(RoundedRectangle(cornerRadius: CGFloat(r.xl), style: .continuous))
                .modifier(GraineDesignSurface(tokens: tokens, fill: chat.wallpaper.color, frosted: false, radius: r.xl, shadow: tokens.elevation.floating))
        }
    }

    private var window: some View {
        VStack(spacing: 0) {
            if !plainHeader { topChrome }
            // The wallpaper and a floating composer are drawn behind and over the thread, never sizing it: the
            // compact window is as tall as its messages (up to its ceiling), whatever stands behind them.
            VStack(spacing: 0) {
                if plainHeader && !heroUnderHeader { topChrome }
                thread
            }
            .overlay(alignment: .top) {
                if heroUnderHeader {
                    topChrome.background(GeometryReader { g in Color.clear.preference(key: GraineChatTopKey.self, value: g.size.height) })
                }
            }
            .overlay(alignment: .bottom) {
                if floating { floatingBottom }
            }
            .background(GraineChatWallpaper(wallpaper: chat.wallpaper))
            .onPreferenceChange(GraineChatTopKey.self) { topHeight = $0 }
            if !floating {
                dockedChips.background(Color.graineHex(chat.composer.strip ?? chat.wallpaper.color))
                composer
            }
        }
        .animation(motion, value: banner)
    }

    /// The header (or title bar), the app's pin as a bar, and the reconnect banner.
    private var topChrome: some View {
        VStack(spacing: 0) {
            if let bar = WindowChrome.titleBar(tokens, for: .chat(heading: title, online: online)) {
                GraineWindowTitleBar(bar: bar) {
                    HStack(spacing: 0) {
                        if ChatWindowRules.headerCall(chat.escalation, takesCalls: takesCalls) {
                            headerCallButton(color: .graineHex(tokens.colors.textMuted))
                        }
                        composeButton(color: .graineHex(tokens.colors.textMuted))
                        windowCollapse(bar)
                    }
                }
            } else {
                header
            }
            if ChatWindowRules.pinPlace(chat.header, pin: pin) == .bar, let pin = pin {
                contextBar(pin)
            }
            if let banner = banner {
                GraineChatBanner(tokens: tokens, type: ty, banner: banner, loader: loader, glass: chatGlass)
                    .transition(still ? .identity : .move(edge: .top).combined(with: .opacity))
            }
        }
    }

    // MARK: Header

    private var header: some View {
        let t = tokens
        let h = chat.header
        let center = h.align == "center"
        let call = ChatWindowRules.headerCall(chat.escalation, takesCalls: takesCalls)
        let compose = onNewConversation != nil && pieces.newConversation
        // The controls at each end, so a centred title stays clear of them (8 apart).
        let trailingCount = (call ? 1 : 0) + (compose ? 1 : 0) + (leadingChevron ? 0 : 1)
        let trailingWidth = CGFloat(trailingCount) * 44 + CGFloat(max(0, trailingCount - 1)) * 10
        let leadingWidth: CGFloat = leadingChevron ? 44 : 0
        let inset = max(leadingWidth, trailingWidth) + (max(leadingWidth, trailingWidth) > 0 ? 8 : 0)
        return ZStack {
            HStack(spacing: 10) {
                if leadingChevron { collapseButton }
                if center {
                    Spacer(minLength: 0)
                } else {
                    if chat.avatar != "none" { mark(size: CGFloat(VoiceBar.Chat.mark)) }
                    titleAndStatus(center: false).frame(maxWidth: .infinity, alignment: .leading)
                }
                if call { headerCallButton(color: .graineHex(h.fill.text)) }
                composeButton(color: .graineHex(h.fill.textMuted))
                if !leadingChevron { collapseButton }
            }
            if center {
                HStack(spacing: 8) {
                    if chat.avatar != "none" { mark(size: 24) }
                    titleAndStatus(center: true)
                }
                .padding(.horizontal, inset)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: CGFloat(VoiceBar.Chat.header))
        .background(GraineChatHeaderFill(header: h, frost: headerFrost, scheme: t.scheme, accentOverride: ink(h.fill.color)))
        .overlay(alignment: .bottom) {
            if h.divider {
                Rectangle().fill(Color.graineHex(t.colors.border)).frame(height: CGFloat(t.shape.borderWidth))
            }
        }
    }

    private func titleAndStatus(center: Bool) -> some View {
        let t = tokens
        let h = chat.header
        let titleSize = min(t.font.scale.title, VoiceBar.Chat.titleMax)
        let line = ChatWindowRules.headerStatus(
            h, status: status, typing: typing, subtitle: chat.subtitle, typingText: chat.typing.text, loader: loader.text,
            disconnected: disconnected
        )
        return VStack(alignment: center ? .center : .leading, spacing: 0) {
            Text(title)
                .font(ty.heading(titleSize, t.font.weights.title))
                .tracking(ty.titleTracking(titleSize))
                .foregroundColor(.graineHex(h.fill.text))
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            switch line {
            case .none:
                EmptyView()
            case .waiting(let words), .words(let words, dot: false):
                statusWords(words)
            case .words(let words, dot: true):
                HStack(spacing: 6) {
                    Circle().fill(Color.graineHex(h.dot))
                        .frame(width: CGFloat(VoiceBar.Chat.dot), height: CGFloat(VoiceBar.Chat.dot))
                        .accessibilityHidden(true)
                    statusWords(words)
                }
            }
        }
    }

    private func statusWords(_ words: String) -> some View {
        Text(words)
            .font(ty.body(tokens.font.scale.caption, tokens.font.weights.body))
            .tracking(ty.bodyTracking(tokens.font.scale.caption))
            .foregroundColor(.graineHex(chat.header.fill.textMuted))
            .lineLimit(1)
    }

    /// The chevron as a button: back to the call, or closed for a chat-only agent.
    private var collapseButton: some View {
        Button(action: onCollapse) {
            chevron(color: .graineHex(chat.header.fill.textMuted))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(collapseLabel)
    }

    /// The call button (`escalation.call: header`): the call icon at 18, in a 44 target.
    private func headerCallButton(color: Color) -> some View {
        Button(action: { onCall?() }) {
            GraineIconView(name: .call, style: tokens.icons.style, stroke: tokens.icons.stroke, color: color, size: 18)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel("Call \(heading)")
    }

    /// "New conversation": the compose icon beside the chevron, only while earlier messages are on screen and the design keeps it.
    @ViewBuilder private func composeButton(color: Color) -> some View {
        if let start = onNewConversation, pieces.newConversation {
            Button(action: start) {
                GraineIconView(name: .compose, style: tokens.icons.style, stroke: tokens.icons.stroke, color: color, size: 18)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel("New conversation")
        }
    }

    /// Back to the call (or closed, for a chat-only agent): the chevron, turned to point down.
    private func chevron(color: Color) -> some View {
        GraineIconView(name: .chevron, style: tokens.icons.style, stroke: tokens.icons.stroke, color: color, flipped: true)
    }

    /// The chevron at the title bar's right end, as far in from it as the lights are from the left.
    private func windowCollapse(_ bar: WindowChrome.TitleBar) -> some View {
        Button(action: onCollapse) {
            chevron(color: .graineHex(tokens.colors.textMuted))
                .padding(.horizontal, CGFloat(bar.lightsInset))
                .frame(height: CGFloat(bar.height))
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(collapseLabel)
    }

    private enum MarkContent {
        case glyph(GraineThemeTokens.Glyph)
        case logo(URL)
        case letter
    }

    /// `chat.avatar`: the logo (else the glyph, else the letter) or the glyph (else the logo, else the letter).
    private var markContent: MarkContent {
        let glyph = tokens.icons.launcher
        let logo = logoUrl.flatMap { $0 == failedLogo ? nil : URL(string: $0) }
        let wanted = tokens.chat?.avatar ?? (glyph != nil ? "glyph" : "logo")
        if wanted == "logo" {
            if let url = logo { return .logo(url) }
            if let g = glyph { return .glyph(g) }
        } else {
            if let g = glyph { return .glyph(g) }
            if let url = logo { return .logo(url) }
        }
        return .letter
    }

    /**
     * The avatar, in the launcher's own shape (a pill drawn as a circle): the
     * glyph at 46% in `onAccent` on `accent`; the brand's logo whole on its
     * plate; else the title's first letter, bold, on the accent.
     */
    private func mark(size: CGFloat) -> some View {
        let t = tokens
        let kind: GraineLauncherShape = t.shape.launcher == .pill ? .circle : t.shape.launcher
        let outline = GraineLauncherOutline(kind: kind, radius: t.shape.radius)
        let letter = Text(String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased())
            .font(.system(size: (size * 0.4).rounded(), weight: .bold))
            .foregroundColor(onAccent)
        let content = markContent
        let isLogo: Bool = { if case .logo = content { return true }; return false }()
        let plate = DesignRules.logoPlateLook(
            isLogo ? logoPlate : .accent, accent: t.colors.accent, border: t.colors.border, borderWidth: t.shape.borderWidth
        )
        let box = CGFloat(DesignRules.logoBox(kind, size: Double(size)))
        return ZStack {
            outline.fill(plate.outline == nil ? accent : Color.graineHex(plate.fill))
            switch content {
            case .glyph(let glyph):
                GraineGlyphView(glyph: glyph, stroke: t.icons.stroke, color: onAccent, size: (size * 0.46).rounded(), fallback: letter)
            case .logo(let url):
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFit().frame(width: box, height: box)
                    case .failure: letter.onAppear { failedLogo = url.absoluteString }
                    default: Color.clear
                    }
                }
            case .letter:
                letter
            }
        }
        .frame(width: size, height: size)
        .clipShape(outline)
        .overlay {
            // The Garage's mark wears the launcher's outline where the design draws hard offsets;
            // otherwise a white plate wears its hairline.
            if t.elevation.hardOffset != nil {
                outline.stroke(Color.graineHex(t.colors.text), lineWidth: CGFloat(t.shape.borderWidth))
            } else if let hairline = plate.outline {
                outline.border(Color.graineHex(hairline.color), width: CGFloat(hairline.width))
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: The app's pin

    /// Under the header: a 32 thumbnail (or the title's first letter on a soft disc), the title over the subtitle, the badge.
    private func contextBar(_ pin: GraineChatPin) -> some View {
        let t = tokens
        return HStack(spacing: 10) {
            pinThumb(pin, size: 32, radius: t.shape.radius.sm)
            pinWords(pin, titleFont: ty.body(t.font.scale.body - 1, t.font.weights.strong))
                .frame(maxWidth: .infinity, alignment: .leading)
            if let badge = pin.badge { pinBadge(badge) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: 52)
        .background(GraineSurfaceFill(shape: Rectangle(), color: .graineHex(t.colors.surface), glass: headerFrost, scheme: t.scheme))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.graineHex(t.colors.border)).frame(height: CGFloat(t.shape.borderWidth))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pin.spoken)
    }

    /// Atop the thread, as a card: a 44 thumbnail, the title in the heading family, the subtitle and the badge.
    private func contextCard(_ pin: GraineChatPin) -> some View {
        let t = tokens
        return HStack(spacing: 10) {
            pinThumb(pin, size: 44, radius: t.shape.radius.md)
            pinWords(pin, titleFont: ty.heading(min(t.font.scale.title, 16), t.font.weights.title))
                .frame(maxWidth: .infinity, alignment: .leading)
            if let badge = pin.badge { pinBadge(badge) }
        }
        .padding(CGFloat(t.spacing.cardPadding))
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(GraineChatCardSurface(tokens: t, cards: chat.cards))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pin.spoken)
    }

    @ViewBuilder
    private func pinThumb(_ pin: GraineChatPin, size: CGFloat, radius: Double) -> some View {
        let t = tokens
        let shape = RoundedRectangle(cornerRadius: CGFloat(radius), style: .continuous)
        let letter = ZStack {
            Circle().fill(Color.graineHex(t.colors.accentSoft))
            Text(String(pin.title.prefix(1)).uppercased())
                .font(ty.body(14, t.font.weights.strong))
                .foregroundColor(.graineHex(t.colors.text))
        }
        .frame(width: size, height: size)
        if let url = pin.imageUrl {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill().frame(width: size, height: size).clipShape(shape)
                } else {
                    letter
                }
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        } else {
            letter.accessibilityHidden(true)
        }
    }

    private func pinWords(_ pin: GraineChatPin, titleFont: Font) -> some View {
        let t = tokens
        return VStack(alignment: .leading, spacing: 1) {
            Text(pin.title).font(titleFont).foregroundColor(.graineHex(t.colors.text)).lineLimit(1)
            if let subtitle = pin.subtitle {
                Text(subtitle)
                    .font(ty.body(t.font.scale.caption, t.font.weights.body))
                    .foregroundColor(.graineHex(t.colors.textMuted))
                    .lineLimit(1)
            }
        }
    }

    private func pinBadge(_ badge: String) -> some View {
        let t = tokens
        return Text(badge)
            .font(ty.body(t.font.scale.caption, t.font.weights.strong))
            .foregroundColor(.graineHex(t.colors.text))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(minHeight: 22)
            .background(Capsule().fill(Color.graineHex(t.colors.accentSoft)))
    }

    // MARK: Thread

    /// One row of the thread, with the gap above it.
    private struct ThreadItem: Identifiable {
        enum Kind {
            case hero, pinCard, upcoming, book, welcomeCard, empty, starters, replies, typing, rating, offline
            case row(ChatThreadRow, ChatGroupPosition)
        }

        let kind: Kind
        let gap: Double

        var id: String {
            switch kind {
            case .row(let row, _): return row.id
            case .hero: return "hero"
            case .pinCard: return "pin"
            case .upcoming: return "upcoming"
            case .book: return "book"
            case .welcomeCard: return "welcome"
            case .empty: return "empty"
            case .starters: return "starters"
            case .replies: return "replies"
            case .typing: return "typing"
            case .rating: return "rating"
            case .offline: return "offline"
            }
        }

        /// Full width: the hero, and chips in one sideways row (their row starts `edge` in on its own).
        func fullWidth(_ chat: GraineChatTokens) -> Bool {
            switch kind {
            case .hero: return true
            case .replies, .starters: return chat.chips.scroll == "row" && chat.welcome.starters != "list"
            default: return false
            }
        }
    }

    private var offered: [String] { chat.suggestions }

    /// The brand's starters drawn in the thread rather than docked (a list, or chips placed inline).
    private var threadStarters: Bool {
        !offered.isEmpty && pieces.starters && ChatWindowRules.starterPlace(chat.chips, welcome: chat.welcome) == .thread
    }

    private var rows: [(row: ChatThreadRow, position: ChatGroupPosition)] {
        // The new-conversation marker ends a group as a day separator does.
        let built = ChatRows.thread(ChatRows.build(pieces.turns), marks: marks)
        let items = built.map { row -> ChatGroups.Item in
            switch row {
            case .row(.turn(let turn)): return ChatGroups.Item(role: turn.role, at: turn.at.timeIntervalSince1970 * 1000)
            default: return ChatGroups.Item(role: nil, at: nil, breaks: true)
            }
        }
        return Array(zip(built, ChatGroups.positions(items)))
    }

    private var items: [ThreadItem] {
        let d = chat.density
        var out: [ThreadItem] = []
        var afterHero = false
        func add(_ kind: ThreadItem.Kind, gap: Double? = nil) {
            let g = out.isEmpty ? 0 : (afterHero ? 16 : (gap ?? d.gap))
            afterHero = false
            out.append(ThreadItem(kind: kind, gap: g))
        }
        let w = welcome
        if w == .hero {
            add(.hero)
            afterHero = true
        }
        if ChatWindowRules.pinPlace(chat.header, pin: pin) == .card { add(.pinCard) }
        let drawn = pieces
        if drawn.upcoming { add(.upcoming) } else if drawn.book { add(.book) }
        if w == .card { add(.welcomeCard) }
        if w == .centered { add(.empty) }
        for entry in rows {
            let grouped = entry.position == .middle || entry.position == .last
            add(.row(entry.row, entry.position), gap: grouped ? d.groupGap : nil)
        }
        // Starters in the thread that no welcome block holds: at the end of what the agent has said so far.
        if threadStarters && w != .card && w != .hero { add(.starters) }
        if !quickReplies.isEmpty && !ChatWindowRules.repliesDocked(chat.chips) { add(.replies, gap: 8) }
        if typing { add(.typing) }
        if ended && chat.rating.show { add(.rating) }
        if status == .offline && !ended && banner == nil { add(.offline) }
        return out
    }

    private var thread: some View {
        let list = items
        let ceiling: CGFloat = lifted ? 150 : 260
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(list) { item in
                        threadItem(item)
                            .padding(.horizontal, item.fullWidth(chat) ? 0 : edge)
                            .padding(.top, CGFloat(item.gap))
                            .id(item.id)
                    }
                    // The end of the thread, and what keeps its last row clear of a floating composer: scrolling to
                    // the bottom brings this whole strip into view, not just the last row's edge.
                    Color.clear.frame(height: 12 + (floating ? floatingHeight : 0)).id(Self.bottomId)
                }
                // A hero meets the header: no strip of wallpaper above it.
                .padding(.top, welcome == .hero ? 0 : 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Read in place, not through a preference: a lazy stack's preferences do not reliably leave the scroll view.
                .background(GeometryReader { inner in
                    let frame = inner.frame(in: .named(Self.space))
                    let now = ThreadMetrics(height: frame.height, bottom: frame.maxY)
                    Color.clear
                        .onAppear { measured(now, proxy) }
                        .onChange(of: now) { measured($0, proxy) }
                })
            }
            .coordinateSpace(name: Self.space)
            .background(GeometryReader { g in Color.clear.preference(key: GraineChatViewportKey.self, value: g.size.height) })
            .frame(height: fills ? nil : min(max(metrics.height, 1), ceiling))
            .frame(maxHeight: fills ? .infinity : nil)
            .onPreferenceChange(GraineChatViewportKey.self) { viewport = $0 }
            .onChange(of: scrollKey) { _ in arrived(proxy) }
            .onChange(of: lastCustomerId) { _ in
                // The customer's own message: always shown, wherever they had scrolled.
                following = true
                unseen = 0
                scrollToBottom(proxy, animated: true)
            }
            .onAppear {
                rowsSeen = rows.count
                scrollToBottom(proxy, animated: false)
            }
            .overlay(alignment: .bottom) {
                if !following {
                    GraineChatScrollPill(tokens: tokens, type: ty, shadow: chat.cards.shadow ?? tokens.elevation.card, unseen: unseen) {
                        following = true
                        unseen = 0
                        scrollToBottom(proxy, animated: true)
                    }
                    .padding(.bottom, 8 + (floating ? floatingHeight : 0))
                    .transition(.opacity)
                }
            }
        }
    }

    /// Changes whenever something new lands at the bottom: a row, the typing indicator, the replies, the end.
    private var scrollKey: String {
        "\(rows.count):\(typing):\(quickReplies.count):\(ended):\(rating != nil):\(pieces.turns.last?.id ?? "")"
    }

    private var lastCustomerId: String {
        turns.last(where: { $0.role == .customer })?.id ?? ""
    }

    /// Something new arrived: followed while the thread is near its bottom; counted on the pill while it is not.
    private func arrived(_ proxy: ScrollViewProxy) {
        let count = rows.count
        let added = max(0, count - rowsSeen)
        rowsSeen = count
        if following {
            scrollToBottom(proxy, animated: true)
        } else if added > 0 {
            unseen += added
        }
    }

    /**
     * The thread measured itself. Growing (a reply being revealed, a row
     * settling) while it follows: it stays at the bottom. Moving without
     * growing is the customer scrolling: within 120 of the bottom it follows.
     */
    private func measured(_ next: ThreadMetrics, _ proxy: ScrollViewProxy) {
        let grew = abs(next.height - metrics.height) > 0.5
        metrics = next
        // A thread shorter than its window has nothing to scroll; a lazy list can keep an offset from rows it
        // estimated taller, which hides the first ones. Back to the top.
        if next.height <= viewport + 1 && next.bottom < next.height - 1, let first = items.first {
            proxy.scrollTo(first.id, anchor: .top)
            return
        }
        let near = Double(next.bottom - viewport) <= ChatWindowRules.followDistance
        let scrollingItself = Date() < selfScrollUntil
        // Whatever leaves the thread at its bottom follows again.
        if near && !following {
            following = true
            unseen = 0
        }
        if grew {
            // Growing (a reply revealed, a row settling, a lazy row measured) while it follows: stay at the bottom —
            // now, or once the scroll already under way is over.
            if following {
                if scrollingItself { settle(proxy) } else { scrollToBottom(proxy, animated: false) }
            }
            return
        }
        // Moving without growing, and not by itself: the customer scrolled away.
        if !near && following && !scrollingItself { following = false }
    }

    /// Once the thread has stopped scrolling itself, make sure it rests on its true bottom (one pending at a time).
    private func settle(_ proxy: ScrollViewProxy) {
        guard !settleScheduled else { return }
        settleScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, selfScrollUntil.timeIntervalSinceNow + 0.05)) {
            settleScheduled = false
            if following && metrics.height > viewport + 1 { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        // Nothing to scroll in a thread shorter than its window (and a lazy list would keep a stale offset).
        guard metrics.height > viewport + 1 else { return }
        if animated, let animation = motion {
            let seconds = tokens.motion.durationMs / 1000
            selfScrollUntil = Date().addingTimeInterval(seconds + 0.25)
            withAnimation(animation) { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
            // A new row's final height lands after the scroll began: settle on the true bottom once it is over.
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.05) {
                if following { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
            }
        } else {
            // A lazy list can land in two steps as it measures the rows it reaches.
            selfScrollUntil = max(selfScrollUntil, Date().addingTimeInterval(0.35))
            proxy.scrollTo(Self.bottomId, anchor: .bottom)
        }
    }

    @ViewBuilder
    private func threadItem(_ item: ThreadItem) -> some View {
        switch item.kind {
        case .hero: hero
        case .pinCard: if let pin = pin { contextCard(pin) }
        case .upcoming: upcomingCard(UpcomingCalls.shown(upcoming), title: pieces.upcomingTitle, book: pieces.book)
        case .book: bookButton(standalone: true)
        case .welcomeCard: welcomeCard
        case .empty: emptyChat
        case .starters: startersBlock(alignment: pieces.turns.isEmpty && welcome == .centered ? .center : .trailing)
        case .replies: repliesBlock
        case .typing: typingRow
        case .rating:
            GraineChatRatingCard(
                tokens: tokens, chat: chat, type: ty, thread: max(0, width - 2 * edge),
                rating: rating, onRate: { value in
                    onRate(GraineChatRating.Style(rawValue: chat.rating.style) ?? .thumbs, value)
                }
            )
            .frame(maxWidth: .infinity)
        case .offline: offlineRow
        case .row(let row, let position):
            switch row {
            case .row(.day(let line)): dayLine(line)
            case .row(.voice(let line)): callLine(line)
            case .row(.turn(let turn)): bubble(turn, position: position)
            case .newConversation: newConversationLine
            }
        }
    }

    // MARK: Welcome

    /// Before any message (v1): the avatar at 48, the title, and the subtitle when the brand set one.
    private var emptyChat: some View {
        let t = tokens
        let size = min(t.font.scale.title, 18)
        return VStack(spacing: 0) {
            if chat.avatar != "none" { mark(size: 48).padding(.bottom, 12) }
            Text(title)
                .font(ty.heading(size, t.font.weights.title))
                .tracking(ty.titleTracking(size))
                .foregroundColor(.graineHex(chat.wallpaper.text))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if !chat.subtitle.isEmpty {
                Text(chat.subtitle)
                    .font(ty.body(t.font.scale.caption, t.font.weights.body))
                    .foregroundColor(.graineHex(chat.wallpaper.textMuted))
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    /// A card first in the thread: the avatar (40) beside the title over the subtitle; the starters inside it.
    private var welcomeCard: some View {
        let t = tokens
        let size = min(t.font.scale.title, 17)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if chat.avatar != "none" { mark(size: 40) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(ty.heading(size, t.font.weights.title))
                        .tracking(ty.titleTracking(size))
                        .foregroundColor(.graineHex(t.colors.text))
                        .lineLimit(2)
                    if !chat.subtitle.isEmpty {
                        Text(chat.subtitle)
                            .font(ty.body(t.font.scale.caption, t.font.weights.body))
                            .foregroundColor(.graineHex(t.colors.textMuted))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if threadStarters { startersBlock(alignment: .leading, inCard: true) }
        }
        .padding(CGFloat(t.spacing.cardPadding))
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(GraineChatCardSurface(tokens: t, cards: chat.cards))
    }

    /// The window's full width in the header's fill (top → bottom), its bottom corners rounded: the avatar, the title, the subtitle, the starters.
    private var hero: some View {
        let t = tokens
        let fill = chat.header.fill
        let titleSize = min(t.font.scale.display, 26)
        let shape = GraineBubbleShape(topLeft: 0, topRight: 0, bottomLeft: CGFloat(t.shape.radius.xl), bottomRight: CGFloat(t.shape.radius.xl), smoothing: GraineBubbleShape.continuousSmoothing)
        let sideways = chat.chips.scroll == "row" && chat.welcome.starters != "list"
        return VStack(spacing: 0) {
            VStack(spacing: 0) {
                if chat.avatar != "none" { mark(size: 56).padding(.bottom, 12) }
                Text(title)
                    .font(ty.heading(titleSize, t.font.weights.title))
                    .tracking(ty.titleTracking(titleSize))
                    .foregroundColor(.graineHex(fill.text))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                if !chat.subtitle.isEmpty {
                    Text(chat.subtitle)
                        .font(ty.body(t.font.scale.body, t.font.weights.body))
                        .foregroundColor(.graineHex(fill.textMuted))
                        .multilineTextAlignment(.center)
                        .padding(.top, 6)
                }
            }
            .padding(.horizontal, 24)
            if threadStarters {
                // Centred chips; a sideways row runs to the hero's edges, starting 24 in.
                Group {
                    if sideways {
                        chipRow(offered.map { ($0, $0) }, alignment: .center, inset: 24)
                    } else {
                        startersBlock(alignment: .center, inCard: true).padding(.horizontal, 24)
                    }
                }
                .padding(.top, 16)
            }
        }
        .padding(.bottom, 24)
        .padding(.top, 24 + (heroUnderHeader ? topHeight : 0))
        .frame(maxWidth: .infinity)
        .background(heroFill(fill, shape))
    }

    @ViewBuilder
    private func heroFill(_ fill: GraineChatTokens.Fill, _ shape: GraineBubbleShape) -> some View {
        if let to = fill.colorTo {
            shape.fill(LinearGradient(colors: [.graineHex(fill.color), .graineHex(to)], startPoint: .top, endPoint: .bottom))
        } else {
            shape.fill(ink(fill.color))
        }
    }

    // MARK: Chips and starters

    private var glassForChips: GraineThemeTokens.Glass? { chatGlass }

    private func chip(_ words: String, send: String) -> some View {
        GraineChatChip(words: words, chips: chat.chips, tokens: tokens, type: ty, glass: glassForChips) { onSend(send) }
    }

    /// The brand's starters in the thread: a list, or chips (wrapping toward `alignment`, or one sideways row).
    @ViewBuilder
    private func startersBlock(alignment: HorizontalAlignment, inCard: Bool = false) -> some View {
        if chat.welcome.starters == "list" {
            VStack(spacing: 8) {
                ForEach(offered, id: \.self) { words in listStarter(words) }
            }
            .frame(maxWidth: .infinity)
        } else {
            chipRow(offered.map { ($0, $0) }, alignment: alignment, inset: inCard ? 0 : edge)
        }
    }

    /// The agent's quick replies under its turn, on its side.
    private var repliesBlock: some View {
        chipRow(quickReplies.map { ($0.label, $0.text) }, alignment: .leading, inset: edge)
    }

    /// Chips: rows that wrap (toward `alignment`), or one row that scrolls sideways starting `inset` in.
    @ViewBuilder
    private func chipRow(_ list: [(label: String, send: String)], alignment: HorizontalAlignment, inset: CGFloat) -> some View {
        let chips = ForEach(Array(list.enumerated()), id: \.offset) { _, entry in chip(entry.label, send: entry.send) }
        if chat.chips.scroll == "row" {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) { chips }
                    .padding(.horizontal, inset)
                    .padding(.vertical, 4)
            }
        } else if #available(iOS 16.0, *) {
            GraineChipFlow(spacing: 8, alignment: alignment) { chips }
                .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
        } else {
            VStack(alignment: alignment, spacing: 8) { chips }
                .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
        }
    }

    /// A starter as a list row: 44 high (it grows), `surfaceRaised`, the words, and a chevron pointing on.
    private func listStarter(_ words: String) -> some View {
        let t = tokens
        let shape = RoundedRectangle(cornerRadius: CGFloat(t.shape.radius.md), style: .continuous)
        let size = t.font.scale.body - 1
        return Button(action: { onSend(words) }) {
            HStack(spacing: 8) {
                Text(words)
                    .font(ty.body(size, t.font.weights.strong))
                    .tracking(ty.bodyTracking(size))
                    .foregroundColor(.graineHex(t.colors.text))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                GraineIconView(name: .chevron, style: t.icons.style, stroke: t.icons.stroke, color: .graineHex(t.colors.textMuted), size: 16)
                    .rotationEffect(.degrees(90))
                    .flipsForRightToLeftLayoutDirection(true)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(GraineSurfaceFill(shape: shape, color: .graineHex(t.colors.surfaceRaised), glass: chatGlass, scheme: t.scheme))
            .overlay(shape.strokeBorder(Color.graineHex(t.colors.border), lineWidth: CGFloat(t.shape.borderWidth)))
            .contentShape(shape)
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(words)
    }

    /// Above the composer: the brand's starters (docked), or the agent's replies where they are docked too.
    @ViewBuilder
    private var dockedChips: some View {
        let replies = ChatWindowRules.repliesDocked(chat.chips) && !quickReplies.isEmpty
        let starters = !offered.isEmpty && pieces.starters && ChatWindowRules.starterPlace(chat.chips, welcome: chat.welcome) == .docked
        if replies || starters {
            let list = replies ? quickReplies.map { ($0.label, $0.text) } : offered.map { ($0, $0) }
            chipRow(list, alignment: .trailing, inset: chat.chips.scroll == "row" ? edge : 0)
                .padding(.horizontal, chat.chips.scroll == "row" ? 0 : 12)
                .padding(.bottom, 8)
                .padding(.top, floating ? 0 : 4)
        }
    }

    // MARK: Bubbles

    private var liveKey: String {
        guard let last = turns.last else { return "" }
        return "\(last.id):\(last.text.utf16.count):\(last.live)"
    }

    private func feedReveal() {
        reveal.feed(turns.last, enabled: !still)
    }

    /// The agent's words, whole: what a long-press copies and a screen reader reads (a reply still arriving, so far).
    private func blocks(_ turn: GraineChatTurn) -> [ChatBlock] {
        turn.live ? ChatMarkdown.blocks(turn.text, live: true) : formats.blocks(turn.text)
    }

    private func bubble(_ turn: GraineChatTurn, position: ChatGroupPosition) -> some View {
        let t = tokens
        let customer = turn.role == .customer
        let side = customer ? chat.bubbles.user : chat.bubbles.agent
        let corners = ChatWindowRules.corners(chat.bubbles, role: turn.role, position: position)
        let shape = GraineBubbleShape(corners, role: turn.role, rightToLeft: layoutDirection == .rightToLeft)
        let pad = ChatWindowRules.padding(side, density: chat.density)
        let align: Alignment = customer ? .trailing : .leading
        let widest = max(0, width - 2 * edge) * CGFloat(chat.bubbles.maxWidth)
        let place = ChatWindowRules.timePlace(chat.timestamps, side: side, position: position, turn: turn)
        let time = place.map { _ in ChatRows.clock(turn.at) }
        let tick = ChatWindowRules.tick(chat.timestamps, turn: turn)
        let formatted = customer ? nil : blocks(turn)
        let plain = formatted.map { ChatMarkdown.plainText($0) } ?? turn.text
        let waiting = turn.delivery == .sending
        let failed = turn.delivery == .failed
        let size = t.font.scale.body
        let weight = t.font.weights.body
        let words: AnyView
        if formatted != nil {
            words = AnyView(GraineChatAgentWords(
                turn: turn, reveal: reveal, formats: formats, type: ty, tokens: t, ink: side.text, link: side.link,
                fill: side.color ?? chat.wallpaper.color
            ))
        } else {
            words = AnyView(Text(turn.text)
                .font(ty.body(size, weight))
                .tracking(ty.bodyTracking(size))
                .lineSpacing(ty.bodyLineSpacing(size: size, weight: weight, lineHeight: size * t.font.lineHeight.body))
                .foregroundColor(onInk(side.text))
                .fixedSize(horizontal: false, vertical: true))
        }
        return VStack(alignment: customer ? .trailing : .leading, spacing: 4) {
            // A time inside sits at the trailing edge on its own line; a hidden copy holds its room, so a short
            // message's bubble is as wide as the wider of the two and no wider.
            VStack(alignment: .leading, spacing: 2) {
                words
                if place == .inside, let time = time {
                    timeLine(time, tick: tick, color: side.textMuted).hidden()
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if place == .inside, let time = time {
                    timeLine(time, tick: tick, color: side.textMuted)
                }
            }
            .padding(.horizontal, CGFloat(pad.h))
            .padding(.vertical, CGFloat(pad.v))
            .background(bubbleBackground(side, shape, agent: !customer))
            .opacity(waiting ? 0.6 : 1)
            .contentShape(Rectangle())
            .onTapGesture { if failed { onRetry() } }
            .contextMenu {
                Button(action: { copy(plain) }) { Label("Copy", systemImage: "doc.on.doc") }
            }
            if place == .below, let time = time {
                timeLine(time, tick: tick, color: chat.wallpaper.textMuted)
            }
            statusLine(turn)
        }
        .frame(maxWidth: widest > 0 ? widest : .infinity, alignment: align)
        .frame(maxWidth: .infinity, alignment: align)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ChatWindowRules.spoken(turn, plain: plain, name: heading, time: time))
        .accessibilityAction(named: Text("Copy")) { copy(plain) }
        .modifier(GraineChatLinkActions(links: formatted.map(graineChatLinks) ?? []))
        .modifier(GraineChatRetryAction(failed: failed, retry: onRetry))
    }

    /// The bubble's box: its fill (a gradient top → bottom; an agent bubble frosted with the chat's glass), its outline, its shadow.
    @ViewBuilder
    private func bubbleBackground(_ side: GraineChatTokens.BubbleSide, _ shape: GraineBubbleShape, agent: Bool) -> some View {
        if !side.bare {
            let t = tokens
            let frosted = agent && chatGlass != nil && side.color != nil && side.colorTo == nil
            ZStack {
                if let color = side.color {
                    if let to = side.colorTo {
                        shape.fill(LinearGradient(colors: [ink(color), .graineHex(to)], startPoint: .top, endPoint: .bottom))
                    } else if frosted {
                        GraineSurfaceFill(shape: shape, color: .graineHex(color), glass: chatGlass, scheme: t.scheme)
                    } else {
                        shape.fill(ink(color))
                    }
                }
                if let border = side.border {
                    shape.stroke(ink(border), lineWidth: CGFloat(max(1, t.shape.borderWidth)))
                }
            }
            // Like a CSS box shadow, never seen through a bubble with no solid fill (none, or frosted).
            .background(GraineShadowLayer(shape: shape, shadow: chat.bubbles.shadow, outsideOnly: frosted || side.color == nil))
        }
    }

    /// A time in the device's short words, and the customer's mark beside it.
    private func timeLine(_ time: String, tick: GraineIconName?, color: String) -> some View {
        let t = tokens
        return HStack(spacing: 4) {
            Text(time)
                .font(ty.body(max(10, t.font.scale.caption - 1), t.font.weights.body))
                .foregroundColor(.graineHex(color))
                .lineLimit(1)
            if let tick = tick {
                GraineIconView(
                    name: tick, style: t.icons.style, stroke: t.icons.stroke,
                    color: .graineHex(tick == .alert ? t.colors.danger : color), size: 12
                )
            }
        }
        .accessibilityHidden(true)
    }

    /// "Waiting for connection…" under a message the connection has not taken; "Not sent · Tap to retry" once it gave up.
    @ViewBuilder
    private func statusLine(_ turn: GraineChatTurn) -> some View {
        let t = tokens
        let font = ty.body(t.font.scale.caption, t.font.weights.body)
        switch turn.delivery {
        case .sending:
            Text("Waiting for connection…").font(font).foregroundColor(.graineHex(chat.wallpaper.textMuted))
        case .failed:
            Button(action: onRetry) {
                HStack(spacing: 4) {
                    GraineIconView(name: .alert, style: t.icons.style, stroke: t.icons.stroke, color: .graineHex(t.colors.danger), size: 14)
                    Text("Not sent · Tap to retry")
                        .font(ty.body(t.font.scale.caption, t.font.weights.strong))
                        .foregroundColor(.graineHex(t.colors.danger))
                }
            }
            .buttonStyle(PlainButtonStyle())
        case .sent:
            EmptyView()
        }
    }

    private func copy(_ words: String) {
        UIPasteboard.general.string = words
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// While the agent works on a reply, as its next row (DESIGN.md "Typing indicator").
    @ViewBuilder
    private var typingRow: some View {
        let t = tokens
        let style = chat.typing.style
        let words = chat.typing.text.isEmpty ? "Typing…" : chat.typing.text
        Group {
            if style == "text" {
                GraineChatTypingMarks(
                    style: "text", color: .graineHex(chat.typing.color), words: words,
                    font: ty.body(t.font.scale.caption, t.font.weights.body), still: still
                )
                .padding(.vertical, 4)
            } else {
                let side = chat.bubbles.agent
                let corners = ChatWindowRules.corners(chat.bubbles, role: .agent, position: .single)
                let shape = GraineBubbleShape(corners, role: .agent, rightToLeft: layoutDirection == .rightToLeft)
                let pad = ChatWindowRules.padding(side, density: chat.density)
                Group {
                    if style == "loader" {
                        GraineLoaderMark(look: loader, color: .graineHex(loader.color ?? chat.typing.color), track: .graineHex(t.colors.border), size: 14, logoUrl: logoUrl)
                            .padding(.vertical, side.bare ? 2 : CGFloat(JSON.jsRound(t.spacing.cardPadding * 0.5)))
                    } else {
                        GraineChatTypingMarks(style: style, color: .graineHex(chat.typing.color), words: words, font: ty.body(t.font.scale.caption, t.font.weights.body), still: still)
                            .padding(.vertical, CGFloat(pad.v))
                    }
                }
                .padding(.horizontal, CGFloat(pad.h))
                .background(bubbleBackground(side, shape, agent: true))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(heading) is typing")
        .onAppear { UIAccessibility.post(notification: .announcement, argument: "\(heading) is typing") }
    }

    // MARK: Rows that are not messages

    /// A day separator: centred, caption size, strong, on the wallpaper (DESIGN.md "Day separators").
    private func dayLine(_ line: ChatDayLine) -> some View {
        Text(ChatRows.dayLabel(line))
            .font(ty.body(tokens.font.scale.caption, tokens.font.weights.strong))
            .tracking(ty.bodyTracking(tokens.font.scale.caption))
            .foregroundColor(.graineHex(chat.wallpaper.textMuted))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityAddTraits(.isHeader)
    }

    /**
     * "Disconnected · new conversation", drawn as a day separator is (DESIGN.md
     * "A new conversation under earlier lines"): the server began a new
     * conversation where this one could not continue.
     */
    private var newConversationLine: some View {
        Text(ChatRows.newConversationLabel)
            .font(ty.body(tokens.font.scale.caption, tokens.font.weights.strong))
            .tracking(ty.bodyTracking(tokens.font.scale.caption))
            .foregroundColor(.graineHex(chat.wallpaper.textMuted))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ChatRows.newConversationSpoken)
            .accessibilityAddTraits(.isHeader)
    }

    /// An earlier call, as one row: the call icon and "Voice call · 6:05 PM" — that it happened, never what was said.
    private func callLine(_ line: ChatCallLine) -> some View {
        let muted = Color.graineHex(chat.wallpaper.textMuted)
        return HStack(spacing: 6) {
            GraineIconView(name: .call, style: tokens.icons.style, stroke: tokens.icons.stroke, color: muted, size: 14)
            Text(ChatRows.callLabel(line))
                .font(ty.body(tokens.font.scale.caption, tokens.font.weights.body))
                .tracking(ty.bodyTracking(tokens.font.scale.caption))
                .foregroundColor(muted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ChatRows.callSpoken(line))
    }

    private var offlineRow: some View {
        HStack(spacing: 8) {
            Text("Not connected.")
                .font(ty.body(tokens.font.scale.caption, tokens.font.weights.body))
                .foregroundColor(.graineHex(chat.wallpaper.textMuted))
            Button(action: onRetry) {
                Text("Try again")
                    .font(ty.body(tokens.font.scale.caption, tokens.font.weights.strong))
                    .foregroundColor(accent)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: Upcoming calls

    /**
     * The customer's booked calls, as a card (DESIGN.md "Cards"): "Upcoming
     * call(s)", then a row per call — the call disc, the time in the
     * customer's own zone and words, the call name, and Cancel ("Cancelling…"
     * until it is done; "Couldn’t cancel · tap to retry" when it is not) —
     * and, where the agent can be booked from the app, "Book a call" under them.
     */
    private func upcomingCard(_ calls: [GraineScheduledCall], title cardTitle: String, book: Bool) -> some View {
        let t = tokens
        let c = t.colors
        let cards = chat.cards
        let shape = RoundedRectangle(cornerRadius: CGFloat(cards.radius), style: .continuous)
        let bar = WindowChrome.titleBar(t, for: .component(title: cardTitle, radius: cards.radius))
        return VStack(alignment: .leading, spacing: CGFloat(t.spacing.gap)) {
            if bar == nil {
                Text(cardTitle)
                    .font(ty.body(t.font.scale.caption, t.font.weights.strong))
                    .foregroundColor(.graineHex(c.textMuted))
            }
            ForEach(calls, id: \.id) { call in upcomingRow(call) }
            if book { bookButton(standalone: false) }
        }
        .padding(CGFloat(t.spacing.cardPadding))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.graineHex(bar == nil ? c.surfaceRaised : WindowChrome.componentBodyFill(t)))
        .modifier(GraineWindowed(bar: bar, spoken: true))
        .clipShape(shape)
        .overlay {
            if cards.border {
                shape.strokeBorder(Color.graineHex(c.border), lineWidth: CGFloat(t.shape.borderWidth))
            }
        }
        .background(GraineShadowLayer(
            shape: shape, shadow: cards.hard ? nil : cards.shadow,
            hardOffset: cards.hard ? t.elevation.hardOffset : nil, hardColor: .graineHex(c.text)
        ))
    }

    private func upcomingRow(_ call: GraineScheduledCall) -> some View {
        let t = tokens
        let c = t.colors
        let busy = cancelling.contains(call.id)
        let failed = cancelFailed.contains(call.id)
        let when = busy ? "Cancelling…" : failed ? "Couldn’t cancel · tap to retry" : call.at.map { UpcomingCalls.label($0) } ?? ""
        let buttonShape = RoundedRectangle(cornerRadius: CGFloat(min(t.shape.radius.md, 16)), style: .continuous)
        return HStack(spacing: 10) {
            ZStack {
                Circle().fill(accent)
                GraineIconView(name: .call, style: t.icons.style, stroke: t.icons.stroke, color: onAccent, size: 16)
            }
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(when)
                    .font(ty.body(t.font.scale.body - 1, t.font.weights.strong))
                    .foregroundColor(.graineHex(failed ? c.danger : c.text))
                    .lineLimit(1)
                Text(callName ?? heading)
                    .font(ty.body(t.font.scale.caption, t.font.weights.body))
                    .foregroundColor(.graineHex(c.textMuted))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { if failed { onCancelCall(call.id) } }
            if call.canCancel {
                Button(action: { onCancelCall(call.id) }) {
                    Text("Cancel")
                        .font(ty.body(t.font.scale.caption, t.font.weights.strong))
                        .foregroundColor(.graineHex(c.text))
                        .padding(.horizontal, 12)
                        .frame(minHeight: 32)
                        .overlay(buttonShape.strokeBorder(Color.graineHex(c.border), lineWidth: CGFloat(max(1, t.shape.borderWidth))))
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(busy)
                .opacity(busy ? VoiceBar.blockedOpacity : 1)
                .accessibilityLabel("Cancel the call \(when)")
            }
        }
        .accessibilityElement(children: .contain)
    }

    /**
     * "Book a call" (BOOKING-SHEET.md §4) — opens the booking sheet. In the
     * card, under its calls: outlined like Cancel, the full width. With no
     * calls booked, a compact row in the card's place: the same, 40 high on
     * `surfaceRaised`.
     */
    private func bookButton(standalone: Bool) -> some View {
        let t = tokens
        let c = t.colors
        let shape = RoundedRectangle(cornerRadius: CGFloat(min(t.shape.radius.md, 16)), style: .continuous)
        return Button(action: onBook) {
            HStack(spacing: 8) {
                GraineIconView(name: .call, style: t.icons.style, stroke: t.icons.stroke, color: accent, size: 16)
                Text(Booking.chatRow)
                    .font(ty.body(t.font.scale.body - 1, t.font.weights.strong))
                    .foregroundColor(.graineHex(c.text))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: standalone ? 40 : 36)
            .background(shape.fill(standalone ? Color.graineHex(c.surfaceRaised) : Color.clear))
            .overlay(shape.strokeBorder(Color.graineHex(c.border), lineWidth: CGFloat(max(1, t.shape.borderWidth))))
            .contentShape(shape)
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Booking.chatRow)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Composer

    private var composerPieces: ChatWindowRules.ComposerPieces {
        ChatWindowRules.composerPieces(chat.composer, escalation: chat.escalation, attachHandler: onAttach != nil, takesCalls: takesCalls)
    }

    /// `bar` (v1) or `pill`, on its strip.
    @ViewBuilder
    private var composer: some View {
        let cp = chat.composer
        let p = composerPieces
        if cp.style == "pill" {
            HStack(spacing: 0) {
                if p.attach { attachButton(size: 36) }
                if p.call { composerCallButton(size: 36) }
                field.padding(.leading, p.attach || p.call ? 4 : 14)
                sendButton(size: 36).padding(.trailing, 4)
            }
            .frame(minHeight: CGFloat(cp.height))
            .background(fieldBackground(radius: cp.radius))
            .padding(.horizontal, 10)
            .frame(minHeight: 60)
            .background(Color.graineHex(cp.strip ?? chat.wallpaper.color))
        } else {
            HStack(spacing: 8) {
                if p.attach { attachButton(size: 40) }
                if p.call { composerCallButton(size: 40) }
                field
                    .padding(.horizontal, 14)
                    .frame(minHeight: CGFloat(cp.height))
                    .background(fieldBackground(radius: cp.radius))
                sendButton(size: CGFloat(VoiceBar.Chat.send))
            }
            .padding(.horizontal, 10)
            .frame(minHeight: CGFloat(VoiceBar.Chat.composer))
            .background(Color.graineHex(cp.strip ?? chat.wallpaper.color))
        }
    }

    /// `floating`: the docked chips and one raised capsule 10 above the window's bottom, the thread scrolling under them.
    private var floatingBottom: some View {
        let cp = chat.composer
        let p = composerPieces
        let capsule = RoundedRectangle(cornerRadius: CGFloat(cp.radius), style: .continuous)
        return VStack(spacing: 0) {
            dockedChips
            HStack(spacing: 0) {
                if p.attach { attachButton(size: 36) }
                if p.call { composerCallButton(size: 36) }
                field.padding(.leading, p.attach || p.call ? 4 : 16)
                sendButton(size: 36).padding(.trailing, 6)
            }
            .frame(minHeight: CGFloat(cp.height))
            .background(GraineSurfaceFill(shape: capsule, color: .graineHex(cp.fill), glass: chatGlass, scheme: tokens.scheme))
            .overlay(capsule.strokeBorder(Color.graineHex(cp.border), lineWidth: CGFloat(tokens.shape.borderWidth)))
            .background(GraineShadowLayer(shape: capsule, shadow: cp.shadow, outsideOnly: chatGlass != nil))
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .background(GeometryReader { g in Color.clear.preference(key: GraineChatFloatingKey.self, value: g.size.height) })
        .onPreferenceChange(GraineChatFloatingKey.self) { floatingHeight = $0 }
    }

    /// The field's own box (`bar` and `pill`): its fill (frosted with the chat's glass), corners and outline.
    private func fieldBackground(radius: Double) -> some View {
        let cp = chat.composer
        let shape = RoundedRectangle(cornerRadius: CGFloat(radius), style: .continuous)
        return GraineSurfaceFill(shape: shape, color: .graineHex(cp.fill), glass: chatGlass, scheme: tokens.scheme)
            .overlay(shape.strokeBorder(Color.graineHex(cp.border), lineWidth: CGFloat(tokens.shape.borderWidth)))
    }

    private var field: some View {
        let t = tokens
        let cp = chat.composer
        let size = t.font.scale.body - 1
        return ZStack(alignment: .leading) {
            if draft.isEmpty {
                Text(chat.placeholder)
                    .font(ty.body(size, t.font.weights.body))
                    .foregroundColor(.graineHex(cp.placeholder))
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }
            TextField("", text: $draft)
                .font(ty.body(size, t.font.weights.body))
                .foregroundColor(.graineHex(cp.text))
                .submitLabel(.send)
                .onSubmit(submit)
                .accessibilityLabel("Message")
        }
        .frame(maxWidth: .infinity)
    }

    /**
     * The send button — round, rounded or a bare icon — and, while the field
     * is empty where the design asks for it, the microphone that calls the agent.
     */
    private func sendButton(size: CGFloat) -> some View {
        let t = tokens
        let cp = chat.composer
        let empty = trimmed.isEmpty
        let mic = composerPieces.mic && empty
        let bare = cp.send == "icon" || cp.sendFill == nil
        let iconColor = bare ? ink(cp.sendIcon) : onInk(cp.sendIcon)
        let icon = GraineIconView(name: mic ? .mic : .send, style: t.icons.style, stroke: t.icons.stroke, color: iconColor, size: bare ? 22 : CGFloat(VoiceBar.icon))
            .flipsForRightToLeftLayoutDirection(!mic)
        return Button(action: { mic ? onCall?() : submit() }) {
            Group {
                if bare {
                    icon.frame(width: 44, height: 44)
                } else if cp.send == "rounded" {
                    icon.frame(width: size, height: size)
                        .background(RoundedRectangle(cornerRadius: CGFloat(min(t.shape.radius.md, 12)), style: .continuous).fill(ink(cp.sendFill ?? t.colors.accent)))
                } else {
                    icon.frame(width: size, height: size).background(Circle().fill(ink(cp.sendFill ?? t.colors.accent)))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(empty && !mic)
        .opacity(empty && !mic ? VoiceBar.blockedOpacity : 1)
        .accessibilityLabel(mic ? "Call \(heading)" : "Send")
    }

    /// The paperclip (`composer.attach`, and only with the app's handler): a tap is the app's.
    private func attachButton(size: CGFloat) -> some View {
        Button(action: { onAttach?() }) {
            GraineIconView(name: .attach, style: tokens.icons.style, stroke: tokens.icons.stroke, color: .graineHex(chat.composer.icon), size: 20)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel("Attach")
    }

    /// `escalation.call: composer`: the call icon at 20 beside the paperclip.
    private func composerCallButton(size: CGFloat) -> some View {
        Button(action: { onCall?() }) {
            GraineIconView(name: .call, style: tokens.icons.style, stroke: tokens.icons.stroke, color: .graineHex(chat.composer.icon), size: 20)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel("Call \(heading)")
    }

    private func submit() {
        let text = trimmed
        guard !text.isEmpty else { return }
        draft = ""
        onSend(text)
    }
}

// MARK: - The header's fill, shared with the bigger windows

/// The header's fill by its style: the surface (frosted), the accent, a gradient leading → trailing (mirrored right to left), or none.
struct GraineChatHeaderFill: View {
    let header: GraineChatTokens.Header
    let frost: GraineThemeTokens.Glass?
    let scheme: String
    /// The accent header's colour as drawn (the app's override, where it has one).
    var accentOverride: Color? = nil

    var body: some View {
        switch header.style {
        case "gradient":
            LinearGradient(
                colors: [.graineHex(header.fill.color), .graineHex(header.fill.colorTo ?? header.fill.color)],
                startPoint: .leading, endPoint: .trailing
            )
            .flipsForRightToLeftLayoutDirection(true)
        case "plain":
            if let frost = frost {
                GraineSurfaceFill(shape: Rectangle(), color: .graineHex(header.fill.color), glass: frost, scheme: scheme)
            } else {
                Color.clear
            }
        case "accent":
            Rectangle().fill(accentOverride ?? .graineHex(header.fill.color))
        default:
            GraineSurfaceFill(shape: Rectangle(), color: .graineHex(header.fill.color), glass: frost, scheme: scheme)
        }
    }
}

// MARK: - Accessibility pieces

/// Each link in a bubble, reachable as an action of its own ("Open …").
private struct GraineChatLinkActions: ViewModifier {
    let links: [(label: String, url: URL)]
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        links.reduce(AnyView(content)) { view, link in
            AnyView(view.accessibilityAction(named: Text("Open \(link.label)")) { openURL(link.url) })
        }
    }
}

/// A message that could not be sent: double-tapping it sends it again.
private struct GraineChatRetryAction: ViewModifier {
    let failed: Bool
    let retry: () -> Void

    func body(content: Content) -> some View {
        if failed {
            content.accessibilityAction { retry() }.accessibilityAddTraits(.isButton)
        } else {
            content
        }
    }
}

// MARK: - The agent's words, revealed

/**
 * The agent's words in its bubble: whole and formatted once settled; while
 * the newest reply is being revealed, the part revealed so far, formatted as
 * still arriving — this view alone redraws on every frame of it, on the clock
 * of a timeline that runs only then. A reply still arriving that is not being
 * revealed (Reduce Motion, a design with no motion) is drawn as it comes, a
 * little faint until it settles.
 */
private struct GraineChatAgentWords: View {
    let turn: GraineChatTurn
    @ObservedObject var reveal: GraineChatReveal
    let formats: GraineChatFormatCache
    let type: GraineType
    let tokens: GraineThemeTokens
    let ink: String
    let link: String
    let fill: String

    var body: some View {
        if let shown = reveal.visible(turn) {
            TimelineView(.animation) { timeline in
                text(ChatMarkdown.blocks(ChatReveal.slice(turn.text, shown), live: true))
                    .onChange(of: timeline.date) { reveal.tick($0) }
            }
        } else if turn.live {
            text(ChatMarkdown.blocks(turn.text, live: true)).opacity(VoiceBar.liveOpacity)
        } else {
            text(formats.blocks(turn.text))
        }
    }

    private func text(_ blocks: [ChatBlock]) -> some View {
        GraineChatRichText(blocks: blocks, type: type, tokens: tokens, ink: ink, link: link, fill: fill)
    }
}

// MARK: - Measuring

/// The thread's height and where its bottom is in the scroll view: one value, so growth and scrolling are never confused.
struct ThreadMetrics: Equatable {
    var height: CGFloat = 0
    var bottom: CGFloat = 0
}

private struct GraineChatViewportKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct GraineChatFloatingKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct GraineChatTopKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
#endif
