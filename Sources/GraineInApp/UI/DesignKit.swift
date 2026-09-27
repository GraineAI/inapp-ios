#if os(iOS)
import SwiftUI
import UIKit

/*
 * THE DESIGN TOKENS, AS SWIFTUI DRAWS THEM — the pieces every surface shares:
 * type, motion, surfaces (glass included), shadows, the launcher glyph.
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

/// The design's type, with the app's own font names: what a role is drawn in.
struct GraineType {
    let font: GraineThemeTokens.Typography
    /// `GraineConfig.fonts`: design family → the name this app registered it under.
    let names: [String: String]

    func callAsFunction(_ role: GraineTextRole) -> Font {
        let spec = self.spec(role)
        return GraineTypeface.font(family: spec.family, size: spec.size, weight: spec.weight, names: names)
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
 * A FAMILY THE APP BUNDLES, OR THE SYSTEM FONT — SILENTLY. The dashboard offers
 * families from Google Fonts; a phone has only what the app shipped. So a
 * family is looked up (through `GraineConfig.fonts` first, then by its own
 * name), and anything that does not resolve is the system font: never a crash,
 * never a warning the customer could see. Each name is looked up once, since
 * views ask on every frame — so a font the app registers after the SDK first
 * drew with it is not picked up until the next launch.
 */
enum GraineTypeface {
    private static let lock = NSLock()
    private static var resolved: [String: String] = [:]
    private static var missing: Set<String> = []

    static func font(family: String, size: Double, weight: Int, names: [String: String]) -> Font {
        if let custom = uiFont(family: family, size: size, weight: weight, names: names) {
            return Font(custom as CTFont)
        }
        return .system(size: CGFloat(size), weight: swiftUIWeight(weight))
    }

    /// The app's font for this family and weight, or nil for the system font.
    static func uiFont(family: String, size: Double, weight: Int, names: [String: String]) -> UIFont? {
        guard !DesignRules.isSystemFamily(family) else { return nil }
        let wanted = family.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = names[wanted] ?? names[wanted.lowercased()] ?? wanted
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
        switch easing {
        case "linear": return .linear(duration: seconds)
        case "emphasized": return .timingCurve(0.2, 0, 0, 1, duration: seconds)
        // iOS 17's spring(duration:bounce:), in the terms iOS 15 has: damping is 1 − bounce.
        case "spring": return .spring(response: seconds, dampingFraction: max(0.3, 1 - bounce), blendDuration: 0)
        default: return .easeInOut(duration: seconds)
        }
    }
}

// MARK: - Surfaces and depth

/**
 * A surface: `surface` itself, or with `glass`, the surface at its opacity
 * over the system's blur — the app's own screen showing through, softened.
 */
struct GraineSurfaceFill<S: Shape>: View {
    let shape: S
    let color: Color
    let glass: GraineThemeTokens.Glass?

    var body: some View {
        if let glass = glass {
            ZStack {
                if glass.blur > 0 { shape.fill(.ultraThinMaterial) }
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
 * The bar's controls as SF Symbols in the design's icon treatment: outline
 * symbols for "outline" and "sharp", their filled variants for "filled" and
 * "duotone", the weight following `icons.stroke`.
 */
enum GraineIcon {
    static func name(_ base: String, style: String) -> String {
        style == "filled" || style == "duotone" ? base + ".fill" : base
    }

    static func weight(stroke: Double) -> Font.Weight {
        switch stroke {
        case ..<1.25: return .light
        case ..<1.75: return .regular
        case ..<2.25: return .medium
        case ..<2.75: return .semibold
        default: return .bold
        }
    }
}
#endif
