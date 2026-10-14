#if os(iOS)
import SwiftUI
import UIKit

/*
 * THE VOICE BAR'S PIECES, drawn from the design's tokens exactly as
 * contract/DESIGN.md ("Voice bar", "Chat window") specifies and the Garage's
 * phone preview draws them: the surface every floating piece wears, the
 * meter, the caption card and the chat window. GraineAgentBar assembles them;
 * the numbers live in Core/VoiceBar.swift.
 */

// MARK: - The surface a floating piece wears

/**
 * Fill (translucent over a blur with `glass`), a `borderWidth` outline in
 * `border` drawn inside the edge as a CSS border is, and the shadow — or,
 * with `hardOffset`, a solid `colors.text` copy offset by {x, y}, never
 * blurred. Like a CSS box-shadow, no shadow ever shows through a translucent
 * surface: it is drawn only outside the outline.
 */
struct GraineDesignSurface: ViewModifier {
    let tokens: GraineThemeTokens
    /// The fill, #RRGGBB: `surface` for the bar and the caption, `background` for the chat window's page.
    let fill: String
    /// Whether `glass` applies — it frosts surfaces, never the chat window's page.
    let frosted: Bool
    let radius: Double
    let shadow: GraineThemeTokens.Shadow?

    func body(content: Content) -> some View {
        let t = tokens
        let shape = RoundedRectangle(cornerRadius: CGFloat(radius), style: .continuous)
        let glass = frosted ? t.glass : nil
        return content
            .background(GraineSurfaceFill(shape: shape, color: .graineHex(fill), glass: glass, scheme: t.scheme))
            .overlay(shape.strokeBorder(Color.graineHex(t.colors.border), lineWidth: CGFloat(t.shape.borderWidth)))
            .background(GraineShadowLayer(
                shape: shape, shadow: shadow,
                hardOffset: t.elevation.hardOffset, hardColor: .graineHex(t.colors.text),
                outsideOnly: glass != nil
            ))
    }
}

/// A caption or a chat window arriving: opacity 0 → 1 and 8 points of rise, in the design's motion (DESIGN.md "Arrivals").
extension AnyTransition {
    static var graineRise: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: CGFloat(VoiceBar.rise))), removal: .identity)
    }
}

// MARK: - The meter

/**
 * Four bars moving at the design's pace (Core/VoiceBar.swift VoiceMeter),
 * drawn from the clock rather than animated, like the loader: nothing runs
 * while it is off screen, and a Reduce Motion switched on mid-call stops it at
 * the next frame.
 */
struct GraineVoiceMeter: View {
    let color: Color
    /// The design's duration after Reduce Motion (Motion.effectiveDurationMs); 0 holds it still.
    let durationMs: Double
    @State private var began = Date()

    var body: some View {
        Group {
            if VoiceMeter.moves(durationMs: durationMs, reduceMotion: false) {
                let leg = VoiceMeter.legMs(durationMs: durationMs)
                TimelineView(.animation) { timeline in
                    bars { i in VoiceMeter.scale(bar: i, elapsedMs: timeline.date.timeIntervalSince(began) * 1000, legMs: leg) }
                }
            } else {
                bars { _ in 1 }
            }
        }
        .accessibilityHidden(true)
    }

    private func bars(_ scale: @escaping (Int) -> Double) -> some View {
        HStack(alignment: .bottom, spacing: CGFloat(VoiceMeter.barGap)) {
            ForEach(0..<VoiceMeter.heights.count, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: CGFloat(VoiceMeter.barWidth), height: CGFloat(VoiceMeter.barHeight(i)))
                    .scaleEffect(x: 1, y: CGFloat(scale(i)), anchor: .bottom)
            }
        }
        .frame(height: CGFloat(VoiceMeter.height), alignment: .bottom)
    }
}

// MARK: - The caption

/**
 * The latest line, 8 above the bar: `surface` (frosted with glass), outlined,
 * `radius.lg`, the card shadow or the hard offset, 12 × 8 inside. 13 points of
 * the body family at `weights.strong`, two lines at most, faint while it is
 * still arriving — and "YOU" over the customer's own lines, because captions
 * carry both sides and an unlabelled "Take me to privacy" reads as the agent
 * talking to itself. With window chrome it opens as a window: a 24-point
 * title bar, smaller lights, titled "captions".
 */
struct GraineCaptionCard: View {
    let tokens: GraineThemeTokens
    let type: GraineType
    let accent: Color
    let line: GraineCaption

    var body: some View {
        let t = tokens
        let strong = t.font.weights.strong
        let size = VoiceBar.Caption.size
        VStack(alignment: .leading, spacing: 2) {
            if line.role == .customer {
                Text("YOU")
                    .font(type.body(VoiceBar.Caption.youSize, strong))
                    .tracking(CGFloat(VoiceBar.Caption.youTracking))
                    .foregroundColor(accent)
                    .lineLimit(1)
            }
            Text(line.text)
                .font(type.body(size, strong))
                .tracking(type.bodyTracking(size))
                .lineSpacing(type.bodyLineSpacing(size: size, weight: strong, lineHeight: VoiceBar.Caption.lineHeight))
                .foregroundColor(.graineHex(t.colors.text))
                .lineLimit(VoiceBar.Caption.maxLines)
                .opacity(line.live ? VoiceBar.liveOpacity : 1)
        }
        .padding(.horizontal, CGFloat(VoiceBar.Caption.paddingH))
        .padding(.vertical, CGFloat(VoiceBar.Caption.paddingV))
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(GraineWindowed(bar: WindowChrome.titleBar(t, for: .caption), spoken: false))
        .modifier(GraineDesignSurface(tokens: t, fill: t.colors.surface, frosted: true, radius: t.shape.radius.lg, shadow: t.elevation.card))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - The chat window

private struct GraineChatHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/**
 * THE CHAT WINDOW (contract/DESIGN.md "Chat window"), above the bar while the
 * customer is in the chat — and, filling the screen, `GraineChatView`, which
 * draws no outline, corners or shadow. It reads the design's `chat` tokens;
 * without them (an older server) it draws from the scheme's colours, as before.
 *
 * - **Header**, 50 high on `chat.headerBackground` (frosted only when that is
 *   `colors.surface`): the avatar per `chat.avatar` at 30 — the brand's logo
 *   on its plate, the launcher mark, or nothing — the title (`chat.title`, or
 *   the heading), and under it "Connecting…" while connecting, else a dot
 *   (`success` on a surface header, `headerText` on any other) and
 *   `chat.subtitle` or "Online"; "New conversation" (the compose icon) while
 *   earlier messages are on screen, unless `chat.newConversation` is off; the
 *   chevron back to the call (or closing a chat-only agent). With window
 *   chrome a title bar replaces it.
 * - **Thread** on `chat.background`, with `chat.pattern` "dots" standing still
 *   behind it: the upcoming-calls card first (Cancel on each row; none with
 *   `chat.showUpcomingCalls` off, under `chat.upcomingTitle` when set), then one
 *   bubble per message in the design's bubble style, times under them with
 *   `chat.showTimestamps`, a conversation that continues with a day line where
 *   the day changes and an earlier call as one "Voice call · time" row (never
 *   its transcript) — none of the earlier conversation with
 *   `chat.showHistory` off, so the window opens like a new chat — a typing
 *   bubble while the agent works on a reply,
 *   "Waiting to send…" / "Not sent · Try again" under a message the
 *   connection has not taken. Before any message: the avatar at 48, the title,
 *   and the subtitle when there is one.
 * - **Starters** (`chat.suggestions`) on the customer's side above the
 *   composer until the customer has said something, never while earlier
 *   messages are on screen; a tap sends one.
 * - **Composer**, 58 high: the field in the chat's composer colours and
 *   `chat.placeholder`, the send button in `accent`.
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
    let onSend: (String) -> Void
    var onRetry: () -> Void = {}
    var onCancelCall: (String) -> Void = { _ in }
    /// "New conversation" — offered in the header only while earlier messages (restored turns) are on screen.
    var onNewConversation: (() -> Void)? = nil
    let onCollapse: () -> Void

    @State private var draft = ""
    /// A logo that would not load: the mark goes back to the glyph or the letter until the logo changes.
    @State private var failedLogo: String? = nil
    @State private var width: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var online: Bool { status == .online }
    /// What the window draws of the pieces the design can leave out: earlier messages, New conversation, booked calls.
    private var pieces: ChatPieces { ChatPieces.of(turns, chat: chat, upcomingCount: UpcomingCalls.shown(upcoming).count) }
    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var chat: GraineChatTokens? { tokens.chat }
    private var title: String { chat.map { $0.title.isEmpty ? heading : $0.title } ?? heading }
    private var pageColor: String { chat?.background ?? tokens.colors.background }
    /// A header on the scheme's surface: frosted with glass, and its dot in `success`.
    private var surfaceHeader: Bool { (chat?.headerBackground ?? tokens.colors.surface) == tokens.colors.surface }

    var body: some View {
        let r = tokens.shape.radius
        let content = VStack(spacing: 0) {
            if let bar = WindowChrome.titleBar(tokens, for: .chat(heading: title, online: online)) {
                GraineWindowTitleBar(bar: bar) {
                    HStack(spacing: 0) {
                        composeButton
                        windowCollapse(bar)
                    }
                }
            } else {
                header
            }
            messages
            starters
            composer
        }
        .background(GeometryReader { proxy in
            Color.clear.onAppear { width = proxy.size.width }.onChange(of: proxy.size.width) { width = $0 }
        })
        if fills && !keepsFrame {
            content.background(Color.graineHex(pageColor))
        } else {
            content
                .clipShape(RoundedRectangle(cornerRadius: CGFloat(r.xl), style: .continuous))
                .modifier(GraineDesignSurface(tokens: tokens, fill: pageColor, frosted: false, radius: r.xl, shadow: tokens.elevation.floating))
        }
    }

    // MARK: Header

    private var header: some View {
        let t = tokens
        let c = t.colors
        let titleSize = min(t.font.scale.title, VoiceBar.Chat.titleMax)
        let subtext = Color.graineHex(chat?.headerSubtext ?? c.textMuted)
        return HStack(spacing: 10) {
            if leadingChevron { collapseButton }
            if chat?.avatar != "none" { mark(size: CGFloat(VoiceBar.Chat.mark)) }
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(type.heading(titleSize, t.font.weights.title))
                    .tracking(type.titleTracking(titleSize))
                    .foregroundColor(.graineHex(chat?.headerText ?? c.text))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if online {
                        Circle().fill(Color.graineHex(surfaceHeader ? c.success : (chat?.headerText ?? c.text)))
                            .frame(width: CGFloat(VoiceBar.Chat.dot), height: CGFloat(VoiceBar.Chat.dot))
                    }
                    Text(subtitle)
                        .font(type.body(t.font.scale.caption, t.font.weights.body))
                        .tracking(type.bodyTracking(t.font.scale.caption))
                        .foregroundColor(subtext)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            composeButton
            if !leadingChevron { collapseButton }
        }
        .padding(.horizontal, 12)
        .frame(height: CGFloat(VoiceBar.Chat.header))
        .background(GraineSurfaceFill(
            shape: Rectangle(), color: .graineHex(chat?.headerBackground ?? c.surface),
            glass: surfaceHeader ? t.glass : nil, scheme: t.scheme
        ))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.graineHex(c.border)).frame(height: CGFloat(t.shape.borderWidth))
        }
    }

    /// The chevron as a button: back to the call, or closed for a chat-only agent.
    private var collapseButton: some View {
        Button(action: onCollapse) {
            chevron
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(collapseLabel)
    }

    private var subtitle: String {
        switch status {
        case .online: return chat.flatMap { $0.subtitle.isEmpty ? nil : $0.subtitle } ?? "Online"
        case .offline, .idle: return "Not connected"
        case .connecting, .reconnecting: return "Connecting…"
        }
    }

    /// "New conversation": the compose icon beside the chevron, only while earlier messages are on screen and the design keeps it.
    @ViewBuilder private var composeButton: some View {
        if let start = onNewConversation, pieces.newConversation {
            Button(action: start) {
                GraineIconView(
                    name: .compose, style: tokens.icons.style, stroke: tokens.icons.stroke,
                    color: .graineHex(chat?.headerSubtext ?? tokens.colors.textMuted), size: 18
                )
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel("New conversation")
        }
    }

    /// Back to the call (or closed, for a chat-only agent): the chevron, turned to point down.
    private var chevron: some View {
        GraineIconView(
            name: .chevron, style: tokens.icons.style, stroke: tokens.icons.stroke,
            color: .graineHex(chat?.headerSubtext ?? tokens.colors.textMuted), flipped: true
        )
    }

    /// The chevron at the title bar's right end, as far in from it as the lights are from the left.
    private func windowCollapse(_ bar: WindowChrome.TitleBar) -> some View {
        Button(action: onCollapse) {
            chevron
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
        let wanted = chat?.avatar ?? (glyph != nil ? "glyph" : "logo")
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

    // MARK: Thread

    private var messages: some View {
        let t = tokens
        let ceiling: CGFloat = lifted ? 150 : 260
        let drawn = pieces
        let rows = ChatRows.build(drawn.turns)
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: CGFloat(t.spacing.gap)) {
                    if drawn.upcoming {
                        upcomingCard(UpcomingCalls.shown(upcoming), title: drawn.upcomingTitle)
                    }
                    if drawn.turns.isEmpty {
                        emptyChat
                    }
                    ForEach(rows) { row in
                        switch row {
                        case .day(let line): dayLine(line).id(row.id)
                        case .voice(let line): callLine(line).id(row.id)
                        case .turn(let turn): bubble(turn).id(turn.id)
                        }
                    }
                    if typing {
                        typingBubble.id("typing")
                    }
                    if status == .offline {
                        offlineRow
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { inner in
                    Color.clear.preference(key: GraineChatHeightKey.self, value: inner.size.height)
                })
            }
            .frame(height: fills ? nil : min(max(contentHeight, 1), ceiling))
            .frame(maxHeight: fills ? .infinity : nil)
            // The pattern stands still behind the messages as they scroll.
            .background(pattern)
            .onPreferenceChange(GraineChatHeightKey.self) { contentHeight = $0 }
            .onChange(of: scrollKey) { _ in
                // The last ROW: a call's turns are one row, under the call's id.
                let target: String? = typing ? "typing" : rows.last?.id
                guard let id = target else { return }
                withAnimation(t.motion.animation(reduceMotion: reduceMotion)) { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    /// `chat.pattern` "dots": dots 2 across in `chat.patternColor` on an 18-point grid, the first 9 in from the top left.
    @ViewBuilder private var pattern: some View {
        if let chat = chat, chat.pattern == "dots" {
            Canvas { context, size in
                let dot = Color.graineHex(chat.patternColor)
                var y: CGFloat = 9
                while y < size.height {
                    var x: CGFloat = 9
                    while x < size.width {
                        context.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)), with: .color(dot))
                        x += 18
                    }
                    y += 18
                }
            }
            .accessibilityHidden(true)
        }
    }

    /// Changes whenever the bottom of the conversation moves: a new turn, a growing reply, the typing bubble.
    private var scrollKey: String {
        "\(turns.count):\(turns.last?.text.count ?? 0):\(typing)"
    }

    /// Before any message: the avatar at 48, the title, and the subtitle when the brand set one.
    private var emptyChat: some View {
        let t = tokens
        let size = min(t.font.scale.title, 18)
        return VStack(spacing: 0) {
            if chat?.avatar != "none" { mark(size: 48).padding(.bottom, 12) }
            Text(title)
                .font(type.heading(size, t.font.weights.title))
                .tracking(type.titleTracking(size))
                .foregroundColor(.graineHex(t.colors.text))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if let sub = chat?.subtitle, !sub.isEmpty {
                Text(sub)
                    .font(type.body(t.font.scale.caption, t.font.weights.body))
                    .foregroundColor(.graineHex(t.colors.textMuted))
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    /// A day separator: centred, caption size, strong, muted (DESIGN.md "Day separators").
    private func dayLine(_ line: ChatDayLine) -> some View {
        Text(ChatRows.dayLabel(line))
            .font(type.body(tokens.font.scale.caption, tokens.font.weights.strong))
            .tracking(type.bodyTracking(tokens.font.scale.caption))
            .foregroundColor(.graineHex(tokens.colors.textMuted))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityAddTraits(.isHeader)
    }

    /// An earlier call, as one row: the call icon and "Voice call · 6:05 PM" — that it happened, never what was said.
    private func callLine(_ line: ChatCallLine) -> some View {
        let muted = Color.graineHex(tokens.colors.textMuted)
        return HStack(spacing: 6) {
            GraineIconView(name: .call, style: tokens.icons.style, stroke: tokens.icons.stroke, color: muted, size: 14)
            Text(ChatRows.callLabel(line))
                .font(type.body(tokens.font.scale.caption, tokens.font.weights.body))
                .tracking(type.bodyTracking(tokens.font.scale.caption))
                .foregroundColor(muted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ChatRows.callSpoken(line))
    }

    private func bubble(_ turn: GraineChatTurn) -> some View {
        let t = tokens
        let colors = DesignRules.bubble(t, role: turn.role)
        let shape = ChatBubble.shape(t, role: turn.role)
        let corners = GraineCornerShape(
            topLeading: CGFloat(shape.topLeading), topTrailing: CGFloat(shape.topTrailing),
            bottomLeading: CGFloat(shape.bottomLeading), bottomTrailing: CGFloat(shape.bottomTrailing)
        )
        let size = t.font.scale.body
        let weight = t.font.weights.body
        let side: Alignment = turn.role == .customer ? .trailing : .leading
        let widest = max(0, width - 24) * CGFloat(VoiceBar.Chat.bubbleShare)
        let waiting = turn.delivery != .sent
        return VStack(alignment: turn.role == .customer ? .trailing : .leading, spacing: 4) {
            Text(turn.text)
                .font(type.body(size, weight))
                .tracking(type.bodyTracking(size))
                .lineSpacing(type.bodyLineSpacing(size: size, weight: weight, lineHeight: size * t.font.lineHeight.body))
                .foregroundColor(.graineHex(colors.text))
                .opacity(turn.live || waiting ? VoiceBar.liveOpacity : 1)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, CGFloat(shape.paddingH))
                .padding(.vertical, CGFloat(shape.paddingV))
                .background(corners.fill(colors.fill.map { Color.graineHex($0) } ?? .clear))
                .overlay {
                    if let outline = colors.outline {
                        corners.stroke(Color.graineHex(outline), lineWidth: CGFloat(t.shape.borderWidth))
                    }
                }
            footnote(turn)
        }
        .frame(maxWidth: widest > 0 ? widest : .infinity, alignment: side)
        .frame(maxWidth: .infinity, alignment: side)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func footnote(_ turn: GraineChatTurn) -> some View {
        let muted = Color.graineHex(tokens.colors.textMuted)
        let font = type.body(max(10, tokens.font.scale.caption - 1), tokens.font.weights.body)
        switch turn.delivery {
        case .sending:
            Text("Waiting to send…").font(font).foregroundColor(muted)
        case .failed:
            Button(action: onRetry) {
                Text("Not sent · Try again").font(font).foregroundColor(.graineHex(tokens.colors.danger))
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel("Not sent. Try again")
        case .sent:
            if chat?.showTimestamps == true && !turn.live {
                Text(Self.time(turn.at)).font(font).foregroundColor(muted)
            }
        }
    }

    private static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    /// While the agent works on a reply: three dots on the agent's bubble.
    private var typingBubble: some View {
        let t = tokens
        let colors = DesignRules.bubble(t, role: .agent)
        let shape = ChatBubble.shape(t, role: .agent)
        let corners = GraineCornerShape(
            topLeading: CGFloat(shape.topLeading), topTrailing: CGFloat(shape.topTrailing),
            bottomLeading: CGFloat(shape.bottomLeading), bottomTrailing: CGFloat(shape.bottomTrailing)
        )
        return GraineTypingDots(color: .graineHex(colors.text), durationMs: t.motion.effectiveDurationMs(reduceMotion: GraineThemeTokens.Motion.reduced(reduceMotion)))
            .padding(.horizontal, CGFloat(max(shape.paddingH, 12)))
            .padding(.vertical, CGFloat(max(shape.paddingV, 10)))
            .background(corners.fill(colors.fill.map { Color.graineHex($0) } ?? Color.graineHex(t.colors.accentSoft)))
            .overlay {
                if let outline = colors.outline {
                    corners.stroke(Color.graineHex(outline), lineWidth: CGFloat(t.shape.borderWidth))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(heading) is typing")
    }

    private var offlineRow: some View {
        HStack(spacing: 8) {
            Text("Not connected.")
                .font(type.body(tokens.font.scale.caption, tokens.font.weights.body))
                .foregroundColor(.graineHex(tokens.colors.textMuted))
            Button(action: onRetry) {
                Text("Try again")
                    .font(type.body(tokens.font.scale.caption, tokens.font.weights.strong))
                    .foregroundColor(accent)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: Upcoming calls

    /**
     * The customer's booked calls, as a component card: "Upcoming call(s)",
     * then a row per call — the call disc, the time in the customer's own zone
     * and words, the call name, and Cancel ("Cancelling…" until it is done;
     * "Couldn’t cancel · tap to retry" when it is not).
     */
    private func upcomingCard(_ calls: [GraineScheduledCall], title cardTitle: String) -> some View {
        let t = tokens
        let c = t.colors
        let radius = t.shape.radius.lg
        let shape = RoundedRectangle(cornerRadius: CGFloat(radius), style: .continuous)
        let bar = WindowChrome.titleBar(t, for: .component(title: cardTitle, radius: radius))
        return VStack(alignment: .leading, spacing: CGFloat(t.spacing.gap)) {
            if bar == nil {
                Text(cardTitle)
                    .font(type.body(t.font.scale.caption, t.font.weights.strong))
                    .foregroundColor(.graineHex(c.textMuted))
            }
            ForEach(calls, id: \.id) { call in upcomingRow(call) }
        }
        .padding(CGFloat(t.spacing.cardPadding))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.graineHex(bar == nil ? c.surfaceRaised : WindowChrome.componentBodyFill(t)))
        .modifier(GraineWindowed(bar: bar, spoken: true))
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.graineHex(c.border), lineWidth: CGFloat(t.shape.borderWidth)))
        .background(GraineShadowLayer(shape: shape, shadow: t.elevation.card, hardOffset: t.elevation.hardOffset, hardColor: .graineHex(c.text)))
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
                    .font(type.body(t.font.scale.body - 1, t.font.weights.strong))
                    .foregroundColor(.graineHex(failed ? c.danger : c.text))
                    .lineLimit(1)
                Text(callName ?? heading)
                    .font(type.body(t.font.scale.caption, t.font.weights.body))
                    .foregroundColor(.graineHex(c.textMuted))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { if failed { onCancelCall(call.id) } }
            if call.canCancel {
            Button(action: { onCancelCall(call.id) }) {
                Text("Cancel")
                    .font(type.body(t.font.scale.caption, t.font.weights.strong))
                    .foregroundColor(.graineHex(c.text))
                    .padding(.horizontal, 12)
                    .frame(height: 32)
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

    // MARK: Starters

    /// The brand's starters, on the customer's side, until the customer has said something — never on a conversation that continues.
    @ViewBuilder private var starters: some View {
        let offered = chat?.suggestions ?? []
        if !offered.isEmpty && pieces.starters {
            let chips = ForEach(offered, id: \.self) { words in starterChip(words) }
            Group {
                if #available(iOS 16.0, *) {
                    GraineTrailingFlow(spacing: 8) { chips }
                } else {
                    VStack(alignment: .trailing, spacing: 8) { chips }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .background(Color.graineHex(pageColor))
        }
    }

    private func starterChip(_ words: String) -> some View {
        let t = tokens
        let shape = RoundedRectangle(cornerRadius: CGFloat(min(t.shape.radius.xl, 17)), style: .continuous)
        return Button(action: { onSend(words) }) {
            Text(words)
                .font(type.body(t.font.scale.body - 1, t.font.weights.strong))
                .foregroundColor(.graineHex(t.colors.text))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(shape.fill(Color.graineHex(pageColor)))
                .overlay(shape.strokeBorder(accent, lineWidth: CGFloat(max(1, t.shape.borderWidth))))
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: Composer

    private var composer: some View {
        let t = tokens
        let c = t.colors
        let field = RoundedRectangle(cornerRadius: CGFloat(t.shape.radius.xl), style: .continuous)
        let fieldSize = t.font.scale.body - 1
        let empty = trimmed.isEmpty
        return HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                if draft.isEmpty {
                    Text(chat?.placeholder ?? "Message…")
                        .font(type.body(fieldSize, t.font.weights.body))
                        .foregroundColor(.graineHex(chat?.composerPlaceholder ?? c.textMuted))
                        .lineLimit(1)
                        .accessibilityHidden(true)
                }
                TextField("", text: $draft)
                    .font(type.body(fieldSize, t.font.weights.body))
                    .foregroundColor(.graineHex(chat?.composerText ?? c.text))
                    .submitLabel(.send)
                    .onSubmit(submit)
                    .accessibilityLabel("Message")
            }
            .padding(.horizontal, 14)
            .frame(height: CGFloat(VoiceBar.Chat.field))
            .background(field.fill(Color.graineHex(chat?.composerBackground ?? c.surfaceRaised)))
            .overlay(field.strokeBorder(Color.graineHex(chat?.composerBorder ?? c.border), lineWidth: CGFloat(t.shape.borderWidth)))
            Button(action: submit) {
                GraineIconView(name: .send, style: t.icons.style, stroke: t.icons.stroke, color: onAccent)
                    .frame(width: CGFloat(VoiceBar.Chat.send), height: CGFloat(VoiceBar.Chat.send))
                    .background(Circle().fill(accent))
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(empty)
            .opacity(empty ? VoiceBar.blockedOpacity : 1)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 10)
        .frame(height: CGFloat(VoiceBar.Chat.composer))
        .background(Color.graineHex(pageColor))
    }

    private func submit() {
        let text = trimmed
        guard !text.isEmpty else { return }
        draft = ""
        onSend(text)
    }
}

/// Chips laid out right to left in rows, wrapping, `spacing` apart both ways: the starters, on the customer's side.
@available(iOS 16.0, *)
struct GraineTrailingFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        let used = rows.map { $0.width }.max() ?? 0
        return CGSize(width: proposal.width ?? used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.maxX - row.width
            for index in row.items {
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
                x += min(size.width, bounds.width) + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            let w = min(size.width, width)
            if var last = rows.last, last.width + spacing + w <= width {
                last.items.append(index)
                last.width += spacing + w
                last.height = max(last.height, size.height)
                rows[rows.count - 1] = last
            } else {
                rows.append(([index], w, size.height))
            }
        }
        return rows
    }
}

/**
 * Three dots rising in turn — the agent is typing — at the design's pace,
 * drawn from the clock like the meter; still under Reduce Motion or a design
 * with no motion.
 */
struct GraineTypingDots: View {
    let color: Color
    let durationMs: Double
    @State private var began = Date()

    var body: some View {
        Group {
            if durationMs > 0 {
                TimelineView(.animation) { timeline in
                    dots { i in
                        let leg = max(360, durationMs * 2.4) / 1000
                        let t = timeline.date.timeIntervalSince(began) - Double(i) * leg / 3
                        let phase = t <= 0 ? 0 : (t.truncatingRemainder(dividingBy: leg * 2)) / leg
                        let up = phase < 1 ? phase : 2 - phase
                        return 0.35 + 0.65 * CubicBezier.easeInOut(up)
                    }
                }
            } else {
                dots { _ in 0.7 }
            }
        }
        .accessibilityHidden(true)
    }

    private func dots(_ opacity: @escaping (Int) -> Double) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(color).frame(width: 6, height: 6).opacity(opacity(i))
            }
        }
        .frame(height: 12)
    }
}
#endif
