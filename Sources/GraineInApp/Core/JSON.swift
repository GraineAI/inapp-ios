import Foundation

/*
 * JSON AS FOUNDATION READS AND WRITES IT — `[String: Any]`, `[Any]`, String,
 * NSNumber, NSNull — with the handful of conversions the wire needs.
 *
 * Android has org.json. iOS has JSONSerialization, which raises an
 * Objective-C exception — a crash, not a Swift error — on a value it cannot
 * write: a NaN, an Optional, a Date. So nothing reaches it without passing
 * through `normalize` and `isValidJSONObject` first. A payload the app handed
 * over that cannot be written is dropped and logged; it never takes the host
 * app down.
 *
 * Pure: Foundation only, so it is proven by `swift test` on a Mac.
 */
enum JSON {

    // MARK: - Reading

    /// One JSON object from a string. Nil for anything that is not an object.
    static func object(from string: String?) -> [String: Any]? {
        guard let string = string, !string.isEmpty, let data = string.data(using: .utf8) else { return nil }
        return object(from: data)
    }

    /// One JSON object from bytes. Nil for anything that is not an object.
    static func object(from data: Data?) -> [String: Any]? {
        guard let data = data, !data.isEmpty else { return nil }
        guard let parsed = try? JSONSerialization.jsonObject(with: data, options: []) else { return nil }
        return parsed as? [String: Any]
    }

    // MARK: - Writing

    /// Serialise an object. Nil when it cannot be written, never a crash.
    static func string(from object: [String: Any], sortedKeys: Bool = false) -> String? {
        let clean = normalize(object)
        guard JSONSerialization.isValidJSONObject(clean) else { return nil }
        let options: JSONSerialization.WritingOptions = sortedKeys ? [.sortedKeys] : []
        guard let data = try? JSONSerialization.data(withJSONObject: clean, options: options) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// A stable text form of any value, for equality checks. Keys sorted.
    static func canonical(_ value: Any?) -> String {
        let clean = normalize(value)
        if JSONSerialization.isValidJSONObject(clean),
           let data = try? JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(describing: clean)
    }

    /**
     * Swift values → values JSONSerialization can write, recursively. The same
     * job as Protocol.toJson on Android: anything unknown becomes its text.
     *
     * nil and NSNull → NSNull. Booleans stay booleans (checked before numbers,
     * because a Bool bridges to NSNumber and would otherwise be written as 1).
     * A number that is not finite → NSNull, since JSON has no NaN.
     */
    static func normalize(_ value: Any?) -> Any {
        guard let value = unwrap(value) else { return NSNull() }
        if value is NSNull { return NSNull() }
        if let s = value as? String { return s }
        if let b = bool(value) { return NSNumber(value: b) }
        if let n = number(value) { return n.doubleValue.isFinite ? n : NSNull() }
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict { out[k] = normalize(v) }
            return out
        }
        if let dict = value as? [AnyHashable: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict { out[String(describing: k.base)] = normalize(v) }
            return out
        }
        if let array = value as? [Any] { return array.map { normalize($0) } }
        if let url = value as? URL { return url.absoluteString }
        return String(describing: value)
    }

    /// An Optional hiding inside an `Any` (a `[String: Any?]` read as `[String: Any]`) → its value, or nil.
    static func unwrap(_ value: Any?) -> Any? {
        guard let value = value else { return nil }
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return value }
        guard let child = mirror.children.first else { return nil }
        return unwrap(child.value)
    }

    /// A boolean — a Swift Bool, or the NSNumber JSONSerialization reads `true` as. Never a 0 or a 1.
    static func bool(_ value: Any) -> Bool? {
        if type(of: value) == Bool.self { return value as? Bool }
        if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        return nil
    }

    /// A number that is not a boolean.
    static func number(_ value: Any) -> NSNumber? {
        if bool(value) != nil { return nil }
        return value as? NSNumber
    }

    // MARK: - Lenient readers, the way org.json's opt* read

    /// A string: numbers and booleans become their text, anything else is "".
    static func string(_ value: Any?) -> String {
        guard let v = unwrap(value) else { return "" }
        if let s = v as? String { return s }
        if let b = bool(v) { return b ? "true" : "false" }
        if let n = number(v) { return numberText(n) }
        return ""
    }

    /// A string, or nil when it is absent or empty.
    static func nonEmpty(_ value: Any?) -> String? {
        let s = string(value)
        return s.isEmpty ? nil : s
    }

    /// true for `true`, a non-zero number or the string "true". Everything else is false.
    static func flag(_ value: Any?) -> Bool {
        guard let v = unwrap(value) else { return false }
        if let b = bool(v) { return b }
        if let n = number(v) { return n.doubleValue != 0 }
        if let s = v as? String { return s.lowercased() == "true" }
        return false
    }

    /// JavaScript truthiness, for the renderer rules that were written against it.
    static func truthy(_ value: Any?) -> Bool {
        guard let v = unwrap(value), !(v is NSNull) else { return false }
        if let b = bool(v) { return b }
        if let n = number(v) {
            let d = n.doubleValue
            return d != 0 && !d.isNaN
        }
        if let s = v as? String { return !s.isEmpty }
        return true
    }

    /// A scalar as JavaScript's String() writes it; nil for null, objects and arrays.
    static func text(_ value: Any?) -> String? {
        guard let v = unwrap(value), !(v is NSNull) else { return nil }
        if let s = v as? String { return s }
        if let b = bool(v) { return b ? "true" : "false" }
        if let n = number(v) { return numberText(n) }
        return nil
    }

    private static let integerTypes: Set<String> = ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q"]

    /**
     * A number as text, the way JavaScript writes it: a whole number has no
     * ".0" (it is substituted into a sentence — "your cart of 1299.0" is a bug
     * a customer reads out loud), and a fraction is its shortest exact digits.
     */
    static func numberText(_ n: NSNumber) -> String {
        if integerTypes.contains(String(cString: n.objCType)) { return n.stringValue }
        return jsNumberText(n.doubleValue)
    }

    // MARK: - JavaScript's own coercions
    //
    // Several React Native rules lean on `String(x)`, truthiness, `Math.round`
    // and `Number(str)`. A port that used Swift's equivalents would agree on
    // every ordinary input and differ on the odd one — a numeric price, an
    // array where a string was expected — which is exactly where nobody looks.
    // So these are literal: nil stands for `undefined`, NSNull for `null`.

    /// `String(v)`: arrays join with commas (null and undefined as ""), objects are "[object Object]".
    static func jsString(_ value: Any?) -> String {
        guard let v = unwrap(value) else { return "undefined" }
        if v is NSNull { return "null" }
        if let s = v as? String { return s }
        if let b = bool(v) { return b ? "true" : "false" }
        if let n = number(v) { return numberText(n) }
        if let list = v as? [Any] {
            return list.map { item -> String in
                guard let x = unwrap(item), !(x is NSNull) else { return "" }
                return jsString(x)
            }.joined(separator: ",")
        }
        if v is [AnyHashable: Any] { return "[object Object]" }
        return String(describing: v)
    }

    /// `String(v ?? "")` — the idiom every allowlist in the React Native SDK reads a value through.
    static func jsStringOrEmpty(_ value: Any?) -> String {
        guard let v = unwrap(value), !(v is NSNull) else { return "" }
        return jsString(v)
    }

    /// `Math.round`: halves round up, toward +∞.
    static func jsRound(_ d: Double) -> Double {
        (d + 0.5).rounded(.down)
    }

    /// `Number(s)` for a string: surrounding whitespace ignored, "" is 0, anything unreadable is nil (NaN).
    static func jsNumber(fromString s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return 0 }
        switch t {
        case "Infinity", "+Infinity": return .infinity
        case "-Infinity": return -.infinity
        default: break
        }
        // Swift also reads "inf" and "nan", which JavaScript does not.
        let lower = t.lowercased()
        if lower.contains("inf") || lower.contains("nan") { return nil }
        return Double(t)
    }

    /**
     * Number.prototype.toString(): the shortest digits that read back as the
     * same double, then no exponent between 1e-6 and 1e21 and "e+21"-style
     * outside it.
     */
    static func jsNumberText(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
        if d == 0 { return "0" }
        // Swift's description is the shortest round-tripping digits; only the layout differs.
        let text = "\(abs(d))"
        var mantissa = text
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = String(text[..<e])
            exponent = Int(text[text.index(after: e)...]) ?? 0
        }
        var whole = mantissa
        var fraction = ""
        if let dot = mantissa.firstIndex(of: ".") {
            whole = String(mantissa[..<dot])
            fraction = String(mantissa[mantissa.index(after: dot)...])
        }
        var digits = whole + fraction
        var n = whole.count + exponent        // the value is 0.digits × 10^n
        while digits.count > 1 && digits.hasPrefix("0") {
            digits.removeFirst()
            n -= 1
        }
        while digits.count > 1 && digits.hasSuffix("0") { digits.removeLast() }
        let k = digits.count
        let out: String
        if k <= n && n <= 21 {
            out = digits + String(repeating: "0", count: n - k)
        } else if 0 < n && n <= 21 {
            let split = digits.index(digits.startIndex, offsetBy: n)
            out = String(digits[..<split]) + "." + String(digits[split...])
        } else if -6 < n && n <= 0 {
            out = "0." + String(repeating: "0", count: -n) + digits
        } else {
            let e = n - 1
            let sign = e >= 0 ? "+" : "-"
            let head = String(digits.prefix(1))
            let tail = String(digits.dropFirst())
            out = (tail.isEmpty ? head : head + "." + tail) + "e" + sign + String(abs(e))
        }
        return d < 0 ? "-" + out : out
    }
}
