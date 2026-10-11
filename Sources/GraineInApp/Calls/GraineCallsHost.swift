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

    /// The customer calls the agent: `{reason?, variables?}`. The call's id, or nil when not configured or a call is live.
    public func startCall(_ options: [String: Any]?) -> String? {
        onMainSync { core.startCall(options) }
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

    // MARK: - What the agent knows

    /// Who is signed in (`GraineInApp.identify`); nil on sign-out.
    public func setIdentity(_ traits: [String: Any]?) {
        onMain { self.core.setIdentity(traits) }
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
        calls?.configure(GraineCallsConfig(
            displayName: options.displayName,
            ringtoneSound: options.ringtoneSound,
            iconTemplateImageData: options.iosIconTemplate.flatMap { UIImage(named: $0)?.pngData() },
            includesCallsInRecents: options.iosIncludesCallsInRecents,
            ringTimeout: options.ringTimeout
        ))
    }

    func enableVoIPPushes(onToken: @escaping (String?) -> Void) {
        calls?.enableVoIPPushes(onToken: onToken)
    }

    func startCall(reason: String?, variables: [String: Any]) -> String? {
        calls?.startCall(reason: reason, variables: variables)
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

    func setVariables(_ values: [String: Any?]) {
        graine?.setVariables(values)
    }

    func setScreen(_ screen: GraineScreen?) {
        graine?.setScreen(screen)
    }

    func registerAction(_ name: String, handler: @escaping GraineInApp.DeferredActionHandler) -> () -> Void {
        guard let graine = graine else { return {} }
        return graine.registerAction(name, deferred: handler)
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
            caption: calls.caption,
            connectedAt: calls.connectedAt
        )
    }

    var appActive: Bool {
        UIApplication.shared.applicationState == .active
    }

    func nextTurn(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
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
        let controller = UIHostingController(rootView: GraineCallView(calls: calls))
        controller.modalPresentationStyle = .fullScreen
        // The call screen is dark whatever the app's appearance; so is the status bar over it.
        controller.overrideUserInterfaceStyle = .dark
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
