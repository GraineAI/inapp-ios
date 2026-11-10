#if os(iOS)
import Combine
import Foundation

/// Which calls the face stage's Call button places: the voice bar's (the default), or native calls (`GraineCalls`).
public enum GraineStageCalls: String {
    case voice
    case native
}

/**
 * THE FACE STAGE, AS STATE — everything `GraineAvatarStage` reads and every
 * action its buttons perform, for a screen of your own over the agent's face
 * (contract/PUBLIC-STATE.md "The face stage"). `state` is one value, decided
 * from what the SDK already publishes: the native call (`GraineCalls`) while
 * one is ringing, being placed or on, else the voice bar's call
 * (`GraineVoice`), with the face (`GraineAvatar.shared.state`), the
 * component (`GraineInApp.components`) and the header's words.
 *
 *     @ObservedObject var stage = GraineInApp.current!.stage
 *
 *     ZStack {
 *         GraineAvatarFace().ignoresSafeArea()
 *         VStack {
 *             if stage.state.live { Text("LIVE · \(stage.state.clock())") }
 *             Spacer()
 *             if let line = stage.state.caption { Text(line.text) }
 *             Button(stage.state.endLabel) { stage.end() }
 *         }
 *     }
 *
 * The face draws inside `GraineAvatarFace`, so anything above it is drawn over
 * the face. Main thread.
 */
public final class GraineStage: ObservableObject {
    /// What the stage shows now.
    @Published public private(set) var state: GraineStageState = .idle

    /// Called on the main thread whenever `state` changes.
    public var onStateChange: ((GraineStageState) -> Void)?

    /// The header's name. Nil: the dashboard chat header's title, else the name rings carry, else the bar's heading.
    public var name: String? {
        didSet { if name != oldValue { recompute() } }
    }

    /// The header's second line ("AI care assistant"). Nil: the dashboard chat header's subtitle, else none.
    public var role: String? {
        didSet { if role != oldValue { recompute() } }
    }

    /// What `call()` places: the voice bar's call, or a native call.
    public var calls: GraineStageCalls = .voice

    /// The app's chat. The stage draws its chat button only with one; a tap calls it — open your chat there.
    public var onChat: (() -> Void)? {
        didSet { if (onChat == nil) != (oldValue == nil) { recompute() } }
    }

    private unowned let graine: GraineInApp
    private var watching: Set<AnyCancellable> = []
    private weak var watchedCalls: GraineCalls?
    /// Hears the session and the design for the header's words (held here: the SDK holds listeners weakly).
    private lazy var relay = StageSessionRelay(stage: self)

    init(graine: GraineInApp) {
        self.graine = graine
        graine.addListener(relay)
        let soon = { [weak self] in self?.recompute() }
        // Each publishes before it changes: the stage reads the new values on the next turn of the main loop.
        graine.voice.objectWillChange.receive(on: DispatchQueue.main).sink { _ in soon() }.store(in: &watching)
        graine.components.objectWillChange.receive(on: DispatchQueue.main).sink { _ in soon() }.store(in: &watching)
        GraineAvatar.shared.$state.receive(on: DispatchQueue.main).sink { _ in soon() }.store(in: &watching)
        watchCallsIfMade()
        recompute()
    }

    // MARK: - What the buttons do

    /// Place the call the stage is for: the voice bar's (the engine is mounted first if nothing has), or a native call.
    public func call() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.call() }
            return
        }
        switch calls {
        case .native:
            _ = graine.calls.startCall()
            watchCallsIfMade()
        case .voice:
            let voice = graine.voice
            if !voice.isAttached { voice.attach() }
            voice.start()
        }
    }

    /// Take the native call that is ringing.
    public func answer() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.answer() }
            return
        }
        GraineCalls.existing?.answer()
    }

    /// Hang up, cancel a call being placed, or decline a ring — whichever the stage shows.
    public func end() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.end() }
            return
        }
        switch state.call {
        case .native:
            guard let calls = GraineCalls.existing else { return }
            if calls.phase == .ringing { calls.decline() } else { calls.end() }
        case .voice:
            graine.voice.end()
        case .none:
            break
        }
    }

    /// The microphone of the call the stage shows.
    public func setMuted(_ muted: Bool) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.setMuted(muted) }
            return
        }
        if state.call == .native, let calls = GraineCalls.existing {
            calls.setMuted(muted)
        } else {
            graine.voice.setMuted(muted)
        }
    }

    /// The loudspeaker (true) or the earpiece of the call the stage shows — with no call, of the next one.
    public func setSpeaker(_ on: Bool) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.setSpeaker(on) }
            return
        }
        if state.call == .native, let calls = GraineCalls.existing {
            calls.setSpeaker(on)
        } else {
            graine.voice.setSpeaker(on)
        }
    }

    /// The chat button: the app's `onChat`.
    public func openChat() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.openChat() }
            return
        }
        onChat?()
    }

    // MARK: - Deciding

    /// The app's calls, once anything made them: the stage never makes them by watching.
    private func watchCallsIfMade() {
        guard let calls = GraineCalls.existing, watchedCalls !== calls else { return }
        watchedCalls = calls
        calls.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.recompute() }.store(in: &watching)
    }

    static func ms(_ date: Date?) -> Double? { date.map { $0.timeIntervalSince1970 * 1000 } }

    /// The header's words: the app's, else the dashboard chat header's, else the name rings carry, else the bar's heading.
    private func words() -> (name: String, role: String?) {
        let session = graine.sessionOrCached
        let chat = session?.design?.tokens(deviceDark: false).chat
        func nonEmpty(_ s: String?) -> String? {
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return s
        }
        let resolvedName = nonEmpty(name)
            ?? nonEmpty(chat?.title)
            ?? nonEmpty(session?.calls?.callName)
            ?? nonEmpty(Appearance.heading(session?.appearance, fallback: "Assistant"))
            ?? "Assistant"
        return (resolvedName, nonEmpty(role) ?? nonEmpty(chat?.subtitle))
    }

    func recompute() {
        watchCallsIfMade()
        let voice = graine.voice
        let native = watchedCalls
        let input = AvatarStage.Input(
            native: AvatarStage.Side(
                word: native?.phase.rawValue ?? "idle",
                muted: native?.muted ?? false,
                speaker: native?.speakerOn ?? true,
                startedAt: Self.ms(native?.connectedAt),
                captions: (native?.transcript ?? []).map(GraineStageCaption.init)
            ),
            voice: AvatarStage.Side(
                // The call as the customer has it: a misconfiguration it survived never takes its End button away.
                word: voice.stageStatus.rawValue,
                muted: voice.muted,
                speaker: voice.speaker,
                startedAt: Self.ms(voice.startedAt),
                captions: voice.captions.map(GraineStageCaption.init),
                captionsOn: voice.captionsOn
            ),
            chat: onChat != nil
        )
        let o = AvatarStage.decide(input)
        let header = words()
        let components = graine.components
        let next = GraineStageState(
            call: o.call, phase: o.phase, status: o.status, live: o.live,
            startedAt: o.startedAt.map { Date(timeIntervalSince1970: $0 / 1000) },
            caption: o.caption, muted: o.muted, speaker: o.speaker, controls: o.controls, enabled: o.enabled,
            endLabel: o.endLabel, face: GraineAvatar.shared.state, name: header.name, role: header.role,
            component: components.current, componentPending: components.pending
        )
        guard next != state else { return }
        state = next
        onStateChange?(next)
    }
}

/// The session and the design arriving: the header's words may have changed.
private final class StageSessionRelay: GraineListener {
    private weak var stage: GraineStage?

    init(stage: GraineStage) { self.stage = stage }

    func onSessionReady(_ session: GraineSessionConfig) {
        DispatchQueue.main.async { [weak self] in self?.stage?.recompute() }
    }

    func onTheme(_ tokens: GraineThemeTokens?) {
        DispatchQueue.main.async { [weak self] in self?.stage?.recompute() }
    }
}
#endif
