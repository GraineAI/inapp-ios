#if os(iOS)
import AVFoundation
import CallKit
import Combine
import Foundation
import PushKit

/// How the calls ring and what they show. Set once, at launch (`GraineCalls.configure`).
public struct GraineCallsConfig {
    /**
     * The name a call rings with and shows on the call screen — your agent's,
     * or your brand's. Empty: your app's name. A push's `caller_name` wins for
     * its own call.
     */
    public var displayName: String
    /// A sound file in your app's bundle to ring with. Nil: the system ringtone.
    public var ringtoneSound: String?
    /// PNG data for a template image (40×40 points, transparent) on the system call screen's app button.
    public var iconTemplateImageData: Data?
    /// List the calls in the Phone app's Recents. Off by default.
    public var includesCallsInRecents: Bool
    /// Seconds an agent's call rings before it is missed.
    public var ringTimeout: TimeInterval

    public init(
        displayName: String = "",
        ringtoneSound: String? = nil,
        iconTemplateImageData: Data? = nil,
        includesCallsInRecents: Bool = false,
        ringTimeout: TimeInterval = 30
    ) {
        self.displayName = displayName
        self.ringtoneSound = ringtoneSound
        self.iconTemplateImageData = iconTemplateImageData
        self.includesCallsInRecents = includesCallsInRecents
        self.ringTimeout = ringTimeout
    }
}

/**
 * What the calls report, for your server. Every method has a default that
 * does nothing. Called on the main thread. Held WEAKLY.
 */
public protocol GraineCallsListener: AnyObject {
    /// An agent's call is ringing on this device.
    func onIncomingCall(_ call: GraineIncomingCall)
    /// The call moved (`idle`, `ringing`, `connecting`, `active`, `ended`).
    func onCallState(_ state: GraineCallState, callId: String?)
    /// What became of a call: answered, declined, missed, ended (local, remote, failed) or failed. Tell your server.
    func onCallOutcome(_ outcome: GraineCallOutcome, callId: String)
}

public extension GraineCallsListener {
    func onIncomingCall(_ call: GraineIncomingCall) {}
    func onCallState(_ state: GraineCallState, callId: String?) {}
    func onCallOutcome(_ outcome: GraineCallOutcome, callId: String) {}
}

/**
 * CALLS LIKE WHATSAPP — on CallKit and VoIP pushes.
 *
 * The customer calls your agent (`startCall`), or your agent rings the
 * customer (your server sends a VoIP push; `enableVoIPPushes` takes it from
 * there): the system's own call screen, the lock screen, Bluetooth, the call
 * going on with the screen off. The audio runs in your app's process with the
 * platform's echo canceller, over the same conversation the in-app agent uses
 * — the agent sees the screen you describe and can run your actions.
 *
 *     let calls = GraineInApp.shared.calls
 *     calls.configure(GraineCallsConfig(displayName: "Acme Assistant"))
 *     calls.enableVoIPPushes { token in myServer.saveVoipToken(token) }
 *     calls.addListener(self)                 // outcomes, for your server
 *     calls.startCall(reason: "card_blocked") // the customer calls the agent
 *
 * One call at a time; a push while a call is live is reported and missed.
 * Starting a call ends any call the web view engine (`voice`) holds. Placing
 * or answering a call asks for the microphone if the app does not hold it; a
 * call that does not get it ends `failed`.
 * `ObservableObject`: draw your own screen from `state`, `muted`, `speakerOn`,
 * `agentSpeaking` and `caption`, or present `GraineCallView`. Main thread.
 */
public final class GraineCalls: NSObject, ObservableObject {
    // MARK: - State

    @Published public private(set) var state: GraineCallState = .idle
    /// The current (or just-ended) call's id: the push's `call_id`, or the one `startCall` generated.
    @Published public private(set) var callId: String?
    @Published public private(set) var direction: GraineCallDirection?
    /// The name the call shows.
    @Published public private(set) var callerName = ""
    @Published public private(set) var muted = false
    /// Audio out of the loudspeaker rather than the earpiece (or a headset).
    @Published public private(set) var speakerOn = false
    /// The agent's voice is playing — from the audio itself, not from the agent's text.
    @Published public private(set) var agentSpeaking = false
    /// The latest line: the agent's words as they are said, or the customer's as they are heard.
    @Published public private(set) var caption: GraineCaption?
    /// When the conversation opened; nil before.
    @Published public private(set) var connectedAt: Date?

    /// The configuration in force.
    public private(set) var config = GraineCallsConfig()

    // MARK: - Internals

    private unowned let graine: GraineInApp
    private var machine = CallMachine()
    private var provider: CXProvider?
    private let controller = CXCallController()
    private var registry: PKPushRegistry?
    private var onToken: ((String?) -> Void)?
    private var listenerBoxes: [WeakCallsListener] = []

    private var callUUID: UUID?
    private var incoming: GraineIncomingCall?
    private var outgoingReason: String?
    private var outgoingVariables: [String: String] = [:]
    private var engine: CallEngine?
    private var ringItem: DispatchWorkItem?
    private var settleItem: DispatchWorkItem?
    private var unwatchContext: (() -> Void)?
    private var routeObserver: NSObjectProtocol?
    private var audioActive = false
    private var savedAudio: SavedCallAudio?
    private let micPermission: MicPermissionSource
    /// Whether an answered call may have the microphone (Core/CallMachine.swift).
    private lazy var answerMic = CallMicGate(source: micPermission, schedule: { seconds, fire in
        let item = DispatchWorkItem(block: fire)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return { item.cancel() }
    })

    /// How long "ended" shows before the calls are idle again.
    static let settleSeconds = 1.0

    init(graine: GraineInApp, micPermission: MicPermissionSource = SystemMicPermission()) {
        self.graine = graine
        self.micPermission = micPermission
        super.init()
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshSpeaker()
        }
    }

    deinit {
        if let token = routeObserver { NotificationCenter.default.removeObserver(token) }
    }

    // MARK: - Setting up

    /// How calls ring and what they show. Call once, at launch, before `enableVoIPPushes`.
    public func configure(_ config: GraineCallsConfig) {
        onMain {
            self.config = config
            self.provider?.configuration = self.providerConfiguration()
        }
    }

    /**
     * Receive your agent's calls as VoIP pushes. Call at launch, every launch
     * (iOS wakes a terminated app for a push and delivers it once this has
     * run). `onToken` gets the device's VoIP token as hex — send it to your
     * server — and nil when it is invalidated. Every push is reported to
     * CallKit before its completion runs, as iOS requires.
     *
     * An app with its own PKPushRegistry passes the payload to
     * `reportIncomingCall(payload:completion:)` instead.
     */
    public func enableVoIPPushes(onToken: @escaping (String?) -> Void) {
        onMain {
            self.onToken = onToken
            _ = self.ensureProvider()
            let registry = self.registry ?? PKPushRegistry(queue: .main)
            registry.delegate = self
            registry.desiredPushTypes = [.voIP]
            self.registry = registry
            if let token = registry.pushToken(for: .voIP) { onToken(GraineCalls.hex(token)) }
        }
    }

    /// Hear about calls. Held weakly.
    public func addListener(_ listener: GraineCallsListener) {
        onMain {
            self.listenerBoxes.removeAll { $0.value == nil }
            if !self.listenerBoxes.contains(where: { $0.value === listener }) {
                self.listenerBoxes.append(WeakCallsListener(listener))
            }
        }
    }

    public func removeListener(_ listener: GraineCallsListener) {
        onMain { self.listenerBoxes.removeAll { $0.value == nil || $0.value === listener } }
    }

    // MARK: - Calls

    /**
     * The customer calls the agent. The agent hears `who_called = "customer"`
     * and `call_reason`, with `variables` over the SDK's own. Returns the
     * call's id, or nil when a call is already live (one at a time). Asks for
     * the microphone first if the app does not hold it.
     */
    @discardableResult
    public func startCall(reason: String? = nil, variables: [String: Any] = [:]) -> String? {
        guard Thread.isMainThread else {
            var id: String?
            DispatchQueue.main.sync { id = self.startCall(reason: reason, variables: variables) }
            return id
        }
        guard !machine.state.isLive else {
            GraineLog.warning("A call is already live; startCall was refused.")
            return nil
        }
        let id = UUID().uuidString.lowercased()
        let uuid = UUID()
        endWebViewCall()
        settleItem?.cancel()
        settleItem = nil
        callUUID = uuid
        incoming = nil
        outgoingReason = reason
        outgoingVariables = GraineCalls.maskedVariables(variables)
        callerName = resolvedDisplayName
        direction = .outgoing
        callId = id
        transition(.outgoing(id: id))

        let proceed: (Bool) -> Void = { [weak self] granted in
            guard let self = self, self.callUUID == uuid, self.machine.state == .connecting else { return }
            if granted {
                self.requestStart(uuid)
            } else {
                self.graine.notifyListeners { $0.onMicDenied(reason: "NotAllowedError") }
                self.transition(.failed(CallMicGate.notGranted))
            }
        }
        if micPermission.permission == .granted {
            proceed(true)
        } else {
            micPermission.request(proceed)
        }
        return id
    }

    /**
     * Report an agent's call from a VoIP push your own PKPushRegistry received.
     * Reported to CallKit at once — before `completion` runs, as iOS requires —
     * even when the payload is not usable or a call is already live (then it
     * is ended at once, and a live call is never disturbed).
     */
    public func reportIncomingCall(payload: [AnyHashable: Any], completion: (() -> Void)? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.sync { self.reportIncomingCall(payload: payload, completion: completion) }
            return
        }
        let provider = ensureProvider()
        let liveId = machine.state.isLive ? machine.call?.id : nil
        let steps = PushIntake.plan(payload, displayName: resolvedDisplayName, liveCallId: liveId)
        let uuid = UUID()
        var name = resolvedDisplayName
        var ringing: GraineIncomingCall?
        var ending: PushIntake.Ending?
        var outcomes: [(String, GraineCallOutcome)] = []
        for step in steps {
            switch step {
            case .report(let callerName): name = callerName
            case .ring(let call): ringing = call
            case .endAtOnce(let why): ending = why
            case .outcome(let id, let outcome): outcomes.append((id, outcome))
            }
        }
        if let call = ringing {
            // The machine first: a second push a moment from now must find this call live.
            endWebViewCall()
            settleItem?.cancel()
            settleItem = nil
            callUUID = uuid
            incoming = call
            callerName = name
            direction = .incoming
            callId = call.callId
            transition(.incoming(id: call.callId))
            armRingTimeout(uuid)
        }
        provider.reportNewIncomingCall(with: uuid, update: callUpdate(name: name)) { [weak self] error in
            DispatchQueue.main.async {
                defer { completion?() }
                guard let self = self else { return }
                if let ending = ending {
                    provider.reportCall(with: uuid, endedAt: Date(), reason: ending == .failed ? .failed : .unanswered)
                    for (id, outcome) in outcomes { self.notifyOutcome(outcome, callId: id) }
                    return
                }
                guard let call = ringing, self.callUUID == uuid, self.machine.state == .ringing else { return }
                if let error = error {
                    // CallKit would not ring it (Do Not Disturb, a block list): nobody heard it.
                    GraineLog.warning("CallKit did not ring the agent's call: \(GraineInApp.describe(error))")
                    self.ringItem?.cancel()
                    self.transition(.ringTimeout)
                    return
                }
                self.notifyListeners { $0.onIncomingCall(call) }
            }
        }
    }

    /// Answer the ringing call from your own screen (the system's call screen answers by itself).
    public func answer() {
        onMain {
            guard let uuid = self.callUUID, self.machine.state == .ringing else { return }
            self.controller.request(CXTransaction(action: CXAnswerCallAction(call: uuid))) { error in
                if let error = error { GraineLog.warning("Could not answer: \(GraineInApp.describe(error))") }
            }
        }
    }

    /// Hang up — or decline, while it rings.
    public func end() {
        onMain {
            guard let uuid = self.callUUID, self.machine.state.isLive else { return }
            self.controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { error in
                guard error != nil else { return }
                // CallKit does not know the call (it never reached it): end it here.
                DispatchQueue.main.async {
                    guard self.callUUID == uuid, self.machine.state.isLive else { return }
                    self.ringItem?.cancel()
                    self.engine?.hangUp()
                    self.transition(.hangUp)
                }
            }
        }
    }

    /// Stop sending the customer's voice without ending the call. The system's call screen shows it too.
    public func setMuted(_ value: Bool) {
        onMain {
            guard let uuid = self.callUUID, self.machine.state.isLive else {
                self.muted = value
                return
            }
            self.controller.request(CXTransaction(action: CXSetMutedCallAction(call: uuid, muted: value))) { error in
                guard error != nil else { return }
                DispatchQueue.main.async { self.applyMuted(value) }
            }
        }
    }

    /// The loudspeaker (true) or the earpiece / headset (false). Earpiece by default, like a phone call.
    public func setSpeaker(_ on: Bool) {
        onMain {
            self.speakerOn = on
            self.applySpeaker()
        }
    }

    // MARK: - The conversation

    private func requestStart(_ uuid: UUID) {
        _ = ensureProvider()
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: callerName))
        action.isVideo = false
        controller.request(CXTransaction(action: action)) { [weak self] error in
            guard let error = error else { return }
            DispatchQueue.main.async {
                guard let self = self, self.callUUID == uuid, self.machine.state == .connecting else { return }
                self.transition(.failed("The call could not be placed: \(GraineInApp.describe(error))"))
            }
        }
    }

    /// Open the conversation. The audio starts when CallKit activates the session.
    private func beginConversation(whoCalled: String, reason: String?, own: [String: String]) {
        guard let uuid = callUUID, engine == nil else { return }
        let graine = self.graine
        let audio = GraineCallAudioIO()
        audio.onFailure = { [weak self] message in
            DispatchQueue.main.async { self?.audioFailed(message, uuid: uuid) }
        }
        let setup = CallEngine.Setup(
            publishableKey: graine.config.publishableKey,
            baseUrl: graine.config.baseUrl,
            variables: CallEngine.variables(sdk: graine.currentVariables(), whoCalled: whoCalled, reason: reason, own: own),
            contextFrame: { [weak graine] in graine?.currentContextFrame() },
            session: { [weak graine] done in
                guard let graine = graine else { return done(nil) }
                graine.loadSession(done)
            },
            runAction: CallEngine.actionRunner(graine)
        )
        let engine = CallEngine(
            setup: setup,
            audio: audio,
            network: URLSessionCallNetwork(),
            scheduler: DispatchCallScheduler(),
            onEvent: { [weak self] event in
                DispatchQueue.main.async { self?.engineEvent(event, uuid: uuid) }
            }
        )
        self.engine = engine
        engine.setMuted(muted)
        engine.start()
        if audioActive { engine.startAudio() }
        unwatchContext = graine.onContext { [weak engine] frame in engine?.sendContext(frame) }
    }

    private func engineEvent(_ event: CallEngine.Event, uuid: UUID) {
        guard callUUID == uuid else { return }
        switch event {
        case .opened(let transport):
            guard machine.state == .connecting else { return }
            if graine.config.debug { GraineLog.trace("call open via \(transport.rawValue)") }
            if direction == .outgoing { provider?.reportOutgoingCall(with: uuid, connectedAt: Date()) }
            connectedAt = Date()
            transition(.connected)
        case .speaking(let value):
            if agentSpeaking != value { agentSpeaking = value }
        case .caption(let line):
            caption = line
        case .format(let format):
            if graine.config.debug { GraineLog.trace("agent audio: \(format.kind.rawValue) at \(format.sampleRate) Hz") }
        case .ended(let ending):
            switch ending {
            case .local:
                break
            case .remote:
                provider?.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
                transition(.remoteEnded)
            case .dropped(let detail):
                GraineLog.warning("The call dropped: \(detail)")
                provider?.reportCall(with: uuid, endedAt: Date(), reason: .failed)
                transition(.dropped)
            case .couldNotOpen(let detail):
                GraineLog.warning("The call could not connect: \(detail)")
                provider?.reportCall(with: uuid, endedAt: Date(), reason: .failed)
                transition(.failed(detail))
            }
        }
    }

    private func audioFailed(_ message: String, uuid: UUID) {
        guard callUUID == uuid, machine.state.isLive else { return }
        GraineLog.warning(message)
        engine?.hangUp()
        provider?.reportCall(with: uuid, endedAt: Date(), reason: .failed)
        transition(machine.state == .active ? .dropped : .failed(message))
    }

    private func applyMuted(_ value: Bool) {
        muted = value
        engine?.setMuted(value)
    }

    /**
     * The answered call, once the microphone is decided: the conversation
     * opens, or the call ends `failed` — after `answered`, as on Android. The
     * answer itself was fulfilled long before; CallKit never waits on this.
     */
    private func answered(_ verdict: CallMicGate.Verdict, call: GraineIncomingCall, uuid: UUID) {
        guard callUUID == uuid, machine.state == .connecting else { return }
        switch verdict {
        case .connect:
            beginConversation(whoCalled: "agent", reason: call.reason, own: GraineCalls.maskedVariables(call.variables))
        case .refused, .unanswered:
            // A refusal is the app's to explain (Settings); a prompt nobody answered may still be answered later.
            if verdict == .refused { graine.notifyListeners { $0.onMicDenied(reason: "NotAllowedError") } }
            provider?.reportCall(with: uuid, endedAt: Date(), reason: .failed)
            transition(.failed(CallMicGate.notGranted))
        }
    }

    // MARK: - The machine

    @discardableResult
    private func transition(_ event: CallMachine.Event) -> CallMachine.Transition {
        let t = machine.handle(event)
        guard t.accepted else { return t }
        if state != t.state { state = t.state }
        graine.nativeCallLive = t.state.isLive
        notifyListeners { $0.onCallState(t.state, callId: t.callId) }
        for outcome in t.outcomes { notifyOutcome(outcome, callId: t.callId ?? "") }
        if case .ended = t.state {
            releaseCall()
            scheduleSettle()
        }
        if t.state == .idle { settled() }
        return t
    }

    /// The call is over: let go of the conversation and the audio. The machine already knows.
    private func releaseCall() {
        ringItem?.cancel()
        ringItem = nil
        answerMic.cancel()
        engine?.hangUp()
        engine = nil
        unwatchContext?()
        unwatchContext = nil
        if agentSpeaking { agentSpeaking = false }
        if !audioActive { restoreAudioSession() }
    }

    private func scheduleSettle() {
        settleItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.settleItem = nil
            self?.transition(.settle)
        }
        settleItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + GraineCalls.settleSeconds, execute: item)
    }

    /// Idle again: nothing of the last call is shown.
    private func settled() {
        callUUID = nil
        incoming = nil
        callId = nil
        direction = nil
        caption = nil
        connectedAt = nil
        muted = false
        speakerOn = false
    }

    private func armRingTimeout(_ uuid: UUID) {
        ringItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, self.callUUID == uuid, self.machine.state == .ringing else { return }
            self.provider?.reportCall(with: uuid, endedAt: Date(), reason: .unanswered)
            self.transition(.ringTimeout)
        }
        ringItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, config.ringTimeout), execute: item)
    }

    // MARK: - Audio session

    /**
     * Play and record, voice chat (the platform's call processing), Bluetooth
     * headsets allowed, the earpiece by default. Never activated here: under
     * CallKit the system activates it and says so in `didActivate`.
     */
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        if savedAudio == nil {
            savedAudio = SavedCallAudio(category: session.category, mode: session.mode, options: session.categoryOptions)
        }
        // The same option (0x4) under two names: Xcode 26 (Swift 6.2) renamed allowBluetooth to allowBluetoothHFP.
        #if compiler(>=6.2)
        let bluetooth: AVAudioSession.CategoryOptions = .allowBluetoothHFP
        #else
        let bluetooth: AVAudioSession.CategoryOptions = .allowBluetooth
        #endif
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [bluetooth])
            try? session.setPreferredIOBufferDuration(0.02)
        } catch {
            GraineLog.warning("Could not configure the audio session: \(GraineInApp.describe(error))")
        }
    }

    /// The app's own category back, once the system has let the session go.
    private func restoreAudioSession() {
        guard let saved = savedAudio, !machine.state.isLive else { return }
        savedAudio = nil
        do {
            try AVAudioSession.sharedInstance().setCategory(saved.category, mode: saved.mode, options: saved.options)
        } catch {
            if graine.config.debug { GraineLog.trace("audio session restore: \(GraineInApp.describe(error))") }
        }
    }

    private func applySpeaker() {
        guard audioActive else { return }
        do {
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(speakerOn ? .speaker : .none)
        } catch {
            GraineLog.warning("Could not switch the speaker: \(GraineInApp.describe(error))")
        }
    }

    /// The route is the truth: the system's call screen can switch the speaker too.
    private func refreshSpeaker() {
        guard audioActive else { return }
        let onSpeaker = AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
        if speakerOn != onSpeaker { speakerOn = onSpeaker }
    }

    // MARK: - Helpers

    private func ensureProvider() -> CXProvider {
        if let provider = provider { return provider }
        let created = CXProvider(configuration: providerConfiguration())
        created.setDelegate(self, queue: nil)
        provider = created
        return created
    }

    private func providerConfiguration() -> CXProviderConfiguration {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        configuration.includesCallsInRecents = config.includesCallsInRecents
        configuration.ringtoneSound = config.ringtoneSound
        configuration.iconTemplateImageData = config.iconTemplateImageData
        return configuration
    }

    private func callUpdate(name: String) -> CXCallUpdate {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: name)
        update.localizedCallerName = name
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        return update
    }

    private var resolvedDisplayName: String {
        let configured = config.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty { return configured }
        let info = Bundle.main.infoDictionary
        return (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String) ?? "Assistant"
    }

    /// The web view engine never holds a call beside a native one.
    private func endWebViewCall() {
        let voice = graine.voice
        if voice.connected || voice.connecting { voice.end() }
    }

    private func notifyListeners(_ call: (GraineCallsListener) -> Void) {
        let current = listenerBoxes.compactMap { $0.value }
        for listener in current { call(listener) }
    }

    private func notifyOutcome(_ outcome: GraineCallOutcome, callId: String) {
        notifyListeners { $0.onCallOutcome(outcome, callId: callId) }
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    /// The app's variables for a call: flattened and masked, as `setVariables` does.
    static func maskedVariables(_ values: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in VariableStore.flatten(values.mapValues { Optional($0) }) {
            out[key] = GraineMasking.mask(value)
        }
        return out
    }

    static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - CallKit

extension GraineCalls: CXProviderDelegate {
    public func providerDidReset(_ provider: CXProvider) {
        engine?.hangUp()
        transition(.reset)
    }

    public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        guard action.callUUID == callUUID, machine.state == .connecting else {
            action.fail()
            return
        }
        configureAudioSession()
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        provider.reportCall(with: action.callUUID, updated: callUpdate(name: callerName))
        beginConversation(whoCalled: "customer", reason: outgoingReason, own: outgoingVariables)
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard action.callUUID == callUUID, machine.state == .ringing, let call = incoming else {
            action.fail()
            return
        }
        ringItem?.cancel()
        ringItem = nil
        endWebViewCall()
        transition(.answer)
        configureAudioSession()
        // Fulfilled at once, whatever the microphone turns out to be: CallKit fails a call whose answer waits.
        action.fulfill()
        let uuid = action.callUUID
        answerMic.afterAnswer { [weak self] verdict in self?.answered(verdict, call: call, uuid: uuid) }
    }

    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard action.callUUID == callUUID, machine.state.isLive else {
            action.fulfill()
            return
        }
        ringItem?.cancel()
        engine?.hangUp()
        transition(.hangUp)
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        guard action.callUUID == callUUID else {
            action.fail()
            return
        }
        applyMuted(action.isMuted)
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        // An agent call is not put on hold; the system offers "End & Accept" instead.
        action.fail()
    }

    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        audioActive = true
        engine?.startAudio()
        // The speaker the customer asked for before the audio was theirs; the route reports back.
        if speakerOn { applySpeaker() } else { refreshSpeaker() }
    }

    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        audioActive = false
        engine?.stopAudio()
        if !machine.state.isLive { restoreAudioSession() }
    }

    public func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        GraineLog.warning("CallKit timed out on \(type(of: action)).")
    }
}

// MARK: - PushKit

extension GraineCalls: PKPushRegistryDelegate {
    public func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        onToken?(GraineCalls.hex(pushCredentials.token))
    }

    public func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        onToken?(nil)
    }

    public func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        guard type == .voIP else {
            completion()
            return
        }
        reportIncomingCall(payload: payload.dictionaryPayload, completion: completion)
    }
}

private struct SavedCallAudio {
    let category: AVAudioSession.Category
    let mode: AVAudioSession.Mode
    let options: AVAudioSession.CategoryOptions
}

/// The system's microphone permission: AVAudioApplication from iOS 17, AVAudioSession before.
final class SystemMicPermission: MicPermissionSource {
    var permission: MicPermission {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return .granted
            case .denied: return .denied
            case .undetermined: return .undetermined
            // Asked, the system answers at once with whatever it holds.
            @unknown default: return .undetermined
            }
        }
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }

    func request(_ done: @escaping (Bool) -> Void) {
        GraineVoice.requestMic(done)
    }
}

private final class WeakCallsListener {
    weak var value: GraineCallsListener?
    init(_ value: GraineCallsListener) { self.value = value }
}
#endif
