import Foundation

/**
 * THE CALL SCREEN'S RULES — what `GraineCallView` draws from the design's
 * `call` tokens (contract §7), kept here, pure, so a Mac proves them: which
 * tokens apply (the brand's, else the screen as it was before designs), what
 * the status line says, what stands in the avatar, which controls show.
 */
enum CallScreen {
    /// What fills the avatar.
    enum Avatar: Equatable {
        case glyph(GraineThemeTokens.Glyph)
        case logo(String)
        case initials(String)
    }

    /// The tokens to draw: the scheme's `call`, else the legacy screen.
    static func tokens(_ theme: GraineThemeTokens?) -> GraineCallTokens {
        theme?.call ?? SurfaceTokens.legacyCall
    }

    /**
     * The avatar the brand chose, falling back in order — the logo, the
     * launcher glyph, the caller's initials — so a design that asks for a logo
     * the workspace never uploaded still shows something of the brand.
     */
    static func avatar(_ call: GraineCallTokens, glyph: GraineThemeTokens.Glyph?, logoUrl: String?, name: String) -> Avatar {
        switch call.avatar {
        case "logo":
            if let url = logoUrl { return .logo(url) }
            if let g = glyph { return .glyph(g) }
        case "glyph":
            if let g = glyph { return .glyph(g) }
            if let url = logoUrl { return .logo(url) }
        default:
            break
        }
        return .initials(initials(name))
    }

    /// The call name's first grapheme, upper-cased where the script has case; "A" for no name.
    static func initials(_ name: String) -> String {
        guard let first = name.trimmingCharacters(in: .whitespacesAndNewlines).first else { return "A" }
        return String(first).uppercased()
    }

    /// What the screen is showing: a call in some state, or a ring nobody answered (which outlives the call, to offer a call back).
    enum Phase: Equatable {
        case call(GraineCallState)
        case missed
    }

    /// A missed ring stays on screen — "Missed call", call back or close — until the customer acts or another call comes.
    static func phase(_ state: GraineCallState, missedPending: Bool) -> Phase {
        switch state {
        case .ended(.missed): return .missed
        case .idle where missedPending: return .missed
        default: return .call(state)
        }
    }

    /**
     * The status line, first match wins (DESIGN.md "Call screen"): missed; an
     * ended call (the brand's words for a normal end, the SDK's for failed and
     * declined); a scheduled ring (`hosted: "1"`), any other ring; connecting,
     * either way; on the call with the timer, the time — then " · Muted" while
     * muted; without it, "Muted", "Speaking" while the agent's line is
     * arriving, else "Listening".
     */
    static func status(
        _ state: GraineCallState, direction: GraineCallDirection?, call: GraineCallTokens,
        elapsed: String?, speaking: Bool, hosted: Bool = false, muted: Bool = false
    ) -> String {
        switch state {
        case .idle:
            return " "
        case .ringing:
            return hosted ? call.statusText.scheduled : call.statusText.ringing
        case .connecting:
            return call.statusText.connecting
        case .active:
            if call.timer {
                let time = elapsed ?? "0:00"
                return muted ? time + " · Muted" : time
            }
            if muted { return "Muted" }
            return speaking ? "Speaking" : "Listening"
        case .ended(let reason):
            switch reason {
            case .local, .remote: return call.statusText.ended
            case .failed: return "Call failed"
            case .declined: return "Declined"
            case .missed: return call.statusText.missed
            }
        }
    }

    /// Light status-bar icons over the screen when its ink is light (from a server that predates the look: its text's luminance is above 0.5).
    static func lightStatusBar(_ call: GraineCallTokens) -> Bool {
        lightStatusBar(call.look)
    }

    /// Light status-bar icons over a moment's look when its ink is light.
    static func lightStatusBar(_ look: GraineCallLook) -> Bool {
        look.ink == "light"
    }

    /// A missed ring's screen closes on its own after this, if nobody chose.
    static let missedHoldSeconds: TimeInterval = 30

    /// The controls on a live call, in the design's order; `chat` only where there is a transcript to open.
    static func controls(_ call: GraineCallTokens, transcript: Bool) -> [String] {
        call.controls.filter { $0 != "chat" || transcript }
    }

    /// `m:ss`, or `h:mm:ss` past the hour.
    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - The look (contract/DESIGN.md "Call screen" → "The look")

/// The eight moments a call screen shows.
enum CallMoment: String, CaseIterable, Equatable, Sendable {
    case incoming, scheduled, outgoing, connecting, connected, reconnecting, ended, missed

    /// The moments a ring is drawn in by default.
    var isRinging: Bool { self == .incoming || self == .scheduled }
}

/// How a call that is over ended, for the status line's words.
enum CallEnding: String, Equatable, Sendable {
    case normal, failed, declined

    init(_ reason: GraineCallEndReason?) {
        switch reason {
        case .failed?: self = .failed
        case .declined?: self = .declined
        default: self = .normal
        }
    }
}

extension CallScreen {
    /**
     * The moment for a call (theme.ts `callMoment()`), first match winning:
     * missed; a ring — scheduled (`hosted`) or not; not through yet — placed
     * by the customer or an answered ring; on the call — recovering its
     * connection or not (`GraineCalls.isReconnecting`: a WebRTC call bringing
     * its media path back; the WebSocket never reconnects); else ended.
     */
    static func moment(_ state: GraineCallState, direction: GraineCallDirection?, hosted: Bool, missed: Bool, reconnecting: Bool = false) -> CallMoment {
        let word: String
        switch state {
        case .idle: word = "idle"
        case .ringing: word = "ringing"
        case .connecting: word = "connecting"
        case .active: word = "active"
        case .ended(let reason): word = "ended"; if reason == .missed { return .missed }
        }
        return moment(word: word, direction: direction?.rawValue, hosted: hosted, missed: missed, reconnecting: reconnecting)
    }

    /// The same rule on the contract's words (design.json → `callVectors.moments`).
    static func moment(word: String, direction: String?, hosted: Bool, missed: Bool, reconnecting: Bool) -> CallMoment {
        if missed { return .missed }
        switch word {
        case "ringing": return hosted ? .scheduled : .incoming
        case "connecting": return direction == "outgoing" ? .outgoing : .connecting
        case "active": return reconnecting ? .reconnecting : .connected
        default: return .ended
        }
    }

    /// What a moment is drawn in: its own look, else the screen's.
    static func look(_ call: GraineCallTokens, _ moment: CallMoment) -> GraineCallLook {
        call.states[moment.rawValue] ?? call.look
    }

    /// The ring the avatar wears in a moment.
    static func ring(_ call: GraineCallTokens, _ moment: CallMoment) -> String {
        call.rings[moment.rawValue] ?? "none"
    }

    /**
     * The status line for a moment (theme.ts `callStatusWords()`): the brand's
     * words for each moment; on a call that ended badly "Call failed" or
     * "Declined"; on the call the timer (" · Muted" while muted), else
     * "Muted", "Speaking" while the agent's line arrives, "Listening".
     */
    static func statusWords(_ call: GraineCallTokens, _ moment: CallMoment, elapsedMs: Double? = nil,
                            muted: Bool = false, speaking: Bool = false, ending: CallEnding = .normal) -> String {
        let st = call.statusText
        switch moment {
        case .missed: return st.missed
        case .ended: return ending == .failed ? "Call failed" : ending == .declined ? "Declined" : st.ended
        case .scheduled: return st.scheduled
        case .incoming: return st.ringing
        case .outgoing: return st.outgoing
        case .connecting: return st.connecting
        case .reconnecting: return st.reconnecting
        case .connected:
            if call.timer { return elapsedText(ms: elapsedMs ?? 0) + (muted ? " · Muted" : "") }
            return muted ? "Muted" : speaking ? "Speaking" : "Listening"
        }
    }

    /// `ms` as the timer shows it: 4:07, or 1:02:09 past an hour.
    static func elapsedText(ms: Double) -> String {
        let s = Int((max(0, ms) / 1000).rounded(.down))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    // MARK: Layouts

    /// How a layout places the screen (theme.ts `CALL_LAYOUTS`).
    struct LayoutSpec: Equatable, Sendable {
        /// Centred, or against the leading edge.
        let leading: Bool
        /// The first thing's top below the safe area's top.
        let top: Double
        /// The avatar at this share of `avatarSize`; 0: none.
        let avatar: Double
        /// From the avatar's bottom to the name's top.
        let nameGap: Double
        /// The name and status first, the avatar in its orb below them.
        let nameFirst: Bool
        let nameSize: Double
        let nameLines: Int
        /// Avatar, name, status, voice and a middle caption on one card.
        let card: Bool
    }

    static let layouts: [String: LayoutSpec] = [
        "classic": .init(leading: false, top: 72, avatar: 1, nameGap: 20, nameFirst: false, nameSize: 28, nameLines: 1, card: false),
        "full-bleed": .init(leading: true, top: 32, avatar: 0.5, nameGap: 24, nameFirst: false, nameSize: 40, nameLines: 2, card: false),
        "card": .init(leading: false, top: 48, avatar: 0.8, nameGap: 16, nameFirst: false, nameSize: 24, nameLines: 1, card: true),
        "orb": .init(leading: false, top: 40, avatar: 0.75, nameGap: 0, nameFirst: true, nameSize: 24, nameLines: 1, card: false),
        "minimal": .init(leading: false, top: 120, avatar: 0, nameGap: 0, nameFirst: false, nameSize: 34, nameLines: 2, card: false),
    ]

    static func layout(_ name: String) -> LayoutSpec { layouts[name] ?? layouts["classic"]! }

    /// The screen's other numbers (theme.ts `CALL_SCREEN`).
    enum Screen {
        static let side = 24.0
        static let statusGap = 6.0
        static let visualizerGap = 16.0
        static let visualizerHeight = 28.0
        static let captionGap = 36.0
        static let captionAboveButtons = 24.0
        static let buttonsBottom = 56.0
        static let labelGap = 8.0
        static let labelSize = 13.0
        static let cardPadding = 24.0
        static let cardRadius = 28.0
        static let cardMinAlpha = 0.16
        static let orbScale = 2.0
        static let speakingScale = 1.06
        static let endedAlpha = 0.4
        static let bigButton = 9.0 / 8.0
        static let icon = 30.0 / 64.0
    }

    /// The rings (theme.ts `CALL_RINGS`).
    enum Rings {
        static let pulse = (periodMs: 1600.0, scale: 1.35, alpha: 0.6, width: 2.0, count: 1)
        static let ripple = (periodMs: 2400.0, scale: 1.6, alpha: 0.5, width: 1.5, count: 3)
        static let glow = (periodMs: 2000.0, reach: 1.45, alphaLow: 0.35, alphaHigh: 0.7, breathe: 1.08)
    }

    /// The voice (theme.ts `CALL_VISUALIZER`).
    enum Voice {
        static let barCount = 5
        static let barWidth = 4.0
        static let barGap = 4.0
        static let barRest = 4.0
        static let barMax = 28.0
        static let barWeights = [0.5, 0.8, 1, 0.8, 0.5]
        static let barWobbleMs = 600.0
        static let waveWidth = 160.0
        static let waveStroke = 2.0
        static let waveAmplitude = 12.0
        static let waveCycles = 1.5
        static let wavePeriodMs = 900.0
        static let waveRestAlpha = 0.4
        static let orbRest = 1.6
        static let orbGain = 0.5
        static let orbLayoutRest = 2.0
        static let orbLayoutGain = 0.4
        static let orbInner = 0.72
        static let orbOuterAlpha = 0.35
        static let orbInnerAlpha = 0.5
        static let attackMs = 60.0
        static let releaseMs = 240.0
    }

    /// How a backdrop moves (theme.ts `CALL_BACKDROP_MOTION`).
    enum Motion {
        static let driftLinearMs = 14_000.0
        static let driftRadialMs = 16_000.0
        static let driftAvatarMs = 18_000.0
        static let driftMeshMs = [17_000.0, 19_000.0, 23_000.0, 29_000.0, 31_000.0]
        static let breatheMs = 7_000.0
        static let idleMs = 10_000.0
        static let settleMs = 600.0
        static let blur = 48.0
        static let meshCols = 32
        static let meshRows = 64
    }

    /// Where a mesh's glows sit (TL, TR, BR, BL, the centre for a fifth stop), in shares of the screen.
    static let meshAnchors: [(Double, Double)] = [(0.15, 0.12), (0.85, 0.2), (0.8, 0.85), (0.18, 0.78), (0.5, 0.48)]

    // MARK: Geometry

    /// theme.ts's rounding: JS Math.round to two (or three) places, never -0.
    static func round2(_ v: Double) -> Double { JSON.jsRound(v * 100) / 100 + 0 }
    static func round3(_ v: Double) -> Double { JSON.jsRound(v * 1000) / 1000 + 0 }

    /// A gradient line's two ends, in points.
    struct Line: Equatable { let x0: Double; let y0: Double; let x1: Double; let y1: Double }

    /**
     * A linear gradient's line across a `w` × `h` screen for an angle read as
     * CSS reads it (theme.ts `callGradientLine()`): through the centre, long
     * enough that the end stops reach the corners.
     */
    static func gradientLine(angle: Double, w: Double, h: Double) -> Line {
        let a = angle * .pi / 180
        let dx = sin(a), dy = -cos(a)
        let len = abs(w * sin(a)) + abs(h * cos(a))
        return Line(x0: round2(w / 2 - dx * len / 2), y0: round2(h / 2 - dy * len / 2),
                    x1: round2(w / 2 + dx * len / 2), y1: round2(h / 2 + dy * len / 2))
    }

    /// A mesh's glow: where it sits (shares of the screen) and its colour.
    struct Glow: Equatable { let u: Double; let v: Double; let color: String }

    /// Where a backdrop's moving parts are at `t` ms (theme.ts `callBackdropFrame()`).
    struct Frame: Equatable {
        let line: Line
        let radial: (cx: Double, cy: Double, r: Double)
        let mesh: [Glow]
        let avatar: (dx: Double, dy: Double, scale: Double)

        static func == (a: Frame, b: Frame) -> Bool {
            a.line == b.line && a.radial == b.radial && a.mesh == b.mesh && a.avatar == b.avatar
        }
    }

    /// The backdrop at `t` ms after it began moving, on a `w` × `h` screen; at rest at t = 0 or with motion "none".
    static func backdropFrame(_ b: GraineCallLook.Backdrop, w: Double, h: Double, t: Double = 0) -> Frame {
        let k = min(1, max(0, b.intensity))
        let drift = b.motion == "drift"
        let breathe = b.motion == "breathe" ? 1 + (0.05 + 0.12 * k) * sin(2 * .pi * t / Motion.breatheMs) : 1
        let sway = drift ? (6 + 18 * k) * sin(2 * .pi * t / Motion.driftLinearMs) : 0
        let base = gradientLine(angle: b.angle + sway, w: w, h: h)
        let cx = w / 2, cy = h / 2
        let line = Line(x0: round2(cx + (base.x0 - cx) * breathe), y0: round2(cy + (base.y0 - cy) * breathe),
                        x1: round2(cx + (base.x1 - cx) * breathe), y1: round2(cy + (base.y1 - cy) * breathe))
        func orbit(_ period: Double, _ phase: Double = 0) -> Double { 2 * .pi * t / period + phase }
        let ra = drift ? (0.03 + 0.06 * k) * w : 0
        let radial = (cx: round2(0.5 * w + ra * cos(orbit(Motion.driftRadialMs))),
                      cy: round2(0.28 * h + ra * sin(orbit(Motion.driftRadialMs))),
                      r: round2((0.35 + 0.4 * k) * hypot(w, h) * breathe))
        let colors = b.stops.map { $0.color }
        let n = colors.count
        let anchors = n >= 5 ? meshAnchors : Array(meshAnchors.prefix(4))
        let ma = drift ? 0.05 + 0.1 * k : 0
        let mesh = anchors.enumerated().map { i, uv -> Glow in
            let a = orbit(Motion.driftMeshMs[i], Double(i) * .pi / 2.5)
            return Glow(u: round3(0.5 + (uv.0 + ma * cos(a) - 0.5) * breathe),
                        v: round3(0.5 + (uv.1 + ma * sin(a) - 0.5) * breathe),
                        color: n > 0 ? colors[i % n] : "#000000")
        }
        let aa = drift ? (0.02 + 0.05 * k) * w : 0
        let avatarScale = b.motion == "breathe" ? 1 + (0.04 + 0.08 * k) * sin(2 * .pi * t / Motion.breatheMs) : 1
        let avatar = (dx: round2(aa * cos(orbit(Motion.driftAvatarMs))),
                      dy: round2(aa * sin(orbit(Motion.driftAvatarMs))),
                      scale: round3(avatarScale))
        return Frame(line: line, radial: radial, mesh: mesh, avatar: avatar)
    }

    /// A frame `rest` of the way (0–1) back to the frame at rest — a connected call nobody has touched settling.
    static func settle(_ f: Frame, toward r: Frame, by rest: Double) -> Frame {
        guard rest > 0 else { return f }
        let p = min(1, rest)
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * p }
        return Frame(
            line: Line(x0: mix(f.line.x0, r.line.x0), y0: mix(f.line.y0, r.line.y0), x1: mix(f.line.x1, r.line.x1), y1: mix(f.line.y1, r.line.y1)),
            radial: (mix(f.radial.cx, r.radial.cx), mix(f.radial.cy, r.radial.cy), mix(f.radial.r, r.radial.r)),
            mesh: zip(f.mesh, r.mesh).map { Glow(u: mix($0.u, $1.u), v: mix($0.v, $1.v), color: $0.color) },
            avatar: (mix(f.avatar.dx, r.avatar.dx), mix(f.avatar.dy, r.avatar.dy), mix(f.avatar.scale, r.avatar.scale))
        )
    }

    /// A colour's channels, 0–255.
    static func channels(_ hex: String) -> (Double, Double, Double) {
        guard let c = Appearance.rgb(hex) else { return (0, 0, 0) }
        return (c.red * 255, c.green * 255, c.blue * 255)
    }

    /// "#RRGGBB" from channels, rounded as JS rounds, clamped.
    static func hex(_ r: Double, _ g: Double, _ b: Double) -> String {
        func c(_ v: Double) -> Int { Int(max(0, min(255, JSON.jsRound(v)))) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }

    /**
     * A mesh's colour at (u, v), shares of the screen (theme.ts
     * `callMeshColor()`): every glow weighted by max(0, 0.9 − its distance)⁴
     * and averaged.
     */
    static func meshColor(_ glows: [Glow], u: Double, v: Double) -> String {
        let c = meshRGB(glows.map { (u: $0.u, v: $0.v, rgb: channels($0.color)) }, u: u, v: v)
        return hex(c.0, c.1, c.2)
    }

    /// The same, on glows whose colours are already channels (0–255): a renderer filling a bitmap every frame.
    static func meshRGB(_ glows: [(u: Double, v: Double, rgb: (Double, Double, Double))], u: Double, v: Double) -> (Double, Double, Double) {
        var r = 0.0, g = 0.0, bl = 0.0, sum = 0.0
        for glow in glows {
            let w = pow(max(0, 0.9 - hypot(u - glow.u, v - glow.v)), 4)
            r += glow.rgb.0 * w; g += glow.rgb.1 * w; bl += glow.rgb.2 * w; sum += w
        }
        if sum < 1e-9 {
            let n = Double(max(1, glows.count))
            return (glows.reduce(0) { $0 + $1.rgb.0 } / n, glows.reduce(0) { $0 + $1.rgb.1 } / n, glows.reduce(0) { $0 + $1.rgb.2 } / n)
        }
        return (r / sum, g / sum, bl / sum)
    }

    /// A stop list's colour at `t` (0–1), between the stops either side of it, in sRGB.
    static func stopColor(_ stops: [GraineCallLook.Stop], at t: Double) -> String {
        guard let first = stops.first else { return "#000000" }
        if stops.count == 1 || t <= first.at { return first.color }
        for i in 1..<stops.count {
            let a = stops[i - 1], b = stops[i]
            if t <= b.at {
                guard b.at > a.at else { return b.color }
                let p = (t - a.at) / (b.at - a.at)
                let ca = channels(a.color), cb = channels(b.color)
                return hex(ca.0 + (cb.0 - ca.0) * p, ca.1 + (cb.1 - ca.1) * p, ca.2 + (cb.2 - ca.2) * p)
            }
        }
        return stops[stops.count - 1].color
    }

    /// A button's box (theme.ts `callButtonFrame()`).
    struct ButtonFrame: Equatable { let width: Double; let height: Double; let radius: Double; let continuous: Bool }

    static func buttonFrame(shape: String, size: Double, share: Double, end: Bool = false, endShape: String? = nil, on: Bool = false) -> ButtonFrame {
        if end && endShape == "pill" {
            return ButtonFrame(width: max(size, JSON.jsRound(share - 8)), height: size, radius: size / 2, continuous: false)
        }
        switch shape {
        case "squircle":
            return ButtonFrame(width: size, height: size, radius: round2(size * 0.3), continuous: true)
        case "pill":
            let width = max(size, min(JSON.jsRound(share - 8), JSON.jsRound(size * 1.5)))
            return ButtonFrame(width: width, height: size, radius: on ? round2(size * 0.3) : size / 2, continuous: on)
        default:
            return ButtonFrame(width: size, height: size, radius: size / 2, continuous: false)
        }
    }

    /// The call's buttons, the ring's and the missed call's (9/8 of them), and the icon in them.
    static func buttonSizes(_ buttonSize: Double) -> (button: Double, big: Double, icon: Double) {
        (buttonSize, JSON.jsRound(buttonSize * Screen.bigButton), JSON.jsRound(buttonSize * Screen.icon))
    }

    /// The agent's voice, 0–1, from an inbound audio level (theme.ts `callVoiceLevel()`).
    static func voiceLevel(_ raw: Double, sensitivity: Double = 0.5) -> Double {
        guard raw > 0 else { return 0 }
        let db = 20 * log10(min(1, raw))
        let floor = -(30 + 30 * min(1, max(0, sensitivity)))
        return round3(min(1, max(0, (db - floor) / (-6 - floor))))
    }

    /// The voice where the call reports only that the agent speaks: a speech-like movement `t` ms in (theme.ts `callSpeakingLevel()`).
    static func speakingLevel(_ t: Double) -> Double {
        let s = t / 1000
        return round3(max(0.15, min(0.95, 0.55 + 0.3 * sin(2 * .pi * s / 0.53) * sin(2 * .pi * s / 1.7))))
    }

    /// The drawn level, following `target` up over 60 ms and down over 240 ms (exponentially) across `dtMs`.
    static func smoothLevel(_ current: Double, toward target: Double, dtMs: Double) -> Double {
        guard dtMs > 0 else { return current }
        let tau = target > current ? Voice.attackMs : Voice.releaseMs
        return current + (target - current) * (1 - exp(-dtMs / tau))
    }
}
