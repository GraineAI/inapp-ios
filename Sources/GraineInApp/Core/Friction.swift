import Foundation

/**
 * One layer of friction rules — the dashboard's (Embed & Widgets → friction,
 * served with the session) or the app's own, applied over it. Most apps set
 * nothing; pass one for the screens only the app knows about — a terms page
 * nobody is stuck on, an OTP step where twenty seconds is already long.
 *
 * Kept as JSON in the React Native SDK's own shape, because that is how the
 * dashboard's layer arrives and one reader for both is one set of rules:
 *
 *     { "enabled": true, "idle": { "afterMs": 45000 } | false, "cooldownMs": 60000,
 *       "message": "…{title}…{seconds}…{field}…{error}…",
 *       "nudge": { "cooldownSeconds": 20, "maxPerSession": 3, "openLauncher": false },
 *       "requireOutstandingField": true,
 *       "screens": { "<screen id>": { "ignore": true, "idle": {…} | false, "message": "…" } } }
 */
public struct GraineFrictionConfig {
    public let json: [String: Any]

    public init(json: [String: Any]) {
        self.json = json
    }

    /// Per-screen overrides.
    public struct Screen {
        public var ignore: Bool?
        /// 0 or less switches the idle rule off on this screen.
        public var idleAfterMs: Int?
        public var message: String?

        public init(ignore: Bool? = nil, idleAfterMs: Int? = nil, message: String? = nil) {
            self.ignore = ignore
            self.idleAfterMs = idleAfterMs
            self.message = message
        }
    }

    /**
     * - Parameters:
     *   - idleAfterMs: on one screen this long → stalled_on_step. Default 45s; 0 or less is off.
     *   - cooldownMs: minimum gap between two signals on the same screen. Default 60s.
     *   - cooldownSeconds / maxPerSession: the runtime's pacing of unsolicited interventions (20s / 3).
     *   - message: what the agent is told instead of the built-in sentence: {title} {screen} {seconds} {field} {error}.
     *   - requireOutstandingField: fire only while a field is outstanding (invalid, or empty and not
     *     optional), timed from when it became so. Default true; false is the React Native rule.
     */
    public init(
        enabled: Bool? = nil,
        idleAfterMs: Int? = nil,
        cooldownMs: Int? = nil,
        cooldownSeconds: Int? = nil,
        maxPerSession: Int? = nil,
        openLauncher: Bool? = nil,
        message: String? = nil,
        requireOutstandingField: Bool? = nil,
        screens: [String: Screen] = [:]
    ) {
        var j: [String: Any] = [:]
        if let enabled = enabled { j["enabled"] = enabled }
        if let ms = idleAfterMs { j["idle"] = ms > 0 ? (["afterMs": ms] as [String: Any]) as Any : false as Any }
        if let ms = cooldownMs { j["cooldownMs"] = ms }
        var nudge: [String: Any] = [:]
        if let s = cooldownSeconds { nudge["cooldownSeconds"] = s }
        if let m = maxPerSession { nudge["maxPerSession"] = m }
        if let o = openLauncher { nudge["openLauncher"] = o }
        if !nudge.isEmpty { j["nudge"] = nudge }
        if let message = message { j["message"] = message }
        if let r = requireOutstandingField { j["requireOutstandingField"] = r }
        if !screens.isEmpty {
            var s: [String: Any] = [:]
            for (id, rules) in screens {
                var o: [String: Any] = [:]
                if let ignore = rules.ignore { o["ignore"] = ignore }
                if let ms = rules.idleAfterMs { o["idle"] = ms > 0 ? (["afterMs": ms] as [String: Any]) as Any : false as Any }
                if let message = rules.message { o["message"] = message }
                s[id] = o
            }
            j["screens"] = s
        }
        self.json = j
    }
}

/// Every layer applied: what is actually in force.
struct FrictionRules: Equatable {
    enum Idle: Equatable {
        case off
        case after(Double)
    }

    struct Screen: Equatable {
        var ignore: Bool?
        var idle: Idle?
        var message: String?
    }

    struct ForScreen: Equatable {
        let ignore: Bool
        let idle: Idle
        let message: String
    }

    var enabled = true
    var cooldownMs: Double = 60_000
    var idle: Idle = .after(45_000)
    var message = ""
    var cooldownSeconds: Double = 20
    var maxPerSession: Double = 3
    var openLauncher = false
    /// The SDK's own gate (the Android SDK's too): false is the React Native rule.
    var requireOutstandingField = true
    var screens: [String: Screen] = [:]

    /// React Native's `rulesFor`: the top level with that screen's overrides on it.
    func forScreen(_ id: String?) -> ForScreen {
        let over = id.flatMap { $0.isEmpty ? nil : screens[$0] }
        return ForScreen(ignore: over?.ignore ?? false, idle: over?.idle ?? idle, message: over?.message ?? message)
    }
}

/// The customer looks stuck. `detail` is plain English, given to the agent verbatim.
public struct GraineFrictionSignal {
    /// "stalled_on_step".
    public let name: String
    public let screen: String
    public let detail: String
    /// `seconds`, `field` and `error`, as the agent's runtime reads them.
    public let data: [String: Any]
    public let cooldownSeconds: Double
    public let maxPerSession: Double
    /// For a host that draws its own launcher: open it for this.
    public let openLauncher: Bool
}

enum Friction {
    static let defaultIdleMs: Double = 45_000

    /**
     * Defaults ← each layer in order, each changing only what it names — the
     * React Native SDK's `resolveFriction`. Unknown keys are dropped and bad
     * numbers fall back, so a hand-edited JSON document can never switch the
     * feature into a state the code did not intend.
     */
    static func resolve(_ layers: [[String: Any]?]) -> FrictionRules {
        var out = FrictionRules()
        for case let layer? in layers {
            let top = screenRules(layer, base: out)
            if let idle = top.idle { out.idle = idle }
            if let message = top.message { out.message = message }
            if let v = JSON.unwrap(layer["enabled"]), let b = JSON.bool(v) { out.enabled = b }
            if let ms = positive(layer["cooldownMs"]) { out.cooldownMs = ms }
            if let nudge = layer["nudge"] as? [String: Any] {
                if let s = positive(nudge["cooldownSeconds"]) { out.cooldownSeconds = s }
                if let m = positive(nudge["maxPerSession"]) { out.maxPerSession = m }
                if let v = JSON.unwrap(nudge["openLauncher"]), let b = JSON.bool(v) { out.openLauncher = b }
            }
            if let v = JSON.unwrap(layer["requireOutstandingField"]), let b = JSON.bool(v) {
                out.requireOutstandingField = b
            }
            if let screens = layer["screens"] as? [String: Any] {
                for (id, raw) in screens where !id.isEmpty {
                    let next = screenRules(raw, base: out)
                    var merged = out.screens[id] ?? FrictionRules.Screen()
                    if let v = next.ignore { merged.ignore = v }
                    if let v = next.idle { merged.idle = v }
                    if let v = next.message { merged.message = v }
                    out.screens[id] = merged
                }
            }
        }
        return out
    }

    /// One screen's rules (or the top level's), read against the rules resolved so far.
    private static func screenRules(_ raw: Any?, base: FrictionRules) -> FrictionRules.Screen {
        var out = FrictionRules.Screen()
        guard let r = JSON.unwrap(raw) as? [String: Any] else { return out }
        if let v = JSON.unwrap(r["ignore"]), JSON.bool(v) == true { out.ignore = true }
        let fallback: Double
        if case .after(let ms) = base.idle { fallback = ms } else { fallback = defaultIdleMs }
        out.idle = idleRule(r["idle"], fallbackAfter: fallback)
        if let m = r["message"] as? String {
            let t = m.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.message = t }
        }
        return out
    }

    /**
     * `false` is off; absent or null inherits (nil); an object reads `afterMs`
     * over the layer below's value. The shape decides: a missing or
     * non-positive `afterMs` falls back rather than switching the rule off.
     */
    private static func idleRule(_ raw: Any?, fallbackAfter: Double) -> FrictionRules.Idle? {
        guard let v = JSON.unwrap(raw), !(v is NSNull) else { return nil }
        if let b = JSON.bool(v) { return b ? nil : .off }
        if let obj = v as? [String: Any] { return .after(positive(obj["afterMs"]) ?? fallbackAfter) }
        if v is [Any] { return .after(fallbackAfter) }   // a JavaScript array is an object with no afterMs
        return nil
    }

    /// A positive finite number, or a string holding one — a hand-edited JSON document says both.
    static func positive(_ value: Any?) -> Double? {
        guard let v = JSON.unwrap(value) else { return nil }
        let n: Double?
        if let s = v as? String {
            n = JSON.jsNumber(fromString: s)
        } else if let num = JSON.number(v) {
            n = num.doubleValue
        } else {
            n = nil
        }
        guard let d = n, d.isFinite, d > 0 else { return nil }
        return d
    }
}

/**
 * STALLED ON A STEP — the idle half of the React Native SDK's friction
 * detector, with time passed in so every rule is a unit test.
 *
 * The clock is per screen VISIT: a field edit on the same screen does not
 * restart it (a customer typing one character every forty seconds is exactly
 * who is stuck); a different screen, or `onInteraction`, does. It fires at
 * most once per visit, and never twice on one screen inside the cooldown.
 *
 * Two gates the React Native rule does not have, both on in the SDK (as on
 * Android) and off for the parity suite, which proves the React Native rule
 * itself:
 *  - `requireOutstandingField`: the clock runs only while a field is
 *    outstanding, from the moment it became so;
 *  - `gateOnCall`: the clock runs only while a call is live, from when it
 *    connected — so the one signal per visit goes to a conversation that can
 *    hear it, and a new call on the same screen may hear it again.
 */
final class FrictionDetector {
    private(set) var rules: FrictionRules
    private let gateOnCall: Bool
    private var screen: GraineScreen?
    private var screenSince: Double = 0
    private var stuckSince: Double?
    private var callSince: Double?
    private var idleFiredFor: String?
    private var lastSignalAt: [String: Double] = [:]

    init(rules: FrictionRules = FrictionRules(), gateOnCall: Bool = false) {
        self.rules = rules
        self.gateOnCall = gateOnCall
    }

    func configure(_ next: FrictionRules) {
        rules = next
    }

    /// The app reported a screen. A different id is a new visit; the same id is an update.
    func onScreen(_ next: GraineScreen?, now: Double) {
        let prev = screen
        screen = next
        guard let next = next else {
            stuckSince = nil
            return
        }
        if prev == nil || prev?.screen != next.screen {
            screenSince = now
            idleFiredFor = nil
            stuckSince = nil
        }
        stuckSince = FrictionDetector.outstanding(next.fields).isEmpty ? nil : (stuckSince ?? now)
    }

    /// The customer did something — the idle clock restarts.
    func onInteraction(now: Double) {
        screenSince = now
    }

    /// A call connected or ended. Only read when the detector is gated on a call.
    func onCall(live: Bool, now: Double) {
        if live && callSince == nil {
            callSince = now
            idleFiredFor = nil
        }
        if !live { callSince = nil }
    }

    private func active() -> FrictionRules.ForScreen? {
        guard let s = screen, rules.enabled else { return nil }
        let r = rules.forScreen(s.screen)
        return r.ignore ? nil : r
    }

    private func startedAt() -> Double? {
        var start = screenSince
        if rules.requireOutstandingField {
            guard let stuck = stuckSince else { return nil }
            start = max(start, stuck)
        }
        if gateOnCall {
            guard let call = callSince else { return nil }
            start = max(start, call)
        }
        return start
    }

    /// How long until the idle rule should fire, or nil if it should not.
    func idleDueIn(now: Double) -> Double? {
        guard let r = active(), case .after(let after) = r.idle, let s = screen else { return nil }
        if idleFiredFor == s.screen { return nil }
        guard let start = startedAt() else { return nil }
        return max(0, after - (now - start))
    }

    /// The idle timer went off. At most once per visit.
    func onIdle(now: Double) -> GraineFrictionSignal? {
        guard let r = active(), case .after(let after) = r.idle, let s = screen else { return nil }
        if idleFiredFor == s.screen { return nil }
        guard let start = startedAt() else { return nil }
        if now - start < after { return nil }
        idleFiredFor = s.screen

        if let last = lastSignalAt[s.screen], now - last < rules.cooldownMs { return nil }
        lastSignalAt[s.screen] = now

        let pool = rules.requireOutstandingField ? FrictionDetector.outstanding(s.fields) : s.fields
        let stuck = pool.first { $0.status == .invalid || $0.error?.isEmpty == false }
            ?? pool.first { $0.status == .empty }
        let vars: [String: Any] = [
            "seconds": JSON.jsRound(after / 1000),
            "field": stuck.map { $0.label ?? $0.name } ?? "",
            "error": stuck.map { $0.error ?? $0.status?.rawValue ?? "" } ?? "",
        ]
        var all = vars
        all["title"] = s.title ?? s.screen
        all["screen"] = s.screen
        let fallback: String
        if let stuck = stuck {
            fallback = "The customer has not touched the \"{title}\" screen for {seconds}s. The \"{field}\" field is "
                + (stuck.error?.isEmpty == false ? "showing: {error}" : "{error}") + "."
        } else {
            fallback = "The customer has not touched the \"{title}\" screen for {seconds}s."
        }
        return GraineFrictionSignal(
            name: "stalled_on_step",
            screen: s.screen,
            detail: FrictionDetector.fill(r.message.isEmpty ? fallback : r.message, all),
            data: vars,
            cooldownSeconds: rules.cooldownSeconds,
            maxPerSession: rules.maxPerSession,
            openLauncher: rules.openLauncher
        )
    }

    /**
     * What the customer still has to deal with. `locked` is not theirs to fix
     * and `optional` not theirs to have to; an explicit error outranks optional.
     */
    static func outstanding(_ fields: [GraineField]) -> [GraineField] {
        fields.filter { f in
            f.error?.isEmpty == false || (!f.isOptional && (f.status == .invalid || f.status == .empty))
        }
    }

    private static let placeholder: NSRegularExpression = {
        do {
            // JavaScript's \w is ASCII; ICU's is not.
            return try NSRegularExpression(pattern: "\\{([A-Za-z0-9_]+)\\}", options: [])
        } catch {
            preconditionFailure("FrictionDetector: placeholder pattern failed to compile — \(error)")
        }
    }()

    /// `{name}` → the value's text; an unknown or null one → "".
    static func fill(_ template: String, _ vars: [String: Any]) -> String {
        let ns = template as NSString
        var out = ""
        var cursor = 0
        for match in placeholder.matches(in: template, options: [], range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            out += JSON.jsStringOrEmpty(vars[ns.substring(with: match.range(at: 1))])
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }
}
