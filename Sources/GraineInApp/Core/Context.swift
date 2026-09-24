import Foundation

/// What an action handler answers. The agent speaks about exactly this, so tell the truth.
public struct GraineActionResult {
    public enum Status: String {
        case ok
        case refused
        case error
    }

    public let status: Status
    /// Shown to the agent, not the customer — it decides how to phrase it.
    public let message: String
    /// Structured result the agent can reason about.
    public let data: [String: Any]

    public init(status: Status, message: String = "", data: [String: Any] = [:]) {
        self.status = status
        self.message = message
        self.data = data
    }

    /// It happened. The agent will tell the customer it is done.
    public static func ok(_ message: String = "", data: [String: Any] = [:]) -> GraineActionResult {
        GraineActionResult(status: .ok, message: message, data: data)
    }

    /// It will not happen, and why ("this is locked after submission") — often the most useful answer.
    public static func refused(_ message: String) -> GraineActionResult {
        GraineActionResult(status: .refused, message: message)
    }

    /// It was tried and failed.
    public static func error(_ message: String) -> GraineActionResult {
        GraineActionResult(status: .error, message: message)
    }
}

/// One input on a screen, as the agent should understand it.
public struct GraineField: Equatable {
    public enum Status: String {
        case empty
        case filled
        case invalid
        case pending
        case locked
    }

    public var name: String
    public var label: String?
    /// The real value. Masked on the way out; never pre-redact it.
    public var value: String?
    public var status: Status?
    /// The validation message actually shown — what the agent can offer to fix.
    public var error: String?
    /// Leaving it blank is fine, so the agent does not count it as work left. On the wire: `optional`.
    public var isOptional: Bool

    public init(
        name: String,
        label: String? = nil,
        value: String? = nil,
        status: Status? = nil,
        error: String? = nil,
        isOptional: Bool = false
    ) {
        self.name = name
        self.label = label
        self.value = value
        self.status = status
        self.error = error
        self.isOptional = isOptional
    }
}

/**
 * What the customer is looking at. `status` on each field is what makes the
 * agent proactive: after a pause it names the field that is `invalid` or
 * `empty` — "the PAN isn't being accepted" — instead of asking "need a hand?".
 *
 * Report real values. Masking runs on the way out; a screen that pre-redacts
 * only blinds the agent.
 */
public struct GraineScreen: Equatable {
    /// Where this screen sits in a flow, and — `next` — where the flow goes after it.
    public struct Journey: Equatable {
        public var name: String
        public var step: Int?
        public var of: Int?
        public var next: String?

        public init(name: String, step: Int? = nil, of: Int? = nil, next: String? = nil) {
            self.name = name
            self.step = step
            self.of = of
            self.next = next
        }
    }

    /// Stable id for the screen — keep it constant; it is used for analytics.
    public var screen: String
    public var title: String?
    public var journey: Journey?
    public var fields: [GraineField]
    /// A screen-level error banner, distinct from a per-field one.
    public var error: String?
    /// Anything else the agent should know. JSON values.
    public var data: [String: Any]
    /**
     * Which registered actions work HERE. nil allows every action this build
     * registered; an empty list allows none. It can only narrow what the
     * dashboard declared — the server enforces that, not this field.
     */
    public var availableActions: [String]?

    public init(
        screen: String,
        title: String? = nil,
        journey: Journey? = nil,
        fields: [GraineField] = [],
        error: String? = nil,
        data: [String: Any] = [:],
        availableActions: [String]? = nil
    ) {
        self.screen = screen
        self.title = title
        self.journey = journey
        self.fields = fields
        self.error = error
        self.data = data
        self.availableActions = availableActions
    }

    public static func == (a: GraineScreen, b: GraineScreen) -> Bool {
        a.screen == b.screen
            && a.title == b.title
            && a.journey == b.journey
            && a.fields == b.fields
            && a.error == b.error
            && a.availableActions == b.availableActions
            && JSON.canonical(a.data) == JSON.canonical(b.data)
    }
}

/**
 * The context frame the runtime reads — the same keys as the React Native
 * SDK's buildContextFrame() and Android's ContextFrame.build, masked on the way
 * out, at the last moment, so no caller can skip it by building a frame some
 * other way.
 */
enum ContextFrame {
    /**
     * - Returns: `["context": …, "availableActions": …?]`, or nil when there is
     *   nothing to say (no screen, no identity, no recent events). A frame is
     *   worth sending for the identity alone: the runtime renders the user
     *   whether or not there is a screen line above it.
     */
    static func build(
        screen: GraineScreen?,
        screenSinceMs: Int64,
        nowMs: Int64,
        identity: [String: String],
        appVersion: String?,
        recentEvents: [[String: Any]],
        registeredActions: [String]
    ) -> [String: Any]? {
        if screen == nil && identity.isEmpty && recentEvents.isEmpty { return nil }
        var ctx: [String: Any] = [:]
        if let s = screen {
            ctx["screen"] = s.screen
            if let title = s.title { ctx["title"] = title }
            if let j = s.journey {
                var journey: [String: Any] = ["name": j.name]
                if let step = j.step { journey["step"] = step }
                if let of = j.of { journey["of"] = of }
                if let next = j.next { journey["next"] = next }
                ctx["journey"] = journey
            }
            if !s.fields.isEmpty {
                ctx["fields"] = s.fields.map { field -> [String: Any] in
                    var f: [String: Any] = ["name": field.name]
                    if let label = field.label { f["label"] = label }
                    if let value = field.value { f["value"] = value }
                    if let status = field.status { f["status"] = status.rawValue }
                    if let error = field.error { f["error"] = error }
                    if field.isOptional { f["optional"] = true }
                    return f
                }
            }
            if let error = s.error { ctx["error"] = error }
            if !s.data.isEmpty { ctx["data"] = JSON.normalize(s.data) }
            // Only with a screen to have been idle ON: without one this would read as a
            // customer stuck for the whole session.
            ctx["idle_ms"] = max(Int64(0), nowMs - screenSinceMs)
        }
        if !identity.isEmpty { ctx["user"] = identity }
        if let version = appVersion { ctx["app_version"] = version }
        if !recentEvents.isEmpty { ctx["recent_events"] = recentEvents }

        var frame: [String: Any] = ["context": GraineMasking.deep(ctx)]
        if let actions = availableActions(stated: screen?.availableActions, registered: registeredActions) {
            frame["availableActions"] = actions
        }
        return frame
    }

    /**
     * `availableActions` for the frame — present, or deliberately absent.
     *
     * The runtime reads an ARRAY as the complete set of what may be called
     * here, so [] means "nothing is permitted on this screen" while an ABSENT
     * key means "everything the dashboard declared". Those are opposite
     * instructions. So, as the React Native SDK does:
     *
     *   - a screen that STATES its actions is honoured exactly, [] included —
     *     narrowed to the ones this build registered, since an action the
     *     screen names but no handler implements would be offered to the agent
     *     and then refused mid-sentence;
     *   - otherwise every registered action is offered;
     *   - and when nothing is registered and nothing was stated, the key is
     *     left out, so a momentarily empty registry never disarms the agent.
     */
    static func availableActions(stated: [String]?, registered: [String]) -> [String]? {
        if let stated = stated {
            let usable = Set(registered)
            return stated.filter { usable.contains($0) }
        }
        return registered.isEmpty ? nil : registered
    }
}
