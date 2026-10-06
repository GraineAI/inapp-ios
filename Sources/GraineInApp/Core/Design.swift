import Foundation

/*
 * THE BRAND'S DESIGN, AS THE SESSION DELIVERS IT — read, never resolved.
 *
 * The brand picks a design in the dashboard: a philosophy and a few knobs.
 * The server resolves that into two complete sets of tokens, light and dark,
 * and the session carries them beside `appearance`:
 *
 *   "design": { "config": { "preset": …, "scheme": "auto", … },
 *               "light":  { ThemeTokens },
 *               "dark":   { ThemeTokens } }
 *
 * This file only PARSES those tokens and picks a set. It never knows what a
 * philosophy is: a new one reaches this SDK as tokens, with no release. The
 * rendering contract — which token draws which element — is contract/DESIGN.md,
 * the same document the web, React Native, Android and Flutter SDKs follow.
 *
 * NOTHING IS TRUSTED, AND NOTHING THROWS. Unknown keys are ignored. A value
 * that is missing or malformed falls back to Graine Classic's (the look every
 * widget had before designs), except the colours: a scheme without a complete
 * set of colours is not a design, and the whole design is nil — which means
 * the SDK keeps drawing from `appearance` exactly as it did before.
 *
 * Pure: Foundation only, so `swift test` proves it against contract/design.json.
 */

/// Which of the design's two sets to draw: the brand's fixed choice, or "auto" (the device's).
public enum GraineDesignScheme: String, Sendable {
    case auto
    case light
    case dark
}

/// The floating launcher's outline.
public enum GraineLauncherShape: String, Sendable {
    case circle
    case squircle
    case roundedSquare = "rounded-square"
    case square
    case pill
}

/// How chat messages sit on the page.
public enum GraineBubbleStyle: String, Sendable {
    /// Each speaker's messages on their own colour.
    case filled
    /// Both transparent, outlined: the customer's in the accent, the agent's in the border colour.
    case outline
    /// The agent's are plain text on the page; the customer's sit on the soft accent.
    case minimal
}

/**
 * How a surface that holds content is framed (contract/DESIGN.md "Window
 * chrome"). A value this build does not know, or none at all (an older
 * server), is `none`.
 */
public enum GraineDesignChrome: String, Sendable {
    /// A plain surface.
    case none
    /// The chat window, the caption card and every component card open as desktop windows:
    /// a title bar with traffic lights and a monospaced, lower-case title.
    case window
}

/// One scheme's tokens: flat numbers and #RRGGBB strings. Lengths are points.
public struct GraineThemeTokens: Equatable, Sendable {

    public struct Colors: Equatable, Sendable {
        /// Behind everything in the chat window.
        public let background: String
        /// The voice bar, the chat header, sheets.
        public let surface: String
        /// Cards, the composer field.
        public let surfaceRaised: String
        public let text: String
        /// Secondary text, captions, status lines.
        public let textMuted: String
        /// Hairlines and outlines.
        public let border: String
        /// Primary buttons, the launcher, the send button.
        public let accent: String
        /// What sits on the accent.
        public let onAccent: String
        /// Chips, selected rows, the focus halo.
        public let accentSoft: String
        public let success: String
        public let warning: String
        /// The end-call button.
        public let danger: String
        public let userBubble: String
        public let userBubbleText: String
        public let agentBubble: String
        public let agentBubbleText: String
        /// Behind a modal sheet, at 40% opacity.
        public let scrim: String
    }

    public struct Typography: Equatable, Sendable {
        public struct Scale: Equatable, Sendable {
            public let caption: Double
            public let body: Double
            public let title: Double
            public let display: Double
        }

        public struct Weights: Equatable, Sendable {
            /// CSS weights, 100–900.
            public let body: Int
            public let strong: Int
            public let title: Int
        }

        public struct Pair: Equatable, Sendable {
            public let body: Double
            public let title: Double
        }

        /// "system" is the platform's UI font; anything else is a family the app may or may not bundle.
        public let body: String
        public let heading: String
        public let scale: Scale
        public let weights: Weights
        /// In em: multiply by the size for points.
        public let letterSpacing: Pair
        /// Multipliers of the size.
        public let lineHeight: Pair
    }

    public struct Radius: Equatable, Sendable {
        public let sm: Double
        public let md: Double
        public let lg: Double
        public let xl: Double
    }

    public struct Shape: Equatable, Sendable {
        public let radius: Radius
        /// The width of every outline.
        public let borderWidth: Double
        public let launcher: GraineLauncherShape
    }

    public struct Spacing: Equatable, Sendable {
        public let unit: Double
        public let cardPadding: Double
        public let gap: Double
    }

    public struct Shadow: Equatable, Sendable {
        public let y: Double
        public let blur: Double
        public let spread: Double
        /// 0–1, applied to `color`.
        public let opacity: Double
        public let color: String
    }

    /// A solid offset shadow, drawn in `colors.text`.
    public struct Offset: Equatable, Sendable {
        public let x: Double
        public let y: Double
    }

    public struct Elevation: Equatable, Sendable {
        public let card: Shadow?
        public let floating: Shadow?
        public let hardOffset: Offset?
    }

    public struct Motion: Equatable, Sendable {
        /// 0 means no transitions at all.
        public let durationMs: Double
        /// "standard", "emphasized", "spring", "linear" or "none" — or a newer word, drawn as "standard".
        public let easing: String
        /// 0–1: how much a spring overshoots.
        public let bounce: Double

        /**
         * How long a transition runs here, in milliseconds; 0 for none. The
         * operating system's Reduce Motion always wins over the brand's choice:
         * somebody who switched it on gets no movement from us, whatever the design.
         */
        public func effectiveDurationMs(reduceMotion: Bool) -> Double {
            if reduceMotion || easing == "none" { return 0 }
            return max(0, durationMs)
        }
    }

    /// A 24×24 SVG path. `stroke` glyphs are drawn with `icons.stroke`; the rest are filled.
    public struct Glyph: Equatable, Sendable {
        public let id: String
        public let path: String
        public let stroke: Bool
    }

    public struct Icons: Equatable, Sendable {
        /// "outline", "filled", "duotone" or "sharp" — for the SDK's own icons.
        public let style: String
        public let stroke: Double
        /// Nil when the launcher shows the brand's logo.
        public let launcher: Glyph?
    }

    /// Translucent surfaces: `surface` at `surfaceOpacity` over a background blurred by `blur`.
    public struct Glass: Equatable, Sendable {
        public let blur: Double
        public let surfaceOpacity: Double
    }

    public let preset: String
    /// "light" or "dark": which of the design's two sets this is.
    public let scheme: String
    public let colors: Colors
    public let font: Typography
    public let shape: Shape
    public let spacing: Spacing
    public let elevation: Elevation
    public let motion: Motion
    public let icons: Icons
    public let glass: Glass?
    public let bubbles: GraineBubbleStyle
    /// `window`: the chat window, the caption card and every component card open as desktop windows.
    public let chrome: GraineDesignChrome

    /**
     * The launcher glyph as an image, for a host that draws its own launcher
     * and would rather not parse SVG. `points` × `scale` is the physical size,
     * so the picture is sharp on every screen. Nil when the brand chose its logo.
     */
    public func launcherGlyphUrl(origin: String?, points: Double, scale: Double) -> String? {
        guard let glyph = icons.launcher else { return nil }
        return GraineGlyph.url(origin: origin, id: glyph.id, color: colors.onAccent, sizePx: points * scale, stroke: icons.stroke)
    }
}

/// Both schemes and the brand's choice between them: the session's `design`.
public struct GraineDesign: Equatable, Sendable {
    /// `config.scheme`: a fixed scheme, or "auto" to follow the device.
    public let scheme: GraineDesignScheme
    /// `config.preset` — informational: the tokens are already resolved.
    public let preset: String?
    public let light: GraineThemeTokens
    public let dark: GraineThemeTokens

    init(scheme: GraineDesignScheme, preset: String?, light: GraineThemeTokens, dark: GraineThemeTokens) {
        self.scheme = scheme
        self.preset = preset
        self.light = light
        self.dark = dark
    }

    /**
     * Which tokens to draw: the brand's fixed scheme, else the device's current
     * appearance — and light when the device has not said (nil). Ask again when
     * the device switches.
     */
    public func tokens(deviceDark: Bool?) -> GraineThemeTokens {
        switch scheme {
        case .light: return light
        case .dark: return dark
        case .auto: return deviceDark == true ? dark : light
        }
    }

    /**
     * The session's `design`, or nil when there is none worth drawing — absent
     * (an older server), not an object, or either scheme without a complete set
     * of colours. Nil is not an error: it means "draw from appearance, as before".
     */
    public static func parse(_ raw: Any?) -> GraineDesign? {
        guard let d = JSON.unwrap(raw) as? [String: Any] else { return nil }
        guard let light = DesignTokens.parse(d["light"], scheme: "light"),
              let dark = DesignTokens.parse(d["dark"], scheme: "dark") else { return nil }
        let config = JSON.unwrap(d["config"]) as? [String: Any] ?? [:]
        let scheme = GraineDesignScheme(rawValue: JSON.jsStringOrEmpty(config["scheme"])
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .auto
        let preset = JSON.nonEmpty(config["preset"]).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return GraineDesign(scheme: scheme, preset: preset?.isEmpty == false ? preset : nil, light: light, dark: dark)
    }
}

/**
 * THE LAUNCHER GLYPH AS AN IMAGE — for an app that cannot draw SVG path data.
 * Built exactly as theme.ts `glyphUrl()` builds it (contract/design.json holds
 * the expected URLs): the image is cached for a year, so a URL that differs by
 * one character is a second copy of the same picture in every CDN.
 */
public enum GraineGlyph {
    /// Bumped by the server whenever a glyph's drawing changes, so a year-cached image never shows an old one.
    public static let assetVersion = 2

    /**
     * - Parameters:
     *   - origin: where Graine is served; "https://www.graine.ai" when empty.
     *   - sizePx: PHYSICAL pixels (points × screen scale), clamped to 16–512.
     *   - stroke: clamped to 0.5–4, in quarter steps.
     */
    public static func url(origin: String?, id: String, color: String, sizePx: Double, stroke: Double = 2) -> String {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hex = DesignTokens.hex(color) ?? "#FFFFFF"
        // `Number(size) || 96`: NaN and 0 are "not given"; anything else is clamped.
        let wanted = sizePx.isNaN || sizePx == 0 ? 96 : sizePx
        let size = Int(JSON.jsRound(max(16, min(512, wanted))))
        let givenStroke = stroke.isNaN || stroke == 0 ? 2 : stroke
        let width = JSON.jsRound(max(0.5, min(4, givenStroke)) * 4) / 4
        let trimmed = (origin ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let base = GraineProtocol.trimTrailingSlashes(trimmed.isEmpty ? Appearance.defaultOrigin : trimmed)
        return base + "/api/embed/glyph?id=" + GraineProtocol.encode(key)
            + "&c=" + String(hex.dropFirst())
            + "&s=" + String(size)
            + "&w=" + JSON.jsNumberText(width)
            + "&v=" + String(assetVersion)
    }
}

/**
 * The drawing rules of contract/DESIGN.md that are arithmetic rather than
 * pixels — kept here, pure, so they are proven on a Mac and every view reads
 * the same answer.
 */
enum DesignRules {

    // MARK: - Chat bubbles

    /// One message's colours. A nil fill is no bubble; a nil outline is no outline.
    struct Bubble: Equatable {
        let fill: String?
        let text: String
        let outline: String?
    }

    static func bubble(_ tokens: GraineThemeTokens, role: GraineRole) -> Bubble {
        let c = tokens.colors
        switch (tokens.bubbles, role) {
        case (.filled, .customer): return Bubble(fill: c.userBubble, text: c.userBubbleText, outline: nil)
        case (.filled, .agent): return Bubble(fill: c.agentBubble, text: c.agentBubbleText, outline: nil)
        case (.outline, .customer): return Bubble(fill: nil, text: c.text, outline: c.accent)
        case (.outline, .agent): return Bubble(fill: nil, text: c.text, outline: c.border)
        case (.minimal, .customer): return Bubble(fill: c.accentSoft, text: c.text, outline: nil)
        case (.minimal, .agent): return Bubble(fill: nil, text: c.text, outline: nil)
        }
    }

    // MARK: - The launcher

    /// The launcher's height (and a round launcher's width), in points.
    static let launcherSize = 56.0
    /// The glyph (and a letter), as a share of the launcher's height. A logo is fitted by `logoBox` instead.
    static let launcherGlyphShare = 0.46
    /// A squircle's continuous corners, as a share of its size.
    static let squircleShare = 0.30

    /// The corner radius for a launcher `size` points high.
    static func launcherCornerRadius(_ shape: GraineLauncherShape, size: Double, radius: GraineThemeTokens.Radius) -> Double {
        switch shape {
        case .circle, .pill: return size / 2
        case .squircle: return size * squircleShare
        case .roundedSquare: return min(radius.lg, size / 2)
        case .square: return min(radius.sm, size / 2)
        }
    }

    // MARK: - The brand's logo

    /**
     * THE BRAND'S LOGO, WHOLE (contract/DESIGN.md "The brand's logo"). It was
     * drawn to fill the circle, and a wordmark lost both ends, a square logo
     * its corners. It is fitted instead — proportions kept, centred, never
     * cropped — into the largest square its shape holds: 70% of the size for a
     * circle, a squircle and a pill's height (the largest square a circle
     * holds is 70.7% of it), 80% for a rounded or square shape. Rounded down,
     * never up: a box rounded up pokes its corners past the circle.
     */
    static func logoBox(_ shape: GraineLauncherShape, size: Double) -> Double {
        let share = shape == .roundedSquare || shape == .square ? 0.8 : 0.7
        return max(1, (size * share).rounded(.down))
    }

    /// The white plate's fill.
    static let logoPlateWhite = "#FFFFFF"
    /// A pill's label on the white plate: what reads on white.
    static let logoPlateLabel = "#101318"

    /// The fill and outline under a logo. A nil outline is none.
    struct LogoPlateLook: Equatable {
        struct Outline: Equatable {
            let width: Double
            let color: String
        }

        let fill: String
        let outline: Outline?
    }

    /**
     * The plate under the logo: the accent with no outline, or white with a
     * `max(1, borderWidth)` outline in `border` — a white plate on a white bar
     * needs its hairline to be seen at all. A hard offset keeps its own
     * `colors.text` outline instead; the views decide that.
     */
    static func logoPlateLook(_ plate: GraineLogoPlate, accent: String, border: String, borderWidth: Double = 1) -> LogoPlateLook {
        switch plate {
        case .white: return LogoPlateLook(fill: logoPlateWhite, outline: .init(width: max(1, borderWidth), color: border))
        case .accent: return LogoPlateLook(fill: accent, outline: nil)
        }
    }

    // MARK: - Components

    /**
     * THE COMPONENT'S OWN CHOICES WIN; THE DESIGN FILLS IN THE REST. A platform
     * chosen on the component brings that platform's shapes, as it always has.
     * Under "auto" the design supplies them — card corners `radius.lg`, buttons
     * `radius.md`, chips `radius.sm`, titles at `weights.title` — where the
     * phone's own grammar used to. Without a design, nothing changes.
     */
    static func widgetGrammar(_ look: WidgetLook, tokens: GraineThemeTokens?) -> WidgetGrammar {
        let base = WidgetRules.grammar(for: look)
        guard let t = tokens, look.platform == .auto else { return base }
        return WidgetGrammar(
            radius: t.shape.radius.lg,
            chipRadius: t.shape.radius.sm,
            buttonRadius: t.shape.radius.md,
            pillButtons: false,
            separatorInset: base.separatorInset,
            grabberWidth: base.grabberWidth,
            grabberHeight: base.grabberHeight,
            titleWeight: t.font.weights.title,
            padBoost: 0,
            chipOutlined: false
        )
    }

    /// The card's corners: the component's radius, else an explicit platform's, else the design's, else Appearance's.
    static func widgetRadius(_ look: WidgetLook, tokens: GraineThemeTokens?, appearanceRadius: Double) -> Double {
        if let own = look.radius { return own }
        if look.platform != .auto || tokens != nil { return widgetGrammar(look, tokens: tokens).radius }
        return appearanceRadius
    }

    /**
     * The accent and what reads on it. An accent chosen on the component brings
     * its own readable label (the luminance rule, as before); the design's
     * accent comes with the design's `onAccent`, already checked for contrast
     * on the server.
     */
    static func widgetAccent(
        _ look: WidgetLook, tokens: GraineThemeTokens?, appearanceAccent: String, appearanceOnAccent: String
    ) -> (accent: String, onAccent: String) {
        if let own = look.accent { return (own, Appearance.onAccent(own)) }
        if let t = tokens { return (t.colors.accent, t.colors.onAccent) }
        return (appearanceAccent, appearanceOnAccent)
    }

    // MARK: - Type

    /// A CSS weight as one of the nine steps every platform names (0 = 100 … 8 = 900).
    static func weightStep(_ cssWeight: Int) -> Int {
        let hundreds = Int(JSON.jsRound(Double(cssWeight) / 100))
        return min(9, max(1, hundreds)) - 1
    }

    /// Whether a family means the platform's own font.
    static func isSystemFamily(_ family: String) -> Bool {
        let f = family.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return f.isEmpty || f == "system"
    }
}

/// Parsing one scheme's tokens: lenient everywhere except the colours.
enum DesignTokens {

    static let colorKeys = [
        "background", "surface", "surfaceRaised", "text", "textMuted", "border", "accent", "onAccent", "accentSoft",
        "success", "warning", "danger", "userBubble", "userBubbleText", "agentBubble", "agentBubbleText", "scrim",
    ]

    /**
     * Graine Classic's values: what a missing or malformed token becomes. They
     * are the look every widget had before designs existed, so a partial token
     * set degrades toward "as it was", never toward something new.
     */
    enum Fallback {
        static let font = GraineThemeTokens.Typography(
            body: "system", heading: "system",
            scale: .init(caption: 12, body: 15, title: 17, display: 22),
            weights: .init(body: 400, strong: 600, title: 600),
            letterSpacing: .init(body: 0, title: -0.01),
            lineHeight: .init(body: 1.45, title: 1.25)
        )
        static let radius = GraineThemeTokens.Radius(sm: 8, md: 12, lg: 18, xl: 24)
        static let borderWidth = 1.0
        static let spacing = GraineThemeTokens.Spacing(unit: 4, cardPadding: 14, gap: 10)
        static let card = GraineThemeTokens.Shadow(y: 2, blur: 8, spread: 0, opacity: 0.08, color: "#000000")
        static let floating = GraineThemeTokens.Shadow(y: 8, blur: 24, spread: 0, opacity: 0.16, color: "#000000")
        static let motion = GraineThemeTokens.Motion(durationMs: 200, easing: "standard", bounce: 0)
        static let glyph = GraineThemeTokens.Glyph(
            id: "waveform",
            path: "M2 13a2 2 0 0 0 2 -2V7a2 2 0 0 1 4 0v13a2 2 0 0 0 4 0V4a2 2 0 0 1 4 0v13a2 2 0 0 0 4 0v-4a2 2 0 0 1 2 -2",
            stroke: true
        )
        static let glass = GraineThemeTokens.Glass(blur: 20, surfaceOpacity: 0.72)
    }

    /// One scheme, or nil when it is not an object or its colours are incomplete.
    static func parse(_ raw: Any?, scheme: String) -> GraineThemeTokens? {
        guard let t = JSON.unwrap(raw) as? [String: Any] else { return nil }
        guard let colors = self.colors(t["colors"]) else { return nil }
        return GraineThemeTokens(
            preset: JSON.nonEmpty(t["preset"]) ?? "",
            scheme: scheme,
            colors: colors,
            font: font(t["font"]),
            shape: shape(t["shape"]),
            spacing: spacing(t["spacing"]),
            elevation: elevation(t["elevation"]),
            motion: motion(t["motion"]),
            icons: icons(t["icons"]),
            glass: glass(t["glass"]),
            bubbles: GraineBubbleStyle(rawValue: word(t["bubbles"])) ?? .filled,
            // Absent (an older server) or a kind of frame this build does not know: a plain surface.
            chrome: GraineDesignChrome(rawValue: word(t["chrome"])) ?? .none
        )
    }

    // MARK: - Groups

    private static func colors(_ raw: Any?) -> GraineThemeTokens.Colors? {
        guard let c = JSON.unwrap(raw) as? [String: Any] else { return nil }
        var v: [String: String] = [:]
        for key in colorKeys {
            guard let hex = hex(c[key]) else { return nil }
            v[key] = hex
        }
        return GraineThemeTokens.Colors(
            background: v["background"]!, surface: v["surface"]!, surfaceRaised: v["surfaceRaised"]!,
            text: v["text"]!, textMuted: v["textMuted"]!, border: v["border"]!,
            accent: v["accent"]!, onAccent: v["onAccent"]!, accentSoft: v["accentSoft"]!,
            success: v["success"]!, warning: v["warning"]!, danger: v["danger"]!,
            userBubble: v["userBubble"]!, userBubbleText: v["userBubbleText"]!,
            agentBubble: v["agentBubble"]!, agentBubbleText: v["agentBubbleText"]!,
            scrim: v["scrim"]!
        )
    }

    private static func font(_ raw: Any?) -> GraineThemeTokens.Typography {
        let d = Fallback.font
        guard let f = JSON.unwrap(raw) as? [String: Any] else { return d }
        let scale = object(f["scale"])
        let weights = object(f["weights"])
        let spacing = object(f["letterSpacing"])
        let line = object(f["lineHeight"])
        return GraineThemeTokens.Typography(
            body: family(f["body"]) ?? d.body,
            heading: family(f["heading"]) ?? d.heading,
            scale: .init(
                caption: positive(scale["caption"]) ?? d.scale.caption,
                body: positive(scale["body"]) ?? d.scale.body,
                title: positive(scale["title"]) ?? d.scale.title,
                display: positive(scale["display"]) ?? d.scale.display
            ),
            weights: .init(
                body: weight(weights["body"]) ?? d.weights.body,
                strong: weight(weights["strong"]) ?? d.weights.strong,
                title: weight(weights["title"]) ?? d.weights.title
            ),
            letterSpacing: .init(
                body: finite(spacing["body"]).map { clamp($0, -0.5, 0.5) } ?? d.letterSpacing.body,
                title: finite(spacing["title"]).map { clamp($0, -0.5, 0.5) } ?? d.letterSpacing.title
            ),
            lineHeight: .init(
                body: positive(line["body"]) ?? d.lineHeight.body,
                title: positive(line["title"]) ?? d.lineHeight.title
            )
        )
    }

    private static func shape(_ raw: Any?) -> GraineThemeTokens.Shape {
        let s = object(raw)
        let r = object(s["radius"])
        let d = Fallback.radius
        return GraineThemeTokens.Shape(
            radius: .init(
                sm: length(r["sm"]) ?? d.sm,
                md: length(r["md"]) ?? d.md,
                lg: length(r["lg"]) ?? d.lg,
                xl: length(r["xl"]) ?? d.xl
            ),
            borderWidth: finite(s["borderWidth"]).map { clamp($0, 0, 8) } ?? Fallback.borderWidth,
            launcher: GraineLauncherShape(rawValue: word(s["launcher"])) ?? .circle
        )
    }

    private static func spacing(_ raw: Any?) -> GraineThemeTokens.Spacing {
        let s = object(raw)
        let d = Fallback.spacing
        return GraineThemeTokens.Spacing(
            unit: length(s["unit"]) ?? d.unit,
            cardPadding: length(s["cardPadding"]) ?? d.cardPadding,
            gap: length(s["gap"]) ?? d.gap
        )
    }

    /// Absent → Classic's; null → no shadow; anything else malformed → no shadow.
    private static func elevation(_ raw: Any?) -> GraineThemeTokens.Elevation {
        guard let e = JSON.unwrap(raw) as? [String: Any] else {
            return GraineThemeTokens.Elevation(card: Fallback.card, floating: Fallback.floating, hardOffset: nil)
        }
        var hard: GraineThemeTokens.Offset?
        if let o = JSON.unwrap(e["hardOffset"]) as? [String: Any], let x = finite(o["x"]), let y = finite(o["y"]) {
            hard = GraineThemeTokens.Offset(x: clamp(x, -24, 24), y: clamp(y, -24, 24))
        }
        return GraineThemeTokens.Elevation(
            card: shadow(e, "card", fallback: Fallback.card),
            floating: shadow(e, "floating", fallback: Fallback.floating),
            hardOffset: hard
        )
    }

    private static func shadow(_ parent: [String: Any], _ key: String, fallback: GraineThemeTokens.Shadow) -> GraineThemeTokens.Shadow? {
        guard parent.keys.contains(key) else { return fallback }
        guard let s = JSON.unwrap(parent[key]) as? [String: Any] else { return nil }
        return GraineThemeTokens.Shadow(
            y: finite(s["y"]).map { clamp($0, -64, 64) } ?? fallback.y,
            blur: length(s["blur"]) ?? fallback.blur,
            spread: finite(s["spread"]).map { clamp($0, -64, 64) } ?? fallback.spread,
            opacity: finite(s["opacity"]).map { clamp($0, 0, 1) } ?? fallback.opacity,
            color: hex(s["color"]) ?? fallback.color
        )
    }

    private static func motion(_ raw: Any?) -> GraineThemeTokens.Motion {
        let m = object(raw)
        let d = Fallback.motion
        let easing = word(m["easing"])
        return GraineThemeTokens.Motion(
            durationMs: finite(m["durationMs"]).map { clamp($0, 0, 2_000) } ?? d.durationMs,
            easing: easing.isEmpty ? d.easing : easing,
            bounce: finite(m["bounce"]).map { clamp($0, 0, 1) } ?? d.bounce
        )
    }

    /// Absent → Classic's waveform; null (or unusable) → the brand's logo.
    private static func icons(_ raw: Any?) -> GraineThemeTokens.Icons {
        let i = object(raw)
        let style = word(i["style"])
        var glyph: GraineThemeTokens.Glyph? = Fallback.glyph
        if i.keys.contains("launcher") {
            glyph = nil
            if let g = JSON.unwrap(i["launcher"]) as? [String: Any],
               let id = JSON.nonEmpty(g["id"]), let path = g["path"] as? String,
               !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let stroke = JSON.unwrap(g["stroke"]).flatMap { JSON.bool($0) } ?? true
                glyph = GraineThemeTokens.Glyph(id: id.lowercased(), path: path, stroke: stroke)
            }
        }
        return GraineThemeTokens.Icons(
            style: style.isEmpty ? "outline" : style,
            stroke: finite(i["stroke"]).map { clamp($0, 0.5, 4) } ?? 2,
            launcher: glyph
        )
    }

    private static func glass(_ raw: Any?) -> GraineThemeTokens.Glass? {
        guard let g = JSON.unwrap(raw) as? [String: Any] else { return nil }
        return GraineThemeTokens.Glass(
            blur: length(g["blur"]) ?? Fallback.glass.blur,
            surfaceOpacity: finite(g["surfaceOpacity"]).map { clamp($0, 0, 1) } ?? Fallback.glass.surfaceOpacity
        )
    }

    // MARK: - Values

    /// "#RRGGBB" for "#rgb" or "#rrggbb" (the "#" optional, any case), else nil — theme.ts `normaliseHex`.
    static func hex(_ raw: Any?) -> String? {
        guard let s = JSON.unwrap(raw) as? String else { return nil }
        var h = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6 else { return nil }
        return "#" + h.uppercased()
    }

    private static func object(_ raw: Any?) -> [String: Any] {
        JSON.unwrap(raw) as? [String: Any] ?? [:]
    }

    /// A token word, trimmed and lower-cased; "" when absent or not text.
    private static func word(_ raw: Any?) -> String {
        guard let s = JSON.unwrap(raw) as? String else { return "" }
        return s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func family(_ raw: Any?) -> String? {
        guard let s = JSON.unwrap(raw) as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// A real number. Never a coercion: "12" is not a size, and a boolean is not 1.
    private static func finite(_ raw: Any?) -> Double? {
        guard let v = JSON.unwrap(raw), let n = JSON.number(v) else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    private static func positive(_ raw: Any?) -> Double? {
        guard let d = finite(raw), d > 0 else { return nil }
        return min(d, 200)
    }

    /// A length: 0 or more, capped where no phone could draw it.
    private static func length(_ raw: Any?) -> Double? {
        guard let d = finite(raw), d >= 0 else { return nil }
        return min(d, 200)
    }

    private static func weight(_ raw: Any?) -> Int? {
        guard let d = finite(raw) else { return nil }
        return Int(JSON.jsRound(clamp(d, 100, 900)))
    }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        min(hi, max(lo, v))
    }
}
