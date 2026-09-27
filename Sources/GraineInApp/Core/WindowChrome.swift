import Foundation

/*
 * WINDOW CHROME — the numbers of contract/DESIGN.md "Window chrome". With
 * `chrome: "window"` (Desktop Buddy's, and a knob on any design) the chat
 * window, the caption card and every component card open as desktop windows:
 * a title bar across the top of the surface, three traffic lights at its left
 * and a lower-case monospaced title in its middle. The chat window's bar
 * replaces its header, and a component card's own title moves into its bar,
 * over a body on `surface`. Everything else — corners, shadows, the voice bar,
 * the launcher, the "coming" loader and the answered row — is drawn as it is
 * without it.
 *
 * The views in UI/ draw what this returns. It lives here, pure, so a Mac
 * proves every number and no view rounds one its own way.
 */
enum WindowChrome {

    /// The surfaces that open as windows, each with its own bar and title.
    enum Surface: Equatable {
        /// The chat window: the bar replaces its header, titled with the heading — after a `success` dot while online.
        case chat(heading: String, online: Bool)
        /// The caption card above the voice bar: a shorter bar with smaller lights, titled "captions".
        case caption
        /// A component card: titled with its own title, in its own corners (a radius chosen on the component wins).
        case component(title: String, radius: Double)
    }

    /// One surface's title bar, every value resolved. Colours are #RRGGBB; lengths are points.
    struct TitleBar: Equatable {
        /// 32 on the chat window and components, 24 on the caption card.
        let height: Double
        /// `surfaceRaised`.
        let fill: String
        /// The bottom outline: `borderWidth` in `border`.
        let outline: String
        let outlineWidth: Double
        /// The surface's own top corners.
        let cornerRadius: Double
        /// From the bar's left edge to the first light.
        let lightsInset: Double
        /// Each light across: 10, or 8 on the caption card.
        let dot: Double
        /// Between one light and the next.
        let dotGap: Double
        /// Left to right. Always the window's own three, never the brand's.
        let lights: [String]
        /// Lower case, one line. Empty leaves the lights alone in the bar.
        let title: String
        /// The platform's monospace at `font.scale.caption`.
        let titleSize: Double
        /// `textMuted`.
        let titleColor: String
        /// Kept clear on BOTH sides of the title, so it stays centred in the bar and never runs under the lights.
        let titleInset: Double
        /// `success`: the dot before the chat window's heading while it is online. Nil on every other bar.
        let onlineDot: String?
    }

    /// The window's controls, not the brand's colours: close, minimise, zoom.
    static let lights = ["#FF5F57", "#FEBC2E", "#28C840"]
    /// The chat window's bar, and a component card's.
    static let barHeight = 32.0
    static let captionBarHeight = 24.0
    static let dot = 10.0
    static let captionDot = 8.0
    static let dotGap = 6.0
    /// From the bar's left edge to the first light; the chat window's chevron keeps the same distance from the right.
    static let inset = 12.0
    /// The least room between the lights and the title.
    static let titleGap = 8.0
    /// The chat window's online dot before the heading — the header's 6-point dot — and the 6 between it and the heading.
    static let onlineDotSize = VoiceBar.Chat.dot
    static let onlineGap = 6.0
    /// What the caption card's bar says.
    static let captionTitle = "captions"

    /// The bar `surface` wears under these tokens; nil when the design draws plain surfaces (`chrome: "none"`).
    static func titleBar(_ t: GraineThemeTokens, for surface: Surface) -> TitleBar? {
        guard t.chrome == .window else { return nil }
        var height = barHeight
        var dot = self.dot
        let title: String
        let corner: Double
        var online: String?
        switch surface {
        case let .chat(heading, isOnline):
            title = heading
            corner = t.shape.radius.xl
            if isOnline { online = t.colors.success }
        case .caption:
            height = captionBarHeight
            dot = captionDot
            title = captionTitle
            corner = t.shape.radius.lg
        case let .component(own, radius):
            title = own
            corner = radius
        }
        return TitleBar(
            height: height,
            fill: t.colors.surfaceRaised,
            outline: t.colors.border,
            outlineWidth: t.shape.borderWidth,
            cornerRadius: max(0, corner),
            lightsInset: inset,
            dot: dot,
            dotGap: dotGap,
            lights: lights,
            title: oneLine(title),
            titleSize: t.font.scale.caption,
            titleColor: t.colors.textMuted,
            titleInset: inset + lightsWidth(dot: dot) + titleGap,
            onlineDot: online
        )
    }

    /**
     * The title a component card draws in its BODY: its own title on a plain
     * surface — and nothing when the card opens as a window, whose bar carries
     * it instead. Rows inside the card keep their own titles either way. Nil
     * draws none; without a design, the card is as it always was.
     */
    static func componentBodyTitle(_ t: GraineThemeTokens?, title: String) -> String? {
        if let t = t, t.chrome == .window { return nil }
        return title.isEmpty ? nil : title
    }

    /**
     * A component card's BODY: `surfaceRaised`, as DESIGN.md's components are
     * — except in a window, whose body is `surface`, so the `surfaceRaised`
     * title bar over it reads as a title bar: the white window under a grey
     * bar. The "coming" loader card and the answered row keep `surfaceRaised`.
     */
    static func componentBodyFill(_ t: GraineThemeTokens) -> String {
        t.chrome == .window ? t.colors.surface : t.colors.surfaceRaised
    }

    /// The three lights, edge to edge.
    static func lightsWidth(dot: Double) -> Double {
        3 * dot + 2 * dotGap
    }

    /// A title as the bar shows it: lower case, and every run of spaces or line breaks one space.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }
}
