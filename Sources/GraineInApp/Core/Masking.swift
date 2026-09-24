import Foundation

/**
 * WHAT NEVER LEAVES THE DEVICE UNMASKED.
 *
 * The same five rules, in the same order, with the same tokens (including the
 * `$1` that puts back the captured leading boundary) as the React Native SDK
 * and Android. Order is load-bearing: a card number must be caught as a card
 * before a twelve-digit run inside it can be caught as an Aadhaar, and a +91
 * mobile is twelve digits exactly like an Aadhaar — Aadhaar first would tell
 * the agent the customer's mobile field holds an Aadhaar, and it would say so
 * out loud. A native SDK that leaked what the React Native one redacts would
 * fail the security review this product is sold through, so all of them are
 * pinned to the same generated test cases (sdk/contract/fixtures.json).
 *
 * WHY THE CHARACTER CLASSES ARE SPELLED OUT. The rules were written for
 * JavaScript, where `\d`, `\w`, `\s` and `\b` (without the u flag) are ASCII.
 * NSRegularExpression is ICU, where `\d` also matches Devanagari digits, `\w`
 * matches every letter in every script, and `\b` follows those letters. Copied
 * verbatim, the rules would agree with React Native on every fixture and still
 * leak on this platform only: "ABCDE1234Fé" keeps its PAN (é is a word
 * character to ICU, so there is no boundary), and "०9876543210" keeps its phone
 * number (० is a digit to ICU, so nothing may precede the match). So each rule
 * below is the JavaScript rule with its classes written out as JavaScript
 * defines them — `\d` → `[0-9]`, `\w` → `[A-Za-z0-9_]`, `\s` → JavaScript's
 * whitespace set, and `\b` next to a letter → a lookaround on `[A-Za-z0-9_]`
 * (ICU has lookbehind; the "no lookbehind" rule in mask.ts is about old
 * JavaScript engines and does not apply here). These exact patterns were run
 * against the React Native SDK's own maskString over every fixture and a set of
 * non-ASCII edge cases, with zero differences.
 *
 * Masking is a set of rules, not a guarantee: report real values and let this
 * run on the way out. A screen that pre-redacts only blinds the agent.
 */
public enum GraineMasking {

    /// JavaScript's `\s`, as the members of a character class.
    private static let jsSpace =
        "\\t\\n\\u000B\\f\\r\\u0020\\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF"

    /// JavaScript's `\w`, as the members of a character class.
    private static let jsWord = "A-Za-z0-9_"

    private static let rules: [(NSRegularExpression, String)] = [
        // /\b[A-Z]{5}[0-9]{4}[A-Z]\b/g
        (compile("(?<![\(jsWord)])[A-Z]{5}[0-9]{4}[A-Z](?![\(jsWord)])"), "[PAN]"),
        // /[\w.+-]+@[\w-]+\.[\w.]{2,}/g
        (compile("[\(jsWord).+\\-]+@[\(jsWord)\\-]+\\.[\(jsWord).]{2,}"), "[EMAIL]"),
        // /(^|[^\d-])((?:\d[ -]?){13,19})(?![\d-])/g
        (compile("(^|[^0-9\\-])((?:[0-9][\\u0020\\-]?){13,19})(?![0-9\\-])"), "$1[CARD]"),
        // /(^|[^\d+])((?:\+91[-\s]?)?[6-9]\d{9})(?!\d)/g — the trailing (?!\d) matters: without it
        // this eats the first ten digits of a twelve-digit Aadhaar and leaves the last two behind.
        (compile("(^|[^0-9+])((?:\\+91[\\-\(jsSpace)]?)?[6-9][0-9]{9})(?![0-9])"), "$1[PHONE]"),
        // /(^|[^\d+])(\d{4}\s?\d{4}\s?\d{4})(?!\d)/g
        (compile("(^|[^0-9+])([0-9]{4}[\(jsSpace)]?[0-9]{4}[\(jsSpace)]?[0-9]{4})(?![0-9])"), "$1[AADHAAR]"),
    ]

    private static let lock = NSLock()
    private static var custom: [(NSRegularExpression, String)] = []

    /// Replace identifiers in one string: the five rules, then any rules the app added.
    public static func mask(_ input: String) -> String {
        if input.isEmpty { return input }
        var out = input
        for (regex, token) in rules { out = replace(regex, in: out, with: token) }
        lock.lock()
        let extra = custom
        lock.unlock()
        for (regex, token) in extra { out = replace(regex, in: out, with: token) }
        return out
    }

    /**
     * A rule for a field shape only your app knows — an account number, a
     * policy id. Registered globally so one call covers every screen: a rule
     * you have to remember per screen is missing from the screen that matters.
     * Every match is replaced, not just the first. `token` is an
     * NSRegularExpression template: `$1` refers to a capture group.
     */
    public static func addRule(_ pattern: NSRegularExpression, token: String = "[REDACTED]") {
        lock.lock()
        custom.append((pattern, token))
        lock.unlock()
    }

    /// The same, from a pattern string. Returns false (and adds nothing) when the pattern does not compile.
    @discardableResult
    public static func addRule(pattern: String, token: String = "[REDACTED]") -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return false }
        addRule(regex, token: token)
        return true
    }

    /// Only for tests — production code registers rules once, at startup.
    public static func clearCustomRules() {
        lock.lock()
        custom.removeAll()
        lock.unlock()
    }

    /**
     * Masks every string anywhere inside a JSON value. Keys are not masked;
     * values are. Non-string leaves are returned untouched: stringifying
     * numbers to run a regex over them would turn every amount and timestamp
     * into a string, and the agent reasons about those.
     */
    public static func deep(_ value: Any?) -> Any {
        guard let v = JSON.unwrap(value) else { return NSNull() }
        if let s = v as? String { return mask(s) }
        if let dict = v as? [String: Any] {
            var out: [String: Any] = [:]
            for (key, x) in dict { out[key] = deep(x) }
            return out
        }
        if let array = v as? [Any] { return array.map { deep($0) } }
        return v
    }

    private static func replace(_ regex: NSRegularExpression, in s: String, with template: String) -> String {
        let range = NSRange(location: 0, length: (s as NSString).length)
        return regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: template)
    }

    /// The built-in patterns are constants, proven by the contract tests; one that failed to compile is a build bug.
    private static func compile(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: [])
        } catch {
            preconditionFailure("GraineMasking: built-in pattern failed to compile: \(pattern) — \(error)")
        }
    }
}
