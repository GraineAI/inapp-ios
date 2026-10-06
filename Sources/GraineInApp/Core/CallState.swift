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

    /**
     * Whether the agent owes an answer, after `next` arrives. Thinking is the
     * gap between the customer's final line and the agent's first — kept as a
     * flag rather than a timer, because the transcript is the truth about who
     * spoke last. A customer turn closed with no words (a barge-in) is still
     * the customer's turn ending. The React Native launcher's rule.
     */
    static func awaitsAgent(_ awaiting: Bool, after next: GraineCaption) -> Bool {
        if next.role == .agent { return false }
        if !next.live { return true }
        return awaiting
    }
}

/**
 * WHAT THE CALL IS DOING, IN ONE WORD — the React Native launcher's
 * `GrainePhase`, for a host drawing its own bar:
 *
 *   idle          no call; ready to start
 *   connecting    the page loading, or a call being placed
 *   reconnecting  the page failed and is being reloaded, or the call is being re-established
 *   thinking      the customer finished a sentence; the agent has not answered yet
 *   speaking      the agent is talking
 *   listening     the agent is waiting for the customer
 *
 * Pair `thinking` with `GraineLoader(moment: "thinking")`: the dashboard's
 * loader, with the dashboard's words for that moment.
 */
public enum GrainePhase: String {
    case idle
    case connecting
    case reconnecting
    case thinking
    case speaking
    case listening

    static func of(
        reconnecting: Bool, connectivity: GraineConnectivity, connecting: Bool, ready: Bool,
        connected: Bool, agentSpeaking: Bool, awaitingAgent: Bool
    ) -> GrainePhase {
        if reconnecting || connectivity == .failed || connectivity == .retrying { return .reconnecting }
        if connecting || !ready { return .connecting }
        if !connected { return .idle }
        if agentSpeaking { return .speaking }
        if awaitingAgent { return .thinking }
        return .listening
    }
}

/**
 * WHERE A CALL BEING PLACED IS, as the engine reports it (`graine:progress`).
 *
 *   registering  a credential and a line are being set up (a cold start)
 *   dialling     the call is on its way to the agent
 *   retrying     the first attempt went unanswered and a fresh connection is
 *                being made — on mobile data, usually a connection the phone
 *                dropped while it sat idle
 *   switching    the call is moving to the other transport
 *
 * A bar that says "Reconnecting…" across a retry is one the customer waits
 * for; one that says "Connecting…" for eight seconds is one they close.
 */
public enum GraineConnectStage: String, Sendable {
    case registering
    case dialling
    case retrying
    case switching
}

/// One `graine:progress` report: a stage, or `failed` — nothing could carry the call on either transport.
public enum GraineConnectProgress: Equatable, Sendable {
    case stage(GraineConnectStage)
    case failed

    /// Nil for a stage this build does not know: ignored, never guessed at.
    static func from(_ raw: String?) -> GraineConnectProgress? {
        guard let raw = raw else { return nil }
        if raw == "failed" { return .failed }
        return GraineConnectStage(rawValue: raw).map { .stage($0) }
    }
}

/**
 * THE CONNECT'S OWN STATE — the stage it is at, and whether the last start
 * could not be connected at all. The React Native launcher's rules:
 *
 *   a stage           is stored (a failure already shown stays until cleared)
 *   failed            ends the connect: no stage, `failed` — stop saying
 *                     "connecting" and offer another try
 *   connected         a call is up: neither is news any more
 *   started / ended   a new attempt, or the customer done with this one
 *                     (the bar closed, the engine removed): a clean slate
 *
 * `failed` is not `error`: an error is a setting someone must change, and a
 * failed connect is a network that may well be better in a moment, so
 * `start()` simply tries again.
 */
struct ConnectAttempt: Equatable {
    var stage: GraineConnectStage? = nil
    var failed = false

    enum Event: Equatable {
        case progress(GraineConnectProgress)
        case connected
        case started
        case ended
    }

    func after(_ event: Event) -> ConnectAttempt {
        switch event {
        case .progress(.stage(let next)): return ConnectAttempt(stage: next, failed: failed)
        case .progress(.failed): return ConnectAttempt(stage: nil, failed: true)
        case .connected, .started, .ended: return ConnectAttempt()
        }
    }

    /// Whether a report means the connect is over and the customer must be told it is not connecting.
    static func stopsConnecting(_ progress: GraineConnectProgress) -> Bool {
        progress == .failed
    }
}

/**
 * "STILL CONNECTING…" — a clock on the customer's wait, not on the network:
 * the network is the engine's to report. Armed while the customer is actually
 * waiting on a connect, cleared the moment it lands or they stop waiting.
 */
enum ConnectWait {
    /**
     * When a connect stops being "Connecting…" and becomes "Still connecting…".
     * Past the point a healthy connect finishes (warm 0.2–0.9 s, cold 1.5–2.5 s
     * on a good network) and well inside the ten seconds after which, without a
     * word of explanation, people assume it is broken.
     */
    static let slowConnectMs = 4_000

    /**
     * - Parameters:
     *   - watched: the customer can see it — a voice bar is on screen with the
     *     engine mounted — or they asked for a call. An idle page loading behind
     *     no bar is nobody's slow connect.
     */
    static func waiting(watched: Bool, connected: Bool, callFailed: Bool, connecting: Bool, ready: Bool) -> Bool {
        watched && !connected && !callFailed && (connecting || !ready)
    }
}

/**
 * The slow-connect clock itself, with its scheduling handed in so a Mac can
 * drive it by hand. One clock per wait: asked again while armed or already
 * slow, it does nothing; a wait that ends cancels it and clears `slow`.
 */
final class SlowConnectClock {
    /// Run `fire` after `afterMs`; the returned closure cancels it.
    typealias Schedule = (_ afterMs: Int, _ fire: @escaping () -> Void) -> () -> Void

    private let delayMs: Int
    private let schedule: Schedule
    private let onChange: (Bool) -> Void
    private var cancel: (() -> Void)?
    private(set) var slow = false

    init(delayMs: Int, schedule: @escaping Schedule, onChange: @escaping (Bool) -> Void) {
        self.delayMs = max(0, delayMs)
        self.schedule = schedule
        self.onChange = onChange
    }

    func update(waiting: Bool) {
        guard waiting else {
            cancel?()
            cancel = nil
            if slow {
                slow = false
                onChange(false)
            }
            return
        }
        guard cancel == nil, !slow else { return }
        cancel = schedule(delayMs) { [weak self] in
            guard let self = self, self.cancel != nil else { return }
            self.cancel = nil
            self.slow = true
            self.onChange(true)
        }
    }
}

/**
 * When the app comes back to the foreground, should the page be told to warm?
 *
 * The page keeps a SIP registration warm so a tap costs only the INVITE
 * (~0.2 s). A phone drops that idle socket while the app sleeps, and the page
 * hears of it only when something wakes it — its own visibilitychange is not
 * reliably that in a web view a point wide. The app knows it is back, so it
 * says so: only when the page is ready to hear it, and never during a call,
 * whose registration a warm would replace. The same rule as the React Native
 * launcher's AppState listener and the Android SDK's Warm.
 */
enum Warm {
    static func onForeground(ready: Bool, startedCall: Bool, connected: Bool, connecting: Bool) -> Bool {
        ready && !startedCall && !connected && !connecting
    }
}

/**
 * THE BAR NAMES THE NETWORK, or the agent takes the blame for it.
 *
 * A customer whose agent goes quiet on a train reads "listening" and concludes
 * the agent is broken. "no connection", "weak connection" and "reconnecting…"
 * are the sentences that keep that blame where it belongs. Same order as the
 * Android bar; "needs microphone" holds after a refusal until the next start.
 *
 * These are the words of the bar drawn WITHOUT a design — an older server's
 * session — which keeps looking and reading exactly as it did. A bar drawn
 * from a design says VoiceBarStatus's, the contract's.
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
