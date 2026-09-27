import Foundation

/*
 * THE SDK'S OWN ICONS — microphone, hang up, send, chat, call, chevron,
 * close — as 24×24 path data: the same strings the dashboard's Garage draws
 * and every SDK draws (contract/design.json → `icons`, which the tests
 * compare against). contract/DESIGN.md "Icons".
 *
 * Drawn, not picked from a symbol font: a brand that chose "sharp" icons at a
 * 1.5 stroke must see square ends at 1.5 on the phone, exactly as the Garage
 * showed them, and no symbol set can promise that. Pure: GlyphPath parses the
 * strings, and DesignKit strokes them.
 */

enum GraineIconName: String, CaseIterable {
    case mic
    case micOff
    case end
    case send
    case chat
    case call
    case chevron
    case close
}

/**
 * One icon: a closed `body` a fill can sit in, and `lines` that are only ever
 * stroked — filling a microphone's stand would draw a half-moon.
 */
struct GraineIconPaths: Equatable {
    let body: String?
    let lines: String?
}

enum GraineIcons {

    static let all: [GraineIconName: GraineIconPaths] = [
        .mic: GraineIconPaths(body: "M12 2.5a3.5 3.5 0 0 0-3.5 3.5v6a3.5 3.5 0 0 0 7 0V6A3.5 3.5 0 0 0 12 2.5z", lines: "M18.5 11.5a6.5 6.5 0 0 1-13 0M12 18v3.5"),
        .micOff: GraineIconPaths(body: "M12 2.5a3.5 3.5 0 0 0-3.5 3.5v6a3.5 3.5 0 0 0 7 0V6A3.5 3.5 0 0 0 12 2.5z", lines: "M18.5 11.5a6.5 6.5 0 0 1-13 0M12 18v3.5M4 4l16 16"),
        .end: GraineIconPaths(body: "M4.2 14.6c4.6-4.1 11-4.1 15.6 0 .6.5.6 1.4.1 2l-1.3 1.4c-.4.5-1.1.6-1.7.3l-2.2-1.2c-.5-.3-.8-.8-.7-1.4l.2-1.3a11 11 0 0 0-4.4 0l.2 1.3c.1.6-.2 1.1-.7 1.4l-2.2 1.2c-.6.3-1.3.2-1.7-.3L4.1 16.6c-.5-.6-.5-1.5.1-2z", lines: nil),
        .send: GraineIconPaths(body: "M4 12 20 4l-4 16-4.5-6.5L4 12z", lines: "M11.5 13.5 20 4"),
        .chat: GraineIconPaths(body: "M20 12a8 8 0 0 1-11.6 7.1L4 20l1-4.2A8 8 0 1 1 20 12z", lines: nil),
        .call: GraineIconPaths(body: nil, lines: "M13.832 16.568a1 1 0 0 0 1.213 -0.303l0.355 -0.465A2 2 0 0 1 17 15h3a2 2 0 0 1 2 2v3a2 2 0 0 1 -2 2A18 18 0 0 1 2 4a2 2 0 0 1 2 -2h3a2 2 0 0 1 2 2v3a2 2 0 0 1 -0.8 1.6l-0.468 0.351a1 1 0 0 0 -0.292 1.233a14 14 0 0 0 6.392 6.384"),
        .chevron: GraineIconPaths(body: nil, lines: "M6 15l6-6 6 6"),
        .close: GraineIconPaths(body: nil, lines: "M6 6l12 12M18 6 6 18"),
    ]

    static func paths(_ name: GraineIconName) -> GraineIconPaths {
        all[name] ?? GraineIconPaths(body: nil, lines: nil)
    }

    /// How one icon style paints the two parts. Widths are in the icon's own 24-unit scale.
    struct Paint: Equatable {
        /// The body's fill opacity; 0 leaves it unfilled.
        let bodyFill: Double
        let bodyStroke: Double
        let linesStroke: Double
        /// Square caps and mitred joins (`sharp`); otherwise round ones.
        let square: Bool
    }

    /**
     * DESIGN.md "Icons": `outline` stroked with round caps and joins; `sharp`
     * stroked with square caps and mitred joins; `filled` the body filled and
     * stroked at 0.75 × the stroke (at least 1); `duotone` the body filled at
     * 28% under the stroke. A style this build does not know is `outline`.
     */
    static func paint(style: String, stroke: Double) -> Paint {
        switch style {
        case "sharp": return Paint(bodyFill: 0, bodyStroke: stroke, linesStroke: stroke, square: true)
        case "filled": return Paint(bodyFill: 1, bodyStroke: max(1, stroke * 0.75), linesStroke: stroke, square: false)
        case "duotone": return Paint(bodyFill: 0.28, bodyStroke: stroke, linesStroke: stroke, square: false)
        default: return Paint(bodyFill: 0, bodyStroke: stroke, linesStroke: stroke, square: false)
        }
    }
}
