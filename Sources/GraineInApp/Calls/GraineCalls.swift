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
    /// The road the calls' audio takes: `auto` (WebRTC when the app includes GraineInAppRTC), `websocket` or `webrtc`.
    public var callTransport: GraineCallTransport

    public init(
        displayName: String = "",
        ringtoneSound: String? = nil,
        iconTemplateImageData: Data? = nil,
        includesCallsInRecents: Bool = false,
        ringTimeout: TimeInterval = 30,
        callTransport: GraineCallTransport = .auto
    ) {
        self.displayName = displayName
        self.ringtoneSound = ringtoneSound
        self.iconTemplateImageData = iconTemplateImageData
        self.includesCallsInRecents = includesCallsInRecents
        self.ringTimeout = ringTimeout
        self.callTransport = callTransport
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
    /**
     * The connected call lost its connection and is bringing it back (true),
     * or has it back (false) — `isReconnecting`. Only after the call
     * connected, and false again before it ends. A call on WebRTC can
     * reconnect; one on the WebSocket never does.
     */
    func onCallReconnecting(_ reconnecting: Bool)
    /**
     * The same outcome as `onCallOutcome(_:callId:)`, heard right after it,
     * with how the call's connection went: `connection` is its report as it
     * stood then — final for a call's end — and nil when nothing about it was
     * known (a ring, a call that never reached its conversation, a ring
     * refused while another call was live). Implement either.
     */
    func onCallOutcome(_ outcome: GraineCallOutcome, callId: String, connection: GraineCallConnection?)
}

public extension GraineCallsListener {
    func onIncomingCall(_ call: GraineIncomingCall) {}
    func onCallState(_ state: GraineCallState, callId: String?) {}
    func onCallOutcome(_ outcome: GraineCallOutcome, callId: String) {}
    func onCallReconnecting(_ reconnecting: Bool) {}
    func onCallOutcome(_ outcome: GraineCallOutcome, callId: String, connection: GraineCallConnection?) {}
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
 * call that does not get it ends `failed`. `requestCallPermissions()` asks
 * earlier, when the app chooses (onboarding); `callPermissions` reads them;
 * `openCallSettings(_:)` opens Settings. `callSetupProblems` says what the
 * app's setup still lacks — an Info.plist entry, a background mode, the push
 * registration — and each one is logged once, with its fix.
 * `ObservableObject`: draw your own screen from `state`, `muted`, `speakerOn`,
 * `agentSpeaking`, `agentLevel`, `isReconnecting`, `caption` and `transcript`
 * — and `connection`, how the call connected — or present `GraineCallView`.
 * Main thread.
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
    /**
     * How loud the agent's voice is as it is heard, 0–1: measured from the
     * call's audio on either transport, eased (up over 60 ms, down over 240)
     * and updated about ten times a second while it moves. 0 at idle. For a
     * visualiser: `GraineCallView` draws it.
     */
    @Published public private(set) var agentLevel: Double = 0
    /**
     * The connected call lost its connection and is bringing it back: its
     * audio is not flowing. Only after the call connected; false again before
     * it ends (`onCallReconnecting`). A call on WebRTC can reconnect; one on
     * the WebSocket never does — losing its socket ends the call.
     */
    @Published public private(set) var isReconnecting = false
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
    /// The road the current call's audio runs on (`.webrtc` or `.websocket`), once decided; nil before.
    @Published public internal(set) var transport: GraineCallTransport?
    /// Why a call that tried WebRTC runs on the WebSocket (`mint_failed`, `register_failed`, `no_response`, `no_answer`, `ice_timeout`, `error`); nil otherwise.
    @Published public internal(set) var transportFallbackReason: String?
    /**
     * Why the current call was made: the reason a ring's push carried, or the
     * one `startCall(reason:)` (or `callBack()`) was given; nil without one,
     * and at idle.
     */
    @Published public private(set) var reason: String?
    /**
     * HOW THE CURRENT CALL CONNECTED, AND HOW ITS AUDIO HOLDS UP — the same
     * facts as Execution Logs' Connection card, live: nil until the call
     * reaches its conversation, then filled in as it goes (the road and where
     * the tap's wait went at once, the agent's first words when they are
     * heard, the audio as it is measured on WebRTC, each time the connection
     * heals), final when it ends — and handed to
     * `onCallOutcome(_:callId:connection:)` then. Nil again at idle.
     * Timings and network figures only.
     */
    @Published public private(set) var connection: GraineCallConnection?
    /**
     * Who or what ended the call that just ended — the customer, the agent, a
     * lost line, audio that never started, the system — set as it ends (before
     * `onCallOutcome`) and kept while the state is `ended`; nil while a call
     * is on, at idle, and for a ring declined or missed (the state's reason says so).
     */
    @Published public private(set) var endCause: GraineCallEndCause?
    /**
     * Calls start on the loudspeaker: `true` (the default) — unless a headset,
     * a car or AirPlay is the route. `speakerOn` then follows the real route;
     * `setSpeaker(false)` moves a call to the earpiece. Set it before a call
     * starts; `false` starts calls on the earpiece, as a phone call does.
     */
    public var speakerByDefault = true

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
    private var engine: CallConversation?
    private var ringItem: DispatchWorkItem?
    private var settleItem: DispatchWorkItem?
    /// The current call's analytics rows, folded into `connection`.
    private var connectionFold = CallConnectionFold()
    /// `agentLevel`, eased toward each level the call reports (Core/AgentLevel.swift), and its next step.
    private var levelEasing = AgentLevelEasing()
    private var levelItem: DispatchWorkItem?
    private var levelSteppedAt: TimeInterval?
    private var unwatchContext: (() -> Void)?
    private var routeObserver: NSObjectProtocol?
    /// CallKit activated this call's audio session (`didActivate`), and has not taken it back.
    private var audioActive = false
    /// This call's audio runs: CallKit activated it, the SDK started it itself when CallKit never did, or WebRTC carries it.
    private var audioRunning = false
    /// The SDK activated the audio session itself (CallKit never did): it lets it go once the call is over.
    private var activatedDirectly = false
    /// The customer (or the app) chose the speaker or the earpiece with `setSpeaker` on this call; otherwise it is the default.
    private var speakerChosen = false
    /// Until then, a route change is the call's own audio settling (WebRTC configuring the session): the wanted route is put back.
    private var routeSettlesAt: Date?
    private var savedAudio: SavedCallAudio?
    private let micPermission: MicPermissionSource
    /// The device's VoIP token, hex, once PushKit has given it.
    private var voipToken: String?
    /// The setup self-check's clock: when `configure` first ran, and when VoIP pushes were enabled.
    private var configuredAt: Date?
    private var voipEnabledAt: Date?
    /// The app runs a PKPushRegistry of its own and hands its token over (`voipTokenUpdated`).
    private var ownPushRegistry = false
    /// Each setup problem is logged once a launch.
    private var setupLog = CallSetup.LogOnce()
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
    /// Whether the open conversation got its audio from CallKit (Calls/CallAudioWatch.swift).
    private lazy var audioWatch = CallAudioWatch(schedule: { seconds, fire in
        let item = DispatchWorkItem(block: fire)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return { item.cancel() }
    }, act: { [weak self] step in
        self?.audioStep(step)
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

    /// The app's calls, if anything has made them yet — without making them. Main thread.
    static var existing: GraineCalls? { processCalls }

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
            self.startSetupCheck()
            // Calls off WebRTC: a call prepared for the tap on it is let go.
            if config.callTransport == .websocket { for agent in self.graine.peers { agent.releasePreparedCall() } }
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
            self.voipPushesEnabled()
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
        let own = GraineCalls.maskedVariables(variables)
        // The same shape on every platform ("call_" and a lowercase UUID), so a server sees one kind of id: the prepared
        // call's, when this is the call prepareCall got ready (it dials at once); else the one the agent's warm grant was
        // asked for (the call then mints at the telephony gateway); else a new one.
        let id = target.preparedCallId(reason: reason, own: own) ?? target.nextCallId() ?? GraineInApp.newCallId()
        let uuid = UUID()
        endWebViewCall()
        // CallKit activates the call's audio only when the app is not holding the session itself.
        releaseAudioSessionForCallKit()
        settleItem?.cancel()
        settleItem = nil
        freshCallAudio()
        callUUID = uuid
        incoming = nil
        missedCall = nil
        hosted = false
        callAgent = target
        self.agent = target.name
        rememberAgent(target.name, forCall: id)
        outgoingReason = reason
        outgoingVariables = own
        callerName = resolvedDisplayName(for: target)
        direction = .outgoing
        callId = id
        self.reason = reason
        resetConnection()
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

    /**
     * Get the agent's next call ready before the customer taps — call it when a
     * screen that offers a call appears — so that `startCall` with the same
     * reason and variables connects in about a second instead of two to four.
     *
     * Cheap to call every time the screen appears: while a call prepared for
     * the same agent, the same customer, reason and variables is less than
     * four minutes old, nothing is sent. Nothing is dialled and nothing is
     * billed until `startCall`. It does nothing without the GraineInAppRTC
     * module, when calls use the WebSocket, before the agent's configuration
     * has loaded, or while a call is ringing or live.
     *
     * The prepared call is let go, quietly, when the app goes to the
     * background, the customer changes (identify, sign-out, their memory
     * choice, the time zone), four minutes pass, calls stop using WebRTC, or a
     * call rings. `startCall` then simply prepares the call at the tap.
     * `agent` names a configured agent (`GraineInApp.configure(_:name:)`); nil
     * is the default.
     */
    public func prepareCall(reason: String? = nil, variables: [String: Any] = [:], agent: String? = nil) {
        onMain {
            guard !self.machine.state.isLive, let target = self.resolveAgent(named: agent) else { return }
            target.prepareNextCall(reason: reason, own: GraineCalls.maskedVariables(variables))
        }
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
            // The ring wins: a call prepared for the customer's tap is let go, on every agent.
            for agent in graine.peers { agent.releasePreparedCall() }
            // The machine first: a second push a moment from now must find this call live.
            endWebViewCall()
            settleItem?.cancel()
            settleItem = nil
            freshCallAudio()
            callUUID = uuid
            incoming = call
            callerName = name
            direction = .incoming
            callId = call.callId
            reason = call.reason
            resetConnection()
            missedCall = nil
            self.hosted = call.hosted
            callAgent = ringer
            agent = ringer.name
            if call.hosted { hostedCalls[call.callId] = ringer }
            // The ring wears its agent's brand on CallKit's screen: its icon, its ring.
            provider.configuration = providerConfiguration(for: ringer)
            transition(.incoming(id: call.callId))
            armRingTimeout(uuid, seconds: ringTimeout(hosted: call.hosted, agent: ringer))
            prepareRing(call, agent: ringer)
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
        onMain {
            self.ownPushRegistry = true
            self.voipPushesEnabled()
            self.tokenArrived(token)
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

    /// Decline the ringing call from your own screen, as the system's call screen declines it. Nothing when no call rings.
    public func decline() {
        onMain {
            guard self.machine.state == .ringing else { return }
            self.end()
        }
    }

    /// Hang up — or decline, while it rings.
    public func end() {
        onMain {
            guard let uuid = self.callUUID, self.machine.state.isLive else { return }
            self.controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { error in
                guard error != nil else { return }
                // CallKit does not know the call (it never reached it): end it here — its cause first, then the hang-up.
                DispatchQueue.main.async {
                    guard self.callUUID == uuid, self.machine.state.isLive else { return }
                    self.ringItem?.cancel()
                    self.transition(.hangUp)
                    self.engine?.hangUp()
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

    /// The loudspeaker (true) or the earpiece / headset (false). Calls start on the speaker unless `speakerByDefault` is false.
    public func setSpeaker(_ on: Bool) {
        onMain {
            self.speakerOn = on
            self.speakerChosen = true
            self.routeSettlesAt = nil
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

    // MARK: - Permissions and setup

    /**
     * The call permissions as the phone holds them now: the microphone
     * (`granted`, `denied` — not asked yet — or `blocked`, which only Settings
     * can change); notifications and the full-screen ring are `notNeeded` on
     * iOS, where CallKit rings. Read it again when the app returns to the
     * foreground: the customer may have changed Settings.
     */
    public var callPermissions: GraineCallPermissions {
        CallSetup.permissions(microphone: micPermission.permission)
    }

    /**
     * Ask for the call permissions the system can still ask for — on iOS the
     * microphone, once — at a moment the app chooses (onboarding, a "Call me"
     * screen). The SDK never asks on its own at launch; a call that starts
     * without the microphone still asks then. `completion` gets the
     * permissions as they stand after, on the main thread.
     */
    public func requestCallPermissions(completion: @escaping (GraineCallPermissions) -> Void) {
        onMain {
            guard self.micPermission.permission == .undetermined else {
                completion(self.callPermissions)
                return
            }
            self.micPermission.request { _ in completion(self.callPermissions) }
        }
    }

    /// `requestCallPermissions(completion:)`, awaited.
    public func requestCallPermissions() async -> GraineCallPermissions {
        await withCheckedContinuation { done in
            requestCallPermissions { done.resume(returning: $0) }
        }
    }

    /**
     * Open the Settings page that changes `item` — the app's own page, where
     * the microphone is switched on. True when Settings was asked to open.
     */
    @discardableResult
    public func openCallSettings(_ item: GraineCallPermission) -> Bool {
        guard Thread.isMainThread else {
            var opened = false
            DispatchQueue.main.sync { opened = self.openCallSettings(item) }
            return opened
        }
        return GraineCalls.openSettings(item)
    }

    /**
     * What the app's setup still lacks for calls, read now: each a stable
     * `code` and a sentence with the exact fix — `NSMicrophoneUsageDescription`
     * or a background mode missing from Info.plist, no push entitlement (where
     * the build shows it), `enableVoIPPushes()` never called or no VoIP token
     * 15 seconds on, the microphone blocked, or Graine not ringing this phone.
     * Empty when nothing is missing. Calls still work where they can.
     */
    public var callSetupProblems: [GraineCallSetupProblem] {
        guard Thread.isMainThread else {
            var problems: [GraineCallSetupProblem] = []
            DispatchQueue.main.sync { problems = self.callSetupProblems }
            return problems
        }
        return CallSetup.problems(setupFacts())
    }

    /// The first `configure` starts the self-check: what is missing now is logged now, and what is still missing once the push registration has had its time.
    private func startSetupCheck() {
        guard configuredAt == nil else { return }
        configuredAt = Date()
        logSetupProblems()
        logSetupProblems(after: CallSetup.settleSeconds)
    }

    private func voipPushesEnabled() {
        guard voipEnabledAt == nil else { return }
        voipEnabledAt = Date()
        logSetupProblems(after: CallSetup.settleSeconds)
    }

    /// Each problem not yet said this launch, as a warning with its fix. Nothing before `configure`.
    private func logSetupProblems(after seconds: TimeInterval? = nil) {
        if let seconds = seconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.5) { [weak self] in self?.logSetupProblems() }
            return
        }
        guard configuredAt != nil else { return }
        for problem in setupLog.fresh(callSetupProblems) {
            GraineLog.warning("Calls setup (\(problem.code)): \(problem.message)")
        }
    }

    private func setupFacts() -> CallSetupFacts {
        let now = Date()
        var facts = CallSetupFacts()
        facts.info = Bundle.main.infoDictionary ?? [:]
        facts.pushEntitlement = GraineCalls.pushEntitlement
        facts.voipPushesEnabled = registry != nil || ownPushRegistry
        facts.hasVoipToken = voipToken != nil
        facts.secondsSinceConfigure = configuredAt.map { now.timeIntervalSince($0) }
        facts.secondsSinceVoipEnabled = voipEnabledAt.map { now.timeIntervalSince($0) }
        #if targetEnvironment(simulator)
        facts.simulator = true
        #endif
        facts.microphone = CallSetup.microphone(micPermission.permission)
        facts.hostedRinging = CallSetup.hostedRinging(graine.peers.compactMap { $0.sessionOrCached }.map { $0.calls })
        return facts
    }

    /// The push entitlement as the build's embedded profile shows it, read once.
    static let pushEntitlement: CallSetup.PushEntitlement = {
        let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
        return CallSetup.pushEntitlement(provisioningProfile: url.flatMap { try? Data(contentsOf: $0) })
    }()

    /// The call permissions with no instance yet: the system's microphone.
    static func systemCallPermissions() -> GraineCallPermissions {
        CallSetup.permissions(microphone: SystemMicPermission().permission)
    }

    /// The app's page in Settings: the microphone's switch is there (and its notifications', for an app that posts any). Main thread.
    static func openSettings(_ item: GraineCallPermission) -> Bool {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return false }
        UIApplication.shared.open(url)
        return true
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
        // This conversation's rows are its report's, from the first.
        resetConnection()
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
            // The session in memory or kept on the device starts the call at once; the network refreshes it behind.
            session: CallEngine.sessionLoader(graine),
            runAction: CallEngine.actionRunner(graine),
            callVariables: CallEngine.variables(sdk: [:], whoCalled: whoCalled, reason: reason, own: own),
            // Who the customer is, the install, the memory choice, the time zone — and this call's id, so Graine
            // joins the conversation to the call it rang (or the app placed).
            identity: graine.identityFields(callId: callId)
        )
        let engine = CallConversation(
            setup: setup,
            audio: audio,
            network: URLSessionCallNetwork(),
            scheduler: DispatchCallScheduler(),
            transport: config.callTransport,
            debug: graine.config.debug,
            // The call prepareCall got ready for this agent, when this is it; else one prepared while it rang.
            takePrepared: { [weak graine] id, mint in
                graine?.takePreparedCall(id: id, mint: mint) ?? RingPreparation.shared.take(id, mint: mint)
            },
            onTransport: { [weak self, callId] report in
                DispatchQueue.main.async { self?.transportDecided(report, callId: callId) }
            },
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
            // Connected once its audio runs too: at once when CallKit has activated it, else the watch waits. On WebRTC the
            // media path comes up only once the call's audio runs (CallKit's, or the leg's own direct start): it runs now.
            let running = CallAudioWatch.runningAtOpen(callKitActivated: audioActive, transport: transport)
            if running && !audioRunning { routeAudio() }
            audioWatch.opened(audioRunning: running)
        case .speaking(let value):
            if agentSpeaking != value { agentSpeaking = value }
        case .reconnecting(let value):
            // Only for a call still under way; its end clears it (`transition`).
            guard machine.state.isLive || !value else { return }
            setReconnecting(value)
        case .level(let value):
            guard machine.state.isLive else { return }
            heardLevel(value)
        case .caption(let line):
            caption = line
            transcript = CaptionLog.fold(transcript, line)
        case .format(let format):
            if graine.config.debug { GraineLog.trace("agent audio: \(format.kind.rawValue) at \(format.sampleRate) Hz") }
        case .row(let frame):
            if connectionFold.read(frame) { connection = connectionFold.report }
        case let .audio(loss, jitterAvg, jitterMax, rtt):
            guard machine.state.isLive else { return }
            if connectionFold.audio(lossPct: loss, jitterAvgMs: jitterAvg, jitterMaxMs: jitterMax, rttAvgMs: rtt) { connection = connectionFold.report }
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
                // Open but still waiting for its audio, the call never connected: say why.
                transition(machine.state == .connecting ? .failed(detail) : .dropped)
            case .couldNotOpen(let detail):
                GraineLog.warning("The call could not connect: \(detail)")
                provider?.reportCall(with: uuid, endedAt: Date(), reason: .failed)
                transition(.failed(detail))
            }
        }
    }

    private func setReconnecting(_ value: Bool) {
        guard isReconnecting != value else { return }
        isReconnecting = value
        if graine.config.debug { GraineLog.trace(value ? "call: reconnecting" : "call: reconnected") }
        notifyListeners { $0.onCallReconnecting(value) }
    }

    /// A level from the call: `agentLevel` follows it, a step every 100 ms until it gets there.
    private func heardLevel(_ level: Double) {
        levelEasing.hear(level)
        guard levelItem == nil, !levelEasing.settled else { return }
        levelSteppedAt = ProcessInfo.processInfo.systemUptime - AgentLevelEasing.stepSeconds
        stepLevel()
    }

    private func stepLevel() {
        levelItem = nil
        let now = ProcessInfo.processInfo.systemUptime
        let value = levelEasing.step(dtMs: (now - (levelSteppedAt ?? now)) * 1_000)
        levelSteppedAt = now
        if agentLevel != value { agentLevel = value }
        guard !levelEasing.settled else { return }
        let item = DispatchWorkItem { [weak self] in self?.stepLevel() }
        levelItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + AgentLevelEasing.stepSeconds, execute: item)
    }

    /// The call is over: the voice is silent and its level forgotten.
    private func resetLevel() {
        levelItem?.cancel()
        levelItem = nil
        levelSteppedAt = nil
        levelEasing.reset()
        if agentLevel != 0 { agentLevel = 0 }
    }

    /**
     * Whether `agentLevel` has been measured on this call: until it has, a
     * call screen moves its visualiser with `agentSpeaking`, as
     * `GraineCallView` does. False again once the call is over.
     */
    public var agentLevelHeard: Bool { levelEasing.heard }

    /// A new call, or a new conversation for it: nothing of the last one's report is this one's.
    private func resetConnection() {
        connectionFold = CallConnectionFold()
        if connection != nil { connection = nil }
    }

    private func audioFailed(_ message: String, uuid: UUID) {
        guard callUUID == uuid, machine.state.isLive else { return }
        GraineLog.warning(message)
        provider?.reportCall(with: uuid, endedAt: Date(), reason: .failed)
        // Its end first — its cause on the channel still up — then the hang-up.
        transition(.failed(message))
        engine?.hangUp()
    }

    /// What the audio watch decided for the open conversation (Calls/CallAudioWatch.swift).
    private func audioStep(_ step: CallAudioWatch.Step) {
        guard let uuid = callUUID, machine.state == .connecting else { return }
        switch step {
        case .connect:
            connectedAt = Date()
            transition(.connected)
        case .retry:
            // THE RESCUE: CallKit never said `didActivate`. The session is activated here, for the call, and its audio started on it.
            GraineLog.warning("Calls: CallKit has not activated the call's audio \(Int(CallAudioWatch.graceSeconds)) s after the conversation opened; activating it directly.")
            let refused = activateAudioDirectly()
            if let refused = refused { GraineLog.warning("Calls: the audio session would not activate: \(refused)") }
            engine?.startAudio { [weak self] started in
                DispatchQueue.main.async {
                    guard let self = self, self.callUUID == uuid else { return }
                    if started {
                        GraineLog.info("Calls: the call's audio started directly.")
                        self.routeAudio()
                        self.audioWatch.audioStarted()
                    } else {
                        GraineLog.warning("Calls: the call's audio could not start directly\(refused.map { " (\($0))" } ?? "").")
                        self.audioWatch.retryFailed()
                    }
                }
            }
        case .fail:
            GraineLog.warning("Calls: \(CallAudioWatch.failure) CallKit never activated it, and starting it directly did not work: the call ends (audio_watch).")
            provider?.reportCall(with: uuid, endedAt: Date(), reason: .failed)
            transition(.failed(CallAudioWatch.failure))
            engine?.hangUp()
        }
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
        // Who or what ends the call, read from where it stood: said before its outcome is.
        let cause = GraineCallEndCause.of(event, from: machine.state)
        let t = machine.handle(event)
        guard t.accepted else { return t }
        if case .ended = t.state, let cause = cause, endCause != cause { endCause = cause }
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
        // A call that ends while reconnecting is reconnecting no more — said before its end is.
        if case .ended = t.state, isReconnecting { setReconnecting(false) }
        if state != t.state { state = t.state }
        // Every agent's assistant steps aside while a native call is live.
        for agent in graine.peers { agent.nativeCallLive = t.state.isLive }
        notifyListeners { $0.onCallState(t.state, callId: t.callId) }
        for outcome in t.outcomes {
            let id = t.callId ?? ""
            notifyOutcome(outcome, callId: id, connection: id == callId ? connection : nil)
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

    /// The call is over: let go of the conversation and the audio. The machine already knows — and why (`endCause`).
    private func releaseCall() {
        ringItem?.cancel()
        ringItem = nil
        answerMic.cancel()
        audioWatch.cancel()
        // Who or what ended it, on the channel still up, before the hang-up closes it.
        if let cause = endCause { engine?.sendEnded(cause) }
        engine?.hangUp()
        engine = nil
        unwatchContext?()
        unwatchContext = nil
        if agentSpeaking { agentSpeaking = false }
        setReconnecting(false)
        resetLevel()
        audioRunning = false
        routeSettlesAt = nil
        if activatedDirectly { releaseDirectAudio() }
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
        if transport != nil { transport = nil }
        if transportFallbackReason != nil { transportFallbackReason = nil }
        if reason != nil { reason = nil }
        resetConnection()
        if endCause != nil { endCause = nil }
        if hosted { hosted = false }
        if agent != nil { agent = nil }
        callAgent = nil
        connectedAt = nil
        muted = false
        speakerOn = false
        speakerChosen = false
    }

    /**
     * A new call — placed, or ringing: nothing of the last call's audio is
     * this one's. CallKit activates each call's audio afresh (`didActivate`);
     * an activation left over from the last call must not open this one's
     * audio before the system has, or the agent speaks into a session that is
     * not running. It starts on the loudspeaker unless `speakerByDefault` is
     * off, or the customer chose otherwise since the last call.
     */
    private func freshCallAudio() {
        audioActive = false
        audioRunning = false
        routeSettlesAt = nil
        if endCause != nil { endCause = nil }
        if !speakerChosen, speakerOn != speakerByDefault { speakerOn = speakerByDefault }
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
     * headsets allowed — the earpiece as the category's own route; the
     * loudspeaker is chosen once the audio runs (`routeAudio`). Never
     * activated here: under CallKit the system activates it and says so in
     * `didActivate` (else the rescue does, `activateAudioDirectly`).
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

    /**
     * BEFORE CALLKIT HANDS A CALL ITS AUDIO: the app must not be holding the
     * audio session active itself, or CallKit never activates it — no
     * `didActivate`, and a call the agent speaks into that nobody hears. The
     * in-app voice call (`voice`, already ended) lets go of the session it
     * activated, and the session is deactivated; a session still busy (audio
     * still running somewhere in the app) says so in the log. Never
     * activated here. Main thread.
     */
    private func releaseAudioSessionForCallKit() {
        for agent in graine.peers { agent.voice.yieldAudioSession() }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch let error as NSError where error.code == AVAudioSession.ErrorCode.isBusy.rawValue {
            // Audio still runs somewhere in the app: the session stays active, and CallKit may not activate the call's.
            GraineLog.warning("Calls: the app's audio session is busy as the call starts (\(GraineCalls.describeAudioError(error))); CallKit may not activate the call's audio, and the SDK will after 3 s.")
        } catch {
            if graine.config.debug { GraineLog.trace("audio session release before the call: \(GraineCalls.describeAudioError(error))") }
        }
    }

    /**
     * CallKit never activated the call's audio (`didActivate`): the rescue
     * activates the session here, for the call. Nil when it is active; else
     * the audio session's error, for the log. Main thread.
     */
    private func activateAudioDirectly() -> String? {
        configureAudioSession()
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: [])
            activatedDirectly = true
            return nil
        } catch {
            return GraineCalls.describeAudioError(error)
        }
    }

    /**
     * The call the SDK activated the audio for is over: the session is let go
     * of — CallKit, which never activated it, will not — so the next call's
     * audio is CallKit's to activate again. A moment after the hang-up, once
     * the call's audio has stopped (a session with audio running cannot be
     * deactivated). Main thread.
     */
    private func releaseDirectAudio() {
        activatedDirectly = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, !self.machine.state.isLive else { return }
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            } catch {
                GraineLog.warning("Calls: the audio session the SDK activated for the call could not be let go of (\(GraineCalls.describeAudioError(error))).")
            }
        }
    }

    /// An audio session error as a log can read it: its domain, code (and four-character code), and sentence.
    static func describeAudioError(_ error: Error) -> String {
        let ns = error as NSError
        var code = "\(ns.code)"
        let value = UInt32(truncatingIfNeeded: ns.code)
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        if bytes.allSatisfy({ (32...126).contains($0) }) { code += " '\(String(decoding: bytes, as: UTF8.self))'" }
        return "\(ns.domain) \(code): \(ns.localizedDescription)"
    }

    /**
     * The call's audio runs: its route as wanted — the loudspeaker by default
     * (`speakerByDefault`), never pulled off the customer's own headset, car or
     * AirPlay unless they asked — now, and again as WebRTC settles the session
     * over the next second (its configuration resets an override).
     */
    private func routeAudio() {
        audioRunning = true
        routeSettlesAt = Date().addingTimeInterval(1)
        applySpeaker()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self, self.audioRunning else { return }
            self.applySpeaker()
        }
    }

    private func applySpeaker() {
        guard audioRunning else { return }
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map { $0.portType.rawValue }
        do {
            switch CallAudioRoute.choice(speaker: speakerOn, chosen: speakerChosen, outputs: outputs) {
            case .speaker: try session.overrideOutputAudioPort(.speaker)
            case .receiver: try session.overrideOutputAudioPort(.none)
            case .leave:
                // The customer's own headset, car or AirPlay carries the call: not the loudspeaker, whatever the default.
                if speakerOn { speakerOn = false }
            }
        } catch {
            GraineLog.warning("Could not switch the speaker: \(GraineInApp.describe(error))")
        }
    }

    /// The route is the truth: the system's call screen can switch the speaker too — except while the call's own audio is settling.
    private func refreshSpeaker() {
        guard audioRunning else { return }
        if let settles = routeSettlesAt, Date() < settles {
            applySpeaker()
            return
        }
        let onSpeaker = CallAudioRoute.onSpeaker(AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType.rawValue })
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

    /// `connection`: the report of the call the outcome is about — nil for any other call's (a ring refused while this one is live).
    private func notifyOutcome(_ outcome: GraineCallOutcome, callId: String, connection: GraineCallConnection? = nil) {
        notifyListeners { $0.onCallOutcome(outcome, callId: callId) }
        notifyListeners { $0.onCallOutcome(outcome, callId: callId, connection: connection) }
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
        // Whether Graine rings this phone is known now.
        logSetupProblems()
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
        GraineLog.warning("Calls: CallKit reset its provider, which ends every call (provider_reset).")
        // Its end first — its cause on the channel still up — then the hang-up.
        transition(.reset)
        engine?.hangUp()
        audioActive = false
        audioRunning = false
        GraineRtcRegistry.module?.audioSessionDeactivated()
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
        // CallKit activates the answered call's audio only when the app is not holding the session itself.
        releaseAudioSessionForCallKit()
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
        // Its end first — "local_end" on the channel still up — then the hang-up.
        transition(.hangUp)
        engine?.hangUp()
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
        // Always in the log: a call whose audio CallKit never activates is otherwise silent with nothing to show why.
        GraineLog.info("Calls: CallKit activated the call's audio (state \(machine.state)).")
        audioActive = true
        engine?.startAudio()
        // An open conversation that was waiting for its audio is connected now.
        audioWatch.audioStarted()
        // The route as wanted: the loudspeaker by default, a choice made before the audio was the call's, the customer's headset.
        if machine.state.isLive { routeAudio() }
    }

    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        GraineLog.info("Calls: CallKit deactivated the call's audio (state \(machine.state)).")
        audioActive = false
        if !activatedDirectly { audioRunning = false }
        if let engine = engine {
            engine.stopAudio()
        } else {
            // The call it was for is over, and nothing told WebRTC: its view of the session must follow, or the next
            // call's start believes active a session that is not.
            GraineRtcRegistry.module?.audioSessionDeactivated()
        }
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
