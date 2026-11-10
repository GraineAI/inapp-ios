import Foundation

/*
 * THE FACE STAGE'S RULE — what the stage over the agent's face shows
 * (contract/DESIGN.md "Face stage", contract/PUBLIC-STATE.md "The face stage"):
 * avatarStage() in sdk/inapp/protocol.ts, word for word, replayed by the tests
 * against contract/avatar-stage.json. Pure, so a Mac proves it.
 */

/// Which call the face stage shows: none, the voice bar's, or a native call (`GraineCalls`).
public enum GraineStageCall: String, Sendable, Equatable {
    case none
    case voice
    case native
}

/**
 * Where the call on the stage is. `failed`: the voice bar's call could not
 * start or go on (`GraineVoice.error` says why); a native call that fails ends.
 */
public enum GraineStagePhase: String, Sendable, Equatable, CaseIterable {
    case idle
    case ringing
    case connecting
    case live
    case reconnecting
    case ended
    case failed
}

/// The stage's buttons. `call` places a call, `answer` takes a ringing one, `end` hangs up, cancels or declines.
public enum GraineStageControl: String, Sendable, Equatable, CaseIterable {
    case call
    case answer
    case mute
    case chat
    case end
    case speaker
}

/// The line being said, as the stage shows it.
public struct GraineStageCaption: Equatable {
    /// Who is saying it.
    public let who: GraineRole
    public let text: String
    /// Settled; a line still arriving is drawn a little faint.
    public let final: Bool

    public init(who: GraineRole, text: String, final: Bool) {
        self.who = who
        self.text = text
        self.final = final
    }

    init(_ caption: GraineCaption) {
        self.init(who: caption.role, text: caption.text, final: !caption.live)
    }
}

/**
 * EVERYTHING THE FACE STAGE READS (`GraineInApp.stage.state`) — for a screen
 * of your own over the face (`GraineAvatarFace`), drawn from the same state
 * the SDK's `GraineAvatarStage` draws.
 */
public struct GraineStageState: Equatable {
    /// Which call the stage shows.
    public let call: GraineStageCall
    public let phase: GraineStagePhase
    /// The words beside the name: "Incoming call", "Connecting…", "Reconnecting…", "Call ended", "Couldn’t connect"; empty while live and idle.
    public let status: String
    /// The LIVE mark and the clock show.
    public let live: Bool
    /// When the call went live, while it is live or coming back; nil otherwise. `GraineStageState.clock(from:)` is the clock's words.
    public let startedAt: Date?
    /// The line being said, while the call is on — never an empty one.
    public let caption: GraineStageCaption?
    public let muted: Bool
    /// The call's audio is on the loudspeaker.
    public let speaker: Bool
    /// The buttons, left to right.
    public let controls: [GraineStageControl]
    /// The buttons that can act now (the microphone waits for the call to be on).
    public let enabled: [GraineStageControl]
    /// What End is called: "Cancel" while a call is being placed, "Decline" while one rings, else "End".
    public let endLabel: String
    /// The agent's face (`GraineAvatar.shared.state`).
    public let face: GraineAvatarState
    /// The header's name: the app's, else the dashboard chat header's title, else the voice bar's name.
    public let name: String
    /// The header's second line: the app's, else the dashboard chat header's subtitle; nil for none.
    public let role: String?
    /// The component on show (`GraineInApp.components.current`), if any.
    public let component: GraineWidget?
    /// A component is on its way (`GraineInApp.components.pending`).
    public let componentPending: Bool

    public static func == (a: GraineStageState, b: GraineStageState) -> Bool {
        a.call == b.call && a.phase == b.phase && a.status == b.status && a.live == b.live && a.startedAt == b.startedAt
            && a.caption == b.caption && a.muted == b.muted && a.speaker == b.speaker && a.controls == b.controls
            && a.enabled == b.enabled && a.endLabel == b.endLabel && a.face == b.face && a.name == b.name && a.role == b.role
            && a.component?.id == b.component?.id && a.componentPending == b.componentPending
    }

    /// Whether `control` is drawn, and can act now.
    public func shows(_ control: GraineStageControl) -> Bool { controls.contains(control) }
    public func canUse(_ control: GraineStageControl) -> Bool { enabled.contains(control) }

    /// The clock's words from `start` to `now`: m:ss, h:mm:ss after an hour — the call screen's own.
    public static func clock(from start: Date, to now: Date = Date()) -> String {
        AvatarStage.clock(elapsedMs: now.timeIntervalSince(start) * 1000)
    }

    /// The clock's words for this state at `now`; "" when it is not live or coming back.
    public func clock(now: Date = Date()) -> String {
        guard let start = startedAt else { return "" }
        return Self.clock(from: start, to: now)
    }

    static let idle = GraineStageState(
        call: .none, phase: .idle, status: "", live: false, startedAt: nil, caption: nil, muted: false, speaker: true,
        controls: [.call], enabled: [.call], endLabel: "End", face: .off, name: "Assistant", role: nil, component: nil,
        componentPending: false
    )

    init(
        call: GraineStageCall, phase: GraineStagePhase, status: String, live: Bool, startedAt: Date?,
        caption: GraineStageCaption?, muted: Bool, speaker: Bool, controls: [GraineStageControl],
        enabled: [GraineStageControl], endLabel: String, face: GraineAvatarState, name: String, role: String?,
        component: GraineWidget?, componentPending: Bool
    ) {
        self.call = call
        self.phase = phase
        self.status = status
        self.live = live
        self.startedAt = startedAt
        self.caption = caption
        self.muted = muted
        self.speaker = speaker
        self.controls = controls
        self.enabled = enabled
        self.endLabel = endLabel
        self.face = face
        self.name = name
        self.role = role
        self.component = component
        self.componentPending = componentPending
    }
}

enum AvatarStage {
    /// The words beside the name. The apostrophe is the curly one.
    static let status: [GraineStagePhase: String] = [
        .idle: "", .ringing: "Incoming call", .connecting: "Connecting…", .live: "",
        .reconnecting: "Reconnecting…", .ended: "Call ended", .failed: "Couldn’t connect",
    ]

    struct Side: Equatable {
        /// The native call's `phase` word, or the voice bar's `status` word.
        var word: String
        var muted = false
        var speaker = true
        /// ms since 1970.
        var startedAt: Double? = nil
        var captions: [GraineStageCaption] = []
        var captionsOn = true
    }

    struct Input: Equatable {
        var native: Side
        var voice: Side
        /// The app handles the chat button.
        var chat: Bool
    }

    struct Output: Equatable {
        let call: GraineStageCall
        let phase: GraineStagePhase
        let status: String
        let live: Bool
        let startedAt: Double?
        let caption: GraineStageCaption?
        let muted: Bool
        let speaker: Bool
        let controls: [GraineStageControl]
        let enabled: [GraineStageControl]
        let endLabel: String
    }

    private static let nativeOn: Set<String> = ["ringing", "calling", "connecting", "active", "reconnecting"]
    private static let voiceOn: Set<String> = ["connecting", "listening", "thinking", "speaking", "reconnecting", "muted"]

    private static func phase(_ call: GraineStageCall, _ input: Input) -> GraineStagePhase {
        switch call {
        case .native:
            switch input.native.word {
            case "ringing": return .ringing
            case "calling", "connecting": return .connecting
            case "active": return .live
            case "reconnecting": return .reconnecting
            case "ended": return .ended
            default: return .idle
            }
        case .voice:
            switch input.voice.word {
            case "connecting": return .connecting
            case "listening", "thinking", "speaking", "muted": return .live
            case "reconnecting": return .reconnecting
            case "ended": return .ended
            case "failed": return .failed
            default: return .idle
            }
        case .none:
            return .idle
        }
    }

    /**
     * Which call: a native call ringing, being placed or on; else the voice
     * bar's call being placed or on; else the voice bar's that ended or
     * failed; else a native call that ended; else none.
     */
    static func decide(_ input: Input) -> Output {
        let call: GraineStageCall
        if nativeOn.contains(input.native.word) {
            call = .native
        } else if voiceOn.contains(input.voice.word) {
            call = .voice
        } else if input.voice.word == "ended" || input.voice.word == "failed" {
            call = .voice
        } else if input.native.word == "ended" {
            call = .native
        } else {
            call = .none
        }
        let phase = phase(call, input)
        let source = call == .native ? input.native : input.voice
        let on = phase == .live || phase == .reconnecting
        let captionsOn = call == .voice ? input.voice.captionsOn : true
        var caption: GraineStageCaption?
        if on, captionsOn, call != .none, let last = source.captions.last,
           !last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            caption = last
        }
        let chat: [GraineStageControl] = input.chat ? [.chat] : []
        let controls: [GraineStageControl]
        let enabled: [GraineStageControl]
        switch phase {
        case .ringing:
            controls = [.end, .answer]
            enabled = controls
        case .connecting:
            controls = [.mute] + chat + [.end, .speaker]
            enabled = chat + [.end, .speaker]
        case .live, .reconnecting:
            controls = [.mute] + chat + [.end, .speaker]
            enabled = controls
        default:
            controls = chat + [.call]
            enabled = controls
        }
        return Output(
            call: call,
            phase: phase,
            status: status[phase] ?? "",
            live: phase == .live,
            startedAt: on ? source.startedAt : nil,
            caption: caption,
            muted: call == .native ? input.native.muted : input.voice.muted,
            speaker: call == .native ? input.native.speaker : input.voice.speaker,
            controls: controls,
            enabled: enabled,
            endLabel: phase == .connecting ? "Cancel" : phase == .ringing ? "Decline" : "End"
        )
    }

    /// m:ss under an hour, h:mm:ss after; below zero (and anything not a number) reads as zero.
    static func clock(elapsedMs: Double) -> String {
        let ms = elapsedMs.isFinite ? max(0, elapsedMs) : 0
        let s = Int((ms / 1000).rounded(.down))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        return h > 0 ? "\(h):\(two(m)):\(two(sec))" : "\(m):\(two(sec))"
    }
}
