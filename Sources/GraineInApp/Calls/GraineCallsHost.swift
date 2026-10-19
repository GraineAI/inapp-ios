#if os(iOS)
import Combine
import SwiftUI
import UIKit

/**
 * CALLS FROM REACT NATIVE AND FLUTTER: the one object their call packages
 * drive this SDK's calls (`GraineCalls`) through, in JSON-safe values —
 * strings, numbers, booleans, null, lists and string-keyed maps.
 *
 * A native app does not use it: `GraineInApp.shared.calls` is the Swift API.
 * The packages for React Native (`@graineai/inapp-react-native-calls`) and
 * Flutter (`graine_inapp`) call it and only marshal values; every rule — the
 * options, the snapshot, where events go, how actions are answered — is here,
 * inside the SDK, where its tests cover it.
 *
 *     GraineCallsHost.shared.restore()      // at launch, before any JavaScript or Dart runs
 *     try GraineCallsHost.shared.configure(["publishableKey": "pk_…", "displayName": "Acme"])
 *     let sink = GraineCallsHost.shared.addSink { event, payload in … }
 *
 * Several agents in one app: `configure` names the others under `agents`
 * (`{"sales": {"publishableKey": "pk_…"}}`), `startCall` takes `{agent:
 * "sales"}`, and a ring Graine sends rings with the agent it is for. The
 * snapshot, `incoming`, `outcome` and `action` say which: `agent` is the
 * call's agent by name ("default" for the default one). The wrapper's actions
 * and variables reach every agent.
 *
 * Permissions and setup: `callPermissions`, `requestCallPermissions`,
 * `openCallSettings` and `callSetupProblems`, as JSON-safe maps.
 *
 * Events: `state` (the snapshot, at most once per turn of the main loop),
 * `outcome`, `incoming`, `voipToken` and `action`. Main thread: a call from
 * another thread hops there first (`configure`, `restore`, `snapshot`,
 * `startCall` and `addSink` wait for their answer), and events are sent on it.
 */
@objc(GraineCallsHost)
public final class GraineCallsHost: NSObject {
    /// One per process, like the SDK instance it drives.
    @objc public static let shared = GraineCallsHost()

    /// Receives every event: its name (`state`, `outcome`, `incoming`, `voipToken`, `action`) and its payload. Main thread.
    public typealias Sink = (_ event: String, _ payload: [String: Any]) -> Void

    private let device = CallsHostDevice()
    private let core: CallsHostCore

    private override init() {
        core = CallsHostCore(platform: device, store: CallsHostStore(defaults: .standard))
        super.init()
        device.core = core
    }

    // MARK: - Setting up

    /**
     * Apply the options the last `configure` kept, at launch — before any
     * JavaScript or Dart runs — and enable VoIP pushes again if they were, so
     * a VoIP push that woke a terminated app rings. True when something was
     * restored; false when nothing was kept, or this launch is configured.
     */
    @objc @discardableResult
    public func restore() -> Bool {
        onMainSync { core.restore() }
    }

    /**
     * Configure the calls and keep the options for the next cold start. The
     * first call makes the SDK instance; later ones update the calls. Throws
     * `GraineCallsHostError` (`invalid_options`), naming the option that is wrong.
     */
    public func configure(_ options: [String: Any]?) throws {
        try onMainSync { try core.configure(options) }
    }

    /// The call as a call screen draws it: every key always present.
    public func snapshot() -> [String: Any] {
        onMainSync { core.snapshot() }
    }

    /// Receive the agent's calls as VoIP pushes, now and at every launch after. The token arrives as `voipToken` — again on every call, the last one known.
    public func enableVoIPPushes() {
        onMain { self.core.enableVoIPPushes() }
    }

    /// Android rings from a push it is handed. On iOS a VoIP push reaches PushKit, and this SDK, natively: always false.
    public func handlePush(_ data: [String: Any]?) -> Bool {
        false
    }

    // MARK: - The call

    /// The customer calls the agent: `{reason?, variables?, agent?}`. The call's id, or nil when not configured, a call is live, or no agent has that name.
    public func startCall(_ options: [String: Any]?) -> String? {
        onMainSync { core.startCall(options) }
    }

    /**
     * Get the agent's next call ready before the customer taps:
     * `{reason?, variables?, agent?}`, as `startCall` takes them. Cheap to ask
     * whenever a screen that offers a call appears; nothing is dialled or
     * billed until `startCall`. Nothing when not configured or a call is live.
     */
    public func prepareCall(_ options: [String: Any]?) {
        onMain { self.core.prepareCall(options) }
    }

    public func answer() {
        onMain { self.core.answer() }
    }

    /// Decline the ringing call (iOS: `end` while it rings).
    public func decline() {
        onMain { self.core.decline() }
    }

    public func end() {
        onMain { self.core.end() }
    }

    public func setMuted(_ muted: Bool) {
        onMain { self.core.setMuted(muted) }
    }

    public func setSpeaker(_ on: Bool) {
        onMain { self.core.setSpeaker(on) }
    }

    // MARK: - Permissions and setup

    /// The call permissions: `{microphone, notifications, fullScreen}`, each `granted`, `denied`, `blocked` or `notNeeded`. Readable before `configure`.
    public func callPermissions() -> [String: Any] {
        onMainSync { core.callPermissions() }
    }

    /// Ask for the call permissions the system can still ask for, when the app chooses; `done` gets them as they stand after, on the main thread.
    public func requestCallPermissions(_ done: @escaping ([String: Any]) -> Void) {
        onMain { self.core.requestCallPermissions(done) }
    }

    /// Open the Settings page for `microphone`, `notifications` or `fullScreen`: true when one was asked to open.
    public func openCallSettings(_ item: String?) -> Bool {
        onMainSync { core.openCallSettings(item) }
    }

    /// What the app's setup still lacks for calls: `[{code, message}]`, empty when nothing is missing (and before `configure`).
    public func callSetupProblems() -> [[String: Any]] {
        onMainSync { core.callSetupProblems() }
    }

    // MARK: - What the agent knows

    /// Who is signed in (`GraineInApp.identify`); nil on sign-out.
    public func setIdentity(_ traits: [String: Any]?) {
        onMain { self.core.setIdentity(traits) }
    }

    /// The current customer's memory choice (`GraineInApp.setMemory`): false — their conversations are neither remembered nor recalled.
    public func setMemory(_ enabled: Bool) {
        onMain { self.core.setMemory(enabled) }
    }

    /**
     * This install's id: a UUID kept in the Keychain (this device only,
     * through reinstalls) — the one the native calls send. A JavaScript or
     * Dart SDK sends the same one on its own requests, so a device is one
     * install whichever layer speaks. Nil before `configure` or `restore`.
     */
    public func installId() -> String? {
        onMainSync { core.installId() }
    }

    /// The runtime variables become exactly this map: a key the last map set and this one leaves out is removed.
    public func setVariables(_ values: [String: Any]?) {
        onMain { self.core.setVariables(values) }
    }

    /// The screen, as `{screen, title?, journey?, fields?, error?, data?, availableActions?}`; nil, or no screen name, for none.
    public func setScreen(_ screen: [String: Any]?) {
        onMain { self.core.setScreen(screen) }
    }

    /**
     * The actions the caller answers, and its sink (`addSink`'s token): each
     * request for one of them is sent as `action` to the sink that last listed
     * a non-empty set, and waits for `resolveAction` — within the SDK's own six
     * seconds. Names no longer listed are unregistered.
     */
    public func setActions(_ names: [String], sink: Int?) {
        onMain { self.core.setActions(names, sink: sink) }
    }

    /// The answer to an `action` request: `{status: "ok" | "refused" | "error", message?, data?}`. The first answer wins.
    public func resolveAction(_ requestId: String, result: [String: Any]?) {
        onMain { self.core.resolveAction(requestId, result) }
    }

    // MARK: - Events

    /// Start receiving events. Outcomes and rings that came while nothing listened are delivered to the first sink, at once.
    public func addSink(_ sink: @escaping Sink) -> Int {
        onMainSync { core.addSink(sink) }
    }

    /// Stop. Action requests this sink had not answered are refused.
    public func removeSink(_ token: Int) {
        onMain { self.core.removeSink(token) }
    }

    // MARK: - Helpers

    private func onMainSync<T>(_ work: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try work() }
        return try DispatchQueue.main.sync(execute: work)
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }
}

/**
 * THE HOST'S HANDS ON iOS: the SDK instance and its calls, the app's
 * lifecycle, and the SDK's call screen over the app's window. Main thread.
 */
private final class CallsHostDevice: NSObject, CallsHostPlatform, GraineCallsListener {
    weak var core: CallsHostCore?
    private var graine: GraineInApp?
    private var calls: GraineCalls?
    private var watching: AnyCancellable?
    private var activeObserver: NSObjectProtocol?
    private var screen: UIViewController?
    private var screenWanted = false

    /// While another presentation or dismissal is under way, presenting is tried again this often, this many times.
    private static let presentRetrySeconds = 0.3
    private static let presentRetries = 10

    /// The wrapper's actions, each registered on every agent: a call with any of them may ask for one.
    private struct HeldAction {
        let token: Int
        let handler: GraineInApp.DeferredActionHandler
        var offs: [() -> Void]
    }
    private var heldActions: [String: HeldAction] = [:]
    private var nextActionToken = 0
    /// The wrapper's runtime variables as they stand, for an agent configured after they were set.
    private var runtime: [String: Any] = [:]
    /// The agents that have the wrapper's actions and variables.
    private var fed: Set<ObjectIdentifier> = []

    /// The default agent and every other one configured beside it.
    private var everyAgent: [GraineInApp] { graine?.peers ?? [] }

    /// An agent configured since the actions and variables were handed over gets them now.
    private func feedNewAgents() {
        for agent in everyAgent where !fed.contains(ObjectIdentifier(agent)) {
            fed.insert(ObjectIdentifier(agent))
            for name in heldActions.keys.sorted() {
                guard let handler = heldActions[name]?.handler else { continue }
                heldActions[name]?.offs.append(agent.registerAction(name, deferred: handler))
            }
            if !runtime.isEmpty { agent.setVariables(runtime.mapValues { Optional($0) }) }
        }
    }

    deinit {
        if let token = activeObserver { NotificationCenter.default.removeObserver(token) }
    }

    // MARK: The instance and its calls

    func makeInstance(_ options: CallsHostOptions) -> (publishableKey: String, baseUrl: String, debug: Bool) {
        let graine = GraineInApp.configure(GraineConfig(
            baseUrl: options.baseUrl,
            publishableKey: options.publishableKey,
            appVersion: options.appVersion,
            debug: options.debug
        ))
        self.graine = graine
        let calls = graine.calls
        self.calls = calls
        calls.addListener(self)
        // Fired before each published property changes; the core reads them once the turn is over.
        watching = calls.objectWillChange.sink { [weak self] _ in self?.core?.engineChanged() }
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.core?.appBecameActive()
        }
        return (graine.config.publishableKey, graine.config.baseUrl, graine.config.debug)
    }

    func configureCalls(_ options: CallsHostOptions) {
        // The other agents first (configuring one twice changes nothing), so a ring for one finds it.
        for name in options.agents.keys.sorted() {
            guard let agent = options.agents[name] else { continue }
            GraineInApp.configure(GraineConfig(
                baseUrl: agent.baseUrl, publishableKey: agent.publishableKey, appVersion: options.appVersion, debug: options.debug
            ), name: name)
        }
        // They answer the wrapper's actions and read its variables too.
        feedNewAgents()
        calls?.configure(GraineCallsConfig(
            displayName: options.displayName,
            ringtoneSound: options.ringtoneSound,
            iconTemplateImageData: options.iosIconTemplate.flatMap { UIImage(named: $0)?.pngData() },
            includesCallsInRecents: options.iosIncludesCallsInRecents,
            ringTimeout: options.ringTimeout,
            callTransport: options.callTransport
        ))
    }

    func enableVoIPPushes(onToken: @escaping (String?) -> Void) {
        calls?.enableVoIPPushes(onToken: onToken)
    }

    func startCall(reason: String?, variables: [String: Any], agent: String?) -> String? {
        calls?.startCall(reason: reason, variables: variables, agent: agent)
    }

    func prepareCall(reason: String?, variables: [String: Any], agent: String?) {
        calls?.prepareCall(reason: reason, variables: variables, agent: agent)
    }

    func answer() {
        calls?.answer()
    }

    func end() {
        calls?.end()
    }

    func setMuted(_ muted: Bool) {
        calls?.setMuted(muted)
    }

    func setSpeaker(_ on: Bool) {
        calls?.setSpeaker(on)
    }

    func identify(_ traits: [String: Any]?) {
        graine?.identify(traits?.mapValues { Optional($0) })
    }

    func setMemory(_ enabled: Bool) {
        graine?.setMemory(enabled)
    }

    var installId: String? {
        graine?.installId
    }

    /// On every agent: the wrapper keeps the agent on the call's variables here, whichever agent that is.
    func setVariables(_ values: [String: Any?]) {
        feedNewAgents()
        for (key, value) in values {
            if let value = value { runtime[key] = value } else { runtime.removeValue(forKey: key) }
        }
        for agent in everyAgent { agent.setVariables(values) }
    }

    func setScreen(_ screen: GraineScreen?) {
        graine?.setScreen(screen)
    }

    /// On every agent: a call with any of them may ask for it.
    func registerAction(_ name: String, handler: @escaping GraineInApp.DeferredActionHandler) -> () -> Void {
        guard graine != nil else { return {} }
        feedNewAgents()
        heldActions.removeValue(forKey: name)?.offs.forEach { $0() }
        nextActionToken += 1
        let token = nextActionToken
        let offs = everyAgent.map { $0.registerAction(name, deferred: handler) }
        heldActions[name] = HeldAction(token: token, handler: handler, offs: offs)
        return { [weak self] in
            guard let self = self, let held = self.heldActions[name], held.token == token else { return }
            held.offs.forEach { $0() }
            self.heldActions.removeValue(forKey: name)
        }
    }

    func callFields() -> CallsHostSnapshot {
        guard let calls = calls else { return CallsHostSnapshot() }
        return CallsHostSnapshot(
            state: calls.state,
            callId: calls.callId,
            direction: calls.direction,
            callerName: calls.callerName,
            muted: calls.muted,
            speakerOn: calls.speakerOn,
            agentSpeaking: calls.agentSpeaking,
            reconnecting: calls.isReconnecting,
            caption: calls.caption,
            connectedAt: calls.connectedAt,
            agent: calls.agent,
            transport: calls.transport?.rawValue,
            transportFallbackReason: calls.transportFallbackReason
        )
    }

    func agentName(forCall callId: String) -> String? {
        calls?.agentName(forCall: callId)
    }

    var callHosted: Bool {
        calls?.hosted ?? false
    }

    var appActive: Bool {
        UIApplication.shared.applicationState == .active
    }

    var missedCallPending: Bool {
        calls?.missedCall != nil
    }

    func nextTurn(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }

    func callPermissions() -> GraineCallPermissions {
        calls?.callPermissions ?? GraineCalls.systemCallPermissions()
    }

    func requestCallPermissions(_ done: @escaping (GraineCallPermissions) -> Void) {
        if let calls = calls {
            calls.requestCallPermissions(completion: done)
            return
        }
        // No instance yet: the system's microphone, asked the same way.
        guard SystemMicPermission().permission == .undetermined else {
            done(GraineCalls.systemCallPermissions())
            return
        }
        GraineVoice.requestMic { _ in done(GraineCalls.systemCallPermissions()) }
    }

    func openCallSettings(_ item: GraineCallPermission) -> Bool {
        GraineCalls.openSettings(item)
    }

    func callSetupProblems() -> [GraineCallSetupProblem] {
        calls?.callSetupProblems ?? []
    }

    func after(_ seconds: TimeInterval, _ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: block)
    }

    // MARK: GraineCallsListener

    func onIncomingCall(_ call: GraineIncomingCall) {
        core?.incoming(call)
    }

    func onCallState(_ state: GraineCallState, callId: String?) {
        core?.callStateChanged(state)
    }

    func onCallOutcome(_ outcome: GraineCallOutcome, callId: String) {
        core?.outcome(outcome, callId: callId)
    }

    // MARK: The SDK's call screen

    func presentCallScreen() {
        screenWanted = true
        showScreen(attempt: 0)
    }

    func dismissCallScreen() {
        screenWanted = false
        guard let shown = screen else { return }
        screen = nil
        // From the controller that presented it, so anything the app put above it goes too.
        shown.presentingViewController?.dismiss(animated: true)
    }

    /// Full screen, over whatever the app shows on top.
    private func showScreen(attempt: Int) {
        guard screenWanted, screen == nil, let calls = calls else { return }
        guard let top = CallsHostDevice.topViewController(), !top.isBeingPresented, !top.isBeingDismissed else {
            // UIKit drops a presentation asked for in the middle of another one: ask again shortly.
            guard attempt < CallsHostDevice.presentRetries else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + CallsHostDevice.presentRetrySeconds) { [weak self] in
                self?.showScreen(attempt: attempt + 1)
            }
            return
        }
        // The brand's call screen for the device's appearance; the status bar over it follows its background.
        let deviceDark = GraineInApp.windowIsDark()
        let controller = UIHostingController(rootView: GraineCallView(calls: calls, deviceDark: deviceDark))
        controller.modalPresentationStyle = .fullScreen
        controller.overrideUserInterfaceStyle = GraineCallView.drawsDark(deviceDark: deviceDark, graine: calls.callAgent ?? graine) ? .dark : .light
        screen = controller
        top.present(controller, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        var top = GraineVoice.keyWindow()?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }
}
#endif
