import Foundation

/*
 * THE CHAT WINDOW'S AND THE CALL SCREEN'S OWN TOKENS (contract §7) — resolved
 * on the server like every other token, one flat set per scheme, under
 * `design.light.chat` / `.call` and `design.dark.chat` / `.call`.
 *
 * Read as the rest of Design.swift reads: nothing trusted, nothing thrown. A
 * scheme without `chat` or `call` (an older server) has nil, and the surface
 * draws as it did before these tokens existed. A field that is missing or
 * malformed inside a set falls back on its own: a chat field to what the chat
 * window drew from the scheme's colours, a call field to the call screen the
 * SDK drew before designs reached it (dark, white type, red and green). Words
 * nobody chose are the SDK's own.
 */

/// How the chat window is drawn: its header, its composer, its words.
public struct GraineChatTokens: Equatable, Sendable {
    /// The header's title; empty means the dashboard's heading.
    public let title: String
    /// Under the title; empty means "Online" / "Connecting…".
    public let subtitle: String
    /// The header's mark: `logo`, `glyph` or `none`.
    public let avatar: String
    /// The composer's placeholder.
    public let placeholder: String
    public let showTimestamps: Bool
    /// Up to four replies offered before the customer has said anything.
    public let suggestions: [String]
    /// Behind the messages.
    public let background: String
    /// Over the thread: `none` or `dots`.
    public let pattern: String
    /// The dots' colour (unused with no pattern).
    public let patternColor: String
    public let headerBackground: String
    public let headerText: String
    public let headerSubtext: String
    public let composerBackground: String
    public let composerText: String
    public let composerPlaceholder: String
    public let composerBorder: String
    /// How big the window opens (Window size in the dashboard): `.compact` unless the design says otherwise.
    public let size: GraineChatSize
    /// The card of the customer's booked calls at the top of the chat (Booked calls in the dashboard).
    public let showUpcomingCalls: Bool
    /// That card's title; empty means "Upcoming call" / "Upcoming calls".
    public let upcomingTitle: String
    /// The conversation kept from before, on screen (Earlier messages). Off, the agent still has it.
    public let showHistory: Bool
    /// The header's compose control (New conversation button). Off, `GraineChat.newConversation()` still works.
    public let newConversation: Bool
}

/// How the call screen is drawn while the app is open (the system's call screen is the system's).
public struct GraineCallTokens: Equatable, Sendable {
    public struct StatusText: Equatable, Sendable {
        public let ringing: String
        public let connecting: String
        public let ended: String
        /// A ring Graine sent for a call booked for this customer (the push says `hosted: "1"`).
        public let scheduled: String
        /// A ring nobody answered; the screen then offers to call back.
        public let missed: String
        /// A call the customer placed, before it is through: the connecting words unless the brand wrote its own.
        public let outgoing: String
        /// A connected call recovering its connection.
        public let reconnecting: String

        init(ringing: String, connecting: String, ended: String, scheduled: String, missed: String,
             outgoing: String? = nil, reconnecting: String? = nil) {
            self.ringing = ringing
            self.connecting = connecting
            self.ended = ended
            self.scheduled = scheduled
            self.missed = missed
            self.outgoing = outgoing ?? connecting
            self.reconnecting = reconnecting ?? SurfaceTokens.reconnectingWords
        }
    }

    public let background: String
    /// With one, the background is a gradient from `background` (top) to this (bottom).
    public let backgroundTo: String?
    public let text: String
    public let textMuted: String
    /// `logo`, `glyph` or `initials`.
    public let avatar: String
    /// `circle`, `squircle` or `rounded-square`.
    public let avatarShape: String
    public let avatarFill: String
    public let avatarText: String
    public let buttonFill: String
    public let buttonIcon: String
    /// A control that is on (muted, the speaker).
    public let buttonActiveFill: String
    public let buttonActiveIcon: String
    public let endFill: String
    public let endIcon: String
    /// `round` or `pill`.
    public let endShape: String
    public let acceptFill: String
    public let acceptIcon: String
    public let declineFill: String
    public let declineIcon: String
    /// Call back, on a missed call.
    public let callbackFill: String
    public let callbackIcon: String
    public let captions: Bool
    public let timer: Bool
    /// In order, from `mute`, `speaker`, `chat` and `end`.
    public let controls: [String]
    /// `system`, `graine` or `soft` — the system's call screen rings with the app's own sound on iOS.
    public let ringtone: String
    public let statusText: StatusText

    // MARK: The look (contract/DESIGN.md "Call screen" → "The look")
    //
    // From a server that predates it, derived as today's screen: an old
    // design draws exactly what it drew.

    /// The preset the look was resolved from — informational.
    public let preset: String
    /// `classic`, `full-bleed`, `card`, `orb` or `minimal`.
    public let layout: String
    /// The screen's own look: what a moment without one of its own is drawn in.
    public let look: GraineCallLook
    /// The avatar's size before its layout's share, in points.
    public let avatarSize: Double
    /// The ring the avatar wears in each moment (`none`, `pulse`, `ripple`, `glow`), by the moment's name.
    public let rings: [String: String]
    /// `solid`, `glass` or `outline`.
    public let buttonStyle: String
    /// `circle`, `squircle` or `pill`.
    public let buttonShape: String
    /// The call's buttons, in points; the ring's and the missed call's are 9/8 of it.
    public let buttonSize: Double
    /// `below` or `none`.
    public let buttonLabels: String
    /// `none`, `bars`, `wave` or `orb`.
    public let visualizer: String
    /// 0–1: how quiet a voice still moves the visualiser.
    public let visualizerSensitivity: Double
    /// `plain`, `card`, `subtitle` or `bubble`.
    public let captionStyle: String
    /// `middle` or `bottom`.
    public let captionPosition: String
    public let nameSize: Double
    public let nameWeight: Int
    public let statusSize: Double
    public let statusWeight: Int
    /// A moment's own look, by the moment's name, where it differs from the screen's.
    public let states: [String: GraineCallLook]
}

/// Everything on the call screen that is drawn in a colour, for one moment (contract/DESIGN.md "Call screen" → Moments).
public struct GraineCallLook: Equatable, Sendable {
    /// A colour along the fill.
    public struct Stop: Equatable, Sendable {
        public let color: String
        /// 0–1.
        public let at: Double
    }

    /// The screen's fill.
    public struct Backdrop: Equatable, Sendable {
        /// `solid`, `linear`, `radial`, `mesh` or `blurred-avatar`.
        public let type: String
        /// One stop for `solid`, 2–5 otherwise, in order.
        public let stops: [Stop]
        /// Degrees as CSS reads them: 180 runs top to bottom.
        public let angle: Double
        /// `none`, `drift` or `breathe`.
        public let motion: String
        /// 0–1.
        public let intensity: Double
        /// `blurred-avatar`: the stops' opacity over the blurred avatar. 1 for every other type.
        public let scrim: Double
    }

    /// One button's colours.
    public struct Action: Equatable, Sendable {
        public let fill: String
        /// Below 1: glass, `fill` at this opacity over the backdrop. 0: an outline's empty middle.
        public let fillAlpha: Double
        public let icon: String
        /// An outline 1.5 wide; nil: none.
        public let stroke: String?
        /// Mute and speaker while on; always opaque.
        public let activeFill: String
        public let activeIcon: String
    }

    /// Every button the screen draws.
    public struct Actions: Equatable, Sendable {
        public let answer: Action
        public let decline: Action
        public let end: Action
        public let callback: Action
        public let mute: Action
        public let speaker: Action
        public let chat: Action
        public let close: Action

        /// A button by its contract name; an unknown one is mute's (a quiet control).
        public subscript(_ name: String) -> Action {
            switch name {
            case "answer": return answer
            case "decline": return decline
            case "end": return end
            case "callback": return callback
            case "speaker": return speaker
            case "chat": return chat
            case "close": return close
            default: return mute
            }
        }
    }

    public let backdrop: Backdrop
    /// `light` or `dark`: whether `text` is light — the status bar's icons follow it.
    public let ink: String
    public let text: String
    public let textMuted: String
    public let avatarRingColor: String
    public let actions: Actions
    public let visualizerColor: String
    /// Behind a card, subtitle or bubble caption (and the card layout's card), at `captionFillAlpha`.
    public let captionFill: String
    public let captionFillAlpha: Double
}

enum SurfaceTokens {
    static let callControls: Set<String> = ["mute", "speaker", "chat", "end"]
    static let defaultControls = ["mute", "speaker", "chat", "end"]
    /// The words of a recovering call where the brand wrote none.
    static let reconnectingWords = "Reconnecting…"

    /// The eight moments, in the contract's order.
    static let moments = ["incoming", "scheduled", "outgoing", "connecting", "connected", "reconnecting", "ended", "missed"]
    static let backdropTypes = ["solid", "linear", "radial", "mesh", "blurred-avatar"]
    static let backdropMotions = ["none", "drift", "breathe"]
    static let rings = ["none", "pulse", "ripple", "glow"]
    static let layouts = ["classic", "full-bleed", "card", "orb", "minimal"]
    static let buttonStyles = ["solid", "glass", "outline"]
    static let buttonShapes = ["circle", "squircle", "pill"]
    static let buttonLabels = ["below", "none"]
    static let visualizers = ["none", "bars", "wave", "orb"]
    static let captionStyles = ["plain", "card", "subtitle", "bubble"]
    static let captionPositions = ["middle", "bottom"]

    /**
     * Graine Classic's call screen (design.json → the first case's
     * `light.call`): what is drawn before any session, without a design, and
     * for any field a server did not send or sent malformed. A word this build
     * does not know falls back to the first one listed for it — `logo`,
     * `circle`, `round`, `system` — which these are.
     */
    static let legacyFields: [String: Any] = [
        "background": "#0E0F11", "text": "#F5F5F4", "textMuted": "#A0A5AE",
        "avatar": "logo", "avatarShape": "circle", "avatarFill": "#318CE7", "avatarText": "#FFFFFF",
        "buttonFill": "#333435", "buttonIcon": "#F5F5F4", "buttonActiveFill": "#F5F5F4", "buttonActiveIcon": "#0E0F11",
        "endFill": "#DC2626", "endIcon": "#FFFFFF", "endShape": "round",
        "acceptFill": "#16A34A", "acceptIcon": "#FFFFFF", "declineFill": "#DC2626", "declineIcon": "#FFFFFF",
        "callbackFill": "#318CE7", "callbackIcon": "#FFFFFF",
        "captions": true, "timer": true, "controls": ["mute", "speaker", "chat", "end"], "ringtone": "system",
        "statusText": ["ringing": "Incoming call", "connecting": "Connecting…", "ended": "Call ended",
                       "scheduled": "Scheduled call", "missed": "Missed call"],
    ]

    /// Classic's call screen with its look derived — exactly what the server sends for it.
    static let legacyCall: GraineCallTokens = call(legacyFields, font: DesignTokens.Fallback.font)!

    static func chat(_ raw: Any?, colors c: GraineThemeTokens.Colors) -> GraineChatTokens? {
        guard let o = JSON.unwrap(raw) as? [String: Any] else { return nil }
        let suggestions = ((JSON.unwrap(o["suggestions"]) as? [Any]) ?? [])
            .compactMap { JSON.unwrap($0) as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(4)
            .map { CallWire.utf16Prefix($0, 40) }
        return GraineChatTokens(
            title: text(o["title"]) ?? "",
            subtitle: text(o["subtitle"]) ?? "",
            avatar: word(o["avatar"], in: ["logo", "glyph", "none"]) ?? "logo",
            placeholder: text(o["placeholder"]) ?? "Message…",
            showTimestamps: flag(o["showTimestamps"]) ?? false,
            suggestions: Array(suggestions),
            background: DesignTokens.hex(o["background"]) ?? c.background,
            pattern: word(o["pattern"], in: ["none", "dots"]) ?? "none",
            patternColor: DesignTokens.hex(o["patternColor"]) ?? c.border,
            headerBackground: DesignTokens.hex(o["headerBackground"]) ?? c.surface,
            headerText: DesignTokens.hex(o["headerText"]) ?? c.text,
            headerSubtext: DesignTokens.hex(o["headerSubtext"]) ?? c.textMuted,
            composerBackground: DesignTokens.hex(o["composerBackground"]) ?? c.surfaceRaised,
            composerText: DesignTokens.hex(o["composerText"]) ?? c.text,
            composerPlaceholder: DesignTokens.hex(o["composerPlaceholder"]) ?? c.textMuted,
            composerBorder: DesignTokens.hex(o["composerBorder"]) ?? c.border,
            // Absent (an older server) or a word this build does not know: the compact window.
            size: GraineChatSize(wire: o["size"]) ?? .compact,
            // The pieces the brand can leave out: absent, or anything but a boolean, is on.
            showUpcomingCalls: flag(o["showUpcomingCalls"]) ?? true,
            upcomingTitle: text(o["upcomingTitle"]) ?? "",
            showHistory: flag(o["showHistory"]) ?? true,
            newConversation: flag(o["newConversation"]) ?? true
        )
    }

    /**
     * `tokens.call`, or nil when it is not an object (an older server's scheme:
     * the screen as it was). `font` is the scheme's type: a server that
     * predates the look leaves the name's and the status line's weights to it.
     */
    static func call(_ raw: Any?, font: GraineThemeTokens.Typography? = nil) -> GraineCallTokens? {
        guard let o = JSON.unwrap(raw) as? [String: Any] else { return nil }
        let d = legacyFields
        func color(_ key: String) -> String { DesignTokens.hex(o[key]) ?? (d[key] as? String ?? "#000000") }
        var controls: [String] = []
        if let list = JSON.unwrap(o["controls"]) as? [Any] {
            for item in list {
                guard let name = (JSON.unwrap(item) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                      callControls.contains(name), !controls.contains(name) else { continue }
                controls.append(name)
            }
        }
        // A call screen with no way to hang up is not one the customer can leave.
        if controls.isEmpty { controls = defaultControls } else if !controls.contains("end") { controls.append("end") }
        let status = JSON.unwrap(o["statusText"]) as? [String: Any] ?? [:]
        let dStatus = d["statusText"] as? [String: String] ?? [:]
        let connecting = text(status["connecting"]) ?? dStatus["connecting"] ?? "Connecting…"
        let flat = Flat(
            background: color("background"),
            backgroundTo: DesignTokens.hex(o["backgroundTo"]),
            text: color("text"),
            textMuted: color("textMuted"),
            buttonFill: color("buttonFill"), buttonIcon: color("buttonIcon"),
            buttonActiveFill: color("buttonActiveFill"), buttonActiveIcon: color("buttonActiveIcon"),
            endFill: color("endFill"), endIcon: color("endIcon"),
            acceptFill: color("acceptFill"), acceptIcon: color("acceptIcon"),
            declineFill: color("declineFill"), declineIcon: color("declineIcon"),
            callbackFill: color("callbackFill"), callbackIcon: color("callbackIcon")
        )
        let base = look(o, fallback: derivedLook(flat))
        var states: [String: GraineCallLook] = [:]
        if let given = JSON.unwrap(o["states"]) as? [String: Any] {
            for m in moments { if let s = JSON.unwrap(given[m]) as? [String: Any] { states[m] = look(s, fallback: base) } }
        }
        var rings: [String: String] = [:]
        let givenRings = JSON.unwrap(o["rings"]) as? [String: Any]
        for m in moments {
            let derived = m == "incoming" || m == "scheduled" ? "pulse" : "none"
            if let r = givenRings, r.keys.contains(m) { rings[m] = pick(r[m], in: self.rings) ?? "none" } else { rings[m] = derived }
        }
        let weights = font?.weights ?? DesignTokens.Fallback.font.weights
        return GraineCallTokens(
            background: flat.background,
            backgroundTo: flat.backgroundTo,
            text: flat.text,
            textMuted: flat.textMuted,
            avatar: word(o["avatar"], in: ["logo", "glyph", "initials"]) ?? "logo",
            avatarShape: word(o["avatarShape"], in: ["circle", "squircle", "rounded-square"]) ?? "circle",
            avatarFill: color("avatarFill"),
            avatarText: color("avatarText"),
            buttonFill: flat.buttonFill,
            buttonIcon: flat.buttonIcon,
            buttonActiveFill: flat.buttonActiveFill,
            buttonActiveIcon: flat.buttonActiveIcon,
            endFill: flat.endFill,
            endIcon: flat.endIcon,
            endShape: word(o["endShape"], in: ["round", "pill"]) ?? "round",
            acceptFill: flat.acceptFill,
            acceptIcon: flat.acceptIcon,
            declineFill: flat.declineFill,
            declineIcon: flat.declineIcon,
            callbackFill: flat.callbackFill,
            callbackIcon: flat.callbackIcon,
            captions: flag(o["captions"]) ?? (d["captions"] as? Bool ?? true),
            timer: flag(o["timer"]) ?? (d["timer"] as? Bool ?? true),
            controls: controls,
            ringtone: word(o["ringtone"], in: ["system", "graine", "soft"]) ?? "system",
            statusText: .init(
                ringing: text(status["ringing"]) ?? dStatus["ringing"] ?? "Incoming call",
                connecting: connecting,
                ended: text(status["ended"]) ?? dStatus["ended"] ?? "Call ended",
                scheduled: text(status["scheduled"]) ?? dStatus["scheduled"] ?? "Scheduled call",
                missed: text(status["missed"]) ?? dStatus["missed"] ?? "Missed call",
                outgoing: text(status["outgoing"]) ?? connecting,
                reconnecting: text(status["reconnecting"]) ?? reconnectingWords
            ),
            preset: JSON.nonEmpty(o["preset"])?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "classic",
            layout: present(o, "layout") { pick($0, in: layouts) ?? layouts[0] } ?? "classic",
            look: base,
            avatarSize: number(o["avatarSize"]).map { clamp($0, 72, 160) } ?? 112,
            rings: rings,
            buttonStyle: present(o, "buttonStyle") { pick($0, in: buttonStyles) ?? buttonStyles[0] } ?? "solid",
            buttonShape: present(o, "buttonShape") { pick($0, in: buttonShapes) ?? buttonShapes[0] } ?? "circle",
            buttonSize: number(o["buttonSize"]).map { clamp($0, 52, 80) } ?? 64,
            buttonLabels: present(o, "buttonLabels") { pick($0, in: buttonLabels) ?? buttonLabels[0] } ?? "below",
            visualizer: present(o, "visualizer") { pick($0, in: visualizers) ?? visualizers[0] } ?? "none",
            visualizerSensitivity: number(o["visualizerSensitivity"]).map { clamp($0, 0, 1) } ?? 0.5,
            captionStyle: present(o, "captionStyle") { pick($0, in: captionStyles) ?? captionStyles[0] } ?? "plain",
            captionPosition: present(o, "captionPosition") { pick($0, in: captionPositions) ?? captionPositions[0] } ?? "middle",
            nameSize: number(o["nameSize"]).map { clamp($0, 20, 44) } ?? 28,
            nameWeight: number(o["nameWeight"]).map { Int(JSON.jsRound(clamp($0, 100, 900))) } ?? weights.title,
            statusSize: number(o["statusSize"]).map { clamp($0, 12, 20) } ?? 16,
            statusWeight: number(o["statusWeight"]).map { Int(JSON.jsRound(clamp($0, 100, 900))) } ?? weights.body,
            states: states
        )
    }

    /// The flat colours a look is derived from when the server sent none.
    struct Flat {
        let background: String
        let backgroundTo: String?
        let text: String
        let textMuted: String
        let buttonFill: String
        let buttonIcon: String
        let buttonActiveFill: String
        let buttonActiveIcon: String
        let endFill: String
        let endIcon: String
        let acceptFill: String
        let acceptIcon: String
        let declineFill: String
        let declineIcon: String
        let callbackFill: String
        let callbackIcon: String
    }

    /**
     * Today's screen in the look's terms (contract/DESIGN.md "An older
     * server"): the flat fill as its backdrop, the ink from the text's
     * lightness, every button from the flat colours, the ring in the status
     * colour, no caption backing.
     */
    static func derivedLook(_ f: Flat) -> GraineCallLook {
        let stops = f.backgroundTo.map { [GraineCallLook.Stop(color: f.background, at: 0), .init(color: $0, at: 1)] }
            ?? [GraineCallLook.Stop(color: f.background, at: 0)]
        let ink = Appearance.luminance(f.text) > 0.5 ? "light" : "dark"
        func plain(_ fill: String, _ icon: String, _ activeFill: String? = nil, _ activeIcon: String? = nil) -> GraineCallLook.Action {
            .init(fill: fill, fillAlpha: 1, icon: icon, stroke: nil, activeFill: activeFill ?? fill, activeIcon: activeIcon ?? icon)
        }
        let quiet = plain(f.buttonFill, f.buttonIcon, f.buttonActiveFill, f.buttonActiveIcon)
        return GraineCallLook(
            backdrop: .init(type: f.backgroundTo == nil ? "solid" : "linear", stops: stops, angle: 180, motion: "none", intensity: 0.5, scrim: 1),
            ink: ink,
            text: f.text,
            textMuted: f.textMuted,
            avatarRingColor: f.textMuted,
            actions: .init(
                answer: plain(f.acceptFill, f.acceptIcon), decline: plain(f.declineFill, f.declineIcon),
                end: plain(f.endFill, f.endIcon), callback: plain(f.callbackFill, f.callbackIcon),
                mute: quiet, speaker: quiet, chat: quiet, close: quiet
            ),
            visualizerColor: f.text,
            captionFill: ink == "light" ? "#000000" : "#FFFFFF",
            captionFillAlpha: 0
        )
    }

    /// A look as the server sent it, each key falling back on its own to `fallback`'s.
    static func look(_ o: [String: Any], fallback d: GraineCallLook) -> GraineCallLook {
        let text = DesignTokens.hex(o["text"]) ?? d.text
        let ink = present(o, "ink") { pick($0, in: ["light", "dark"]) ?? "light" } ?? d.ink
        var actions = d.actions
        if let given = JSON.unwrap(o["actions"]) as? [String: Any] {
            func action(_ name: String) -> GraineCallLook.Action {
                let fb = d.actions[name]
                guard let a = JSON.unwrap(given[name]) as? [String: Any] else { return fb }
                // `null` is a legitimate answer: no outline.
                let stroke: String?
                if a.keys.contains("stroke") {
                    let given = JSON.unwrap(a["stroke"])
                    stroke = given == nil || given is NSNull ? nil : (DesignTokens.hex(given) ?? fb.stroke)
                } else {
                    stroke = fb.stroke
                }
                return .init(
                    fill: DesignTokens.hex(a["fill"]) ?? fb.fill,
                    fillAlpha: number(a["fillAlpha"]).map { clamp($0, 0, 1) } ?? fb.fillAlpha,
                    icon: DesignTokens.hex(a["icon"]) ?? fb.icon,
                    stroke: stroke,
                    activeFill: DesignTokens.hex(a["activeFill"]) ?? fb.activeFill,
                    activeIcon: DesignTokens.hex(a["activeIcon"]) ?? fb.activeIcon
                )
            }
            actions = .init(
                answer: action("answer"), decline: action("decline"), end: action("end"), callback: action("callback"),
                mute: action("mute"), speaker: action("speaker"), chat: action("chat"), close: action("close")
            )
        }
        return GraineCallLook(
            backdrop: backdrop(o["backdrop"], fallback: d.backdrop),
            ink: ink,
            text: text,
            textMuted: DesignTokens.hex(o["textMuted"]) ?? d.textMuted,
            avatarRingColor: DesignTokens.hex(o["avatarRingColor"]) ?? d.avatarRingColor,
            actions: actions,
            visualizerColor: DesignTokens.hex(o["visualizerColor"]) ?? d.visualizerColor,
            captionFill: DesignTokens.hex(o["captionFill"]) ?? d.captionFill,
            captionFillAlpha: number(o["captionFillAlpha"]).map { clamp($0, 0, 1) } ?? d.captionFillAlpha
        )
    }

    /// A backdrop as the server sent it: each key on its own, stops only when at least one is a colour.
    static func backdrop(_ raw: Any?, fallback d: GraineCallLook.Backdrop) -> GraineCallLook.Backdrop {
        guard let b = JSON.unwrap(raw) as? [String: Any] else { return d }
        var stops: [GraineCallLook.Stop] = []
        if let list = JSON.unwrap(b["stops"]) as? [Any] {
            for (i, item) in list.enumerated() {
                guard let s = JSON.unwrap(item) as? [String: Any], let c = DesignTokens.hex(s["color"]) else { continue }
                let at = number(s["at"]).map { clamp($0, 0, 1) } ?? (list.count > 1 ? Double(i) / Double(list.count - 1) : 0)
                stops.append(.init(color: c, at: at))
                if stops.count == 5 { break }
            }
        }
        return .init(
            type: present(b, "type") { pick($0, in: backdropTypes) ?? backdropTypes[0] } ?? d.type,
            stops: stops.isEmpty ? d.stops : stops,
            angle: number(b["angle"]) ?? d.angle,
            motion: present(b, "motion") { pick($0, in: backdropMotions) ?? backdropMotions[0] } ?? d.motion,
            intensity: number(b["intensity"]).map { clamp($0, 0, 1) } ?? d.intensity,
            scrim: number(b["scrim"]).map { clamp($0, 0, 1) } ?? d.scrim
        )
    }

    /// `body(value)` when the key is there; nil when it is absent (so the caller derives it).
    private static func present<T>(_ o: [String: Any], _ key: String, _ body: (Any?) -> T) -> T? {
        o.keys.contains(key) ? body(o[key]) : nil
    }

    /// A word from a list, trimmed and lower-cased; nil when it is not one of them.
    private static func pick(_ raw: Any?, in allowed: [String]) -> String? {
        guard let s = (JSON.unwrap(raw) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              allowed.contains(s) else { return nil }
        return s
    }

    /// A real number — never a string or a boolean.
    private static func number(_ raw: Any?) -> Double? {
        guard let v = JSON.unwrap(raw), let n = JSON.number(v) else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }

    private static func text(_ raw: Any?) -> String? {
        guard let s = (JSON.unwrap(raw) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    private static func word(_ raw: Any?, in allowed: Set<String>) -> String? {
        guard let s = (JSON.unwrap(raw) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              allowed.contains(s) else { return nil }
        return s
    }

    private static func flag(_ raw: Any?) -> Bool? {
        guard let v = JSON.unwrap(raw) else { return nil }
        return JSON.bool(v)
    }
}

extension DesignTokens {
    /**
     * A design for a surface that has none to draw with — the chat screen on an
     * older server, or before the first session ever arrived: the widget
     * palettes the SDK drew before designs (Appearance.palette), around the
     * dashboard's accent, and Graine Classic's everything else.
     */
    static func classic(dark: Bool, accent rawAccent: String) -> GraineThemeTokens {
        let accent = hex(rawAccent) ?? Appearance.defaultAccent
        let palette = Appearance.palette(["theme": dark ? "dark" : "light"], deviceDark: dark, accent: accent)
        let background = dark ? "#101114" : "#F7F7F5"
        let colors: [String: Any] = [
            "background": background, "surface": palette.surface, "surfaceRaised": dark ? "#1F2024" : "#FFFFFF",
            "text": palette.text, "textMuted": palette.muted, "border": palette.border,
            "accent": accent, "onAccent": palette.onAccent, "accentSoft": mix(accent, over: background, share: 0.14),
            "success": "#1FAD5B", "warning": "#F5A524", "danger": "#E5484D",
            "userBubble": accent, "userBubbleText": palette.onAccent,
            "agentBubble": dark ? "#1F2024" : "#FFFFFF", "agentBubbleText": palette.text, "scrim": "#000000",
        ]
        // Only the colours are required, and every one is given: this cannot be nil.
        return parse(["colors": colors], scheme: dark ? "dark" : "light")!
    }

    /// `color` at `share` over `base`, as #RRGGBB.
    static func mix(_ color: String, over base: String, share: Double) -> String {
        guard let c = Appearance.rgb(color), let b = Appearance.rgb(base) else { return base }
        func channel(_ x: Double, _ y: Double) -> String {
            String(format: "%02X", Int((x * share + y * (1 - share)) * 255 + 0.5))
        }
        return "#" + channel(c.red, b.red) + channel(c.green, b.green) + channel(c.blue, b.blue)
    }
}
