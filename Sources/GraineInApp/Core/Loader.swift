import Foundation

/**
 * HOW WAITING LOOKS — chosen in Embed & Widgets → Appearance, carried in the
 * session's `appearance.loader`, drawn by the SDK (GraineLoader) and by the web
 * embed. One contract for the moments a customer waits:
 *
 *   connecting    the page and the call are being set up
 *   reconnecting  the page is being reloaded after a failure
 *   thinking      the customer finished and the agent has not started
 *   component     the agent asked for a component and its content is loading
 *
 * Allowlisted like a component's style: an unknown kind draws the default,
 * never nothing, and a label is capped so it cannot become a paragraph. A port
 * of protocol.ts `normaliseLoaderStyle` / `resolveLoader`, pinned by the parity
 * suite against the React Native SDK's own answers.
 */
public struct GraineLoaderText: Equatable {
    public var connecting: String?
    public var reconnecting: String?
    public var thinking: String?
    public var component: String?

    public init(connecting: String? = nil, reconnecting: String? = nil, thinking: String? = nil, component: String? = nil) {
        self.connecting = connecting
        self.reconnecting = reconnecting
        self.thinking = thinking
        self.component = component
    }

    /// The words for one moment: "connecting", "reconnecting", "thinking" or "component".
    public func forMoment(_ moment: String) -> String? {
        switch moment {
        case "connecting": return connecting
        case "reconnecting": return reconnecting
        case "thinking": return thinking
        case "component": return component
        default: return nil
        }
    }

    var isEmpty: Bool { connecting == nil && reconnecting == nil && thinking == nil && component == nil }
}

/// What the dashboard stored, allowlisted. Nil means "not chosen".
struct LoaderStyle: Equatable {
    var kind: String?
    /// "accent" or #RRGGBB.
    var color: String?
    var size: String?
    var speed: String?
    var text: GraineLoaderText?
    var skeleton: Bool?
}

/// The effective loader: numbers a renderer can use directly.
public struct GraineLoaderLook: Equatable {
    /// "dots", "pulse", "ring", "bars" or "mark" (the brand's logo, breathing).
    public let kind: String
    /// #RRGGBB, or nil for "use the accent".
    public let color: String?
    /// The mark's size, in points.
    public let px: Double
    /// One animation cycle.
    public let periodMs: Double
    /// Every moment filled in.
    public let text: GraineLoaderText
    /// Also draw the shape of the coming component under the loader.
    public let skeleton: Bool
}

enum Loaders {
    static let kinds = ["dots", "pulse", "ring", "bars", "mark"]
    static let sizes = ["small", "medium", "large"]
    static let speeds = ["calm", "normal", "quick"]
    static let moments = ["connecting", "reconnecting", "thinking", "component"]
    static let defaultKind = "dots"
    static let textMax = 40
    static let defaultText = GraineLoaderText(
        connecting: "Connecting…", reconnecting: "Reconnecting…", thinking: "Thinking…", component: "Loading…"
    )
    private static let px: [String: Double] = ["small": 14, "medium": 20, "large": 28]
    private static let period: [String: Double] = ["calm": 1_600, "normal": 1_100, "quick": 700]

    private static func pick(_ value: Any?, _ allowed: [String]) -> String? {
        let s = JSON.jsStringOrEmpty(value).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allowed.contains(s) ? s : nil
    }

    static func normalise(_ raw: Any?) -> LoaderStyle {
        var out = LoaderStyle()
        guard let r = JSON.unwrap(raw) as? [String: Any] else { return out }
        out.kind = pick(r["kind"], kinds)
        out.size = pick(r["size"], sizes)
        out.speed = pick(r["speed"], speeds)
        if let c = r["color"] as? String {
            let t = c.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.lowercased() == "accent" {
                out.color = "accent"
            } else if t.count == 7, t.hasPrefix("#"), t.dropFirst().allSatisfy({ $0.isASCII && $0.isHexDigit }) {
                out.color = t.uppercased()
            }
        }
        if let v = JSON.unwrap(r["skeleton"]), let b = JSON.bool(v) { out.skeleton = b }
        if let t = r["text"] as? [String: Any] {
            func words(_ moment: String) -> String? {
                guard let s = t[moment] as? String else { return nil }
                let trimmed = String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(textMax))
                return trimmed.isEmpty ? nil : trimmed
            }
            let text = GraineLoaderText(
                connecting: words("connecting"), reconnecting: words("reconnecting"),
                thinking: words("thinking"), component: words("component")
            )
            if !text.isEmpty { out.text = text }
        }
        return out
    }

    /// The look for a raw `appearance.loader` value. Anything unreadable resolves to the default.
    static func resolve(_ raw: Any?) -> GraineLoaderLook {
        resolve(style: normalise(raw))
    }

    /**
     * Linear interpolation between keyframes, as React Native's
     * Animated.interpolate does it — the loader's animations are its keyframes.
     * `t` is the cycle's progress, 0...1.
     */
    static func interpolate(_ t: Double, _ input: [Double], _ output: [Double]) -> Double {
        guard let first = output.first, input.count == output.count, input.count > 1 else { return output.first ?? 0 }
        if t <= input[0] { return first }
        for i in 1..<input.count where t <= input[i] {
            let span = input[i] - input[i - 1]
            let f = span > 0 ? (t - input[i - 1]) / span : 1
            return output[i - 1] + (output[i] - output[i - 1]) * f
        }
        return output[output.count - 1]
    }

    static func resolve(style s: LoaderStyle) -> GraineLoaderLook {
        GraineLoaderLook(
            kind: s.kind ?? defaultKind,
            color: s.color == "accent" ? nil : s.color,
            px: px[s.size ?? "medium"] ?? 20,
            periodMs: period[s.speed ?? "normal"] ?? 1_100,
            text: GraineLoaderText(
                connecting: s.text?.connecting ?? defaultText.connecting,
                reconnecting: s.text?.reconnecting ?? defaultText.reconnecting,
                thinking: s.text?.thinking ?? defaultText.thinking,
                component: s.text?.component ?? defaultText.component
            ),
            skeleton: s.skeleton ?? false
        )
    }
}
