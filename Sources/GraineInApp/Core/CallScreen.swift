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

    /// Light status-bar icons over the screen when its text is light (WCAG luminance above 0.5).
    static func lightStatusBar(_ call: GraineCallTokens) -> Bool {
        Appearance.luminance(call.text) > 0.5
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
