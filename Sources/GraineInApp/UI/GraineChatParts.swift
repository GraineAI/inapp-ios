#if os(iOS)
import SwiftUI
import UIKit

/*
 * THE CHAT WINDOW'S PIECES (contract/DESIGN.md "Chat window v2"), drawn from
 * the chat tokens: a bubble's shape (its four corners, continuous where iOS
 * draws them so, and the tail), the wallpaper, the typing indicators, the
 * agent's formatted words, a chip, the rating card, the scroll-to-latest pill
 * and the reconnect banner. GraineChatWindow assembles them; the decisions
 * live in Core/ChatWindowRules.swift.
 */

// MARK: - A bubble's shape

/**
 * A bubble: each corner its own radius — continuous (iOS's own corner, the
 * curvature easing in rather than starting abruptly) or circular — and, on
 * the last bubble of a `tail` group, the tail at its bottom speaker-side
 * corner, drawn as one outline with the bubble so a fill and a stroke both
 * run round the whole shape. The tail is the contract's path: for the
 * customer, with the bubble's bottom-trailing corner at (W, H),
 * M W,H−12 · Q W+1,H−2 W+8,H · L W−12,H — outside the bubble's width, in the
 * thread's margin. Corners here are physical (left, right): the window turns
 * leading and trailing into them for the reading direction.
 */
struct GraineBubbleShape: Shape {
    enum Tail {
        case none
        case left
        case right
    }

    var topLeft: CGFloat
    var topRight: CGFloat
    var bottomLeft: CGFloat
    var bottomRight: CGFloat
    /// 0 for circular corners; 0.6 for continuous ones (iOS's own smoothing).
    var smoothing: CGFloat
    var tail: Tail = .none

    /// iOS's continuous corners, as a smoothing of the circular corner.
    static let continuousSmoothing: CGFloat = 0.6

    func path(in rect: CGRect) -> Path {
        let budget = max(0, min(rect.width, rect.height) / 2)
        var path = Path()
        let points = Corner.all(rect)
        let radii = [topLeft, topRight, bottomRight, bottomLeft]
        let shapes = radii.map { CornerCurve(radius: $0, smoothing: smoothing, budget: budget) }
        // Start where the top-left corner ends, on the top edge.
        path.move(to: points[0].along(shapes[0].p, outgoing: true))
        for i in [1, 2, 3, 0] {
            let corner = points[i]
            if tail == .right && i == 2 {
                // The customer's tail: down the right edge, then out into the margin.
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 12))
                path.addQuadCurve(to: CGPoint(x: rect.maxX + 8, y: rect.maxY), control: CGPoint(x: rect.maxX + 1, y: rect.maxY - 2))
                continue
            }
            if tail == .left && i == 3 {
                // The agent's, mirrored: along the bottom into the margin, then back up the left edge.
                path.addLine(to: CGPoint(x: rect.minX - 8, y: rect.maxY))
                path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - 12), control: CGPoint(x: rect.minX - 1, y: rect.maxY - 2))
                continue
            }
            shapes[i].add(to: &path, at: corner)
        }
        path.closeSubpath()
        return path
    }

    /// A corner point and the directions the outline travels into it and out of it (clockwise).
    private struct Corner {
        let point: CGPoint
        let into: CGVector
        let out: CGVector

        static func all(_ r: CGRect) -> [Corner] {
            [
                Corner(point: CGPoint(x: r.minX, y: r.minY), into: CGVector(dx: 0, dy: -1), out: CGVector(dx: 1, dy: 0)),
                Corner(point: CGPoint(x: r.maxX, y: r.minY), into: CGVector(dx: 1, dy: 0), out: CGVector(dx: 0, dy: 1)),
                Corner(point: CGPoint(x: r.maxX, y: r.maxY), into: CGVector(dx: 0, dy: 1), out: CGVector(dx: -1, dy: 0)),
                Corner(point: CGPoint(x: r.minX, y: r.maxY), into: CGVector(dx: -1, dy: 0), out: CGVector(dx: 0, dy: -1)),
            ]
        }

        func at(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            CGPoint(x: point.x + into.dx * u + out.dx * v, y: point.y + into.dy * u + out.dy * v)
        }

        /// `distance` back along the incoming edge, or on along the outgoing one.
        func along(_ distance: CGFloat, outgoing: Bool) -> CGPoint {
            outgoing ? at(0, distance) : at(-distance, 0)
        }
    }

    /**
     * One corner as Figma's corner smoothing draws it (the published method
     * behind its iOS-like squircles): a cubic easing off the edge, a circular
     * arc of 90°·(1 − smoothing), a cubic easing onto the next edge, all within
     * `p` of the corner. Smoothing gives way where the corner has no room.
     */
    private struct CornerCurve {
        let radius: CGFloat
        let p: CGFloat
        let a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat

        init(radius r: CGFloat, smoothing s0: CGFloat, budget: CGFloat) {
            let radius = max(0, min(r, budget))
            self.radius = radius
            guard radius > 0 else {
                p = 0; a = 0; b = 0; c = 0; d = 0
                return
            }
            var s = max(0, s0)
            var p = (1 + s) * radius
            if p > budget {
                s = max(0, min(s, budget / radius - 1))
                p = min(p, budget)
            }
            func rad(_ deg: CGFloat) -> CGFloat { deg * .pi / 180 }
            let arcMeasure = 90 * (1 - s)
            let arc = sin(rad(arcMeasure / 2)) * radius * sqrt(2)
            let alpha = (90 - arcMeasure) / 2
            let p3p4 = radius * tan(rad(alpha / 2))
            let beta = 45 * s
            let c = p3p4 * cos(rad(beta))
            let d = c * tan(rad(beta))
            let b = max(0, (p - arc - c - d) / 3)
            self.p = p
            self.a = 2 * b
            self.b = b
            self.c = c
            self.d = d
        }

        func add(to path: inout Path, at k: Corner) {
            guard radius > 0 else {
                path.addLine(to: k.point)
                return
            }
            let start = k.at(-p, 0)
            path.addLine(to: start)
            let arcStart = k.at(-p + a + b + c, d)
            path.addCurve(to: arcStart, control1: k.at(-p + a, 0), control2: k.at(-p + a + b, 0))
            let center = k.at(-radius, radius)
            let arcEnd = k.at(-d, p - (a + b + c))
            let from = atan2(arcStart.y - center.y, arcStart.x - center.x)
            let to = atan2(arcEnd.y - center.y, arcEnd.x - center.x)
            // In a y-down space `clockwise: false` runs clockwise on screen, as the outline does.
            path.addArc(center: center, radius: radius, startAngle: .radians(Double(from)), endAngle: .radians(Double(to)), clockwise: false)
            path.addCurve(to: k.at(0, p), control1: k.at(0, p - a - b), control2: k.at(0, p - a))
        }
    }
}

extension GraineBubbleShape {
    /// A bubble's corners in reading terms, turned into physical ones for the layout direction.
    init(_ corners: ChatWindowRules.Corners, role: GraineRole, rightToLeft: Bool) {
        let leading = (top: CGFloat(corners.topLeading), bottom: CGFloat(corners.bottomLeading))
        let trailing = (top: CGFloat(corners.topTrailing), bottom: CGFloat(corners.bottomTrailing))
        let left = rightToLeft ? trailing : leading
        let right = rightToLeft ? leading : trailing
        var tail = Tail.none
        if corners.tail {
            // The speaker's side: trailing for the customer, leading for the agent.
            let speakerTrailing = role == .customer
            tail = speakerTrailing != rightToLeft ? .right : .left
        }
        self.init(
            topLeft: left.top, topRight: right.top, bottomLeft: left.bottom, bottomRight: right.bottom,
            smoothing: corners.continuous ? GraineBubbleShape.continuousSmoothing : 0, tail: tail
        )
    }
}

// MARK: - The wallpaper

/**
 * Behind the thread: one colour, a gradient top → bottom, or a colour with a
 * pattern over it in `patternColor` — dots 2 across on an 18-point grid (the
 * first centred 9 in), 1-wide grid lines at 9 + 18k, or 1-wide diagonals where
 * x + y is a multiple of 14. The pattern stands still while the messages
 * scroll (it is drawn behind the scroll view, not in it) and never mirrors
 * for right-to-left languages.
 */
struct GraineChatWallpaper: View {
    let wallpaper: GraineChatTokens.Wallpaper

    var body: some View {
        ZStack {
            if wallpaper.style == "gradient", let to = wallpaper.colorTo {
                LinearGradient(colors: [.graineHex(wallpaper.color), .graineHex(to)], startPoint: .top, endPoint: .bottom)
            } else {
                Color.graineHex(wallpaper.color)
            }
            if wallpaper.style == "pattern" && wallpaper.pattern != "none" {
                pattern
            }
        }
        .accessibilityHidden(true)
    }

    private var pattern: some View {
        let ink = Color.graineHex(wallpaper.patternColor)
        let kind = wallpaper.pattern
        return Canvas { context, size in
            switch kind {
            case "grid":
                var x: CGFloat = 9
                while x < size.width {
                    context.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height)), with: .color(ink))
                    x += 18
                }
                var y: CGFloat = 9
                while y < size.height {
                    context.fill(Path(CGRect(x: 0, y: y - 0.5, width: size.width, height: 1)), with: .color(ink))
                    y += 18
                }
            case "diagonal":
                var lines = Path()
                var k: CGFloat = 14
                while k < size.width + size.height {
                    lines.move(to: CGPoint(x: k, y: 0))
                    lines.addLine(to: CGPoint(x: k - size.height, y: size.height))
                    k += 14
                }
                context.stroke(lines, with: .color(ink), lineWidth: 1)
            default:
                var y: CGFloat = 9
                while y < size.height {
                    var x: CGFloat = 9
                    while x < size.width {
                        context.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)), with: .color(ink))
                        x += 18
                    }
                    y += 18
                }
            }
        }
        // A pattern is a texture, not reading matter: the same in every reading direction.
        .environment(\.layoutDirection, .leftToRight)
    }
}

// MARK: - The typing indicator

/**
 * While the agent works on a reply (DESIGN.md "Typing indicator"): three
 * 7-point dots fading 0.35 → 1 → 0.35 over 1200 ms, each 160 ms after the
 * last; or rising 4 points and back over 900 ms, 120 ms apart (`wave`); or
 * the words breathing between 0.55 and 1 over 1400 ms (`text`). Drawn from the
 * clock, still under Reduce Motion or a design with no motion.
 */
struct GraineChatTypingMarks: View {
    /// `dots`, `wave` or `text`.
    let style: String
    let color: Color
    let words: String
    let font: Font
    let still: Bool
    @State private var began = Date()

    var body: some View {
        Group {
            if still {
                frame(elapsed: nil)
            } else {
                TimelineView(.animation) { timeline in
                    frame(elapsed: timeline.date.timeIntervalSince(began) * 1000)
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// The breathing curve: 0 → 1 → 0 over `period`, eased, starting `delay` late.
    private func wave(_ elapsed: Double, period: Double, delay: Double) -> Double {
        let t = elapsed - delay
        guard t > 0 else { return 0 }
        let phase = t.truncatingRemainder(dividingBy: period) / period
        return CubicBezier.easeInOut(phase < 0.5 ? phase * 2 : 2 - phase * 2)
    }

    @ViewBuilder
    private func frame(elapsed: Double?) -> some View {
        switch style {
        case "text":
            Text(words)
                .font(font)
                .foregroundColor(color)
                .lineLimit(1)
                .opacity(elapsed.map { 0.55 + 0.45 * wave($0, period: 1400, delay: 0) } ?? 1)
        case "wave":
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(color).frame(width: 7, height: 7)
                        .offset(y: -4 * CGFloat(elapsed.map { wave($0, period: 900, delay: Double(i) * 120) } ?? 0))
                }
            }
            .frame(height: 11, alignment: .bottom)
        default:
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(color).frame(width: 7, height: 7)
                        .opacity(elapsed.map { 0.35 + 0.65 * wave($0, period: 1200, delay: Double(i) * 160) } ?? 0.6)
                }
            }
            .frame(height: 7)
        }
    }
}

// MARK: - The agent's words, formatted

/**
 * THE AGENT'S WORDS AS `chatMarkdown` PARSED THEM: paragraphs 6 apart, bold
 * at `weights.strong`, italics, code in the monospace a step smaller on a tint
 * of the bubble, links underlined in the side's link colour (a tap opens
 * http(s) in the browser and mailto/tel with the system), bullets "•" and
 * numbered items with their wrapped lines hanging under the words. Text
 * stays text: nothing here is HTML.
 */
struct GraineChatRichText: View {
    let blocks: [ChatBlock]
    let type: GraineType
    let tokens: GraineThemeTokens
    let ink: String
    let link: String
    /// The bubble's fill, for the code tint (the wallpaper's for a bare bubble).
    let fill: String

    var body: some View {
        let size = tokens.font.scale.body
        let weight = tokens.font.weights.body
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block.kind {
                case .paragraph:
                    line(block.spans)
                case .bullet:
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").font(type.body(size, weight)).foregroundColor(.graineHex(ink))
                        line(block.spans)
                    }
                case .number(let n):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(n).").font(type.body(size, weight)).foregroundColor(.graineHex(ink))
                        line(block.spans)
                    }
                }
            }
        }
        .tint(.graineHex(link))
    }

    private func line(_ spans: [ChatSpan]) -> some View {
        let size = tokens.font.scale.body
        let weight = tokens.font.weights.body
        return Text(attributed(spans))
            .tracking(type.bodyTracking(size))
            .lineSpacing(type.bodyLineSpacing(size: size, weight: weight, lineHeight: size * tokens.font.lineHeight.body))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func attributed(_ spans: [ChatSpan]) -> AttributedString {
        let f = tokens.font
        let codeFill = Color.graineHex(ChatInk.mix(fill, ink, 0.1))
        var out = AttributedString()
        for span in spans {
            var run = AttributedString(span.text)
            var font = span.code ? type.mono(f.scale.body - 1, f.weights.body) : type.body(f.scale.body, span.bold ? f.weights.strong : f.weights.body)
            if span.italic { font = font.italic() }
            run.font = font
            run.foregroundColor = .graineHex(ink)
            if span.code { run.backgroundColor = codeFill }
            if let address = span.link, let url = URL(string: address) {
                run.link = url
                run.foregroundColor = .graineHex(link)
                run[AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self] = .single
            }
            out.append(run)
        }
        return out
    }
}

/// The links in some formatted words, for a screen reader's actions.
func graineChatLinks(_ blocks: [ChatBlock]) -> [(label: String, url: URL)] {
    blocks.flatMap { $0.spans }.compactMap { span in
        span.link.flatMap { URL(string: $0) }.map { (span.text, $0) }
    }
}

// MARK: - A chip

/**
 * A starter or a quick reply (DESIGN.md "Chips"): `chips.height` high (it
 * grows with the text), 14 in from each side, `chips.radius`, its fill
 * (frosted with the chat's glass for `elevated`), outline and shadow; the
 * words at `scale.body − 1` in `weights.strong`, one line.
 */
struct GraineChatChip: View {
    let words: String
    let chips: GraineChatTokens.Chips
    let tokens: GraineThemeTokens
    let type: GraineType
    let glass: GraineThemeTokens.Glass?
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CGFloat(chips.radius), style: .continuous)
        let size = tokens.font.scale.body - 1
        return Button(action: action) {
            Text(words)
                .font(type.body(size, tokens.font.weights.strong))
                .tracking(type.bodyTracking(size))
                .foregroundColor(.graineHex(chips.text))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 14)
                .frame(minHeight: CGFloat(chips.height))
                .background(GraineSurfaceFill(
                    shape: shape, color: .graineHex(chips.fill), glass: chips.style == "elevated" ? glass : nil, scheme: tokens.scheme
                ))
                .overlay {
                    if let border = chips.border, chips.borderWidth > 0 {
                        shape.strokeBorder(Color.graineHex(border), lineWidth: CGFloat(chips.borderWidth))
                    }
                }
                .background(GraineShadowLayer(shape: shape, shadow: chips.shadow, outsideOnly: glass != nil && chips.style == "elevated"))
                .contentShape(shape)
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(words)
    }
}

/// Chips in rows that wrap, `spacing` apart both ways, each row pushed to `alignment`.
@available(iOS 16.0, *)
struct GraineChipFlow: Layout {
    var spacing: CGFloat
    var alignment: HorizontalAlignment = .trailing

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
            var x: CGFloat
            switch alignment {
            case .leading: x = bounds.minX
            case .center: x = bounds.minX + (bounds.width - row.width) / 2
            default: x = bounds.maxX - row.width
            }
            for index in row.items {
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                let w = min(size.width, bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: w, height: size.height))
                x += w + spacing
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

// MARK: - Cards

/**
 * A card in the chat (DESIGN.md "Cards"): `cards.radius`, its fill, a
 * `borderWidth` outline in `border` when `cards.border`, and `cards.shadow` —
 * or the design's hard offset when `cards.hard`.
 */
struct GraineChatCardSurface: ViewModifier {
    let tokens: GraineThemeTokens
    let cards: GraineChatTokens.Cards
    var fill: String? = nil

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: CGFloat(cards.radius), style: .continuous)
        return content
            .background(shape.fill(Color.graineHex(fill ?? tokens.colors.surfaceRaised)))
            .clipShape(shape)
            .overlay {
                if cards.border {
                    shape.strokeBorder(Color.graineHex(tokens.colors.border), lineWidth: CGFloat(tokens.shape.borderWidth))
                }
            }
            .background(GraineShadowLayer(
                shape: shape, shadow: cards.hard ? nil : cards.shadow,
                hardOffset: cards.hard ? tokens.elevation.hardOffset : nil, hardColor: .graineHex(tokens.colors.text)
            ))
    }
}

// MARK: - The rating card

/**
 * After the agent ends the conversation (DESIGN.md "Rating"): the question,
 * then thumbs (two round buttons), stars (five targets, filled up to the
 * choice) or faces (five round targets, the chosen one on a soft disc,
 * larger). The card's width and its choices' size come from the thread's
 * width (ChatWindowRules.ratingLayout): at full size — thumbs and faces 44,
 * stars 36 — wherever they fit, smaller together where even the whole thread
 * is too narrow, so a narrow phone never pushes a face out of the card. Once
 * chosen it stays drawn, nothing else can be chosen, and "Thanks for your
 * feedback" appears under it.
 */
struct GraineChatRatingCard: View {
    let tokens: GraineThemeTokens
    let chat: GraineChatTokens
    let type: GraineType
    /// The width the thread's rows have (inside its side padding): the card and its choices are sized from it.
    let thread: CGFloat
    let rating: GraineChatRating?
    let onRate: (Int) -> Void

    private var style: GraineChatRating.Style { GraineChatRating.Style(rawValue: chat.rating.style) ?? .thumbs }

    var body: some View {
        let t = tokens
        let c = t.colors
        let titleSize = min(t.font.scale.title, 16)
        let fit = ChatWindowRules.ratingLayout(style: style.rawValue, thread: Double(thread), padding: t.spacing.cardPadding)
        VStack(spacing: 8) {
            Text(chat.rating.prompt.isEmpty ? ChatRatings.defaultPrompt : chat.rating.prompt)
                .font(type.heading(titleSize, t.font.weights.title))
                .tracking(type.titleTracking(titleSize))
                .foregroundColor(.graineHex(c.text))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: CGFloat(fit.gap)) {
                ForEach(ChatRatings.choices(style), id: \.self) { value in choice(value, fit: fit) }
            }
            if rating != nil {
                Text(ChatRatings.thanks)
                    .font(type.body(t.font.scale.caption, t.font.weights.body))
                    .foregroundColor(.graineHex(c.textMuted))
                    .transition(.opacity)
            }
        }
        .padding(CGFloat(t.spacing.cardPadding))
        .frame(width: CGFloat(fit.width))
        .modifier(GraineChatCardSurface(tokens: t, cards: chat.cards))
        .accessibilityElement(children: .contain)
    }

    private func isChosen(_ value: Int) -> Bool {
        guard let r = rating, r.style == style else { return false }
        return r.value == value
    }

    @ViewBuilder
    private func choice(_ value: Int, fit: ChatWindowRules.RatingLayout) -> some View {
        let t = tokens
        let c = t.colors
        let chosen = isChosen(value)
        let label = ChatRatings.label(style, value: value)
        let size = CGFloat(fit.size)
        let glyph = CGFloat(fit.glyph)
        Button(action: { if rating == nil { onRate(value) } }) {
            Group {
                switch style {
                case .thumbs:
                    GraineIconView(
                        name: value == 1 ? .thumbUp : .thumbDown, style: t.icons.style, stroke: t.icons.stroke,
                        color: chosen ? .graineHex(c.onAccent) : .graineHex(c.text), size: glyph
                    )
                    .frame(width: size, height: size)
                    .background(Circle().fill(Color.graineHex(chosen ? c.accent : c.accentSoft)))
                case .stars:
                    star(filled: (rating?.value ?? 0) >= value && rating?.style == .stars, size: glyph)
                        .frame(width: size, height: size)
                case .emoji:
                    // A picture sized by the layout: a fixed size, never scaled with the system text size.
                    Text(ChatRatings.emoji[max(0, min(4, value - 1))])
                        .font(.system(size: glyph))
                        .scaleEffect(chosen ? 1.15 : 1)
                        .frame(width: size, height: size)
                        .background(Circle().fill(chosen ? Color.graineHex(c.accentSoft) : .clear))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        // Answered: nothing else can be chosen, and the choice stays drawn as it is — not dimmed as a disabled button.
        .allowsHitTesting(rating == nil)
        .accessibilityLabel(label)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    /// The star at `size` (28 at full size): filled in the accent up to the choice, stroked in the muted colour after it.
    private func star(filled: Bool, size: CGFloat) -> some View {
        let t = tokens
        let shape = GraineGlyphShape(segments: GlyphPath.cached(GraineIcons.paths(.star).body ?? "") ?? [])
        return ZStack {
            if filled {
                shape.fill(Color.graineHex(t.colors.accent))
            } else {
                shape.stroke(Color.graineHex(t.colors.textMuted), style: StrokeStyle(lineWidth: CGFloat(t.icons.stroke) * size / 24, lineJoin: .round))
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Scroll to the latest

/**
 * Scrolled up from the newest row: a pill centred above the composer — the
 * arrow, and "N new" once something has arrived since. A tap scrolls down.
 */
struct GraineChatScrollPill: View {
    let tokens: GraineThemeTokens
    let type: GraineType
    let shadow: GraineThemeTokens.Shadow?
    let unseen: Int
    let action: () -> Void

    var body: some View {
        let t = tokens
        let c = t.colors
        let capsule = Capsule(style: .continuous)
        return Button(action: action) {
            HStack(spacing: 6) {
                GraineIconView(name: .arrowDown, style: t.icons.style, stroke: t.icons.stroke, color: .graineHex(c.text), size: 16)
                if let words = ChatWindowRules.newCount(unseen) {
                    Text(words)
                        .font(type.body(t.font.scale.caption, t.font.weights.strong))
                        .foregroundColor(.graineHex(c.text))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, unseen > 0 ? 14 : 10)
            .frame(minWidth: 36, minHeight: 36)
            .background(capsule.fill(Color.graineHex(c.surfaceRaised)))
            .overlay(capsule.strokeBorder(Color.graineHex(c.border), lineWidth: CGFloat(max(1, t.shape.borderWidth))))
            .background(GraineShadowLayer(shape: capsule, shadow: shadow))
            .contentShape(capsule)
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel("Scroll to the latest message")
    }
}

// MARK: - The reconnect banner

/**
 * Calm, never red, never a modal (DESIGN.md "Reconnect banner"): a strip
 * under the header on `surfaceRaised` (frosted with the chat's glass), the
 * loader and "Reconnecting…", or a `warning` dot and "Offline · messages send
 * when you're back". Announced once, politely.
 */
struct GraineChatBanner: View {
    let tokens: GraineThemeTokens
    let type: GraineType
    let banner: ChatWindowRules.Banner
    let loader: GraineLoaderLook
    let glass: GraineThemeTokens.Glass?

    private var words: String {
        banner == .reconnecting ? (loader.text.reconnecting ?? "Reconnecting…") : "Offline · messages send when you're back"
    }

    var body: some View {
        let t = tokens
        let c = t.colors
        HStack(spacing: 6) {
            if banner == .reconnecting {
                GraineLoaderMark(look: loader, color: .graineHex(loader.color ?? c.accent), track: .graineHex(c.border), size: 12)
            } else {
                Circle().fill(Color.graineHex(c.warning)).frame(width: 6, height: 6)
            }
            Text(words)
                .font(type.body(t.font.scale.caption, t.font.weights.body))
                .foregroundColor(.graineHex(c.textMuted))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 28)
        .background(GraineSurfaceFill(shape: Rectangle(), color: .graineHex(c.surfaceRaised), glass: glass, scheme: t.scheme))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.graineHex(c.border)).frame(height: CGFloat(t.shape.borderWidth))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(words)
        .onAppear { UIAccessibility.post(notification: .announcement, argument: words) }
    }
}

extension GraineChatTokens.Glass {
    /// The chat's frost as the surface fill draws it.
    var surface: GraineThemeTokens.Glass { GraineThemeTokens.Glass(blur: blur, surfaceOpacity: opacity) }
}
#endif
