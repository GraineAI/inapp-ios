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
        fonts: [String: String] = [:]
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
     * the screen off. Main thread only.
     */
    public private(set) lazy var calls: GraineCalls = GraineCalls(graine: self)
    #endif

    /// A native call (`calls`) is live: the web view engine must not start one beside it. Main thread.
    var nativeCallLive = false

    /// The design's typefaces, fetched and registered by the SDK; every surface draws from it.
    let fonts: GraineFontStore

    /// Internal so tests can build an instance without the process-wide one.
    init(config: GraineConfig, fonts: GraineFontStore = GraineFontStore()) {
        self.config = config
        self.variables = VariableStore(buildTime: config.variables.mapValues { Optional($0) })
        self.appFriction = config.friction
        self.fonts = fonts
    }

    deinit {
        for token in lifecycleTokens { NotificationCenter.default.removeObserver(token) }
    }

    // MARK: - The one instance

    private static let instanceLock = NSLock()
    private static var instance: GraineInApp?

    /**
     * Create the one instance. Call once, at launch (App.init or
     * application(_:didFinishLaunchingWithOptions:)). A second call returns
     * the first instance unchanged.
     */
    @discardableResult
    public static func configure(_ config: GraineConfig) -> GraineInApp {
        instanceLock.lock()
        if let existing = instance {
            instanceLock.unlock()
            return existing
        }
        let created = GraineInApp(config: config)
        instance = created
        instanceLock.unlock()
        created.begin()
        return created
    }

    /// The instance configure() created, or nil before it.
    public static var current: GraineInApp? {
        instanceLock.lock()
        defer { instanceLock.unlock() }
        return instance
    }

    /// The instance configure() created. Traps if configure() was never called.
    public static var shared: GraineInApp {
        guard let existing = current else {
            fatalError("GraineInApp.configure(_:) has not been called. Call it once, at launch.")
        }
        return existing
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

    /// Who is signed in. Traits become prompt variables and land on the call record. nil on sign-out.
    public func identify(_ traits: [String: Any?]?) {
        variables.setIdentity(traits)
        announceVariables()
        scheduleContext()
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

    /// A product event that informs without interrupting. Rides the next context frame; the last 10 are kept.
    public func track(_ name: String, data: [String: Any] = [:]) {
        guard !name.isEmpty else { return }
        var event: [String: Any] = ["name": name, "at": GraineInApp.wallClockMs()]
        if !data.isEmpty { event["data"] = JSON.normalize(data) }
        stateLock.lock()
        recentEvents.append(event)
        if recentEvents.count > GraineInApp.recentEventsCap {
            recentEvents.removeFirst(recentEvents.count - GraineInApp.recentEventsCap)
        }
        stateLock.unlock()
        scheduleContext()
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
        onMain {
            self.friction.onInteraction(now: now)
            self.armStall()
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

    /// A call connected or ended. The idle clock only runs during a call. Main thread.
    func callStateChanged(live: Bool) {
        friction.onCall(live: live, now: GraineInApp.uptimeMs())
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
        #if os(iOS)
        voice.reportEvent(signal.name, detail: signal.detail, data: [
            "cooldown_seconds": signal.cooldownSeconds,
            "max_per_session": signal.maxPerSession,
        ])
        #endif
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
            variables.setDashboardDefaults(session.variables.mapValues { Optional($0) })
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
        let center = NotificationCenter.default
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
