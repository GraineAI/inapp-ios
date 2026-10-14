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
}

enum SurfaceTokens {
    static let callControls: Set<String> = ["mute", "speaker", "chat", "end"]
    static let defaultControls = ["mute", "speaker", "chat", "end"]

    /**
     * Graine Classic's call screen (design.json → the first case's
     * `light.call`): what is drawn before any session, without a design, and
     * for any field a server did not send or sent malformed. A word this build
     * does not know falls back to the first one listed for it — `logo`,
     * `circle`, `round`, `system` — which these are.
     */
    static let legacyCall = GraineCallTokens(
        background: "#0E0F11", backgroundTo: nil, text: "#F5F5F4", textMuted: "#A0A5AE",
        avatar: "logo", avatarShape: "circle", avatarFill: "#318CE7", avatarText: "#FFFFFF",
        buttonFill: "#333435", buttonIcon: "#F5F5F4", buttonActiveFill: "#F5F5F4", buttonActiveIcon: "#0E0F11",
        endFill: "#DC2626", endIcon: "#FFFFFF", endShape: "round",
        acceptFill: "#16A34A", acceptIcon: "#FFFFFF", declineFill: "#DC2626", declineIcon: "#FFFFFF",
        callbackFill: "#318CE7", callbackIcon: "#FFFFFF",
        captions: true, timer: true, controls: ["mute", "speaker", "chat", "end"], ringtone: "system",
        statusText: .init(ringing: "Incoming call", connecting: "Connecting…", ended: "Call ended",
                          scheduled: "Scheduled call", missed: "Missed call")
    )

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

    static func call(_ raw: Any?) -> GraineCallTokens? {
        guard let o = JSON.unwrap(raw) as? [String: Any] else { return nil }
        let d = legacyCall
        func color(_ key: String, _ fallback: String) -> String { DesignTokens.hex(o[key]) ?? fallback }
        var controls: [String] = []
        if let list = JSON.unwrap(o["controls"]) as? [Any] {
            for item in list {
                guard let name = (JSON.unwrap(item) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                      callControls.contains(name), !controls.contains(name) else { continue }
                controls.append(name)
            }
        }
        // A call screen with no way to hang up is not one the customer can leave.
        if controls.isEmpty { controls = d.controls } else if !controls.contains("end") { controls.append("end") }
        let status = JSON.unwrap(o["statusText"]) as? [String: Any] ?? [:]
        return GraineCallTokens(
            background: color("background", d.background),
            backgroundTo: DesignTokens.hex(o["backgroundTo"]),
            text: color("text", d.text),
            textMuted: color("textMuted", d.textMuted),
            avatar: word(o["avatar"], in: ["logo", "glyph", "initials"]) ?? d.avatar,
            avatarShape: word(o["avatarShape"], in: ["circle", "squircle", "rounded-square"]) ?? d.avatarShape,
            avatarFill: color("avatarFill", d.avatarFill),
            avatarText: color("avatarText", d.avatarText),
            buttonFill: color("buttonFill", d.buttonFill),
            buttonIcon: color("buttonIcon", d.buttonIcon),
            buttonActiveFill: color("buttonActiveFill", d.buttonActiveFill),
            buttonActiveIcon: color("buttonActiveIcon", d.buttonActiveIcon),
            endFill: color("endFill", d.endFill),
            endIcon: color("endIcon", d.endIcon),
            endShape: word(o["endShape"], in: ["round", "pill"]) ?? d.endShape,
            acceptFill: color("acceptFill", d.acceptFill),
            acceptIcon: color("acceptIcon", d.acceptIcon),
            declineFill: color("declineFill", d.declineFill),
            declineIcon: color("declineIcon", d.declineIcon),
            callbackFill: color("callbackFill", d.callbackFill),
            callbackIcon: color("callbackIcon", d.callbackIcon),
            captions: flag(o["captions"]) ?? d.captions,
            timer: flag(o["timer"]) ?? d.timer,
            controls: controls,
            ringtone: word(o["ringtone"], in: ["system", "graine", "soft"]) ?? d.ringtone,
            statusText: .init(
                ringing: text(status["ringing"]) ?? d.statusText.ringing,
                connecting: text(status["connecting"]) ?? d.statusText.connecting,
                ended: text(status["ended"]) ?? d.statusText.ended,
                scheduled: text(status["scheduled"]) ?? d.statusText.scheduled,
                missed: text(status["missed"]) ?? d.statusText.missed
            )
        )
    }

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
