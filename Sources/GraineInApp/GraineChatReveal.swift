import Combine
import Foundation

/*
 * THE CHAT WINDOW'S MOVING PART, kept out of the views so a Mac proves it: the
 * newest reply revealed smoothly as it arrives (DESIGN.md "Chat window v2" →
 * Bubbles; `ChatReveal` is the pace), and the agent's settled words formatted
 * once rather than on every frame.
 */

/**
 * THE LIVE REPLY'S REVEAL: how much of the agent's newest turn is drawn,
 * moved on every frame by `ChatReveal.length` — at least 90 characters a
 * second, catching up within about 0.6 s. When the turn ends the rest is
 * revealed at the same pace, then it is drawn whole. Only one turn at a time,
 * and nothing runs once it is caught up.
 */
final class GraineChatReveal: ObservableObject {
    @Published private(set) var shown = 0
    @Published private(set) var id: String?
    private var target = 0
    private var live = false
    private var last: Date?

    var active: Bool { id != nil }

    func visible(_ turn: GraineChatTurn) -> Int? { turn.id == id ? shown : nil }

    func feed(_ turn: GraineChatTurn?, enabled: Bool) {
        guard enabled, let t = turn, t.role == .agent else { return stop() }
        if t.live {
            if id != t.id {
                id = t.id
                shown = 0
                last = nil
            }
            target = ChatReveal.count(t.text)
            live = true
        } else if id == t.id {
            target = ChatReveal.count(t.text)
            live = false
            if shown >= target { stop() }
        }
    }

    func tick(_ now: Date) {
        guard id != nil else { return }
        let elapsed = last.map { now.timeIntervalSince($0) * 1000 } ?? 16
        last = now
        let next = ChatReveal.length(shown: Double(shown), target: Double(target), elapsedMs: elapsed)
        if next != shown { shown = next }
        if !live && shown >= target { stop() }
    }

    private func stop() {
        guard id != nil else { return }
        id = nil
        shown = 0
        last = nil
    }
}

/// A finished turn's words parsed once, not on every frame (DESIGN.md "Long conversations").
final class GraineChatFormatCache {
    private var store: [String: [ChatBlock]] = [:]

    func blocks(_ text: String) -> [ChatBlock] {
        if let hit = store[text] { return hit }
        if store.count >= 400 { store.removeAll(keepingCapacity: true) }
        let parsed = ChatMarkdown.blocks(text)
        store[text] = parsed
        return parsed
    }
}
