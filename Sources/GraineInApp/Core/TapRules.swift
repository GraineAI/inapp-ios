import Foundation

/**
 * WHAT A TAP TELLS THE AGENT (contract §8): a tap on a named control is
 * `tap:<name>` — its accessibility identifier (the test id a developer gave it),
 * or, for a button, its accessibility label — and any other tap is
 * `tap:screen` with where it landed. A text field's label is never read (it can
 * hold what was typed), and no value ever is. At most two taps a second reach
 * the context: a customer hammering a dead button is one fact, not twenty.
 */
enum TapRules {
    static let unnamed = "tap:screen"
    static let perSecond = 2
    static let nameLimit = 60
    /// A named tap this close to a bare one is the same tap.
    static let namedOverlapMs = 400.0

    /// A name fit for the context: trimmed, inner whitespace collapsed, cut to 60. Nil when nothing is left.
    static func clean(_ raw: String?) -> String? {
        guard let raw = raw else { return nil }
        let words = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let joined = words.joined(separator: " ")
        guard !joined.isEmpty else { return nil }
        return CallWire.utf16Prefix(joined, nameLimit)
    }

    /// Whether a tap at `nowMs` may be recorded, given the times of those recorded before; and the times to keep.
    static func admit(nowMs: Double, recent: [Double]) -> (allowed: Bool, recent: [Double]) {
        let window = recent.filter { nowMs - $0 < 1_000 && nowMs >= $0 }
        guard window.count < perSecond else { return (false, window) }
        return (true, window + [nowMs])
    }
}
