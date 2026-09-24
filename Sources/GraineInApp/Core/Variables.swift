import Foundation

/**
 * THE PROMPT'S {variables}, from every place they can come from, in one view.
 *
 *   1. the agent's defaults from the dashboard (Embed & Widgets → Variables)
 *   2. what the app knows at build time (GraineConfig.variables)
 *   3. what the app learns while it runs (setVariables)
 *   4. who is signed in (identify) — last, so a person beats a default
 *
 * Every value is a string, because it is substituted into a sentence: numbers
 * and booleans are flattened (a whole number without ".0"), nested objects and
 * arrays dropped (they would render as a repr inside the agent's first line).
 * Runtime values and identity are masked on the way in, like everything else
 * the app hands over.
 *
 * Thread-safe: every read and write holds one lock.
 */
final class VariableStore {
    private let lock = NSLock()
    private let buildTime: [String: String]
    private var dashboard: [String: String] = [:]
    private var runtime: [String: String] = [:]
    private var identity: [String: String] = [:]

    init(buildTime: [String: Any?] = [:]) {
        self.buildTime = VariableStore.flatten(buildTime)
    }

    func setDashboardDefaults(_ values: [String: Any?]) {
        let flat = VariableStore.flatten(values)
        lock.lock(); dashboard = flat; lock.unlock()
    }

    /// Merged over what is there. nil under a key removes it; nil for the whole map clears.
    func setRuntime(_ values: [String: Any?]?) {
        lock.lock()
        defer { lock.unlock() }
        guard let values = values else { runtime = [:]; return }
        var next = runtime
        for (key, value) in values {
            if key.isEmpty { continue }
            guard let unwrapped = JSON.unwrap(value), !(unwrapped is NSNull) else {
                next.removeValue(forKey: key)
                continue
            }
            if let flat = VariableStore.flattenOne(unwrapped) { next[key] = GraineMasking.mask(flat) }
        }
        runtime = next
    }

    /// Who is signed in. nil on sign-out clears it.
    func setIdentity(_ traits: [String: Any?]?) {
        var next: [String: String] = [:]
        if let traits = traits {
            for (key, value) in VariableStore.flatten(traits) { next[key] = GraineMasking.mask(value) }
        }
        lock.lock(); identity = next; lock.unlock()
    }

    func identitySnapshot() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return identity
    }

    /// Every variable the agent will receive, later sources winning.
    func merged() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        var out = dashboard
        for (k, v) in buildTime { out[k] = v }
        for (k, v) in runtime { out[k] = v }
        for (k, v) in identity { out[k] = v }
        return out
    }

    static func flatten(_ values: [String: Any?]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in values {
            if key.isEmpty { continue }
            if let flat = flattenOne(value) { out[key] = flat }
        }
        return out
    }

    /// One value as the sentence will read it, or nil when it cannot be one.
    static func flattenOne(_ value: Any?) -> String? {
        guard let v = JSON.unwrap(value), !(v is NSNull) else { return nil }
        if let s = v as? String { return s }
        if let b = JSON.bool(v) { return b ? "true" : "false" }
        if let n = JSON.number(v) { return JSON.numberText(n) }
        if v is [Any] || v is [AnyHashable: Any] { return nil }
        return String(describing: v)
    }
}
