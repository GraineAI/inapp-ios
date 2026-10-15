import Foundation

/*
 * THE VOICE BAR'S RULES — the numbers, the words and the timing of
 * contract/DESIGN.md "Voice bar" and "Chat window", which the dashboard's
 * Garage draws in its phone preview. The views in UI/ draw them; they live
 * here, pure, so a Mac proves them and no view can round a number its own way.
 */

enum VoiceBar {
    /// The frame: 60 high, 9 in from each side, its items 10 apart.
    static let height = 60.0
    static let sidePadding = 9.0
    static let spacing = 10.0
    /// The avatar, and every round button on the bar.
    static let button = 38.0
    /// The launcher glyph in the avatar, and the icon on every button.
    static let icon = 18.0
    /// The heading's first letter, when the avatar has neither a glyph nor a logo.
    static let initial = 15.0
    static let nameSize = 14.0
    static let nameLineHeight = 17.5
    /// Between the meter and the status words.
    static let meterGap = 6.0
    /// A line still arriving is drawn a little faint until it settles.
    static let liveOpacity = 0.75
    /// The microphone while it cannot act.
    static let blockedOpacity = 0.4
    /// How far an arriving caption or chat window rises into place.
    static let rise = 8.0
    /// The caption (or the chat window) sits this far above the bar.
    static let stackGap = 8.0

    /// The line being said, above the bar.
    enum Caption {
        static let paddingH = 12.0
        static let paddingV = 8.0
        static let size = 13.0
        static let lineHeight = 17.5
        static let maxLines = 2
        /// "YOU", above the customer's own lines.
        static let youSize = 10.5
        static let youTracking = 0.6

        /**
         * The line the bar shows above it: the last one said, on a call, while
         * the captions switch is on — never an empty one. The whole transcript
         * would push the bar off the screen.
         */
        static func line(connected: Bool, captionsOn: Bool, captions: [GraineCaption]) -> GraineCaption? {
            guard connected, captionsOn, let last = captions.last,
                  !last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return last
        }
    }

    /// The chat window, above the bar while the customer is in the chat.
    enum Chat {
        static let header = 50.0
        static let mark = 30.0
        static let markGlyph = 14.0
        static let titleMax = 16.0
        static let dot = 6.0
        static let composer = 58.0
        static let field = 40.0
        static let send = 40.0
        /// A message is at most this share of the window's width.
        static let bubbleShare = 0.84
    }
}

/**
 * THE METER — four bars moving at the design's own pace, so the motion knob
 * shows on the one surface a customer watches during a call. The Garage's
 * `dg-eq`: each bar scales from its bottom between 35% and 100% and back, one
 * leg every max(420, durationMs × 3.2) ms, eased in and out, each 90 ms behind
 * the last. Still, at full height, when the design has no motion or the OS
 * asked for less.
 */
enum VoiceMeter {
    /// The bars' heights, as shares of the meter's.
    static let heights = [0.55, 1, 0.7, 0.4]
    static let height = 12.0
    static let barWidth = 2.5
    static let barGap = 2.0
    /// The lowest a bar sinks, as a share of its own height.
    static let low = 0.35
    /// Each bar starts this long after the one before it.
    static let staggerMs = 90.0

    /// One leg — up, or down.
    static func legMs(durationMs: Double) -> Double {
        max(420, durationMs * 3.2)
    }

    /// `durationMs` is the design's after Reduce Motion has had its say (Motion.effectiveDurationMs).
    static func moves(durationMs: Double, reduceMotion: Bool) -> Bool {
        durationMs > 0 && !reduceMotion
    }

    /// Bar `i`'s height in points, rounded to a tenth as the React Native bar rounds it.
    static func barHeight(_ i: Int) -> Double {
        guard heights.indices.contains(i) else { return 0 }
        return JSON.jsRound(height * heights[i] * 10) / 10
    }

    /**
     * Bar `i`'s scale `elapsedMs` after the meter appeared. Every bar starts
     * low, so none of them jumps when its turn comes; then up and down, one
     * leg at a time, for as long as it is on screen.
     */
    static func scale(bar i: Int, elapsedMs: Double, legMs: Double) -> Double {
        let t = elapsedMs - Double(i) * staggerMs
        guard t > 0, legMs > 0 else { return low }
        let legs = t / legMs
        let done = legs.rounded(.down)
        let eased = CubicBezier.easeInOut(legs - done)
        let rising = Int(done.truncatingRemainder(dividingBy: 2)) == 0
        return low + (1 - low) * (rising ? eased : 1 - eased)
    }
}

/**
 * A CSS cubic-bézier timing curve: progress in time → progress in value.
 * WebKit's UnitBezier — Newton's method, then bisection where it stalls — so
 * a curve here is the one the Garage animates with in the browser.
 */
struct CubicBezier {
    private let ax: Double, bx: Double, cx: Double
    private let ay: Double, by: Double, cy: Double

    init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        cx = 3 * x1
        bx = 3 * (x2 - x1) - cx
        ax = 1 - cx - bx
        cy = 3 * y1
        by = 3 * (y2 - y1) - cy
        ay = 1 - cy - by
    }

    /// CSS `ease-in-out`.
    static let easeInOut = CubicBezier(0.42, 0, 0.58, 1)

    func callAsFunction(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        return sample(ay, by, cy, solve(x))
    }

    private func sample(_ a: Double, _ b: Double, _ c: Double, _ t: Double) -> Double {
        ((a * t + b) * t + c) * t
    }

    /// The curve's own parameter where its x is `x`.
    private func solve(_ x: Double) -> Double {
        let epsilon = 1e-7
        var t = x
        for _ in 0..<8 {
            let error = sample(ax, bx, cx, t) - x
            if abs(error) < epsilon { return t }
            let slope = (3 * ax * t + 2 * bx) * t + cx
            if abs(slope) < 1e-6 { break }
            t -= error / slope
        }
        var lo = 0.0, hi = 1.0
        t = x
        while lo < hi {
            let value = sample(ax, bx, cx, t)
            if abs(value - x) < epsilon { return t }
            if x > value { lo = t } else { hi = t }
            t = (lo + hi) / 2
            if hi - lo < epsilon { break }
        }
        return t
    }
}

/**
 * WHAT THE STATUS LINE SAYS — contract/DESIGN.md "Status words", first match
 * wins, in sentence case. While the bar waits (connecting, reconnecting, the
 * agent thinking) it draws the dashboard's loader with that moment's words
 * instead; while the agent listens or speaks, the meter leads the words.
 *
 * The bar drawn without a design keeps BarStatus, its own words from before
 * designs existed: an older server's look does not change.
 */
enum VoiceBarStatus {
    struct Input: Equatable {
        /// A misconfiguration the call reported — its transport `not_configured`.
        var error = false
        /// The customer is in the chat rather than on a call.
        var inChat = false
        var chatOnline = false
        /// The page's view of the network; nil until it has said.
        var online: Bool? = nil
        var reconnecting = false
        var connectivity: GraineConnectivity = .ready
        var micDenied = false
        var ready = true
        var connecting = false
        var muted = false
        var connected = false
        var phase: GrainePhase = .idle
        var quality: GraineConnectionQuality = .unknown
        /// Neither transport could carry the last start (`graine:progress` `failed`).
        var callFailed = false
        /// Where the connect is, as the engine reports it.
        var connectStage: GraineConnectStage? = nil
        /// The customer has waited on this connect past `GraineConfig.Timing.slowConnectMs`.
        var slowConnect = false
        /// The brand's words for the connecting moment (Appearance → Loading), resolved: the default when they chose none.
        var connectingWords = "Connecting…"
    }

    struct Line: Equatable {
        /// The contract's words for this moment.
        let text: String
        /// "connecting", "reconnecting" or "thinking": draw the loader with that moment's words instead of `text`.
        let waiting: String?
        /// The agent is listening or speaking: the meter goes before the words.
        let meter: Bool
        /// Words the loader says in place of the moment's own ("Still connecting…"). Nil: the moment's.
        var label: String? = nil

        /// What the line says out loud: the label, else the brand's words for the moment it waits on, else the text.
        func spoken(loader: GraineLoaderLook) -> String {
            label ?? waiting.flatMap { loader.text.forMoment($0) } ?? text
        }
    }

    /**
     * WHAT A CONNECT SAYS WHILE IT RUNS. Measured, the commonest slow connect
     * on mobile data is a connection the phone dropped while idle being
     * replaced: a few seconds the customer will wait if the bar says what is
     * happening, and will not if it says "Connecting…" for all of them.
     *
     * The words stay the BRAND's. The loader draws each moment in the wording
     * set under Appearance → Loading — often not English — so a retry or a
     * switch to the other transport is the "reconnecting" moment, in their
     * words, and a slow connect only says "Still connecting…" while the brand
     * has left "Connecting…" as it was. A wording someone chose is never
     * overwritten. The React Native bar's `connectingLook`.
     */
    static func connecting(_ s: Input) -> Line {
        if s.connectStage == .retrying || s.connectStage == .switching {
            return Line(text: "Reconnecting…", waiting: "reconnecting", meter: false)
        }
        if s.slowConnect && s.connectingWords == Loaders.defaultText.connecting {
            return Line(text: "Still connecting…", waiting: "connecting", meter: false, label: "Still connecting…")
        }
        return Line(text: s.connectingWords, waiting: "connecting", meter: false)
    }

    static func line(_ s: Input) -> Line {
        func say(_ text: String) -> Line { Line(text: text, waiting: nil, meter: false) }
        if s.error { return say("Unavailable") }
        // The chat has no microphone and no call to place: none of the words below are true there.
        if s.inChat { return s.chatOnline ? say("Online") : Line(text: "Connecting…", waiting: "connecting", meter: false) }
        // The network gets named, or the agent takes the blame for it.
        if s.online == false { return say("No connection") }
        if s.reconnecting || s.connectivity == .retrying { return Line(text: "Reconnecting…", waiting: "reconnecting", meter: false) }
        if s.micDenied { return say("Needs microphone") }
        if s.connectivity == .failed { return say("Couldn’t load · tap to retry") }
        // Neither transport could carry the call. The microphone tries again.
        if s.callFailed { return say("Couldn’t connect · tap to retry") }
        if !s.ready || s.connecting { return connecting(s) }
        if s.muted { return say("Muted") }
        // The gap between the customer finishing and the agent answering: a loader, not a meter over silence.
        if s.connected && s.phase == .thinking { return Line(text: "Thinking…", waiting: "thinking", meter: false) }
        if s.connected && s.phase == .speaking { return Line(text: "Speaking", waiting: nil, meter: true) }
        if s.connected && s.quality == .poor { return say("Weak connection") }
        if s.connected { return Line(text: "Listening", waiting: nil, meter: true) }
        return say("Tap to talk")
    }
}

/**
 * The call and the chat are two products in one agent, and which of them a
 * customer is offered is the brand's decision (Embed & Widgets → What visitors
 * get: `appearance.mode`, absent meaning both) — protocol.ts `resolveSurface`,
 * SurfacePolicy. The switch between them shows only when the dashboard offers
 * both AND the SDK can carry the chat: a switch into a chat that cannot send a
 * word would be worse than no switch at all.
 */
enum AgentSurfaces {
    static func canSwitch(appearance: [String: Any]?, carriesChat: Bool) -> Bool {
        guard carriesChat else { return false }
        return SurfacePolicy.resolve(appearance: appearance, prefer: nil).canSwitch
    }
}

/**
 * ONE MESSAGE'S SHAPE in the chat window: corners `radius.lg` with the one
 * nearest the speaker at `radius.sm`, padded `cardPadding × 0.75` by
 * `cardPadding` — except the agent's words under `minimal`, which sit on the
 * page as plain text with no bubble at all. The colours are
 * DesignRules.bubble's.
 */
enum ChatBubble {
    struct Shape: Equatable {
        let paddingH: Double
        let paddingV: Double
        let topLeading: Double
        let topTrailing: Double
        let bottomLeading: Double
        let bottomTrailing: Double
    }

    static func shape(_ t: GraineThemeTokens, role: GraineRole) -> Shape {
        let r = t.shape.radius
        let pad = t.spacing.cardPadding
        if t.bubbles == .minimal && role == .agent {
            return Shape(paddingH: 2, paddingV: 2, topLeading: 0, topTrailing: 0, bottomLeading: 0, bottomTrailing: 0)
        }
        let customer = role == .customer
        return Shape(
            paddingH: pad,
            paddingV: JSON.jsRound(pad * 0.75),
            topLeading: r.lg,
            topTrailing: r.lg,
            bottomLeading: customer ? r.lg : r.sm,
            bottomTrailing: customer ? r.sm : r.lg
        )
    }
}
