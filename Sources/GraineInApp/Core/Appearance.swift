import Foundation

/// The dashboard's appearance, translated for a phone: see `Appearance.resolve`.
public struct GraineNativeAppearance: Equatable {
    /// Always a valid "#rgb" or "#rrggbb".
    public let accent: String
    /// The panel heading ("Talk to our AI assistant") — NOT the assistant's name.
    public let heading: String
    /// Absolute, or nil when no logo is set. The dashboard stores an S3 key, not a URL.
    public let logoUrl: String?
    /// What the logo sits on where it stands in for the launcher glyph. contract/DESIGN.md "The brand's logo".
    public let logoPlate: GraineLogoPlate
    /// Corner rounding, clamped to what the host draws.
    public let radius: Double
}

/**
 * WHAT THE BRAND'S LOGO SITS ON — `appearance.logoPlate`, wherever the logo
 * stands in for the launcher glyph (the launcher, the voice bar's avatar, the
 * chat header's mark):
 *
 *   accent  the shape's own fill — for a white or light mark made for a
 *           coloured background. Absent means this: logos were drawn so before.
 *   white   #FFFFFF with a hairline in `border` — for a coloured or dark logo,
 *           or an opaque image, which is what most logo files are.
 *
 * A logo drawn in the brand's own colour on the brand's own accent is no logo
 * at all, which is why the plate exists. The dashboard reads it from the
 * pixels on upload and the brand can change it.
 */
public enum GraineLogoPlate: String, CaseIterable, Sendable {
    case accent
    case white

    /// Only "white" is white — exactly, as theme.ts reads it. Anything else, of any type, is the accent.
    static func from(_ raw: Any?) -> GraineLogoPlate {
        (JSON.unwrap(raw) as? String) == "white" ? .white : .accent
    }
}

/// The colours a component is drawn in, as #RRGGBB.
public struct GraineWidgetPalette: Equatable {
    public let surface: String
    public let border: String
    public let text: String
    public let muted: String
    /// Readable ON the accent — chosen by luminance, so a yellow accent still has a label.
    public let onAccent: String
    /// "light" or "dark", after resolving "auto" against the device.
    public let mode: String
}

/**
 * THE DASHBOARD'S APPEARANCE, as a native UI can actually use it — a port of
 * the React Native SDK's appearance.ts, pinned by the parity suite.
 *
 * The session's `appearance` is stored for a widget in an iframe, and three of
 * its fields do not mean on a phone what their names suggest:
 *
 *   accent  sometimes arrives without its "#"
 *   title   is a HEADING ("Talk to our AI assistant"), not a name
 *   logo    is an S3 KEY, which becomes <origin>/api/embed/logo?k=…
 *
 * and `logoPlate` says what that logo is drawn on (GraineLogoPlate).
 *
 * PRECEDENCE IS ONE RULE, IN ONE DIRECTION: the dashboard decides, and the
 * host's own values are the fallback.
 */
enum Appearance {
    static let defaultAccent = "#318CE7"
    static let defaultOrigin = "https://www.graine.ai"
    /// The corner-rounding range the dashboard offers.
    static let radiusCeiling = 48.0

    /**
     * - Parameters:
     *   - accent / heading: used when the dashboard has none.
     *   - radius: used when the dashboard has none; the schema's 18 otherwise.
     *   - maxRadius: the largest rounding this host draws (a pill bar and a panel differ).
     *   - origin: where /api/embed/logo lives.
     */
    static func resolve(
        _ appearance: [String: Any]?,
        accent: String,
        heading: String,
        radius: Double? = nil,
        maxRadius: Double? = nil,
        origin: String? = nil
    ) -> GraineNativeAppearance {
        let a = appearance ?? [:]
        let ceiling = clamp(maxRadius.flatMap { $0.isFinite ? $0 : nil } ?? radiusCeiling, radiusCeiling)
        let rawAccent = JSON.jsStringOrEmpty(a["accent"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let title = JSON.jsStringOrEmpty(a["title"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let logoKey = JSON.jsStringOrEmpty(a["logo"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let base = GraineProtocol.trimTrailingSlashes((origin?.isEmpty == false ? origin : nil) ?? defaultOrigin)
        return GraineNativeAppearance(
            accent: isHex3or6(rawAccent) ? "#" + stripHash(rawAccent) : accent,
            heading: title.isEmpty ? heading : title,
            logoUrl: logoKey.isEmpty ? nil : base + "/api/embed/logo?k=" + GraineProtocol.encode(logoKey),
            logoPlate: GraineLogoPlate.from(a["logoPlate"]),
            radius: clamp(numeric(a["radius"]) ?? radius.flatMap { $0.isFinite ? $0 : nil } ?? 18, ceiling)
        )
    }

    /**
     * Light, dark, or "auto" — which follows the DEVICE, not the dashboard's
     * own light default: one bright card over a dark app is what auto prevents.
     */
    static func palette(_ appearance: [String: Any]?, deviceDark: Bool?, accent: String?) -> GraineWidgetPalette {
        // String(theme ?? "auto"): absent and null are "auto", and so is anything not dark or light.
        let theme = JSON.jsStringOrEmpty(appearance?["theme"]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let dark = theme == "dark" ? true : theme == "light" ? false : deviceDark == true
        let onAccent = self.onAccent(accent ?? "")
        return dark
            ? GraineWidgetPalette(surface: "#17181B", border: "#2C2E33", text: "#F5F5F4", muted: "#A0A5AE", onAccent: onAccent, mode: "dark")
            : GraineWidgetPalette(surface: "#FFFFFF", border: "#E5E4E0", text: "#101318", muted: "#5F6672", onAccent: onAccent, mode: "light")
    }

    // MARK: - Helpers the UI reads

    /// A valid "#rgb" / "#rrggbb" (the dashboard's own validation, "#" optional), or nil.
    static func accent(_ raw: Any?) -> String? {
        let s = JSON.jsStringOrEmpty(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return isHex3or6(s) ? "#" + stripHash(s) : nil
    }

    /// The panel heading, or the fallback. Not the assistant's name — see above.
    static func heading(_ appearance: [String: Any]?, fallback: String) -> String {
        resolve(appearance, accent: defaultAccent, heading: fallback).heading
    }

    /// Corner rounding, clamped to 0...maxRadius. An absent radius is the schema's 18, never 0.
    static func radius(_ appearance: [String: Any]?, fallback: Double = 18, maxRadius: Double = 48) -> Double {
        resolve(appearance, accent: defaultAccent, heading: "", radius: fallback, maxRadius: maxRadius).radius
    }

    /// "light" / "dark" from the dashboard; "auto" (the default) follows the device.
    static func prefersDark(_ appearance: [String: Any]?, deviceIsDark: Bool) -> Bool {
        palette(appearance, deviceDark: deviceIsDark, accent: nil).mode == "dark"
    }

    /// The words the dashboard chose for one waiting moment, or the default.
    static func loaderText(_ appearance: [String: Any]?, moment: String) -> String {
        Loaders.resolve(appearance?["loader"]).text.forMoment(moment) ?? "Loading…"
    }

    /**
     * What reads ON the accent. White was hardcoded, and a dashboard that
     * offers a colour picker will eventually be given a yellow — at which
     * point every button label disappears. 0.45 is where white stops winning.
     */
    static func onAccent(_ accent: String) -> String {
        luminance(accent) > 0.45 ? "#101318" : "#FFFFFF"
    }

    /// WCAG relative luminance of a #rrggbb colour; 0 for anything else (a 3-digit hex included, as in React Native).
    static func luminance(_ hex: String) -> Double {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, s.allSatisfy({ $0.isASCII && $0.isHexDigit }), let n = UInt32(s, radix: 16) else { return 0 }
        func channel(_ c: UInt32) -> Double {
            let v = Double(c) / 255
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel((n >> 16) & 0xFF) + 0.7152 * channel((n >> 8) & 0xFF) + 0.0722 * channel(n & 0xFF)
    }

    /// "#rgb" or "#rrggbb" → red, green, blue in 0...1, for drawing.
    static func rgb(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, s.allSatisfy({ $0.isASCII && $0.isHexDigit }), let n = UInt32(s, radix: 16) else { return nil }
        return (Double((n >> 16) & 0xFF) / 255, Double((n >> 8) & 0xFF) / 255, Double(n & 0xFF) / 255)
    }

    // MARK: - Private

    private static func clamp(_ value: Double, _ max: Double) -> Double {
        if value < 0 { return 0 }
        return value > max ? max : value
    }

    /// A number, or nothing. Never a coercion: an absent value is not 0, and "" is not a radius.
    private static func numeric(_ value: Any?) -> Double? {
        guard let v = JSON.unwrap(value) else { return nil }
        if let n = JSON.number(v) {
            let d = n.doubleValue
            return d.isFinite ? d : nil
        }
        if let s = v as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let d = JSON.jsNumber(fromString: s), d.isFinite else { return nil }
            return d
        }
        return nil
    }

    /// /^#?([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/
    private static func isHex3or6(_ s: String) -> Bool {
        let hex = stripHash(s)
        return (hex.count == 3 || hex.count == 6) && hex.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    private static func stripHash(_ s: String) -> String {
        s.hasPrefix("#") ? String(s.dropFirst()) : s
    }
}
