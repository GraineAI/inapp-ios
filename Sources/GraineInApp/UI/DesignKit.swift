#if os(iOS)
import SwiftUI
import UIKit

/*
 * THE DESIGN TOKENS, AS SWIFTUI DRAWS THEM — the pieces every surface shares:
 * type, motion, surfaces (glass included), shadows, window chrome, the
 * launcher glyph.
 *
 * Nothing here decides what a design looks like; contract/DESIGN.md does, and
 * the tokens carry it. This only turns a token into the SwiftUI value that
 * draws it, the same way for the bar, the components, the loader and the
 * launcher.
 */

// MARK: - Type

/// One of the text roles DESIGN.md names.
enum GraineTextRole {
    /// `font.heading` at `scale.title`, `weights.title`.
    case title
    /// `font.body` at `scale.body`, `weights.body`.
    case body
    /// `font.body` at `scale.body`, `weights.strong` — names, prices, buttons.
    case strong
    /// `font.body` at `scale.caption` — meta, status lines.
    case caption
    /// `font.body` at `scale.caption`, `weights.strong`.
    case captionStrong
}

/// The design's type, with the app's own font names and the faces the SDK loaded: what a role is drawn in.
struct GraineType {
    let font: GraineThemeTokens.Typography
    /// `GraineConfig.fonts`: design family → the name this app registered it under.
    let names: [String: String]
    /// GraineFontStore.faces: `family|weight` → the PostScript name of a face the SDK registered.
    var faces: [String: String] = [:]
    /// The system's text size, as a multiple of the default (Dynamic Type); 1 where a surface keeps its sizes fixed.
    var scale: Double = 1

    /// The same type at the system's text size (the chat window follows Dynamic Type).
    func scaled(_ factor: Double) -> GraineType {
        var copy = self
        copy.scale = factor
        return copy
    }

    func callAsFunction(_ role: GraineTextRole) -> Font {
        let spec = self.spec(role)
        return GraineTypeface.font(family: spec.family, size: spec.size, weight: spec.weight, names: names, faces: faces)
    }

    func size(_ role: GraineTextRole) -> CGFloat { CGFloat(spec(role).size) }

    /// Letter spacing in points (the tokens say em).
    func tracking(_ role: GraineTextRole) -> CGFloat {
        let em = role == .title ? font.letterSpacing.title : font.letterSpacing.body
        return CGFloat(em * spec(role).size)
    }

    /// Extra space between lines, from the line-height multiplier.
    func lineSpacing(_ role: GraineTextRole) -> CGFloat {
        let multiple = role == .title ? font.lineHeight.title : font.lineHeight.body
        return CGFloat(max(0, multiple - 1) * spec(role).size)
    }

    // The voice bar sets its own sizes (a 14-point name, a 13-point caption), so it asks by size and weight.

    /// The body family at `size` points and `weight`.
    func body(_ size: Double, _ weight: Int) -> Font {
        GraineTypeface.font(family: font.body, size: size * scale, weight: weight, names: names, faces: faces)
    }

    /// The heading family at `size` points and `weight`.
    func heading(_ size: Double, _ weight: Int) -> Font {
        GraineTypeface.font(family: font.heading, size: size * scale, weight: weight, names: names, faces: faces)
    }

    /// The platform's monospace at `size` points (code in the agent's words).
    func mono(_ size: Double, _ weight: Int) -> Font {
        .system(size: CGFloat(size * scale), weight: GraineTypeface.swiftUIWeight(weight), design: .monospaced)
    }

    /// `letterSpacing.body` (em) as points at `size`.
    func bodyTracking(_ size: Double) -> CGFloat { CGFloat(font.letterSpacing.body * size * scale) }

    /// `letterSpacing.title` (em) as points at `size`.
    func titleTracking(_ size: Double) -> CGFloat { CGFloat(font.letterSpacing.title * size * scale) }

    /// The gap that makes a body-family line `lineHeight` points tall, in the face it actually resolves to.
    func bodyLineSpacing(size: Double, weight: Int, lineHeight: Double) -> CGFloat {
        GraineTypeface.lineSpacing(family: font.body, size: size * scale, weight: weight, lineHeight: lineHeight * scale, names: names, faces: faces)
    }

    private func spec(_ role: GraineTextRole) -> (family: String, size: Double, weight: Int) {
        switch role {
        case .title: return (font.heading, font.scale.title, font.weights.title)
        case .body: return (font.body, font.scale.body, font.weights.body)
        case .strong: return (font.body, font.scale.body, font.weights.strong)
        case .caption: return (font.body, font.scale.caption, font.weights.body)
        case .captionStrong: return (font.body, font.scale.caption, font.weights.strong)
        }
    }
}

/**
 * THE DESIGN'S TYPEFACE, WHEREVER IT CAME FROM — OR THE SYSTEM FONT, SILENTLY.
 *
 * In order: a family the app maps in `GraineConfig.fonts` (the app's own file
 * wins, per DESIGN.md); the face the SDK downloaded and registered
 * (GraineFontStore); a family the app bundles under its own name; and
 * otherwise the system font at the weight — until a face arrives, and for
 * good if it never does. Never a crash, never a warning the customer could see.
 *
 * A face the SDK loaded IS its weight: it is asked for by its PostScript
 * name, with no weight trait on top — a bold face asked to be bold again is
 * drawn heavier than the brand chose. App font names are looked up once, since
 * views ask on every frame — so a font the app registers after the SDK first
 * drew with it is not picked up until the next launch.
 */
enum GraineTypeface {
    private static let lock = NSLock()
    private static var resolved: [String: String] = [:]
    private static var missing: Set<String> = []

    static func font(family: String, size: Double, weight: Int, names: [String: String], faces: [String: String] = [:]) -> Font {
        if let custom = uiFont(family: family, size: size, weight: weight, names: names, faces: faces) {
            return Font(custom as CTFont)
        }
        return .system(size: CGFloat(size), weight: swiftUIWeight(weight))
    }

    /// The design's font for this family and weight, or nil for the system font.
    static func uiFont(family: String, size: Double, weight: Int, names: [String: String], faces: [String: String] = [:]) -> UIFont? {
        guard !DesignRules.isSystemFamily(family) else { return nil }
        let wanted = family.trimmingCharacters(in: .whitespacesAndNewlines)
        if let mapped = names[wanted] ?? names[wanted.lowercased()] {
            return appFont(mapped, size: size, weight: weight)
        }
        if let key = GraineFonts.loadedKey(family: wanted, weight: weight), let postScript = faces[key],
           let loaded = UIFont(name: postScript, size: CGFloat(size)) {
            return loaded
        }
        return appFont(wanted, size: size, weight: weight)
    }

    /**
     * Extra space between lines so a line is `lineHeight` points tall in the
     * font this family and weight actually resolve to — the tokens and the
     * Garage give line heights in points, SwiftUI only takes the gap.
     */
    static func lineSpacing(
        family: String, size: Double, weight: Int, lineHeight: Double, names: [String: String], faces: [String: String]
    ) -> CGFloat {
        let font = uiFont(family: family, size: size, weight: weight, names: names, faces: faces)
            ?? UIFont.systemFont(ofSize: CGFloat(size), weight: uiWeight(weight))
        return max(0, CGFloat(lineHeight) - font.lineHeight)
    }

    /// A family (or face) the app installed, at the nearest weight it has; nil when it has none.
    private static func appFont(_ name: String, size: Double, weight: Int) -> UIFont? {
        guard let familyName = familyName(for: name) else { return nil }
        // The nearest face the family has for this weight; the family's regular if it has no weights.
        let descriptor = UIFontDescriptor(fontAttributes: [
            .family: familyName,
            .traits: [UIFontDescriptor.TraitKey.weight: uiWeight(weight)],
        ])
        let font = UIFont(descriptor: descriptor, size: CGFloat(size))
        if font.familyName == familyName { return font }
        return UIFont(name: name, size: CGFloat(size))
    }

    /// The installed family behind a family name or a face name, remembered either way.
    private static func familyName(for name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let hit = resolved[name] { return hit }
        if missing.contains(name) { return nil }
        var family: String?
        if !UIFont.fontNames(forFamilyName: name).isEmpty {
            family = name
        } else if let face = UIFont(name: name, size: 12) {
            family = face.familyName
        }
        if let family = family {
            resolved[name] = family
        } else {
            missing.insert(name)
        }
        return family
    }

    static func swiftUIWeight(_ css: Int) -> Font.Weight {
        let steps: [Font.Weight] = [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black]
        return steps[DesignRules.weightStep(css)]
    }

    static func uiWeight(_ css: Int) -> UIFont.Weight {
        let steps: [UIFont.Weight] = [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black]
        return steps[DesignRules.weightStep(css)]
    }
}

// MARK: - Motion

extension GraineThemeTokens.Motion {
    /**
     * The design's transition, or nil for none — `durationMs: 0`, easing
     * "none", or the customer's Reduce Motion, which always wins. `reduceMotion`
     * is SwiftUI's environment value; the UIKit setting is checked as well, so
     * a host that overrides the environment cannot override the customer.
     */
    func animation(reduceMotion: Bool) -> Animation? {
        let ms = effectiveDurationMs(reduceMotion: reduceMotion || UIAccessibility.isReduceMotionEnabled)
        guard ms > 0 else { return nil }
        let seconds = ms / 1000
        // The Garage's curves (its easingCss), so a surface arrives on the phone as it did in the preview.
        switch easing {
        case "linear": return .linear(duration: seconds)
        case "emphasized": return .timingCurve(0.05, 0.7, 0.1, 1, duration: seconds)
        // iOS 17's spring(duration:bounce:), in the terms iOS 15 has: damping is 1 − bounce.
        case "spring": return .spring(response: seconds, dampingFraction: max(0.3, 1 - bounce), blendDuration: 0)
        default: return .timingCurve(0.2, 0, 0, 1, duration: seconds)
        }
    }

    /// Reduce Motion as the SDK reads it: SwiftUI's environment, and UIKit's setting, which a host cannot override.
    static func reduced(_ environment: Bool) -> Bool {
        environment || UIAccessibility.isReduceMotionEnabled
    }
}

// MARK: - Surfaces and depth

/**
 * A surface: `surface` itself, or with `glass`, the surface at its opacity
 * over the system's blur (a material — UIVisualEffectView underneath) — the
 * app's own screen showing through, softened. iOS offers no public blur
 * radius, so `glass.blur` only decides whether there is one. The blur is
 * tinted for the design's own light or dark, not the device's: a dark design
 * on a light phone frosts dark.
 */
struct GraineSurfaceFill<S: Shape>: View {
    let shape: S
    let color: Color
    let glass: GraineThemeTokens.Glass?
    /// The design's scheme ("light"/"dark"); nil follows the device.
    var scheme: String? = nil

    var body: some View {
        if let glass = glass {
            ZStack {
                if glass.blur > 0 {
                    if let scheme = scheme {
                        shape.fill(.ultraThinMaterial).environment(\.colorScheme, scheme == "dark" ? .dark : .light)
                    } else {
                        shape.fill(.ultraThinMaterial)
                    }
                }
                shape.fill(color.opacity(glass.surfaceOpacity))
            }
        } else {
            shape.fill(color)
        }
    }
}

/// Everything but the shape: what a shadow is masked to, so a translucent surface never shows its own shadow through itself.
struct GraineOutside<S: Shape>: Shape {
    let shape: S

    func path(in rect: CGRect) -> Path {
        var path = Path(rect.insetBy(dx: -400, dy: -400))
        path.addPath(shape.path(in: rect))
        return path
    }
}

/**
 * A shadow drawn the way the tokens describe it — offset, blur, SPREAD,
 * opacity, colour — which `.shadow` cannot (it has no spread). Or the solid
 * offset copy in `colors.text` (`elevation.hardOffset`) that neo-brutalist
 * designs use instead. Put it behind the element with `.background`.
 */
struct GraineShadowLayer<S: Shape>: View {
    let shape: S
    let shadow: GraineThemeTokens.Shadow?
    var hardOffset: GraineThemeTokens.Offset? = nil
    var hardColor: Color = .black
    /// For a translucent element: draw only outside its outline.
    var outsideOnly = false

    var body: some View {
        if outsideOnly {
            layer.mask(GraineOutside(shape: shape).fill(style: FillStyle(eoFill: true)))
        } else {
            layer
        }
    }

    @ViewBuilder
    private var layer: some View {
        if let offset = hardOffset {
            shape.fill(hardColor).offset(x: CGFloat(offset.x), y: CGFloat(offset.y))
        } else if let s = shadow, s.opacity > 0 {
            shape
                .fill(Color.graineHex(s.color, fallback: .black))
                .padding(CGFloat(-s.spread))
                .offset(y: CGFloat(s.y))
                .blur(radius: CGFloat(s.blur / 2))   // CSS blur is twice the Gaussian's deviation
                .opacity(s.opacity)
        }
    }
}

/// A rectangle with each corner its own radius — a chat bubble's corner nearest the speaker is tighter. iOS 15 has no UnevenRoundedRectangle.
struct GraineCornerShape: Shape {
    var topLeading: CGFloat
    var topTrailing: CGFloat
    var bottomLeading: CGFloat
    var bottomTrailing: CGFloat

    func path(in rect: CGRect) -> Path {
        let limit = min(rect.width, rect.height) / 2
        let tl = min(max(0, topLeading), limit)
        let tr = min(max(0, topTrailing), limit)
        let bl = min(max(0, bottomLeading), limit)
        let br = min(max(0, bottomTrailing), limit)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr), radius: tr,
                 startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        p.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        p.addArc(center: CGPoint(x: rect.minX + tl, y: rect.minY + tl), radius: tl,
                 startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

// MARK: - Window chrome

/**
 * A WINDOW'S TITLE BAR (DESIGN.md "Window chrome"), drawn from
 * Core/WindowChrome.swift: `surfaceRaised` across the top of the surface with
 * a `borderWidth` outline in `border` below it, the three traffic lights at
 * the left, and the title centred on one line in the platform's monospace (SF
 * Mono) at caption size, lower case, in `textMuted`. The surface clips it to
 * its own top corners. `trailing` sits at the bar's right end: the chat
 * window's collapse chevron.
 */
struct GraineWindowTitleBar<Trailing: View>: View {
    let bar: WindowChrome.TitleBar
    let trailing: Trailing

    init(bar: WindowChrome.TitleBar, @ViewBuilder trailing: () -> Trailing) {
        self.bar = bar
        self.trailing = trailing()
    }

    var body: some View {
        ZStack {
            title
                .padding(.horizontal, CGFloat(bar.titleInset))
            lights
                .padding(.leading, CGFloat(bar.lightsInset))
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
        .frame(height: CGFloat(bar.height))
        .background(Color.graineHex(bar.fill))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.graineHex(bar.outline)).frame(height: CGFloat(bar.outlineWidth))
        }
    }

    private var lights: some View {
        HStack(spacing: CGFloat(bar.dotGap)) {
            ForEach(Array(bar.lights.enumerated()), id: \.offset) { _, hex in
                Circle().fill(Color.graineHex(hex)).frame(width: CGFloat(bar.dot), height: CGFloat(bar.dot))
            }
        }
        .accessibilityHidden(true)
    }

    /// The online dot (the chat window's, while online), then the title. No title: the lights alone.
    private var title: some View {
        HStack(spacing: CGFloat(WindowChrome.onlineGap)) {
            if let online = bar.onlineDot {
                Circle()
                    .fill(Color.graineHex(online))
                    .frame(width: CGFloat(WindowChrome.onlineDotSize), height: CGFloat(WindowChrome.onlineDotSize))
                    .accessibilityHidden(true)
            }
            if !bar.title.isEmpty {
                Text(bar.title)
                    .font(.system(size: CGFloat(bar.titleSize), weight: .regular, design: .monospaced))
                    .foregroundColor(.graineHex(bar.titleColor))
                    .lineLimit(1)
                    // The window's name — and, where the dot shows, what the dot says.
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityValue(bar.onlineDot == nil ? "" : "Online")
            }
        }
    }
}

extension GraineWindowTitleBar where Trailing == EmptyView {
    init(bar: WindowChrome.TitleBar) {
        self.init(bar: bar) { EmptyView() }
    }
}

/**
 * A SURFACE OPENING AS A WINDOW: the title bar above the content, the two
 * clipped together to the surface's own corners — so the bar takes the top
 * ones, and the outline and shadow the surface applies afterwards go round
 * both. Nil: the surface exactly as it was.
 */
struct GraineWindowed: ViewModifier {
    let bar: WindowChrome.TitleBar?
    /**
     * Whether VoiceOver reads the bar: yes where its title is the surface's
     * name (a component card's own title lives only there), no where it only
     * decorates (the caption card's "captions").
     */
    let spoken: Bool

    func body(content: Content) -> some View {
        if let bar = bar {
            VStack(spacing: 0) {
                GraineWindowTitleBar(bar: bar)
                    .accessibilityHidden(!spoken)
                content
            }
            .clipShape(RoundedRectangle(cornerRadius: CGFloat(bar.cornerRadius), style: .continuous))
        } else {
            content
        }
    }
}

// MARK: - The launcher glyph

/// A parsed glyph, fitted into the middle of its frame at 24 units to the side.
struct GraineGlyphShape: Shape {
    let segments: [GlyphSegment]

    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 24
        let ox = rect.midX - 12 * unit
        let oy = rect.midY - 12 * unit
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: ox + CGFloat(x) * unit, y: oy + CGFloat(y) * unit)
        }
        var path = Path()
        for segment in segments {
            switch segment {
            case let .move(x, y):
                path.move(to: point(x, y))
            case let .line(x, y):
                path.addLine(to: point(x, y))
            case let .cubic(x1, y1, x2, y2, x, y):
                path.addCurve(to: point(x, y), control1: point(x1, y1), control2: point(x2, y2))
            case .close:
                path.closeSubpath()
            }
        }
        return path
    }
}

/**
 * The design's glyph in one colour: stroked at `icons.stroke` (in the glyph's
 * own 24-unit scale, with round ends as the icon set draws them) or filled.
 * Nil segments — path data this parser cannot read — draw `fallback`.
 */
struct GraineGlyphView<Fallback: View>: View {
    let glyph: GraineThemeTokens.Glyph
    let stroke: Double
    let color: Color
    let size: CGFloat
    let fallback: Fallback

    var body: some View {
        if let segments = GlyphPath.cached(glyph.path) {
            let shape = GraineGlyphShape(segments: segments)
            Group {
                if glyph.stroke {
                    shape.stroke(color, style: StrokeStyle(
                        lineWidth: CGFloat(stroke) * size / 24, lineCap: .round, lineJoin: .round
                    ))
                } else {
                    shape.fill(color)
                }
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        } else {
            fallback
        }
    }
}

// MARK: - The SDK's own icons

/**
 * One of the SDK's own icons, drawn from its path data in the design's icon
 * style (DESIGN.md "Icons", Core/Icons.swift): the body filled or not, then
 * stroked; the lines only ever stroked; round ends, or square ones with
 * mitred corners for `sharp`. Widths are in the icon's 24-unit scale, as the
 * Garage's SVG draws them. The same path data on every platform — not an SF
 * Symbol that is only nearly the same drawing.
 */
struct GraineIconView: View {
    let name: GraineIconName
    let style: String
    let stroke: Double
    let color: Color
    var size: CGFloat = CGFloat(VoiceBar.icon)
    /// Turned half a circle — the chat header's chevron, which points up as drawn.
    var flipped = false

    var body: some View {
        let icon = GraineIcons.paths(name)
        let paint = GraineIcons.paint(style: style, stroke: stroke)
        let unit = size / 24
        ZStack {
            if let data = icon.body, let segments = GlyphPath.cached(data) {
                let shape = GraineGlyphShape(segments: segments)
                if paint.bodyFill > 0 {
                    shape.fill(color.opacity(paint.bodyFill))
                }
                shape.stroke(color, style: line(paint, width: paint.bodyStroke * Double(unit)))
            }
            if let data = icon.lines, let segments = GlyphPath.cached(data) {
                GraineGlyphShape(segments: segments).stroke(color, style: line(paint, width: paint.linesStroke * Double(unit)))
            }
        }
        .frame(width: size, height: size)
        .rotationEffect(flipped ? .degrees(180) : .zero)
        .accessibilityHidden(true)
    }

    /// SVG's own miter limit (4), so a `sharp` corner is cut where the Garage's is.
    private func line(_ paint: GraineIcons.Paint, width: Double) -> StrokeStyle {
        StrokeStyle(
            lineWidth: CGFloat(width),
            lineCap: paint.square ? .square : .round,
            lineJoin: paint.square ? .miter : .round,
            miterLimit: 4
        )
    }
}
#endif
