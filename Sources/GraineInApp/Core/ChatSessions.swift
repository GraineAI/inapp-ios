import Foundation

/**
 * ONE SESSION OF THE CHAT (sdk/contract/PUBLIC-STATE.md, history.json
 * `sessions`): a run of consecutive turns said in the same session — a chat
 * connection's run, or a call — for a "past conversations" list or session
 * dividers of your own. From `GraineChat.sessions`.
 */
public struct GraineChatSession: Equatable, Sendable {
    /// The session's id, as Execution Logs shows it; nil for turns kept before sessions were recorded, and with a server that sends none.
    public let id: String?
    /// When its first turn was said.
    public let startedAt: Date
    /// When its last turn was said.
    public let endedAt: Date
    /// `.voice` when every turn of it was said on a call, else `.chat`.
    public let channel: GraineChatChannel
    /// How many turns it holds.
    public let turns: Int
    /// It is the chat's current session: its `id` is the chat's `sessionId`. Never for a session with no id.
    public let current: Bool

    public init(id: String?, startedAt: Date, endedAt: Date, channel: GraineChatChannel, turns: Int, current: Bool) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.channel = channel
        self.turns = turns
        self.current = current
    }
}

/**
 * THE CHAT'S SESSIONS, from its turns (history.json `sessions`, Android's
 * ChatSessions): oldest first, consecutive turns with the same session value —
 * nil included — make one; its start and end are its first and last turn's
 * time; it is a call's when every turn is voice; current when its id is not
 * nil and is `sessionId`. Pure.
 */
enum ChatSessions {
    static func of(_ turns: [GraineChatTurn], sessionId: String?) -> [GraineChatSession] {
        var out: [GraineChatSession] = []
        var i = 0
        while i < turns.count {
            let id = turns[i].session
            var j = i
            while j + 1 < turns.count && turns[j + 1].session == id { j += 1 }
            let run = turns[i...j]
            out.append(GraineChatSession(
                id: id,
                startedAt: run.first!.at,
                endedAt: run.last!.at,
                channel: run.allSatisfy { $0.channel == .voice } ? .voice : .chat,
                turns: run.count,
                current: id != nil && id == sessionId
            ))
            i = j + 1
        }
        return out
    }
}
