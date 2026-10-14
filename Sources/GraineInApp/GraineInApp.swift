import Foundation
#if os(iOS)
import UIKit
#endif

/// Everything the SDK needs to know up front.
public struct GraineConfig {
    /// Load timing, for a field app on a very slow network. Milliseconds, as on Android and React Native.
    public struct Timing {
        /// Silence — nothing downloaded — before a load is given up on.
        public var stallMs: Int
        /// Downloaded but still not ready: the page is broken, not slow.
        public var bootMs: Int
        /// Ceiling on one attempt however steadily it is arriving.
        public var hardCapMs: Int
        /// The whole reload ladder; its length is the number of reloads before `failed`.
        public var retryDelaysMs: [Int]
        /// How long `end()` waits for the page to confirm before forcing the end.
        public var endWatchdogMs: Int
        /// A connect the customer has waited on this long becomes `GraineVoice.slowConnect` ("Still connecting…").
        public var slowConnectMs: Int

        public init(
            stallMs: Int = 15_000,
            bootMs: Int = 15_000,
            hardCapMs: Int = 120_000,
            retryDelaysMs: [Int] = [1_000, 2_000, 4_000, 8_000, 15_000, 15_000],
            endWatchdogMs: Int = 4_000,
            slowConnectMs: Int = 4_000
        ) {
            self.stallMs = stallMs
            self.bootMs = bootMs
            self.hardCapMs = hardCapMs
            self.retryDelaysMs = retryDelaysMs
            self.endWatchdogMs = endWatchdogMs
            self.slowConnectMs = slowConnectMs
        }
    }

    /// "https://www.graine.ai" unless self-hosted.
    public var baseUrl: String
    /**
     * From Agent → Embed & Widgets. Selects the agent. It is not a secret and
     * cannot place a call on its own — add `app://` to that agent's Allowed
     * domains, or every request is refused.
     */
    public var publishableKey: String
    /// Prompt {variables} known at build time. identify() and setVariables() win over these.
    public var variables: [String: Any]
    /// Force a transport. nil (the default) lets the dashboard's Call audio setting decide.
    public var transport: GraineTransport?
    /// Lands on the call record, to tell builds apart.
    public var appVersion: String?
    /// End a live call when the app goes to the background. On by default; you want it on.
    public var endOnBackground: Bool
    public var timing: Timing
    /**
     * Log every message across the bridge, both ways, and the engine page's
     * own console, under the subsystem "ai.graine.inapp". Off by default; turn
     * it on in debug builds — "the agent did not speak" is answered in one read
     * of this log, and unanswerable without it. Variables are logged as keys
     * only, and screen context as the screen's name only.
     */
    public var debug: Bool
    /**
     * This app's friction rules, over the dashboard's (Embed & Widgets →
     * friction). Most apps set nothing; pass it for the screens only the app
     * knows about — a terms page nobody is stuck on, an OTP step where twenty
     * seconds is already long.
     */
    public var friction: GraineFrictionConfig?
    /**
     * Fonts this app ships itself. The SDK fetches the design's typeface from
     * Graine and draws it with no help from the app; a family named here, or
     * one the app bundles under the family's own name, wins instead and is
     * never downloaded. Map a family to the name your app registered it under
     * when the two differ: `["Inter": "InterVariable"]`. Most apps set nothing.
     */
    public var fonts: [String: String]
    /**
     * Tell the agent about taps (contract §8): a tap on a control with an
     * accessibility identifier — or a button's accessibility label — reaches it
     * as `tap:<name>`, any other tap as `tap:screen` with where it landed; at
     * most two a second, only while a screen is set, and never a field's value.
     * The recogniser never takes a touch from the app. On by default.
     */
    public var captureTaps: Bool
    /**
     * How big the chat window opens, over the dashboard's choice (Embed &
     * Widgets → Appearance → Chat window → Window size): `.compact` above the
     * bar, `.large` a sheet over most of a phone (a panel on an iPad), `.full`
     * the whole screen. Nil, the default, follows the dashboard; a size passed
     * to `chat.open(size:)` wins for that open.
     */
    public var chatSize: GraineChatSize?

    public init(
        baseUrl: String,
        publishableKey: String,
        variables: [String: Any] = [:],
        transport: GraineTransport? = nil,
        appVersion: String? = nil,
        endOnBackground: Bool = true,
        timing: Timing = Timing(),
        debug: Bool = false,
        friction: GraineFrictionConfig? = nil,
        fonts: [String: String] = [:],
        captureTaps: Bool = true,
        chatSize: GraineChatSize? = nil
    ) {
        self.baseUrl = baseUrl
        self.publishableKey = publishableKey
        self.variables = variables
        self.transport = transport
        self.appVersion = appVersion
        self.endOnBackground = endOnBackground
        self.timing = timing
        self.debug = debug
        self.friction = friction
        self.fonts = fonts
        self.captureTaps = captureTaps
        self.chatSize = chatSize
    }
}

/**
 * Everything the SDK reports. Every method has a default that does nothing;
 * implement what you draw. Called on the main thread. Listeners are held
 * WEAKLY — keep your own reference, and a view controller that forgets to
 * remove itself is not leaked.
 */
public protocol GraineListener: AnyObject {
    func onSessionReady(_ session: GraineSessionConfig)
    func onCallState(connected: Bool, connecting: Bool)
    func onCaption(role: GraineRole, text: String, live: Bool)
    /// The agent drew a component. Answer it with `GraineVoice.answerWidget`, or mount `GraineWidgetView`.
    func onWidget(_ widget: [String: Any])
    /// A component is on its way; its content is loading. Draw your loader.
    func onWidgetPending(_ hint: [String: Any])
    func onEnded()
    func onMicDenied(reason: String)
    /// One word for the connection. Fires only when the word changes.
    func onQuality(_ quality: GraineConnectionQuality)
    func onNetwork(online: Bool)
    /// The network interrupted the call and it is being re-established. Not an end.
    func onReconnecting(active: Bool)
    func onTransport(_ transport: GraineTransport, requested: GraineTransport, reason: String?, message: String?)
    func onConnectivity(_ state: GraineConnectivity, attempt: Int, reason: String?)
    func onActionRequested(name: String)
    func onActionCompleted(name: String, result: GraineActionResult)
    /**
     * The customer looks stuck (stalled_on_step): on one screen, with a field
     * outstanding, through a stretch of a live call. The agent has already been
     * told; this is for the app — badge a control, count it.
     */
    func onFriction(_ signal: GraineFrictionSignal)
    /**
     * The brand's design tokens for the device's current appearance — when the
     * session arrives, and again when the device switches between light and
     * dark. For an app that draws its own UI in the brand's design. Never
     * called when the session carries no design (then `appearance` is the look).
     */
    func onTheme(_ tokens: GraineThemeTokens?)
    /**
     * The agent finished a message in the chat (`GraineChat`). `proactive` is
     * true when it spoke up without being asked — open or badge your chat for
     * those, if the customer is not looking at it.
     */
    func onChatMessage(_ turn: GraineChatTurn)
    /// Loud for you, invisible to the customer: a misconfigured agent is never the customer's problem.
    func onError(_ message: String)
}

public extension GraineListener {
    func onSessionReady(_ session: GraineSessionConfig) {}
    func onCallState(connected: Bool, connecting: Bool) {}
    func onCaption(role: GraineRole, text: String, live: Bool) {}
    func onWidget(_ widget: [String: Any]) {}
    func onWidgetPending(_ hint: [String: Any]) {}
    func onEnded() {}
    func onMicDenied(reason: String) {}
    func onQuality(_ quality: GraineConnectionQuality) {}
    func onNetwork(online: Bool) {}
    func onReconnecting(active: Bool) {}
    func onTransport(_ transport: GraineTransport, requested: GraineTransport, reason: String?, message: String?) {}
    func onConnectivity(_ state: GraineConnectivity, attempt: Int, reason: String?) {}
    func onActionRequested(name: String) {}
    func onActionCompleted(name: String, result: GraineActionResult) {}
    func onFriction(_ signal: GraineFrictionSignal) {}
    func onTheme(_ tokens: GraineThemeTokens?) {}
    func onChatMessage(_ turn: GraineChatTurn) {}
    func onError(_ message: String) {}
}

/// Which registered actions the agent can call, and which it cannot. Log it once at startup.
public struct GraineActionCheck {
    /// Registered here and declared on the agent: these work.
    public let usable: [String]
    /// Registered here, not declared on the agent: never offered.
    public let undeclared: [String]
    /// Declared on the agent, not registered here: refused mid-sentence.
    public let unhandled: [String]
}

/**
 * THE GRAINE IN-APP AGENT, FOR NATIVE iOS.
 *
 *     let graine = GraineInApp.configure(GraineConfig(
 *         baseUrl: "https://www.graine.ai",
 *         publishableKey: "pk_live_…"
 *     ))
 *     graine.identify(["name": user.name])
 *     graine.setScreen(GraineScreen(screen: "kyc_documents", fields: [...]))
 *     graine.registerAction("set_tenure") { args in .ok("Tenure set") }
 *     graine.voice.attach(to: window)      // loads the engine, idle
 *     graine.voice.start()                 // places the call
 *
 * One instance per process. Everything that touches a view runs on the main
 * thread; everything that touches the network does not. The methods here may
 * be called from any thread.
 */
public final class GraineInApp {
    public typealias ActionHandler = ([String: Any]) throws -> GraineActionResult
    public typealias DeferredActionHandler = ([String: Any], @escaping (GraineActionResult) -> Void) -> Void

    public let config: GraineConfig

    let variables: VariableStore

    /// Guards the state below that the app may touch from any thread.
    private let stateLock = NSLock()
    private var sessionValue: GraineSessionConfig?
    private var themeValue: GraineThemeTokens?
    private var screen: GraineScreen?
    private var screenSinceMs: Int64 = GraineInApp.wallClockMs()
    private var recentEvents: [[String: Any]] = []
    private var actions: [String: RegisteredAction] = [:]
    private var actionOrder: [String] = []
    private var contextSeq = 0
    private var lastNamedTapMs = -Double.infinity

    // Main thread only.
    private var listenerBoxes: [WeakListener] = []
    private var variableWatchers: [UUID: ([String: String]) -> Void] = [:]
    private var contextWatchers: [UUID: ([String: Any]) -> Void] = [:]
    private var contextWindowOpen = false
    private var contextDirty = false
    private var sessionWaiters: [(GraineSessionConfig?) -> Void] = []
    private var sessionLoading = false
    private(set) var foreground = true
    private var foregroundWatchers: [UUID: (Bool) -> Void] = [:]
    private var lifecycleTokens: [NSObjectProtocol] = []
    /// The device's light or dark, as the window last reported it; nil until it has. Main thread.
    private var deviceDark: Bool?
    /**
     * Idle friction, the React Native SDK's `stalled_on_step`: the customer
     * has been on one screen, with a field outstanding, for the configured time
     * (45s by default) during a live call — once per screen visit. The agent
     * hears it with a sentence naming the field; the app hears onFriction.
     * Main-thread state; the clock is uptime.
     */
    private lazy var friction = FrictionDetector(rules: Friction.resolve([config.friction?.json]), gateOnCall: true)
    private var appFriction: GraineFrictionConfig?
    private var stallItem: DispatchWorkItem?

    private lazy var urlSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    /// Screen updates are coalesced to this. Scroll events must not become traffic.
    static let contextThrottleMs = 400
    /// A product event list is capped: an unbounded one grows the prompt until it crowds out the instructions.
    static let recentEventsCap = 10

    /// The dashboard's configuration for this agent, once it has loaded.
    public var session: GraineSessionConfig? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return sessionValue
    }

    /**
     * The brand's design, from the session: light and dark tokens and which to
     * use. Nil before the session loads, and from a server that sends none —
     * every surface then draws from `appearance`, as it always has.
     */
    public var design: GraineDesign? { session?.design }

    /**
     * The design's tokens to draw right now: the brand's fixed scheme, else the
     * device's current appearance, picked again whenever the device switches.
     * Nil without a design. `onTheme` reports each change.
     */
    public var theme: GraineThemeTokens? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return themeValue
    }

    #if os(iOS)
    /// The voice call. Attach it to your window before starting one. Main thread only.
    public private(set) lazy var voice: GraineVoice = GraineVoice(graine: self)

    /**
     * Calls like WhatsApp, on CallKit and VoIP pushes: the customer calling
     * your agent (`startCall`), or your agent ringing the customer (a push).
     * The audio runs in your app's own process, so the call keeps going with
     * the screen off. One for the whole app — every agent's `calls` is the same
     * object (`startCall(reason:variables:agent:)` picks the agent). Main thread only.
     */
    public var calls: GraineCalls { GraineCalls.process(home: registry?.primary ?? self) }
    #endif

    /// A native call (`calls`) is live: the web view engine must not start one beside it. Main thread.
    var nativeCallLive = false {
        didSet {
            guard nativeCallLive != oldValue else { return }
            // The chat steps aside for a native call, and comes back after it if the customer was in it.
            if nativeCallLive { chat.hold(GraineChat.holdNativeCall) } else { chat.release(GraineChat.holdNativeCall) }
        }
    }

    /// The design's typefaces, fetched and registered by the SDK; every surface draws from it.
    let fonts: GraineFontStore

    /**
     * The typed conversation: open it when the customer is in the chat, send
     * their messages, draw `turns`. `GraineChatView` and the bar use it
     * themselves. Main thread.
     */
    public private(set) lazy var chat: GraineChat = GraineChat(graine: self, network: network, scheduler: chatScheduler)

    /// Who the customer is for memory, and their memory choice (contract §1.2).
    let identity: IdentityState
    private let installIds: InstallIdStore
    private let installLock = NSLock()
    private var installValue: String?
    /// The last session, kept for a cold start (a push that wakes a closed app draws in the brand's design).
    let sessionCache: SessionCache
    /// The network the SDK's own requests and the chat use; the calls' seam, so tests answer for it.
    let network: CallNetwork
    private let chatScheduler: CallScheduler
    lazy var requests = EmbedRequests(baseUrl: config.baseUrl, publishableKey: config.publishableKey, network: network)

    // Main thread only.
    private var identityWatchers: [UUID: () -> Void] = [:]
    /// The component the agent drew and nobody has answered, whichever conversation drew it.
    private(set) var componentFrame: [String: Any]?
    /// The last component the customer closed without answering, for `reopenComponent()`.
    private(set) var closedComponentFrame: [String: Any]?
    private var voiceLive = false
    private var chatLive = false
    #if os(iOS)
    /// The component views the app mounted itself: the bar's own steps aside for them.
    lazy var componentHosts = GraineComponentHosts()
    /// Taps, for the agents (GraineConfig.captureTaps): one recogniser for the app, whichever agent installs it.
    var tapCapture: GraineTapCapture { GraineTapCapture.process(for: registry?.primary ?? self) }
    #endif

    /// The name this agent was configured under (`GraineInApp.configure(_:name:)`); `"default"` for the default agent.
    public let name: String
    /// The agents this one shares the person, the device and the screen with; nil for one built alone (tests).
    let registry: GraineAgentRegistry?
    /// Where this agent keeps what it remembers between launches (the device's registration with Graine).
    let defaults: UserDefaults

    /// Internal so tests can build an instance without the process-wide one, and without the Keychain or the disk.
    init(
        config: GraineConfig,
        fonts: GraineFontStore = GraineFontStore(),
        installIds: InstallIdStore = KeychainInstallIdStore(),
        defaults: UserDefaults = .standard,
        sessionCache: SessionCache = SessionCache(),
        network: CallNetwork = URLSessionCallNetwork(),
        chatScheduler: CallScheduler = DispatchCallScheduler(queue: .main),
        name: String = GraineAgentRegistry.defaultName,
        registry: GraineAgentRegistry? = nil
    ) {
        self.name = name
        self.registry = registry
        self.defaults = defaults
        self.config = config
        self.variables = VariableStore(buildTime: config.variables.mapValues { Optional($0) })
        self.appFriction = config.friction
        self.fonts = fonts
        self.installIds = installIds
        self.identity = IdentityState(choices: MemoryChoices(defaults: defaults))
        self.sessionCache = sessionCache
        self.network = network
        self.chatScheduler = chatScheduler
    }

    deinit {
        for token in lifecycleTokens { NotificationCenter.default.removeObserver(token) }
    }

    // MARK: - The agents

    /**
     * Configure an agent. Call at launch (App.init or
     * application(_:didFinishLaunchingWithOptions:)). Without a name it is the
     * default agent — `shared`, and what every view draws unless handed
     * another. An app with several agents configures each under its own name
     * and its own publishable key, and picks one per screen
     * (`GraineChatView(graine: .named("support"))`). A second call with a name
     * already configured returns that agent unchanged.
     */
    @discardableResult
    public static func configure(_ config: GraineConfig, name: String = "default") -> GraineInApp {
        let key = GraineAgentRegistry.normalise(name)
        let registry = GraineAgentRegistry.process
        let result = registry.agent(named: key) {
            GraineInApp(config: config, sessionCache: SessionCache(agent: key), name: key, registry: registry)
        }
        if result.created {
            result.agent.adoptShared()
            result.agent.begin()
            #if os(iOS)
            // The app's calls hear every agent's session: its design, and whether it rings this device.
            result.agent.onMain { GraineCalls.agentConfigured(result.agent) }
            #endif
        }
        return result.agent
    }

    /// The agent configured under `name`, or nil.
    public static func named(_ name: String) -> GraineInApp? {
        GraineAgentRegistry.process.named(GraineAgentRegistry.normalise(name))
    }

    /// Every configured agent, by name.
    public static var all: [String: GraineInApp] {
        GraineAgentRegistry.process.all
    }

    /// The default agent (else the first one configured), or nil before any is.
    public static var current: GraineInApp? {
        GraineAgentRegistry.process.primary
    }

    /// The default agent. Traps if no agent was configured.
    public static var shared: GraineInApp {
        guard let existing = current else {
            fatalError("GraineInApp.configure(_:) has not been called. Call it once, at launch.")
        }
        return existing
    }

    /// This agent and every other configured beside it: what the person, the device and the screen are shared with.
    var peers: [GraineInApp] {
        registry?.members(including: self) ?? [self]
    }

    /// A newly configured agent takes on who is signed in, their memory choice and the current screen.
    func adoptShared() {
        guard let shared = registry?.shared() else { return }
        if let identified = shared.identified {
            applyIdentify(identified.traits, memory: shared.memory ?? identified.memory)
        } else if let memory = shared.memory {
            applySetMemory(memory)
        }
        if let screen = shared.screen { applySetScreen(screen) }
    }

    /**
     * One conversation at a time, across every agent: a call starting on this
     * agent ends a call on any other and closes every chat; a chat opening
     * here ends every call and closes the other agents' chats. Main thread.
     */
    func takeConversation(for surface: GraineSurface) {
        for agent in peers {
            #if os(iOS)
            if surface == .chat || agent !== self {
                let voice = agent.voice
                if voice.connected || voice.connecting { voice.end() }
            }
            #endif
            if surface == .voice || agent !== self {
                if agent.chat.isOpen { agent.chat.close() }
            }
        }
    }

    private func begin() {
        #if os(iOS)
        onMain { self.watchLifecycle() }
        #endif
        loadSession { _ in }
    }

    // MARK: - Listeners

    /// Hear everything the SDK reports. Held weakly.
    public func addListener(_ listener: GraineListener) {
        onMain {
            self.listenerBoxes.removeAll { $0.value == nil }
            if !self.listenerBoxes.contains(where: { $0.value === listener }) {
                self.listenerBoxes.append(WeakListener(listener))
            }
        }
    }

    public func removeListener(_ listener: GraineListener) {
        onMain { self.listenerBoxes.removeAll { $0.value == nil || $0.value === listener } }
    }

    /// Main thread. A snapshot, so a listener may remove itself from inside a callback.
    func notifyListeners(_ call: (GraineListener) -> Void) {
        let current = listenerBoxes.compactMap { $0.value }
        for listener in current { call(listener) }
    }

    // MARK: - Who, and what they are called

    /**
     * Who is signed in. Traits become prompt variables (masked on the device)
     * and land on the call record. nil on sign-out.
     *
     * The trait the agent's Identity setting names (`user_id` unless the
     * dashboard says `email`, `phone` or a custom trait) is who the customer is
     * for memory: its value goes, raw, only on the requests that start a
     * conversation — never into the variables — and Graine keeps a one-way key
     * of it, not the value. A placeholder ("guest", "null", a masked
     * "[EMAIL]") is no identity: that conversation is anonymous, and has no
     * memory.
     *
     * - Parameter memory: false — this customer's conversations are neither
     *   remembered nor recalled. Kept on the device for them, so it need not be
     *   repeated; nil keeps their last choice (true until they make one).
     *
     * Identity is fixed per conversation: a change reaches the next one.
     * `identify(nil)` signs out — the device stops being this customer's, and
     * later conversations are anonymous.
     */
    public func identify(_ traits: [String: Any?]?, memory: Bool? = nil) {
        // One person for the whole app: every agent hears it (each reads the trait its own Identity setting names).
        registry?.rememberIdentify(traits, memory: memory)
        for agent in peers { agent.applyIdentify(traits, memory: memory) }
    }

    /// Whether the current customer's conversations are remembered: `identify(currentTraits, memory: enabled)`. Every agent.
    public func setMemory(_ enabled: Bool) {
        registry?.rememberMemory(enabled)
        for agent in peers { agent.applySetMemory(enabled) }
    }

    private func applyIdentify(_ traits: [String: Any?]?, memory: Bool?) {
        let before = identity.snapshot().value
        variables.setIdentity(traits)
        identity.identify(traits, memory: memory)
        announceVariables()
        scheduleContext()
        identityChanged(previous: before)
    }

    private func applySetMemory(_ enabled: Bool) {
        identity.setMemory(enabled)
        identityChanged(previous: identity.snapshot().value)
    }

    /// The current customer's memory choice (true until they turn it off). False is never recalled or stored.
    public var memoryChoice: Bool { identity.snapshot().memory }

    /**
     * This install's id: a UUID made on first launch and kept in the Keychain,
     * this device only, through reinstalls. Graine counts a customer's devices
     * by it; the agent never sees it.
     */
    public var installId: String {
        // One device, one id, whichever agent asks.
        if let registry = registry { return registry.installId(resolving: installIds) }
        installLock.lock()
        defer { installLock.unlock() }
        if let known = installValue { return known }
        let made = InstallId.resolve(installIds)
        if !made.kept { GraineLog.warning("The install id could not be kept in the Keychain; this launch uses a new one.") }
        // A copy that was not kept is used for this launch only: the next launch reads (or makes) its own.
        installValue = made.id
        return made.id
    }

    /**
     * Forget everything the agent remembers about the current customer, for
     * this agent's memory — the conversation the chat continues included, so
     * the chat on screen clears too. Allowed only from a device bound to them.
     * Returns how many memories were deleted. Throws `GraineServiceError` —
     * `identityRequired` when nobody is identified, `deviceLimit` from a device
     * that is not one of theirs (and then nothing is cleared).
     */
    @discardableResult
    public func forgetMemory() async throws -> Int {
        _ = await sessionNow()
        let now = identity.snapshot()
        guard let value = now.value else {
            throw GraineServiceError(code: .identityRequired, message: "Nobody is identified: call identify() with the customer's identifier first.")
        }
        let body = try await requests.post("/api/embed/memory/forget", [
            ("installId", .string(installId)),
            ("identity", .object([("value", .string(value))])),
        ])
        // The conversation is part of what was forgotten: off the screen, and what was waiting to go with it.
        chat.forgetTranscript()
        return (JSON.unwrap(body["deleted"]).flatMap { JSON.number($0) }?.intValue).map { max(0, $0) } ?? 0
    }

    /**
     * Graine lets go of the conversation it kept for this agent and the current
     * customer, so the next chat starts fresh (`GraineChat.newConversation()`).
     * Nobody identified: nothing was kept, nothing to ask. Throws
     * `GraineServiceError` as `forgetMemory()` does.
     */
    func letGoOfConversation() async throws {
        _ = await sessionNow()
        guard let value = identity.snapshot().value else { return }
        _ = try await requests.post("/api/embed/conversation/new", [
            ("installId", .string(installId)),
            ("identity", .object([("value", .string(value))])),
        ])
    }

    /**
     * What the agent remembers about the current customer, newest first (at
     * most 100), already redacted — to show people what is kept about them.
     * Only from a device bound to them. Throws `GraineServiceError`:
     * `identity_required` when nobody is identified, `device_limit` from a
     * device that is not one of theirs.
     */
    public func memories() async throws -> [GraineMemory] {
        _ = await sessionNow()
        guard let value = identity.snapshot().value else {
            throw GraineServiceError(code: .identityRequired, message: "Nobody is identified: call identify() with the customer's identifier first.")
        }
        let body = try await requests.post("/api/embed/memory/list", [
            ("installId", .string(installId)),
            ("identity", .object([("value", .string(value))])),
        ])
        return GraineMemory.list(body)
    }

    /// The identity fields a request carries now (contract §1.3).
    func identityFields(callId: String?) -> IdentityWire.Fields {
        let now = identity.snapshot()
        return IdentityWire.Fields(
            value: now.value,
            installId: installId,
            memory: now.memory,
            timezone: IdentityWire.deviceTimezone(),
            callId: callId
        )
    }

    /// Main thread. Returns the function that stops watching. Called when the identity, or the memory choice, changes.
    func onIdentity(_ watch: @escaping () -> Void) -> () -> Void {
        let id = UUID()
        identityWatchers[id] = watch
        return { [weak self] in
            guard let self = self else { return }
            self.onMain { self.identityWatchers.removeValue(forKey: id) }
        }
    }

    private func identityChanged(previous: String?) {
        let current = identity.snapshot().value
        onMain {
            // Another customer on this phone: the last one's chat is not theirs to read.
            if previous != nil && previous != current { self.chat.forgetTranscript() }
            for watch in Array(self.identityWatchers.values) { watch() }
            self.sendSignOuts()
        }
    }

    /// The customers this device stopped being: released on the server, so their memory and calls stop reaching it.
    private func sendSignOuts() {
        guard session != nil else { return }
        for value in identity.takeSignOuts() {
            requests.post("/api/embed/identity/signout", [
                ("installId", .string(installId)),
                ("identity", .object([("value", .string(value))])),
            ]) { result in
                if case .failure(let error) = result { GraineLog.warning("Sign-out was not recorded: \(error.message)") }
            }
        }
    }

    /**
     * Prompt variables from the app's own data, while it runs. Merged, not
     * replaced; nil under a key removes it, nil for the whole map clears.
     * Reaches the next call, and a live engine page re-mints with it.
     */
    public func setVariables(_ values: [String: Any?]?) {
        variables.setRuntime(values)
        announceVariables()
    }

    /// Every variable the agent will receive, in precedence order already applied.
    public func currentVariables() -> [String: String] {
        variables.merged()
    }

    /// Main thread. Returns the function that stops watching.
    func onVariables(_ watch: @escaping ([String: String]) -> Void) -> () -> Void {
        let id = UUID()
        variableWatchers[id] = watch
        return { [weak self] in
            guard let self = self else { return }
            self.onMain { self.variableWatchers.removeValue(forKey: id) }
        }
    }

    private func announceVariables() {
        let merged = variables.merged()
        onMain {
            for watch in Array(self.variableWatchers.values) { watch(merged) }
        }
    }

    // MARK: - What is on the screen

    /**
     * What the customer is looking at. Call on every meaningful change; an
     * unchanged screen is not resent, and bursts are coalesced to one frame
     * per 400ms (the first goes at once — it is the frame the agent's opening
     * line depends on).
     */
    public func setScreen(_ next: GraineScreen?) {
        // The screen is the app's: every agent hears it, and tells it to its own live conversation.
        registry?.rememberScreen(next)
        for agent in peers { agent.applySetScreen(next) }
    }

    private func applySetScreen(_ next: GraineScreen?) {
        stateLock.lock()
        let changed = next != screen
        if changed {
            if next?.screen != screen?.screen { screenSinceMs = GraineInApp.wallClockMs() }
            screen = next
        }
        stateLock.unlock()
        if changed {
            scheduleContext()
            let now = GraineInApp.uptimeMs()
            onMain {
                self.friction.onScreen(next, now: now)
                self.armStall()
            }
        }
    }

    /**
     * One field changed — report just that. Merged by name into the current
     * screen (added when new), so a form need not describe itself again on every
     * keystroke. Without a screen there is nothing to attach it to: the next
     * `setScreen` carries it.
     */
    public func updateField(_ field: GraineField) {
        guard !field.name.isEmpty else { return }
        stateLock.lock()
        guard var next = screen else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()
        if let i = next.fields.firstIndex(where: { $0.name == field.name }) {
            next.fields[i] = field
        } else {
            next.fields.append(field)
        }
        setScreen(next)
    }

    /// A field left the screen. Nothing happens if it was never reported.
    public func removeField(_ name: String) {
        stateLock.lock()
        guard var next = screen, next.fields.contains(where: { $0.name == name }) else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()
        next.fields.removeAll { $0.name == name }
        setScreen(next)
    }

    /**
     * Forget a screen — only if it is still the one described. A screen's
     * teardown runs after the next screen has reported itself, and an
     * unconditional `setScreen(nil)` there would tell the agent the customer is
     * looking at nothing. nil clears whatever is there.
     */
    public func clearScreen(_ screenId: String?) {
        stateLock.lock()
        let current = screen
        stateLock.unlock()
        guard let shown = current else { return }
        if let id = screenId, shown.screen != id { return }
        setScreen(nil)
    }

    /// A product event that informs without interrupting. Rides the next context frame; the last 10 are kept. Every agent hears it.
    public func track(_ name: String, data: [String: Any] = [:]) {
        for agent in peers { agent.track(name, data: data, coalesce: false) }
    }

    /**
     * The customer tapped a control the agent should know about — "you tapped
     * Submit twice and it did not go through" — recorded as `tap:<name>`. Taps
     * are context, not news: they ride the next frame, at the end of its
     * 400 ms window.
     */
    public func tap(_ name: String, data: [String: Any] = [:]) {
        guard let clean = TapRules.clean(name) else { return }
        let at = GraineInApp.uptimeMs()
        for agent in peers {
            agent.stateLock.lock()
            agent.lastNamedTapMs = at
            agent.stateLock.unlock()
            agent.track("tap:" + clean, data: data, coalesce: true)
        }
    }

    /// A bare tap (the window's recogniser): context for every agent, at the end of the window.
    func recordUnnamedTap(x: Int, y: Int) {
        for agent in peers { agent.track(TapRules.unnamed, data: ["x": x, "y": y], coalesce: true) }
    }

    /// Whether a named tap was recorded at or after `ms` (uptime).
    func namedTapSince(_ ms: Double) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lastNamedTapMs >= ms
    }

    /// `coalesce`: never a frame now — one at the end of the window (taps can come several a second).
    func track(_ name: String, data: [String: Any], coalesce: Bool) {
        guard !name.isEmpty else { return }
        var event: [String: Any] = ["name": name, "at": GraineInApp.wallClockMs()]
        if !data.isEmpty { event["data"] = JSON.normalize(data) }
        stateLock.lock()
        recentEvents.append(event)
        if recentEvents.count > GraineInApp.recentEventsCap {
            recentEvents.removeFirst(recentEvents.count - GraineInApp.recentEventsCap)
        }
        let hasScreen = screen != nil
        stateLock.unlock()
        if coalesce {
            if hasScreen { scheduleContextTrailing() }
        } else {
            scheduleContext()
        }
    }

    /// Whether a screen is described: a tap has nothing to attach to without one.
    var hasScreen: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return screen != nil
    }

    /// Main thread. Returns the function that stops watching.
    func onContext(_ watch: @escaping ([String: Any]) -> Void) -> () -> Void {
        let id = UUID()
        contextWatchers[id] = watch
        return { [weak self] in
            guard let self = self else { return }
            self.onMain { self.contextWatchers.removeValue(forKey: id) }
        }
    }

    /// The current frame (`context`, `availableActions`, `seq`), for a transport that has just come up.
    func currentContextFrame() -> [String: Any]? {
        stateLock.lock()
        let screen = self.screen
        let since = screenSinceMs
        let events = recentEvents
        let registered = actionOrder
        stateLock.unlock()
        guard var frame = ContextFrame.build(
            screen: screen,
            screenSinceMs: since,
            nowMs: GraineInApp.wallClockMs(),
            identity: variables.identitySnapshot(),
            appVersion: config.appVersion,
            recentEvents: events,
            registeredActions: registered
        ) else { return nil }
        stateLock.lock()
        contextSeq += 1
        let seq = contextSeq
        stateLock.unlock()
        // Monotonic: lets the runtime drop a frame that overtook a newer one on a reconnect.
        frame["seq"] = seq
        return frame
    }

    /// Coalesced: a screen that updates on every keystroke is sent at most every 400ms.
    private func scheduleContext() {
        onMain {
            if self.contextWindowOpen {
                self.contextDirty = true
                return
            }
            self.flushContext()
        }
    }

    /// One frame at the end of the window, never one now.
    private func scheduleContextTrailing() {
        onMain {
            self.contextDirty = true
            if !self.contextWindowOpen { self.openContextWindow() }
        }
    }

    /// Main thread. Opens the window without sending; whatever is waiting at its end goes then.
    private func openContextWindow() {
        contextWindowOpen = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(GraineInApp.contextThrottleMs)) { [weak self] in
            guard let self = self else { return }
            self.contextWindowOpen = false
            if self.contextDirty {
                self.contextDirty = false
                self.flushContext()
            }
        }
    }

    private func flushContext() {
        guard let frame = currentContextFrame() else { return }
        for watch in Array(contextWatchers.values) { watch(frame) }
        contextWindowOpen = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(GraineInApp.contextThrottleMs)) { [weak self] in
            guard let self = self else { return }
            self.contextWindowOpen = false
            if self.contextDirty {
                self.contextDirty = false
                self.flushContext()
            }
        }
    }

    // MARK: - Friction: noticing the customer is stuck

    /**
     * The customer did something that is not a field edit — scrolled a list,
     * opened a picker, sent a message. The idle clock restarts. Field edits do
     * NOT count: a customer typing one character every forty seconds is
     * exactly who is stuck.
     */
    public func noteInteraction() {
        let now = GraineInApp.uptimeMs()
        for agent in peers {
            agent.onMain {
                agent.friction.onInteraction(now: now)
                agent.armStall()
            }
        }
    }

    /// Replace the app's layer of friction rules (over the dashboard's). Safe at any time.
    public func configureFriction(_ override: GraineFrictionConfig?) {
        onMain {
            self.appFriction = override
            self.friction.configure(Friction.resolve([self.session?.friction, override?.json]))
            self.armStall()
        }
    }

    /// The rules in force right now — defaults, the dashboard's, the app's. Main thread.
    var frictionRules: FrictionRules { friction.rules }

    /// A call connected or ended. The idle clock only runs during a conversation. Main thread.
    func callStateChanged(live: Bool) {
        voiceLive = live
        friction.onCall(live: voiceLive || chatLive, now: GraineInApp.uptimeMs())
        armStall()
    }

    /// The chat opened or closed: a conversation, for friction, as a call is. Main thread.
    func conversationLive(chat live: Bool) {
        chatLive = live
        friction.onCall(live: voiceLive || chatLive, now: GraineInApp.uptimeMs())
        armStall()
    }

    private func armStall() {
        stallItem?.cancel()
        stallItem = nil
        guard let due = friction.idleDueIn(now: GraineInApp.uptimeMs()) else { return }
        let item = DispatchWorkItem { [weak self] in self?.onStall() }
        stallItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(due.rounded(.up))), execute: item)
    }

    private func onStall() {
        stallItem = nil
        guard let signal = friction.onIdle(now: GraineInApp.uptimeMs()) else {
            armStall()
            return
        }
        // The app first, so a host can badge a control; then the agent, as every app event goes.
        notifyListeners { $0.onFriction(signal) }
        reportEvent(signal.name, detail: signal.detail, data: [
            "cooldown_seconds": signal.cooldownSeconds,
            "max_per_session": signal.maxPerSession,
        ])
    }

    // MARK: - The live conversation: a call, or the chat

    /**
     * Something happened that the agent may want to speak up about, told to
     * whichever conversation is live — the chat, else the call. Neither live:
     * dropped, as on a call — queued, it would open the next conversation by
     * announcing something from this one. Main thread.
     */
    func reportEvent(_ name: String, detail: String?, data: [String: Any]) {
        if chat.carriesConversation {
            chat.reportEvent(name, detail: detail, data: data)
            return
        }
        #if os(iOS)
        voice.reportEvent(name, detail: detail, data: data)
        #endif
    }

    /// A component arrived from either conversation: kept until answered, and drawn by every view that shows them. Main thread.
    func componentArrived(_ frame: [String: Any]) {
        componentFrame = frame
        closedComponentFrame = nil
        notifyListeners { $0.onWidget(frame) }
    }

    /// The customer answered the component: to the conversation it belongs to. Main thread.
    func answerComponent(widgetId: String, data: [String: Any], summary: String) {
        if let pending = componentFrame, GraineInApp.componentId(pending) == widgetId { componentFrame = nil }
        if chat.carriesConversation {
            chat.submitWidget(widgetId: widgetId, data: data, summary: summary)
            return
        }
        #if os(iOS)
        voice.answerWidget(widgetId: widgetId, data: data, summary: summary)
        #endif
    }

    /// The customer closed it without answering: kept for `reopenComponent()`. Main thread.
    func componentDismissed() {
        if let shown = componentFrame { closedComponentFrame = shown }
        componentFrame = nil
    }

    /// Nothing from the conversation that just ended belongs on screen. Main thread.
    func forgetComponents() {
        componentFrame = nil
        closedComponentFrame = nil
    }

    /**
     * Put back the last component the customer closed, exactly as it was —
     * the cheap path for a "show that again" control (the agent could draw it
     * again, at the cost of another tool call). False when there is none.
     */
    @discardableResult
    public func reopenComponent() -> Bool {
        guard Thread.isMainThread else {
            var reopened = false
            DispatchQueue.main.sync { reopened = self.reopenComponent() }
            return reopened
        }
        guard let closed = closedComponentFrame else { return false }
        componentArrived(closed)
        return true
    }

    static func componentId(_ frame: [String: Any]) -> String {
        JSON.nonEmpty(frame["widget_id"]) ?? JSON.string(frame["id"])
    }

    // MARK: - What the agent may do

    /**
     * Something the agent can do in your app. Declare it on the agent in the
     * dashboard too — a handler with no declaration is never offered, and a
     * declaration with no handler is refused mid-sentence.
     *
     * The handler runs on the main thread (it will usually touch UI) and must
     * answer within six seconds, or the agent is told it was not done. A
     * handler that throws answers `error` with the error's description.
     * Returns a function that unregisters it.
     */
    @discardableResult
    public func registerAction(_ name: String, handler: @escaping ActionHandler) -> () -> Void {
        register(name) { args, done in
            let result = try handler(args)
            done(result)
        }
    }

    /**
     * The same, for work that finishes later — an upload, a network call.
     * Call `done` exactly once, from any thread; later calls are ignored.
     * Anything slower than six seconds should answer at once and report the
     * outcome with `setScreen` or `track` when it finishes.
     */
    @discardableResult
    public func registerAction(_ name: String, deferred handler: @escaping DeferredActionHandler) -> () -> Void {
        register(name) { args, done in handler(args, done) }
    }

    private func register(_ name: String, run: @escaping RegisteredAction.Run) -> () -> Void {
        let token = UUID()
        stateLock.lock()
        actions[name] = RegisteredAction(token: token, run: run)
        if !actionOrder.contains(name) { actionOrder.append(name) }
        stateLock.unlock()
        // Availability is part of the screen: an action registered as a screen mounts must reach
        // the agent without waiting for the next unrelated update.
        scheduleContext()
        return { [weak self] in
            guard let self = self else { return }
            self.stateLock.lock()
            if self.actions[name]?.token == token {
                self.actions.removeValue(forKey: name)
                self.actionOrder.removeAll { $0 == name }
            }
            self.stateLock.unlock()
            self.scheduleContext()
        }
    }

    /// Which registered actions the agent can call, and which it cannot. Log this once at startup.
    public func checkActions() -> GraineActionCheck {
        stateLock.lock()
        let registered = actionOrder
        let declared = sessionValue?.declaredActions ?? []
        stateLock.unlock()
        return GraineActionCheck(
            usable: registered.filter { declared.contains($0) },
            undeclared: registered.filter { !declared.contains($0) },
            unhandled: declared.filter { !registered.contains($0) }.sorted()
        )
    }

    /**
     * Run one action for the agent, on the main thread, against the deadline.
     * Always answers — a handler that throws is `error`, a slow one is `error`
     * with a timeout message, an unknown one is `refused`. The agent is blocked
     * waiting, so silence is the one answer never given.
     *
     * A native call answers on the socket itself, so it runs the same handlers
     * inside the runtime's six seconds (`deadlineMs`), with its own words for
     * a late handler (`timeoutMessage`).
     */
    func executeAction(
        name: String,
        arguments: [String: Any],
        deadlineMs: Int = GraineProtocol.actionDeadlineMs,
        timeoutMessage: String? = nil,
        answer: @escaping (GraineActionResult) -> Void
    ) {
        onMain {
            self.notifyListeners { $0.onActionRequested(name: name) }
            self.stateLock.lock()
            let registered = self.actions[name]
            self.stateLock.unlock()

            let call = ActionCall()
            let finish: (GraineActionResult) -> Void = { [weak self] result in
                if call.done { return }
                call.done = true
                call.deadline?.cancel()
                call.deadline = nil
                self?.notifyListeners { $0.onActionCompleted(name: name, result: result) }
                answer(result)
            }
            guard let action = registered else {
                finish(.refused("This app build does not implement \"\(name)\"."))
                return
            }
            let deadline = DispatchWorkItem {
                finish(.error(timeoutMessage ?? "The app did not answer within \(GraineProtocol.actionDeadlineMs / 1000) seconds."))
            }
            call.deadline = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(deadlineMs), execute: deadline)
            DispatchQueue.main.async {
                do {
                    try action.run(arguments) { result in
                        if Thread.isMainThread {
                            finish(result)
                        } else {
                            DispatchQueue.main.async { finish(result) }
                        }
                    }
                } catch {
                    finish(.error(GraineInApp.describe(error)))
                }
            }
        }
    }

    // MARK: - The session

    /// Fetch the agent's configuration once; later callers share the answer. `done` runs on the main thread.
    func loadSession(_ done: @escaping (GraineSessionConfig?) -> Void) {
        onMain {
            if let loaded = self.session {
                done(loaded)
                return
            }
            self.sessionWaiters.append(done)
            if self.sessionLoading { return }
            self.sessionLoading = true
            self.fetchSession { result in
                DispatchQueue.main.async { self.finishSession(result) }
            }
        }
    }

    /// Main thread. Internal so tests can deliver a session without the network.
    func finishSession(_ result: Result<GraineSessionConfig, Error>) {
        var loaded: GraineSessionConfig?
        switch result {
        case .success(let session):
            loaded = session
            stateLock.lock()
            sessionValue = session
            stateLock.unlock()
            sessionCache.save(session)
            variables.setDashboardDefaults(session.variables.mapValues { Optional($0) })
            // Which trait names the customer: the identity the app gave is read now, and anyone it replaced signed out.
            let before = identity.snapshot()
            identity.setField(session.identitySettings.field)
            variables.setIdentityField(session.identitySettings.field)
            if identity.snapshot() != before { for watch in Array(identityWatchers.values) { watch() } }
            sendSignOuts()
            // The design first, so `theme` is already right when onSessionReady is heard.
            repickTheme()
            #if os(iOS)
            // Its typefaces start on their way now, so the bar is set in them by the time anyone taps it.
            if let design = session.design { loadFonts(for: design) }
            #endif
            // The dashboard's friction rules, under the app's own.
            friction.configure(Friction.resolve([session.friction, appFriction?.json]))
            armStall()
            notifyListeners { $0.onSessionReady(session) }
            let check = checkActions()
            if !check.unhandled.isEmpty {
                GraineLog.warning("The agent declares actions this build does not implement: \(check.unhandled). They will be refused mid-sentence.")
            }
        case .failure(let error):
            let message = GraineInApp.describe(error)
            GraineLog.error(message)
            notifyListeners { $0.onError(message) }
        }
        sessionLoading = false
        let waiting = sessionWaiters
        sessionWaiters = []
        for waiter in waiting { waiter(loaded) }
    }

    /// The session, or — when it cannot be loaded (a push woke the app before the network came up) — the last one kept. Main thread.
    func loadSessionOrCached(_ done: @escaping (GraineSessionConfig?) -> Void) {
        loadSession { [weak self] session in
            done(session ?? self?.sessionCache.load())
        }
    }

    /// The session as it is, or the last one kept: for drawing before the network answers (a cold start's call screen).
    var sessionOrCached: GraineSessionConfig? {
        session ?? sessionCache.load()
    }

    /// The session, waited for.
    func sessionNow() async -> GraineSessionConfig? {
        await withCheckedContinuation { continuation in
            loadSession { continuation.resume(returning: $0) }
        }
    }

    // MARK: - The device, for the calls Graine rings

    /**
     * Tell Graine this device's VoIP token from every agent whose workspace
     * rings the app — each with its own key, so every one of them can ring
     * this device. The token is the device's; the registration is each
     * agent's. Main thread.
     */
    func registerDeviceEverywhere(token: String, appId: String, apnsEnvironment: String, now: Date = Date()) {
        for agent in peers {
            agent.registerDevice(token: token, appId: appId, apnsEnvironment: apnsEnvironment, now: now)
        }
    }

    /**
     * This agent's registration (`/api/embed/devices`), when its session says
     * Graine rings this app and one is due (DeviceRegistration): a new token, a
     * new customer, time zone or version, or a day since the last.
     */
    func registerDevice(token: String, appId: String, apnsEnvironment: String, now: Date = Date()) {
        guard let calls = sessionOrCached?.calls, calls.ringsThisPlatform else { return }
        let f = identityFields(callId: nil)
        let appVersion = config.appVersion ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
        let fingerprint = DeviceRegistration.fingerprint(token: token, fields: [
            ("install", f.installId ?? ""), ("app", appId), ("env", apnsEnvironment), ("tz", f.timezone),
            ("version", appVersion), ("sdk", GraineVersion.name), ("identity", f.value ?? ""),
        ])
        let agentName = name
        let store = defaults
        guard DeviceRegistration.due(last: DeviceRegistration.load(store, agent: agentName), fingerprint: fingerprint, now: now) else { return }
        var fields: [(String, WireJSON)] = [
            ("installId", .string(f.installId ?? installId)),
            ("platform", .string("ios")),
            ("appId", .string(appId)),
            ("token", .string(token)),
            ("tokenKind", .string("voip")),
            ("apnsEnvironment", .string(apnsEnvironment)),
            ("timezone", .string(f.timezone)),
            ("appVersion", .string(appVersion)),
            ("sdkVersion", .string(GraineVersion.name)),
        ]
        if let value = f.value { fields.append(("identity", .object([("value", .string(value))]))) }
        requests.post("/api/embed/devices", fields) { result in
            switch result {
            case .success(let body):
                DeviceRegistration(fingerprint: fingerprint, at: now).save(store, agent: agentName)
                // `{ok, trusted?, reason?}`: registered either way, but an untrusted device is not rung for the customer.
                if JSON.unwrap(body["trusted"]).flatMap({ JSON.bool($0) }) == false {
                    GraineLog.warning("This device is registered for calls but not linked to the signed-in customer (\(JSON.nonEmpty(body["reason"]) ?? "untrusted")).")
                }
            case .failure(let error):
                GraineLog.warning("This device could not be registered for calls: \(error.message)")
            }
        }
    }

    // MARK: - Calls the agent will make (contract §4.2)

    /// The rules for booking calls, from the session (the last one kept before it loads): `scheduleCall` checks them first.
    public var schedulingRules: GraineSchedulingRules {
        sessionOrCached?.schedulingRules ?? GraineSchedulingRules()
    }

    /**
     * Whether this agent can be booked from the app now — what the SDK's own
     * "Book a call" follows, and what an app's own button should: Graine rings
     * this iPhone (`calls.hosted`, and `calls.platforms` empty or naming iOS),
     * the agent lets customers book, and the customer is identified with the
     * trait the agent's Identity setting names (otherwise a booking is refused
     * with `identityRequired`). Each agent answers for itself. Read it again
     * after `identify` and once the session has loaded.
     */
    public var bookingAvailable: Bool {
        Booking.available(calls: sessionOrCached?.calls, identified: identity.snapshot().value != nil)
    }

    /// Why the booking sheet cannot book now, as its line; nil when it can.
    var bookingBlocked: String? {
        Booking.blocked(calls: sessionOrCached?.calls, identified: identity.snapshot().value != nil)
    }

    /**
     * Ask the agent to call this customer at `date` — Graine rings this device
     * then, as a call on the system's call screen. `reason` (120 characters) is
     * what the agent is told the call is for; it never appears in the push.
     * Returns the booked call (status `scheduled`).
     *
     * Checked here first, before anything is sent (`schedulingRules`):
     * `schedulingOff` when the agent does not let customers book, `tooSoon`
     * before `earliest(now:)`, `tooFar` after `latest(now:)`. Then the server's:
     * `outsideWindow` (the agent's calling hours, in this device's time zone),
     * `tooManyPending`, `identityRequired`, `rateLimited` (`retryAfterSeconds`).
     */
    public func scheduleCall(at date: Date, reason: String? = nil) async throws -> GraineScheduledCall {
        _ = await sessionNow()
        try GraineInApp.check(date, against: schedulingRules, now: Date())
        let f = identityFields(callId: nil)
        var fields: [(String, WireJSON)] = [("installId", .string(installId))]
        if let value = f.value { fields.append(("identity", .object([("value", .string(value))]))) }
        fields.append(("at", .string(Scheduling.isoTime(date))))
        if let why = Scheduling.clippedReason(reason) { fields.append(("reason", .string(why))) }
        fields.append(("timezone", .string(f.timezone)))
        let body = try await requests.post("/api/embed/calls/schedule", fields)
        guard let call = Scheduling.booked(body) else {
            throw GraineServiceError(code: .unknown("unreadable_answer"), message: "The booking was accepted, but its answer did not describe the call.", status: 200)
        }
        // The chat's upcoming-calls card shows it at once.
        onMain { self.chat.refreshUpcomingCalls() }
        return call
    }

    /// This customer's calls still to come (this install's, when nobody is identified), upcoming first.
    public func scheduledCalls() async throws -> [GraineScheduledCall] {
        try await withCheckedThrowingContinuation { continuation in
            listScheduledCalls { continuation.resume(with: $0) }
        }
    }

    /**
     * Call one off. Only this customer's own calls (this install's, when nobody
     * is identified); `notFound` for anything else. Returns the call's status
     * afterwards — `cancelled`.
     */
    @discardableResult
    public func cancelScheduledCall(id: String) async throws -> GraineCallStatus {
        try await withCheckedThrowingContinuation { continuation in
            cancelScheduledCall(id: id) { continuation.resume(with: $0) }
        }
    }

    /// The local checks `scheduleCall` makes before it asks.
    static func check(_ date: Date, against rules: GraineSchedulingRules, now: Date) throws {
        guard rules.usersCanBook else {
            throw GraineServiceError(code: .schedulingOff, message: "Calls can't be booked from the app for this assistant.")
        }
        if date < rules.earliest(now: now) {
            throw GraineServiceError(code: .tooSoon, message: "That is too soon: calls can be booked from \(rules.minLeadMinutes) minutes ahead.")
        }
        if date > rules.latest(now: now) {
            throw GraineServiceError(code: .tooFar, message: "That is too far ahead: calls can be booked up to \(rules.maxDaysAhead) days ahead.")
        }
    }

    /// `scheduledCalls()`, for code that answers on a callback (the chat's card). After the session, so the identity is known.
    func listScheduledCalls(_ done: @escaping (Result<[GraineScheduledCall], GraineServiceError>) -> Void) {
        loadSession { [weak self] _ in
            guard let self = self else { return }
            self.requests.post("/api/embed/calls/list", self.ownCallsFields()) { result in
                done(result.map { Scheduling.listed($0) })
            }
        }
    }

    /// `cancelScheduledCall(id:)` on a callback: the status afterwards (`{ok, status?}`; `cancelled` when the answer says none).
    func cancelScheduledCall(id: String, _ done: @escaping (Result<GraineCallStatus, GraineServiceError>) -> Void) {
        loadSession { [weak self] _ in
            guard let self = self else { return }
            self.requests.post("/api/embed/calls/cancel", self.ownCallsFields() + [("callId", .string(id))]) { result in
                done(result.map { body in JSON.nonEmpty(body["status"]).map { GraineCallStatus(wire: $0) } ?? .cancelled })
            }
        }
    }

    /// Whose calls: the install, and the customer when one is identified.
    private func ownCallsFields() -> [(String, WireJSON)] {
        var fields: [(String, WireJSON)] = [("installId", .string(installId))]
        if let value = identity.snapshot().value { fields.append(("identity", .object([("value", .string(value))]))) }
        return fields
    }

    private func fetchSession(_ completion: @escaping (Result<GraineSessionConfig, Error>) -> Void) {
        let endpoint = GraineProtocol.trimTrailingSlashes(config.baseUrl) + "/api/embed/session"
        guard let url = URL(string: endpoint) else {
            completion(.failure(GraineError("baseUrl \"\(config.baseUrl)\" is not a URL.")))
            return
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["publishableKey": config.publishableKey], options: [])
        let task = urlSession.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = JSON.object(from: data)
            if let message = GraineSessionConfig.errorMessage(status: status, body: body) {
                completion(.failure(GraineError(message)))
                return
            }
            completion(.success(GraineSessionConfig.parse(body ?? [:])))
        }
        task.resume()
    }

    // MARK: - The design, light or dark

    /**
     * The device switched appearance (or reported it for the first time). The
     * engine's host view reports it from inside the window, where the app's own
     * override applies; the lifecycle reads it again on each return. Main thread.
     */
    func deviceAppearanceChanged(dark: Bool?) {
        if dark == deviceDark { return }
        deviceDark = dark
        repickTheme()
    }

    /// Main thread. Tells listeners only when the tokens actually changed.
    private func repickTheme() {
        let next = session?.design?.tokens(deviceDark: deviceDark)
        stateLock.lock()
        let changed = next != themeValue
        themeValue = next
        stateLock.unlock()
        if changed, next != nil { notifyListeners { $0.onTheme(next) } }
    }

    // MARK: - The app's lifecycle

    /// Main thread. `true` on return to the foreground, `false` on entering the background.
    func onForegroundChange(_ watch: @escaping (Bool) -> Void) -> () -> Void {
        let id = UUID()
        foregroundWatchers[id] = watch
        return { [weak self] in
            guard let self = self else { return }
            self.onMain { self.foregroundWatchers.removeValue(forKey: id) }
        }
    }

    private func setForeground(_ value: Bool) {
        if foreground == value { return }
        foreground = value
        for watch in Array(foregroundWatchers.values) { watch(value) }
    }

    #if os(iOS)
    /**
     * Background, not inactive. iOS reports `inactive` for the app switcher, a
     * pulled-down notification and — the one that matters — the moment a
     * permission dialog appears; ending on it would hang up the call that asked
     * for the microphone.
     */
    private func watchLifecycle() {
        foreground = UIApplication.shared.applicationState != .background
        deviceAppearanceChanged(dark: GraineInApp.windowIsDark())
        tapCapture.attach(to: GraineVoice.keyWindow())
        let center = NotificationCenter.default
        lifecycleTokens.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // The window exists by now on a cold start, and may be a new one after a scene came back.
            self?.tapCapture.attach(to: GraineVoice.keyWindow())
        })
        lifecycleTokens.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.setForeground(false) })
        lifecycleTokens.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.setForeground(true)
            // The customer may have switched to dark in Control Centre while the app was away.
            self?.deviceAppearanceChanged(dark: GraineInApp.windowIsDark())
        })
    }

    /**
     * Fetch the faces the design draws with, in either scheme — except a
     * family the app ships itself, which wins over the download (DESIGN.md
     * "Fonts"): one it maps in `GraineConfig.fonts`, or one it bundles under
     * the family's own name. Asked before anything of ours is registered, so
     * a family found installed here is the app's.
     */
    private func loadFonts(for design: GraineDesign) {
        let own = config.fonts.keys
        let wanted = GraineFonts.faces(for: design, origin: config.baseUrl).filter { face in
            !own.contains { $0.caseInsensitiveCompare(face.family) == .orderedSame }
                && UIFont.fontNames(forFamilyName: face.family).isEmpty
        }
        fonts.load(wanted)
    }

    /// The key window's light or dark; nil when it has not said.
    static func windowIsDark() -> Bool? {
        isDark(GraineVoice.keyWindow()?.traitCollection.userInterfaceStyle ?? UITraitCollection.current.userInterfaceStyle)
    }

    static func isDark(_ style: UIUserInterfaceStyle) -> Bool? {
        switch style {
        case .dark: return true
        case .light: return false
        default: return nil
        }
    }
    #endif

    // MARK: - Helpers

    func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    static func wallClockMs() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }

    /// Milliseconds on a clock that never jumps: for timers, never for timestamps.
    static func uptimeMs() -> Double {
        ProcessInfo.processInfo.systemUptime * 1000
    }

    /// An error as one sentence for a developer: its description, or its type and case.
    static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription, !text.isEmpty {
            return text
        }
        if type(of: error) is NSError.Type {
            return (error as NSError).localizedDescription
        }
        return String(describing: error)
    }
}

/// A registered handler, and the token that lets only its own unregister remove it.
struct RegisteredAction {
    typealias Run = ([String: Any], @escaping (GraineActionResult) -> Void) throws -> Void
    let token: UUID
    let run: Run
}

/// One action in flight: answered at most once, whichever of the handler and the deadline comes first.
private final class ActionCall {
    var done = false
    var deadline: DispatchWorkItem?
}

private final class WeakListener {
    weak var value: GraineListener?
    init(_ value: GraineListener) { self.value = value }
}

struct GraineError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
