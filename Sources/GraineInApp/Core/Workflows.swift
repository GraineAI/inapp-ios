import Foundation

/*
 * WORKFLOWS THE APP STARTS (0.14.4) — `GraineInApp.startWorkflow`, every SDK's
 * rule (sdk/contract/PUBLIC-STATE.md §7): what is checked on the device, what
 * of the app's data is sent, and how the answer is read. Foundation only, so
 * `swift test` holds it on a Mac.
 *
 * The run is for the identified user, never for anyone the app names: with
 * nobody identified nothing is asked, and who the run is for never leaves the
 * device in `data`. What could never be kept is left out before anything is
 * sent — a list, an object, null, a text over 200 characters, a name no
 * workflow can allow, `user_id` / `user_field` / `reference_id`, where a step
 * sends by default (`mobile_number`, `email`), `fields`, a `graine_` name — and
 * of the rest the first 12 by name go (a dictionary has no order).
 * Left out, never refused. Every call carries an idempotency key: the app's,
 * or one made for the call, kept for the one retry a request that got no
 * answer is given.
 */

/// A run `startWorkflow` started — or the one the user already had under way (`alreadyRunning`).
public struct GraineWorkflowRun: Equatable, Sendable {
    /// The run's id (`oex_…`).
    public let runId: String
    /// The workflow's id (`owf_…`); nil when the answer did not say.
    public let workflowId: String?
    /// True when the user already had a run of this workflow under way: that run, never a second.
    public let alreadyRunning: Bool

    public init(runId: String, workflowId: String?, alreadyRunning: Bool) {
        self.runId = runId
        self.workflowId = workflowId
        self.alreadyRunning = alreadyRunning
    }
}

enum Workflows {
    static let route = "/api/embed/workflows/start"
    static let nameMax = 120
    static let fieldsMax = 12
    static let valueMax = 200
    /// After a request that got no answer, the one more ask (the same key) waits this long.
    static let retryDelay: TimeInterval = 1

    /// Never sent: who the run is for, the engine's `fields`, and where a step sends by default.
    private static let reserved: Set<String> = ["user_id", "user_field", "reference_id", "fields", "mobile_number", "email"]
    private static let fieldName = try! NSRegularExpression(pattern: "^[A-Za-z0-9_-]{1,64}$")
    private static let key = try! NSRegularExpression(pattern: "^[A-Za-z0-9_.:-]{8,128}$")

    static let keyMessage = "idempotencyKey is 8 to 128 letters, digits, _ - . or :."
    static let nameMessage = "Pass the workflow's exact name or its id (at most \(nameMax) characters)."

    /// The workflow's name or id as sent — trimmed — or nil when empty or over 120 characters (UTF-16, as the route counts).
    static func name(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name.utf16.count > nameMax ? nil : name
    }

    /// Whether `value` is a key Graine takes: 8 to 128 letters, digits, `_ - . :`.
    static func isIdempotencyKey(_ value: String) -> Bool {
        matches(key, value)
    }

    /// A fresh key for one call: a UUID, lowercase.
    static func newKey() -> String {
        UUID().uuidString.lowercased()
    }

    /// The fields sent: what could be kept, the first 12 by name.
    static func fields(_ data: [String: Any]) -> [(String, WireJSON)] {
        var out: [(String, WireJSON)] = []
        for name in data.keys.sorted() {
            if out.count >= fieldsMax { break }
            guard matches(fieldName, name), !reserved.contains(name), !name.lowercased().hasPrefix("graine_"),
                  let value = JSON.unwrap(data[name]) else { continue }
            if let text = value as? String {
                // Code points, as Graine counts them: an emoji is one.
                guard text.unicodeScalars.count <= valueMax else { continue }
                out.append((name, .string(text)))
            } else if let flag = JSON.bool(value) {
                out.append((name, .bool(flag)))
            } else if let number = JSON.number(value), number.doubleValue.isFinite {
                out.append((name, WireJSON.from(number)))
            }
        }
        return out
    }

    /// The run in the answer — `{runId, workflowId, alreadyRunning}` — or nil without a run id.
    static func run(_ body: [String: Any]) -> GraineWorkflowRun? {
        guard let runId = JSON.nonEmpty(body["runId"]) ?? JSON.nonEmpty(body["run_id"]) else { return nil }
        let workflowId = JSON.nonEmpty(body["workflowId"]) ?? JSON.nonEmpty(body["workflow_id"])
        let already = JSON.unwrap(body["alreadyRunning"] ?? body["already_running"]).flatMap { JSON.bool($0) } ?? false
        return GraineWorkflowRun(runId: runId, workflowId: workflowId, alreadyRunning: already)
    }

    private static func matches(_ pattern: NSRegularExpression, _ value: String) -> Bool {
        pattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }
}
