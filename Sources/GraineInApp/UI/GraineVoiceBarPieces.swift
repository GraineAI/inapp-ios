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
 * talking to itself.
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
 * THE CHAT WINDOW, above the bar while the customer is in the chat: the page
 * in `background`, outlined, `radius.xl`, the floating shadow or the hard
 * offset. A 50-point header on `surface` — the launcher mark at 30 (a pill
 * drawn as a circle), the heading in the heading family at `weights.title`,
 * "Online" after a `success` dot, and a chevron back to the call. Messages in
 * the design's bubble style, 84% wide at most. A 58-point composer: a
 * 40-point field on `surfaceRaised` and a round send button in `accent`.
 *
 * This package carries calls only — there is no text channel for it to send
 * on — so GraineAgentBar mounts the window only once it can (see
 * AgentSurfaces). It is drawn complete, so that is a matter of connecting a
 * channel rather than of design.
 */
struct GraineChatWindow: View {
    let tokens: GraineThemeTokens
    let type: GraineType
    let accent: Color
    let onAccent: Color
    let heading: String
    let logoUrl: String?
    let turns: [GraineCaption]
    let online: Bool
    /// The keyboard is up: the messages give way to it.
    let lifted: Bool
    let onSend: (String) -> Void
    let onCollapse: () -> Void

    @State private var draft = ""
    @State private var width: CGFloat = 0
    @State private var contentHeight: CGFloat = 0

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let r = tokens.shape.radius
        VStack(spacing: 0) {
            header
            messages
            composer
        }
        .clipShape(RoundedRectangle(cornerRadius: CGFloat(r.xl), style: .continuous))
        .modifier(GraineDesignSurface(tokens: tokens, fill: tokens.colors.background, frosted: false, radius: r.xl, shadow: tokens.elevation.floating))
        .background(GeometryReader { proxy in
            Color.clear.onAppear { width = proxy.size.width }.onChange(of: proxy.size.width) { width = $0 }
        })
    }

    // MARK: Header

    private var header: some View {
        let t = tokens
        let c = t.colors
        let titleSize = min(t.font.scale.title, VoiceBar.Chat.titleMax)
        return HStack(spacing: 10) {
            mark
            VStack(alignment: .leading, spacing: 0) {
                Text(heading)
                    .font(type.heading(titleSize, t.font.weights.title))
                    .tracking(type.titleTracking(titleSize))
                    .foregroundColor(.graineHex(c.text))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if online {
                        Circle().fill(Color.graineHex(c.success))
                            .frame(width: CGFloat(VoiceBar.Chat.dot), height: CGFloat(VoiceBar.Chat.dot))
                    }
                    Text(online ? "Online" : "Connecting…")
                        .font(type.body(t.font.scale.caption, t.font.weights.body))
                        .tracking(type.bodyTracking(t.font.scale.caption))
                        .foregroundColor(.graineHex(c.textMuted))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onCollapse) {
                GraineIconView(name: .chevron, style: t.icons.style, stroke: t.icons.stroke, color: .graineHex(c.textMuted), flipped: true)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel("Collapse")
        }
        .padding(.horizontal, 12)
        .frame(height: CGFloat(VoiceBar.Chat.header))
        .background(GraineSurfaceFill(shape: Rectangle(), color: .graineHex(c.surface), glass: t.glass, scheme: t.scheme))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.graineHex(c.border)).frame(height: CGFloat(t.shape.borderWidth))
        }
    }

    /// The launcher's own shape and fill at 30 points: its glyph at 14, else the logo, else the first letter.
    private var mark: some View {
        let t = tokens
        let size = CGFloat(VoiceBar.Chat.mark)
        let glyphSize = CGFloat(VoiceBar.Chat.markGlyph)
        let outline = GraineLauncherOutline(kind: t.shape.launcher == .pill ? .circle : t.shape.launcher, radius: t.shape.radius)
        let letter = Text(String(heading.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased())
            .font(.system(size: (size * 0.4).rounded(), weight: .bold))
            .foregroundColor(onAccent)
        return ZStack {
            outline.fill(accent)
            if let glyph = t.icons.launcher {
                GraineGlyphView(glyph: glyph, stroke: t.icons.stroke, color: onAccent, size: glyphSize, fallback: letter)
            } else if let url = logoUrl.flatMap({ URL(string: $0) }) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFit().frame(width: glyphSize, height: glyphSize)
                    case .failure: letter
                    default: Color.clear
                    }
                }
            } else {
                letter
            }
        }
        .frame(width: size, height: size)
        .clipShape(outline)
        .overlay {
            // The Garage's mark wears the launcher's outline where the design draws hard offsets.
            if t.elevation.hardOffset != nil {
                outline.stroke(Color.graineHex(t.colors.text), lineWidth: CGFloat(t.shape.borderWidth))
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: Messages

    private var messages: some View {
        let t = tokens
        let ceiling: CGFloat = lifted ? 150 : 260
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: CGFloat(t.spacing.gap)) {
                    if turns.isEmpty {
                        Text(online ? "\(heading) can see what you're looking at — ask it anything." : "Connecting…")
                            .font(type.body(t.font.scale.body, t.font.weights.body))
                            .foregroundColor(.graineHex(t.colors.textMuted))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(turns.enumerated()), id: \.offset) { index, turn in
                        bubble(turn).id(index)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { inner in
                    Color.clear.preference(key: GraineChatHeightKey.self, value: inner.size.height)
                })
            }
            .frame(height: min(max(contentHeight, 1), ceiling))
            .onPreferenceChange(GraineChatHeightKey.self) { contentHeight = $0 }
            .onChange(of: turns.count) { count in
                guard count > 0 else { return }
                withAnimation(t.motion.animation(reduceMotion: false)) { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
    }

    private func bubble(_ turn: GraineCaption) -> some View {
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
        return Text(turn.text)
            .font(type.body(size, weight))
            .tracking(type.bodyTracking(size))
            .lineSpacing(type.bodyLineSpacing(size: size, weight: weight, lineHeight: size * t.font.lineHeight.body))
            .foregroundColor(.graineHex(colors.text))
            .opacity(turn.live ? VoiceBar.liveOpacity : 1)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, CGFloat(shape.paddingH))
            .padding(.vertical, CGFloat(shape.paddingV))
            .background(corners.fill(colors.fill.map { Color.graineHex($0) } ?? .clear))
            .overlay {
                if let outline = colors.outline {
                    corners.stroke(Color.graineHex(outline), lineWidth: CGFloat(t.shape.borderWidth))
                }
            }
            .frame(maxWidth: widest > 0 ? widest : .infinity, alignment: side)
            .frame(maxWidth: .infinity, alignment: side)
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
                    Text("Message…")
                        .font(type.body(fieldSize, t.font.weights.body))
                        .foregroundColor(.graineHex(c.textMuted))
                        .lineLimit(1)
                        .accessibilityHidden(true)
                }
                TextField("", text: $draft)
                    .font(type.body(fieldSize, t.font.weights.body))
                    .foregroundColor(.graineHex(c.text))
                    .submitLabel(.send)
                    .onSubmit(submit)
                    .accessibilityLabel("Message")
            }
            .padding(.horizontal, 14)
            .frame(height: CGFloat(VoiceBar.Chat.field))
            .background(field.fill(Color.graineHex(c.surfaceRaised)))
            .overlay(field.strokeBorder(Color.graineHex(c.border), lineWidth: CGFloat(t.shape.borderWidth)))
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
        .background(Color.graineHex(c.background))
    }

    private func submit() {
        let text = trimmed
        guard !text.isEmpty else { return }
        draft = ""
        onSend(text)
    }
}
#endif
