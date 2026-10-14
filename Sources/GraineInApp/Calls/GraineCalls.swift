#if os(iOS)
import AVFoundation
import CallKit
import Combine
import Foundation
import PushKit
import SwiftUI
import UIKit

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
    /// What has been said on this call, oldest first, a live line replaced as its words arrive. Cleared when the call is over.
    @Published public private(set) var transcript: [GraineCaption] = []
    /// Graine rang this call — one booked for this customer (the push said `hosted: "1"`). The screen says "Scheduled call".
    @Published public private(set) var hosted = false
    /// The name of the agent the current call is with (`GraineInApp.configure(_:name:)`); nil at idle.
    @Published public private(set) var agent: String?
    /**
     * The ring nobody answered, kept after the call is over so a call screen
     * can say "Missed call" and offer `callBack()` — until the customer calls
     * back, `dismissMissedCall()`, or another call rings or is placed.
     */
    @Published public private(set) var missedCall: GraineMissedCall?

    /// Whether a call screen has something to show: a call, its last second, or a missed ring (of the last ten minutes) to call back.
    public var showsCallScreen: Bool {
        if case .idle = state { return missedCall?.isRecent() ?? false }
        return true
    }

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
    /// The device's VoIP token, hex, once PushKit has given it.
    private var voipToken: String?
    /// Calls Graine rang (`hosted: "1"`), and the agent each belongs to: their outcomes go back to that agent's workspace.
    private var hostedCalls: [String: GraineInApp] = [:]
    /// The agent the current call is with: its key, its variables, its actions, its design.
    private(set) var callAgent: GraineInApp?
    /// The agent each recent call is with, by id — placed with, rung for, or refused for — newest last.
    private var recentCallAgents: [(callId: String, agent: String)] = []
    private static let recentCallsKept = 16
    private var unwatchIdentity: (() -> Void)?
    private var unwatchForeground: (() -> Void)?
    private let outcomeReporter = HostedOutcomeReporter()
    /// The brand's glyph as a CallKit template image, made once per glyph.
    private var brandIcon: (path: String, data: Data?)?
    /// Held strongly here: the instance holds its listeners weakly.
    private lazy var sessionWatcher = CallsSessionWatcher(self)
    /// Closes a missed call's screen when nobody chose.
    private var missedItem: DispatchWorkItem?
    /// The brand's ring as a sound file CallKit can name (`call.ringtone` graine or soft), once written.
    private var brandRingtone: (name: String, file: String?)?
    /// Whether an answered call may have the microphone (Core/CallMachine.swift).
    private lazy var answerMic = CallMicGate(source: micPermission, schedule: { seconds, fire in
        let item = DispatchWorkItem(block: fire)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return { item.cancel() }
    })

    /// How long "ended" shows before the calls are idle again.
    static let settleSeconds = 1.0

    private static var processCalls: GraineCalls?

    /// The app's calls — one CallKit provider, one push registry — made by the first agent that asks. Main thread.
    static func process(home: GraineInApp) -> GraineCalls {
        if let existing = processCalls { return existing }
        let made = GraineCalls(graine: home)
        processCalls = made
        for agent in home.peers where agent !== home { made.watch(agent) }
        return made
    }

    /// An agent configured after the calls were made: they hear its session too. Main thread.
    static func agentConfigured(_ agent: GraineInApp) {
        processCalls?.watch(agent)
    }

    private var watchedAgents: [ObjectIdentifier] = []

    private func watch(_ agent: GraineInApp) {
        let id = ObjectIdentifier(agent)
        guard !watchedAgents.contains(id) else { return }
        watchedAgents.append(id)
        agent.addListener(sessionWatcher)
    }

    init(graine: GraineInApp, micPermission: MicPermissionSource = SystemMicPermission()) {
        self.graine = graine
        self.micPermission = micPermission
        super.init()
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshSpeaker()
        }
        watch(graine)
        graine.onMain { [weak self] in
            guard let self = self else { return }
            // A new customer on this phone is linked to it (or unlinked) at once, not tomorrow.
            self.unwatchIdentity = graine.onIdentity { [weak self] in self?.registerDevice() }
            self.unwatchForeground = graine.onForegroundChange { [weak self] foreground in
                if foreground { self?.registerDevice() }
            }
        }
    }

    deinit {
        if let token = routeObserver { NotificationCenter.default.removeObserver(token) }
        unwatchIdentity?()
        unwatchForeground?()
    }

    // MARK: - Setting up

    /// How calls ring and what they show. Call once, at launch, before `enableVoIPPushes`.
    public func configure(_ config: GraineCallsConfig) {
        onMain {
            self.config = config
            self.provider?.configuration = self.providerConfiguration(for: self.callAgent ?? self.graine)
        }
    }

    /**
     * Receive your agent's calls as VoIP pushes. Call at launch, every launch
     * (iOS wakes a terminated app for a push and delivers it once this has
     * run). Every push is reported to CallKit before its completion runs, as
     * iOS requires.
     *
     * When Graine rings this app (the workspace uploaded its push credentials
     * — In-app calling, in the dashboard), the SDK registers the token with
     * Graine itself, on every new token and at most daily otherwise, and
     * reports what became of every ring: nothing else to do. Otherwise
     * `onToken` gets the device's VoIP token as hex — send it to your server —
     * and nil when it is invalidated.
     *
     * An app with its own PKPushRegistry passes the payload to
     * `reportIncomingCall(payload:completion:)` instead, and the token to
     * `voipTokenUpdated(_:)`.
     */
    public func enableVoIPPushes(onToken: ((String?) -> Void)? = nil) {
        onMain {
            self.onToken = onToken
            _ = self.ensureProvider()
            let registry = self.registry ?? PKPushRegistry(queue: .main)
            registry.delegate = self
            registry.desiredPushTypes = [.voIP]
            self.registry = registry
            if let token = registry.pushToken(for: .voIP) { self.tokenArrived(GraineCalls.hex(token)) }
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
     * and `call_reason`, with `variables` over the SDK's own. `agent` names
     * which configured agent to call (`GraineInApp.configure(_:name:)`); nil
     * is the default. Returns the call's id, or nil when a call is already
     * live (one at a time) or no agent has that name. Asks for the microphone
     * first if the app does not hold it.
     */
    @discardableResult
    public func startCall(reason: String? = nil, variables: [String: Any] = [:], agent: String? = nil) -> String? {
        guard Thread.isMainThread else {
            var id: String?
            DispatchQueue.main.sync { id = self.startCall(reason: reason, variables: variables, agent: agent) }
            return id
        }
        guard !machine.state.isLive else {
            GraineLog.warning("A call is already live; startCall was refused.")
            return nil
        }
        guard let target = resolveAgent(named: agent) else {
            GraineLog.warning("No agent is configured under the name \"\(agent ?? "")\"; startCall was refused.")
            return nil
        }
        // The same shape on every platform ("call_" and a lowercase UUID), so a server sees one kind of id.
        let id = "call_" + UUID().uuidString.lowercased()
        let uuid = UUID()
        endWebViewCall()
        settleItem?.cancel()
        settleItem = nil
        callUUID = uuid
        incoming = nil
        missedCall = nil
        hosted = false
        callAgent = target
        self.agent = target.name
        rememberAgent(target.name, forCall: id)
        outgoingReason = reason
        outgoingVariables = GraineCalls.maskedVariables(variables)
        callerName = resolvedDisplayName(for: target)
        direction = .outgoing
        callId = id
        transition(.outgoing(id: id))

        let proceed: (Bool) -> Void = { [weak self] granted in
            guard let self = self, self.callUUID == uuid, self.machine.state == .connecting else { return }
            if granted {
                self.requestStart(uuid)
            } else {
                target.notifyListeners { $0.onMicDenied(reason: "NotAllowedError") }
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

    /// The agent under `name` (any configured one), the default for nil; nil for a name nobody configured.
    private func resolveAgent(named name: String?) -> GraineInApp? {
        guard let name = name else { return graine }
        let key = GraineAgentRegistry.normalise(name)
        if key == graine.name { return graine }
        return graine.peers.first { $0.name == key }
    }

    /**
     * The agent a ring belongs to: the push's `agent_id` matched against each
     * configured agent's session (agent id or web-call twin); the default when
     * the push names none, or one no agent has (said in the log).
     */
    private func agentForPush(_ payload: [AnyHashable: Any]) -> GraineInApp {
        guard let wanted = CallPush.agentId(payload) else { return graine }
        if let found = graine.registry?.agent(forAgentId: wanted) { return found }
        if let session = graine.sessionOrCached, session.agentId == wanted || session.webcallAgentId == wanted { return graine }
        GraineLog.warning("A ring named an agent no configured agent has; it rings with the default agent.")
        return graine
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
        let ringer = agentForPush(payload)
        let display = resolvedDisplayName(for: ringer)
        let steps = PushIntake.plan(payload, displayName: display, liveCallId: liveId)
        let pushHosted = CallPush.hosted(payload)
        let uuid = UUID()
        var name = display
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
        // Whatever becomes of this push, it is the routed agent's: a ring, or a refusal while another call is live.
        if let call = ringing { rememberAgent(ringer.name, forCall: call.callId) }
        for (id, _) in outcomes where id != liveId { rememberAgent(ringer.name, forCall: id) }
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
            missedCall = nil
            self.hosted = call.hosted
            callAgent = ringer
            agent = ringer.name
            if call.hosted { hostedCalls[call.callId] = ringer }
            // The ring wears its agent's brand on CallKit's screen: its icon, its ring.
            provider.configuration = providerConfiguration(for: ringer)
            transition(.incoming(id: call.callId))
            armRingTimeout(uuid, seconds: ringTimeout(hosted: call.hosted, agent: ringer))
        }
        provider.reportNewIncomingCall(with: uuid, update: callUpdate(name: name)) { [weak self] error in
            DispatchQueue.main.async {
                defer { completion?() }
                guard let self = self else { return }
                if let ending = ending {
                    provider.reportCall(with: uuid, endedAt: Date(), reason: ending == .failed ? .failed : .unanswered)
                    for (id, outcome) in outcomes {
                        self.notifyOutcome(outcome, callId: id)
                        // Graine rang it, so Graine hears it: busy, or a push this SDK could not ring.
                        if pushHosted {
                            let report = outcome == .missed ? HostedOutcome.busy(callId: id) : HostedOutcome.report(outcome, callId: id, connectedAt: nil)
                            self.outcomeReporter.send(report, via: ringer)
                        }
                    }
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
                if call.hosted { self.outcomeReporter.send(HostedOutcome.ringing(callId: call.callId), via: ringer) }
                self.notifyListeners { $0.onIncomingCall(call) }
            }
        }
    }

    /**
     * The VoIP token from an app's own PKPushRegistry (hex, or nil once
     * invalidated) — the token `enableVoIPPushes` would have registered with
     * Graine. Only for an app that runs its own registry.
     */
    public func voipTokenUpdated(_ token: String?) {
        onMain { self.tokenArrived(token) }
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

    /**
     * Return the missed call: the customer calls the agent, with the missed
     * call's reason (or that they are returning it) as `call_reason`. The id of
     * the new call, or nil when there is nothing to return or a call is live.
     */
    @discardableResult
    public func callBack() -> String? {
        guard Thread.isMainThread else {
            var id: String?
            DispatchQueue.main.sync { id = self.callBack() }
            return id
        }
        guard let missed = missedCall else { return nil }
        missedItem?.cancel()
        // The agent that rang is the one called back.
        return startCall(reason: missed.callBackReason, agent: missed.agent)
    }

    /// The customer has seen the missed call: the screen can go.
    public func dismissMissedCall() {
        onMain {
            if self.missedCall != nil { self.missedCall = nil }
        }
    }

    // MARK: - The conversation

    private func requestStart(_ uuid: UUID) {
        let provider = ensureProvider()
        provider.configuration = providerConfiguration(for: callAgent ?? graine)
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
        // The call's own agent: its key, its variables, its screen and actions, its session.
        let graine = callAgent ?? self.graine
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
                // A push can wake the app before the network is up: the last session still finds the agent.
                graine.loadSessionOrCached(done)
            },
            runAction: CallEngine.actionRunner(graine),
            callVariables: CallEngine.variables(sdk: [:], whoCalled: whoCalled, reason: reason, own: own),
            // Who the customer is, the install, the memory choice, the time zone — and this call's id, so Graine
            // joins the conversation to the call it rang (or the app placed).
            identity: graine.identityFields(callId: callId)
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
            transcript = CaptionLog.fold(transcript, line)
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
            beginConversation(whoCalled: CallEngine.whoCalled(hosted: call.hosted), reason: call.reason, own: GraineCalls.maskedVariables(call.variables))
        case .refused, .unanswered:
            // A refusal is the app's to explain (Settings); a prompt nobody answered may still be answered later.
            if verdict == .refused { (callAgent ?? graine).notifyListeners { $0.onMicDenied(reason: "NotAllowedError") } }
            provider?.reportCall(with: uuid, endedAt: Date(), reason: .failed)
            transition(.failed(CallMicGate.notGranted))
        }
    }

    // MARK: - The machine

    @discardableResult
    private func transition(_ event: CallMachine.Event) -> CallMachine.Transition {
        let t = machine.handle(event)
        guard t.accepted else { return t }
        if case .ended(.missed) = t.state, let id = t.callId {
            // The ring on this device ran out (or the system dropped it): kept, to be called back — for 30 seconds.
            missedCall = GraineMissedCall(callId: id, callerName: callerName, reason: incoming?.reason, hosted: incoming?.hosted ?? false,
                                          agent: callAgent?.name)
            missedItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self = self, self.missedCall?.callId == id else { return }
                self.missedCall = nil
            }
            missedItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + CallScreen.missedHoldSeconds, execute: item)
        }
        if state != t.state { state = t.state }
        // Every agent's assistant steps aside while a native call is live.
        for agent in graine.peers { agent.nativeCallLive = t.state.isLive }
        notifyListeners { $0.onCallState(t.state, callId: t.callId) }
        for outcome in t.outcomes {
            let id = t.callId ?? ""
            notifyOutcome(outcome, callId: id)
            if let ringer = hostedCalls[id] {
                outcomeReporter.send(HostedOutcome.report(outcome, callId: id, connectedAt: connectedAt), via: ringer)
                // `answered` comes first; the call's end is its last word.
                if outcome != .answered { hostedCalls.removeValue(forKey: id) }
            }
        }
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
        if !transcript.isEmpty { transcript = [] }
        if hosted { hosted = false }
        if agent != nil { agent = nil }
        callAgent = nil
        connectedAt = nil
        muted = false
        speakerOn = false
    }

    /// How long a ring lasts: Graine's ring timeout for a call it rang (the server closes it as missed then), else the app's.
    private func ringTimeout(hosted: Bool, agent: GraineInApp) -> TimeInterval {
        hosted ? TimeInterval(agent.schedulingRules.ringTimeoutSeconds) : config.ringTimeout
    }

    private func armRingTimeout(_ uuid: UUID, seconds: TimeInterval) {
        ringItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, self.callUUID == uuid, self.machine.state == .ringing else { return }
            self.provider?.reportCall(with: uuid, endedAt: Date(), reason: .unanswered)
            self.transition(.ringTimeout)
        }
        ringItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, seconds), execute: item)
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
        let created = CXProvider(configuration: providerConfiguration(for: callAgent ?? graine))
        created.setDelegate(self, queue: nil)
        provider = created
        return created
    }

    private func providerConfiguration(for agent: GraineInApp) -> CXProviderConfiguration {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        configuration.includesCallsInRecents = config.includesCallsInRecents
        // The app's own sound wins; else the brand's ring, when it is not the phone's own.
        configuration.ringtoneSound = config.ringtoneSound ?? brandRingtoneFile(for: agent)
        // The app's own icon wins; else the brand's launcher glyph, from the design (the last session's on a cold start).
        configuration.iconTemplateImageData = config.iconTemplateImageData ?? brandIconData(for: agent)
        return configuration
    }

    /**
     * The design's ring (`call.ringtone`): nil for `system`. CallKit plays a
     * sound by file name and an SDK cannot add one to the app's bundle, so the
     * pattern is written to Library/Sounds (Ringtones) — once, on first need.
     */
    private func brandRingtoneFile(for agent: GraineInApp) -> String? {
        let design = agent.sessionOrCached?.design
        let name = (design?.light.call ?? design?.dark.call)?.ringtone ?? "system"
        if let made = brandRingtone, made.name == name { return made.file }
        let file = name == "system" ? nil : Ringtones.soundFile(name)
        brandRingtone = (name, file)
        return file
    }

    private func brandIconData(for agent: GraineInApp) -> Data? {
        let design = agent.sessionOrCached?.design
        guard let glyph = design?.light.icons.launcher ?? design?.dark.icons.launcher else { return nil }
        if let made = brandIcon, made.path == glyph.path { return made.data }
        let data = GraineCallIcon.templatePNG(glyph: glyph, stroke: design?.light.icons.stroke ?? 2)
        brandIcon = (glyph.path, data)
        return data
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

    private func resolvedDisplayName(for agent: GraineInApp) -> String {
        let configured = config.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        // One agent: the app's name for its calls wins. Several: each agent's own call name first, so a ring says who.
        let several = graine.peers.count > 1
        if !configured.isEmpty && !several { return configured }
        // The agent's call name from the dashboard (Calls & scheduling), when it set one.
        if let named = agent.sessionOrCached?.calls?.callName { return named }
        if !configured.isEmpty { return configured }
        let info = Bundle.main.infoDictionary
        return (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String) ?? "Assistant"
    }

    /// The web view engine never holds a call beside a native one.
    private func endWebViewCall() {
        for agent in graine.peers {
            let voice = agent.voice
            if voice.connected || voice.connecting { voice.end() }
        }
    }

    private func notifyListeners(_ call: (GraineCallsListener) -> Void) {
        let current = listenerBoxes.compactMap { $0.value }
        for listener in current { call(listener) }
    }

    private func notifyOutcome(_ outcome: GraineCallOutcome, callId: String) {
        notifyListeners { $0.onCallOutcome(outcome, callId: callId) }
    }

    /**
     * The name of the agent a call is with — the one it was placed with, or
     * the one its ring was routed to by the push's `agent_id` — for the calls
     * host to put on the call's events. Nil for a call this engine never saw.
     */
    func agentName(forCall id: String) -> String? {
        if let known = recentCallAgents.last(where: { $0.callId == id }) { return known.agent }
        return id == callId ? agent : nil
    }

    private func rememberAgent(_ name: String, forCall id: String) {
        guard !id.isEmpty else { return }
        recentCallAgents.removeAll { $0.callId == id }
        recentCallAgents.append((id, name))
        if recentCallAgents.count > GraineCalls.recentCallsKept {
            recentCallAgents.removeFirst(recentCallAgents.count - GraineCalls.recentCallsKept)
        }
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

// MARK: - Hosted ringing: the token, with Graine

/// Hears the session for the calls, without making GraineCalls itself a listener in the public API.
private final class CallsSessionWatcher: GraineListener {
    weak var calls: GraineCalls?

    init(_ calls: GraineCalls) {
        self.calls = calls
    }

    func onSessionReady(_ session: GraineSessionConfig) {
        calls?.sessionArrived()
    }
}

extension GraineCalls {
    /// An agent's session arrived: the brand's icon and call name are known; and the token goes to it, if it rings this app.
    fileprivate func sessionArrived() {
        provider?.configuration = providerConfiguration(for: callAgent ?? graine)
        registerDevice()
    }

    /// A token from PushKit (or the app's own registry): to the app, and to every agent whose workspace rings it.
    fileprivate func tokenArrived(_ token: String?) {
        voipToken = token
        onToken?(token)
        registerDevice()
    }

    /// The device's token to Graine, from each configured agent whose session says Graine rings this app, when due.
    fileprivate func registerDevice() {
        guard let token = voipToken else { return }
        graine.registerDeviceEverywhere(token: token, appId: Bundle.main.bundleIdentifier ?? "", apnsEnvironment: ApnsEnvironment.current)
    }
}

/**
 * WHAT BECAME OF A RING GRAINE SENT, back to the workspace of the agent that
 * rang (`/api/embed/calls/outcome`, with that agent's key). Usually sent from
 * the background — a ring declined on the lock screen — so each report holds
 * a short background task until it has left, and is tried again twice on a
 * network failure or a server error. The server ignores a report it already has.
 */
final class HostedOutcomeReporter {
    static let retryDelays: [Double] = [2, 6]

    func send(_ report: HostedOutcome.Report, via agent: GraineInApp, attempt: Int = 0) {
        var task: UIBackgroundTaskIdentifier = .invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "graine-call-outcome") {
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
            task = .invalid
        }
        let fields = HostedOutcome.fields(report, installId: agent.installId)
        agent.requests.post("/api/embed/calls/outcome", fields) { [weak self, weak agent] result in
            DispatchQueue.main.async {
                defer {
                    if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
                    task = .invalid
                }
                guard case .failure(let error) = result else { return }
                let retryable = error.status == 0 || error.status >= 500
                guard retryable, attempt < HostedOutcomeReporter.retryDelays.count, let agent = agent else {
                    GraineLog.warning("The call's outcome (\(report.outcome)) was not recorded: \(error.message)")
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + HostedOutcomeReporter.retryDelays[attempt]) {
                    self?.send(report, via: agent, attempt: attempt + 1)
                }
            }
        }
    }
}

/// The brand's launcher glyph as CallKit's template image: white on clear, 40 points at 3×.
enum GraineCallIcon {
    static func templatePNG(glyph: GraineThemeTokens.Glyph, stroke: Double) -> Data? {
        guard let segments = GlyphPath.cached(glyph.path) else { return nil }
        let side: CGFloat = 120
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let image = renderer.image { context in
            let inset = side * 0.1
            let path = GraineGlyphShape(segments: segments).path(in: CGRect(x: inset, y: inset, width: side - 2 * inset, height: side - 2 * inset)).cgPath
            let cg = context.cgContext
            cg.addPath(path)
            if glyph.stroke {
                cg.setStrokeColor(UIColor.white.cgColor)
                cg.setLineWidth(CGFloat(stroke) * (side - 2 * inset) / 24)
                cg.setLineCap(.round)
                cg.setLineJoin(.round)
                cg.strokePath()
            } else {
                cg.setFillColor(UIColor.white.cgColor)
                cg.fillPath()
            }
        }
        return image.pngData()
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
        tokenArrived(GraineCalls.hex(pushCredentials.token))
    }

    public func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        tokenArrived(nil)
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
