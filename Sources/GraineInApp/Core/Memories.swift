import Foundation

/**
 * ONE THING THE AGENT REMEMBERS about the signed-in customer, as Graine keeps
 * it — already redacted — so an app can show people what is remembered about
 * them, beside `forgetMemory()`.
 */
public struct GraineMemory: Equatable, Sendable, Identifiable {
    public let id: String
    public let text: String
    public let createdAt: Date?
    public let updatedAt: Date?

    public init(id: String, text: String, createdAt: Date? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// `memory/list`'s answer, `{ memories: [{id, text, createdAt, updatedAt}] }`, in the server's order (newest first).
    /// An entry with no id or no words is skipped; `created_at` / `updated_at` are read too.
    static func list(_ body: [String: Any]) -> [GraineMemory] {
        let raw = (JSON.unwrap(body["memories"]) as? [Any]) ?? []
        return raw.compactMap { entry in
            guard let o = JSON.unwrap(entry) as? [String: Any],
                  let id = JSON.nonEmpty(o["id"]),
                  let text = JSON.nonEmpty(o["text"]) else { return nil }
            return GraineMemory(
                id: id,
                text: text,
                createdAt: Scheduling.date(o["createdAt"]) ?? Scheduling.date(o["created_at"]),
                updatedAt: Scheduling.date(o["updatedAt"]) ?? Scheduling.date(o["updated_at"])
            )
        }
    }
}
