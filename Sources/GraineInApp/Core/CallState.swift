import Foundation

/// Whether the page that carries the call is actually there.
public enum GraineConnectivity: String {
    /// First load in progress.
    case loading
    /// The page said graine:ready.
    case ready
    /// A load failed or ready never came; a reload is scheduled.
    case retrying
    /// Every retry used up — say so, and offer `GraineVoice.retry()`.
    case failed
}

/// One caption line, as the engine reported it.
public struct GraineCaption: Equatable {
    public let role: GraineRole
    public let text: String
    /// Still being recognised or streamed — draw it as provisional.
    public let live: Bool

    public init(role: GraineRole, text: String, live: Bool) {
        self.role = role
        self.text = text
        self.live = live
    }
}

/**
 * WHAT HAS BEEN SAID SO FAR, folded the way the React Native launcher folds it.
 *
 * The engine sends a turn many times as its words arrive, each time with the
 * fuller text and `live: true`, then once more with `live: false` when it is
 * settled. Appending each of those would fill the transcript with one sentence
 * growing a word at a time, so a live turn REPLACES the tail it belongs to —
 * matched on role, and only while that tail is still live.
 *
 * AN EMPTY LINE IS A FULL STOP, NOT A LINE. The engine closes a turn (a
 * barge-in, an interruption) by sending it with empty text and `live: false`.
 * Folded as text, the caption a customer was reading went blank. It settles
 * the open turn instead, and is ignored when there is nothing open to settle.
 */
enum CaptionLog {
    /// How many turns are kept. A caption box shows two or three.
    static let history = 12

    static func fold(_ lines: [GraineCaption], _ next: GraineCaption) -> [GraineCaption] {
        var out = lines
        let tail = lines.last
        if next.text.isEmpty {
            if let t = tail, t.live, t.role == next.role {
                out[out.count - 1] = GraineCaption(role: t.role, text: t.text, live: false)
            }
            return out
        }
        if let t = tail, t.live, t.role == next.role {
            out[out.count - 1] = next
        } else {
            out.append(next)
        }
        if out.count > history { out.removeFirst(out.count - history) }
        return out
    }

    /// The agent is talking: the newest turn is the agent's, and still live.
    static func agentSpeaking(_ lines: [GraineCaption]) -> Bool {
        guard let last = lines.last else { return false }
        return last.role == .agent && last.live
    }
}

/**
 * THE BAR NAMES THE NETWORK, or the agent takes the blame for it.
 *
 * A customer whose agent goes quiet on a train reads "listening" and concludes
 * the agent is broken. "no connection", "weak connection" and "reconnecting…"
 * are the sentences that keep that blame where it belongs. Same order as the
 * Android bar; "needs microphone" holds after a refusal until the next start.
 */
enum BarStatus {
    struct Input {
        var connectivity: GraineConnectivity
        var online: Bool?
        var reconnecting: Bool
        var connecting: Bool
        var ready: Bool
        var muted: Bool
        var connected: Bool
        var quality: GraineConnectionQuality
        var agentSpeaking: Bool
        var micDenied: Bool
    }

    /**
     * WHILE IT IS COMING UP, THE STATUS LINE IS THE LOADER — the one the brand
     * chose in Appearance, with its words for the moment: "connecting" or
     * "reconnecting". Nil once there is nothing to wait for, or when waiting
     * would be a lie (the page failed for good, or the network is gone).
     */
    static func waiting(_ s: Input) -> String? {
        if s.connectivity == .failed || s.online == false { return nil }
        if s.reconnecting || s.connectivity == .retrying { return "reconnecting" }
        if s.connecting || !s.ready { return "connecting" }
        return nil
    }

    /// The words when nothing is being waited for. Same order as the Android bar.
    static func settled(_ s: Input) -> String {
        if s.connectivity == .failed { return "couldn't load · tap to retry" }
        if s.online == false { return "no connection" }
        if s.micDenied && !s.connected { return "needs microphone" }
        if s.muted { return "muted" }
        if s.connected && s.quality == .poor { return "weak connection" }
        if s.connected && s.agentSpeaking { return "speaking" }
        if s.connected { return "listening" }
        return "tap to talk"
    }

    /// The status as one phrase — what VoiceOver reads, and what a bar with no loader shows.
    static func text(_ s: Input) -> String {
        if let moment = waiting(s) { return moment == "reconnecting" ? "reconnecting…" : "connecting…" }
        return settled(s)
    }
}
