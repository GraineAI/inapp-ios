import Foundation

/*
 * THE SDK'S OWN ICONS — microphone, hang up, send, chat, call, chevron,
 * close, and the chat window's paperclip, thumbs, star, arrow and message
 * marks — as 24×24 path data: the same strings the dashboard's Garage draws
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
    /// "New conversation" in a chat window's header: a page and a pen.
    case compose
    /// The call screen's loudspeaker.
    case speaker
    // The chat window (DESIGN.md "Chat window v2"): the paperclip, the rating, scroll-to-latest and a message's status.
    case attach
    case thumbUp
    case thumbDown
    case star
    case arrowDown
    case check
    case clock
    case alert
    case retry
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
        .compose: GraineIconPaths(body: nil, lines: "M12 3H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7M18.4 2.6a2.1 2.1 0 0 1 3 3L12 15l-4 1 1-4z"),
        .speaker: GraineIconPaths(body: "M4 9.5h3.5L12 5.5v13l-4.5-4H4z", lines: "M15.5 9a4 4 0 0 1 0 6M18 6.5a7.5 7.5 0 0 1 0 11"),
        .attach: GraineIconPaths(body: nil, lines: "M21.44 11.05l-9.19 9.19a6 6 0 0 1-8.49-8.49l8.57-8.57A4 4 0 1 1 18 8.84l-8.59 8.57a2 2 0 0 1-2.83-2.83l8.49-8.48"),
        .thumbUp: GraineIconPaths(body: "M15 5.88L14 10h5.83a2 2 0 0 1 1.92 2.56l-2.33 8A2 2 0 0 1 17.5 22H4a2 2 0 0 1-2-2v-8a2 2 0 0 1 2-2h2.76a2 2 0 0 0 1.79-1.11L12 2a3.13 3.13 0 0 1 3 3.88z", lines: "M7 10v12"),
        .thumbDown: GraineIconPaths(body: "M9 18.12L10 14H4.17a2 2 0 0 1-1.92-2.56l2.33-8A2 2 0 0 1 6.5 2H20a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2h-2.76a2 2 0 0 0-1.79 1.11L12 22a3.13 3.13 0 0 1-3-3.88z", lines: "M17 14V2"),
        .star: GraineIconPaths(body: "M11.525 2.295a0.53 0.53 0 0 1 0.95 0l2.31 4.679a2.123 2.123 0 0 0 1.595 1.16l5.166 0.756a0.53 0.53 0 0 1 0.294 0.904l-3.736 3.638a2.123 2.123 0 0 0 -0.611 1.878l0.882 5.14a0.53 0.53 0 0 1 -0.771 0.56l-4.618 -2.428a2.122 2.122 0 0 0 -1.973 0L6.396 21.01a0.53 0.53 0 0 1 -0.77 -0.56l0.881 -5.139a2.122 2.122 0 0 0 -0.611 -1.879L2.16 9.795a0.53 0.53 0 0 1 0.294 -0.906l5.165 -0.755a2.122 2.122 0 0 0 1.597 -1.16z", lines: nil),
        .arrowDown: GraineIconPaths(body: nil, lines: "M12 5v14M19 12l-7 7-7-7"),
        .check: GraineIconPaths(body: nil, lines: "M20 6L9 17l-5-5"),
        .clock: GraineIconPaths(body: "M12 3a9 9 0 1 0 0 18a9 9 0 1 0 0-18z", lines: "M12 7.5V12l3 2"),
        .alert: GraineIconPaths(body: "M12 3a9 9 0 1 0 0 18a9 9 0 1 0 0-18z", lines: "M12 7.5v5M12 16.25v0.01"),
        .retry: GraineIconPaths(body: nil, lines: "M3 12a9 9 0 0 1 15.36-6.36L21 8M21 3v5h-5M21 12a9 9 0 0 1-15.36 6.36L3 16M3 21v-5h5"),
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
