#if os(iOS)
import AVFoundation
import Combine
import UIKit
import WebKit

/**
 * THE CALL — a hosted page in a WKWebView this SDK owns, one invisible point big.
 *
 * Why a web view and not a native WebRTC stack: every fix to the audio path —
 * the TURN relay, the dead-media watchdog, connection quality, the WebSocket
 * fallback, echo handling — lives in that page and reaches your installed app
 * the day it ships, with no release. A native media stack would make each of
 * those an App Store update. The trade is a page load, which this class
 * prewarms at attach time and caches per deployment, so a tap costs one SIP
 * registration and an INVITE.
 *
 * Laid out at 1×1 with alpha 0 rather than hidden: a hidden view, or one
 * removed from the window, can have its media suspended, which would kill the
 * call the moment your own UI hid it. Attach it to the WINDOW, not to a view a
 * screen owns: a full-screen presentation removes the presenter's views from
 * the window, and a WKWebView out of a window goes deaf.
 *
 * Observable (SwiftUI) and reported through GraineListener. Every public method
 * belongs on the main thread; one called from elsewhere hops there.
 */
public final class GraineVoice: NSObject, ObservableObject {

    // MARK: - State you can read, and hear about through GraineListener

    @Published public private(set) var connected = false { didSet { refreshConnectWait() } }
    @Published public private(set) var connecting = false { didSet { refreshConnectWait() } }
    @Published public private(set) var muted = false
    /// The page said graine:ready: a start now is an INVITE away.
    @Published public private(set) var ready = false { didSet { refreshConnectWait() } }
    @Published public private(set) var quality: GraineConnectionQuality = .unknown
    /// The page's own view of the network; nil until it has said.
    @Published public private(set) var online: Bool? = nil
    /// The network interrupted the call and it is being re-established. Not an end.
    @Published public private(set) var reconnecting = false
    @Published public private(set) var connectivity: GraineConnectivity = .loading
    /**
     * What has been said this call, oldest first. A live turn is replaced as
     * its words arrive, not appended; capped at 12; cleared when a call starts
     * — a transcript outliving its call is a privacy question, not a feature.
     */
    @Published public private(set) var captions: [GraineCaption] = []
    /**
     * The captions switch — CC. The bar shows the line being said only while
     * it is on. On by default: a caption nobody asked to hide is an
     * accessibility default. What is said is kept (`captions`) either way.
     */
    @Published public private(set) var captionsOn = true
    /// The customer has finished a line and the agent has not started its answer. See `phase`.
    @Published private(set) var awaitingAgent = false
    /**
     * WHERE A CALL BEING PLACED IS, as the engine reports it (`graine:progress`):
     * registering, dialling, retrying (a fresh connection after an unanswered
     * first try — on mobile data, usually one the phone dropped while idle) or
     * switching (to the other transport). Nil outside a connect.
     */
    @Published public private(set) var connectStage: GraineConnectStage? = nil
    /**
     * The customer has waited on this connect for `GraineConfig.Timing.slowConnectMs`
     * (4 s by default) — their bar open with the page not there yet, or a call
     * they asked for not yet answered. Say so honestly ("Still connecting…"),
     * not with a faster spinner. Cleared the moment it lands or they stop waiting.
     */
    @Published public private(set) var slowConnect = false
    /**
     * The last start could not be connected at all — not on WebRTC, not on the
     * fallback (`graine:progress` `failed`). Distinct from an error (a setting
     * someone must change): the network may well be better in a moment, so
     * `start()` simply tries again. Cleared by a start, an answered call,
     * `end()` and `detach()`.
     */
    @Published public private(set) var callFailed = false { didSet { refreshConnectWait() } }

    /// Whether the engine is mounted.
    public var isAttached: Bool { webView != nil }

    /// Turn the captions on or off — for your own CC button. The call goes on.
    public func setCaptionsOn(_ on: Bool) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.setCaptionsOn(on) }
            return
        }
        if captionsOn != on { captionsOn = on }
    }

    /**
     * A voice UI of your own came on screen (`viewOpened()`) or left it
     * (`viewClosed()`) — `GraineAgentBar` says so itself. While one is open, a
     * page still loading is the customer's wait, reported as `slowConnect`.
     * Call them in pairs.
     */
    public func viewOpened() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.viewOpened() }
            return
        }
        viewerAppeared()
    }

    /// The UI from `viewOpened()` left the screen.
    public func viewClosed() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.viewClosed() }
            return
        }
        viewerDisappeared()
    }

    /// Forget what has been said (`captions`) without ending the call.
    public func clearCaptions() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.clearCaptions() }
            return
        }
        if !captions.isEmpty { captions = [] }
    }

    /**
     * What the call is doing, in one word — idle, connecting, reconnecting,
     * thinking, speaking or listening — for an app that draws its own bar.
     * `thinking` is the gap between the customer finishing and the agent
     * answering: draw `GraineLoader(moment: "thinking")` there, not a meter.
     */
    public var phase: GrainePhase {
        GrainePhase.of(
            reconnecting: reconnecting, connectivity: connectivity, connecting: connecting, ready: ready,
            connected: connected, agentSpeaking: CaptionLog.agentSpeaking(captions), awaitingAgent: awaitingAgent
        )
    }

    // MARK: - Internals

    private unowned let graine: GraineInApp
    private var webView: WKWebView?
    private var host: UIView?
    private weak var container: UIView?
    private var contentController: WKUserContentController?
    private var bridge: ScriptBridge?
    private var consoleBridge: ScriptBridge?
    private lazy var engineDelegate = EngineDelegate(voice: self)
    private var progressObservation: NSKeyValueObservation?

    private var pendingStart = false
    private var startedCall = false
    private var endNotified = true
    private var cacheKey = String(GraineInApp.wallClockMs())
    private var mountedIdle = true
    private var unwatch: [() -> Void] = []

    private let watchdog: LoadWatchdog
    private let ladder: RetryLadder
    /// How many voice bars are on screen: a connect is only somebody's wait while one is (see ConnectWait).
    private var viewers = 0
    private lazy var slowClock = SlowConnectClock(
        delayMs: graine.config.timing.slowConnectMs,
        schedule: { ms, fire in
            let item = DispatchWorkItem(block: fire)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms), execute: item)
            return { item.cancel() }
        },
        onChange: { [weak self] slow in
            guard let self = self, self.slowConnect != slow else { return }
            self.slowConnect = slow
        }
    )
    private var checkLoadItem: DispatchWorkItem?
    private var retryItem: DispatchWorkItem?
    private var endWatchdogItem: DispatchWorkItem?
    private var backgroundConfirmItem: DispatchWorkItem?
    private var audioRestoreItem: DispatchWorkItem?
    private var savedAudio: SavedAudioSession?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    /// The last component the agent drew that nobody has answered — for a widget view that mounts later. The instance keeps it, for either conversation.
    var pendingWidgetFrame: [String: Any]? { graine.componentFrame }

    init(graine: GraineInApp) {
        self.graine = graine
        let timing = graine.config.timing
        watchdog = LoadWatchdog(stallMs: Int64(timing.stallMs), bootMs: Int64(timing.bootMs), hardCapMs: Int64(timing.hardCapMs))
        ladder = RetryLadder(delaysMs: timing.retryDelaysMs.map { Int64($0) })
        super.init()
    }

    // MARK: - Mounting

    /**
     * Mount the engine. Loads the page idle — nothing is registered, nothing is
     * dialled, no microphone — so a start() later is an INVITE away rather
     * than a page load away.
     *
     * Pass your key window. Attaching somewhere new moves the engine and ends
     * any call in progress.
     */
    public func attach(to view: UIView) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.attach(to: view) }
            return
        }
        if container === view && webView != nil { return }
        detach()
        container = view

        let configuration = WKWebViewConfiguration()
        // The agent speaks first, and nothing on a 1×1 view can be tapped to satisfy a gesture requirement.
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let content = WKUserContentController()
        content.addUserScript(WKUserScript(source: EngineScripts.bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let messages = ScriptBridge(voice: self, kind: .messages)
        content.add(messages, name: GraineProtocol.messageHandlerName)
        bridge = messages
        if graine.config.debug {
            content.addUserScript(WKUserScript(source: EngineScripts.consoleForwarder, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            let console = ScriptBridge(voice: self, kind: .console)
            content.add(console, name: EngineScripts.consoleHandlerName)
            consoleBridge = console
        }
        configuration.userContentController = content
        contentController = content

        let frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        let engine = WKWebView(frame: frame, configuration: configuration)
        engine.navigationDelegate = engineDelegate
        engine.uiDelegate = engineDelegate
        engine.isOpaque = false
        engine.backgroundColor = .clear
        engine.scrollView.backgroundColor = .clear
        engine.scrollView.isScrollEnabled = false
        engine.isUserInteractionEnabled = false
        engine.accessibilityElementsHidden = true
        if graine.config.debug {
            // In debug, the engine is inspectable in Safari's Develop menu like any page.
            if #available(iOS 16.4, *) { engine.isInspectable = true }
        }

        let hostView = EngineHostView(frame: frame)
        // It lives in the window for as long as the engine does, so its traits are the window's:
        // the one place a UIKit app's light/dark switch (or override) can be heard.
        hostView.onStyleChange = { [weak self] style in
            self?.graine.deviceAppearanceChanged(dark: GraineInApp.isDark(style))
        }
        hostView.alpha = 0
        hostView.isUserInteractionEnabled = false
        hostView.accessibilityElementsHidden = true
        hostView.addSubview(engine)
        view.addSubview(hostView)
        webView = engine
        host = hostView

        // PROOF THE LOAD IS ALIVE: without progress the watchdog has only a clock,
        // and a slow download is indistinguishable from a dead one.
        progressObservation = engine.observe(\.estimatedProgress, options: [.new]) { [weak self] observed, _ in
            let percent = Int((observed.estimatedProgress * 100).rounded(.down))
            DispatchQueue.main.async { self?.watchdog.progress(percent, now: GraineVoice.uptimeMs()) }
        }

        unwatch = [
            graine.onVariables { [weak self] variables in
                // WHEN THE VARIABLES CHANGE, THE PAGE HEARS IT — a sign-in after the page
                // loaded must not leave the next call greeting a stranger.
                guard let self = self, self.ready else { return }
                self.post(GraineProtocol.out(GraineProtocol.Out.variables, ["variables": variables]))
            },
            graine.onContext { [weak self] frame in
                guard let self = self, self.connected else { return }
                self.postContext(frame)
            },
            graine.onIdentity { [weak self] in
                // The page reads it when it mints its next session: a sign-in after the page loaded reaches the next call.
                guard let self = self, self.ready else { return }
                self.postIdentity()
            },
            graine.onForegroundChange { [weak self] foreground in
                self?.foregroundChanged(foreground)
            },
        ]
        load(idle: true)
        refreshConnectWait()
        graine.tapCapture.attach(to: (view as? UIWindow) ?? view.window ?? GraineVoice.keyWindow())
    }

    /// Mount the engine in the app's key window. Call once a window exists — from a view's onAppear, say.
    public func attach() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.attach() }
            return
        }
        guard let window = GraineVoice.keyWindow() else {
            report { $0.onError("GraineVoice.attach() found no window yet. Call it once your UI is on screen, or pass one to attach(to:).") }
            return
        }
        attach(to: window)
    }

    /// Remove the engine. Hangs up first — a call must never outlive its UI.
    public func detach() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.detach() }
            return
        }
        if webView != nil { post(GraineProtocol.out(GraineProtocol.Out.endCall)) }
        unwatch.forEach { $0() }
        unwatch = []
        cancelTimers()
        teardownEngine(grace: true)
        ready = false
        startedCall = false
        pendingStart = false
        if !graine.chat.carriesConversation { graine.forgetComponents() }
        if !captions.isEmpty { captions = [] }
        if awaitingAgent { awaitingAgent = false }
        setAttempt(attempt.after(.ended))
        setCall(connected: false, connecting: false)
        scheduleAudioRestore()
    }

    // MARK: - The call

    /**
     * Place the call. Asks for the microphone first if the app does not hold
     * it — the permission is settled BEFORE the page opens its session,
     * because the page greets on connect. Before the page is ready the start is
     * held and fired on ready, which is what the customer meant.
     */
    public func start() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.start() }
            return
        }
        guard webView != nil else {
            report { $0.onError("GraineVoice.attach(to:) must be called before start().") }
            return
        }
        // The two engines never hold a call at once: a native call (GraineCalls) owns the audio until it ends.
        guard !graine.nativeCallLive else {
            report { $0.onError("A call is in progress on GraineCalls; end it before starting one here.") }
            return
        }
        // One conversation at a time, across every agent: a call takes over from any chat and any other agent's call.
        graine.takeConversation(for: .voice)
        // A new call, not a continuation: the last one's words must not appear above this one's first line.
        if !captions.isEmpty { captions = [] }
        if awaitingAgent { awaitingAgent = false }
        graine.forgetComponents()
        // A new attempt: the last one's failure and stage are not news.
        setAttempt(attempt.after(.started))
        setCall(connected: connected, connecting: true)
        if !GraineVoice.micGranted() {
            pendingStart = true
            GraineVoice.requestMic { [weak self] granted in
                guard let self = self, self.pendingStart else { return }   // ended while the prompt was up
                if !granted {
                    self.pendingStart = false
                    self.setCall(connected: false, connecting: false)
                    self.report { $0.onMicDenied(reason: "NotAllowedError") }
                    return
                }
                if self.ready {
                    self.pendingStart = false
                    self.beginCall()
                }
            }
            return
        }
        if !ready {
            pendingStart = true
            return
        }
        beginCall()
    }

    /**
     * Hang up. Guaranteed: if the page never confirms, the call is torn down
     * after a bounded wait — local state, onEnded, and a reload that drops the
     * media for certain. A start that was only being held is simply cancelled:
     * there is no media to drop, and a reload would cost the next start its
     * warm page.
     */
    public func end() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.end() }
            return
        }
        let wasHeld = pendingStart && !startedCall
        pendingStart = false
        // The customer is done with this attempt — the bar's hang-up or close. A failure it showed is
        // not news the next time the bar opens (the React Native bar closing clears it the same way).
        setAttempt(attempt.after(.ended))
        post(GraineProtocol.out(GraineProtocol.Out.endCall))
        endWatchdogItem?.cancel()
        endWatchdogItem = nil
        if connected || startedCall {
            let item = DispatchWorkItem { [weak self] in self?.forceEnd() }
            endWatchdogItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(graine.config.timing.endWatchdogMs), execute: item)
        } else if wasHeld || connecting {
            setCall(connected: false, connecting: false)
        }
    }

    /// Stop sending the customer's voice without ending the call.
    public func setMuted(_ value: Bool) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.setMuted(value) }
            return
        }
        muted = value
        post(GraineProtocol.out(GraineProtocol.Out.setMuted, ["muted": value]))
    }

    /**
     * The customer answered a component the agent drew. `summary` is the
     * sentence the agent hears ("Compare: Creta and Seltos") — without it
     * the tap lands and the conversation does not move.
     */
    public func answerWidget(widgetId: String, data: [String: Any], summary: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.answerWidget(widgetId: widgetId, data: data, summary: summary) }
            return
        }
        if let pending = graine.componentFrame, GraineInApp.componentId(pending) == widgetId { graine.forgetComponents() }
        post(GraineProtocol.out(GraineProtocol.Out.widgetResult, ["widgetId": widgetId, "data": data, "summary": summary]))
    }

    /**
     * Something happened that the agent may want to speak up about. Only
     * during a call: queued, it would open the NEXT conversation by announcing
     * a failure from the last one. The screen goes first — an event is about
     * the screen it happened on. `data` may carry `quiet`, `cooldown_seconds`
     * and `max_per_session`, which the runtime reads.
     */
    public func reportEvent(_ name: String, detail: String? = nil, data: [String: Any] = [:]) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.reportEvent(name, detail: detail, data: data) }
            return
        }
        guard connected else { return }
        if let frame = graine.currentContextFrame() { postContext(frame) }
        var payload = data
        if let detail = detail { payload["detail"] = detail }
        post(GraineProtocol.out(GraineProtocol.Out.appEvent, ["name": name, "data": payload]))
    }

    /// Reload the page and start the retry ladder over. For a "Try again" button.
    public func retry() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.retry() }
            return
        }
        ladder.reset()
        retryItem?.cancel()
        retryItem = nil
        setConnectivity(.loading, reason: nil)
        reloadEngine()
    }

    /// Forget the retained component — it was answered.
    func clearPendingWidget() {
        graine.forgetComponents()
    }

    // MARK: - Loading

    private func load(idle: Bool) {
        graine.loadSession { [weak self] session in
            guard let self = self, let engine = self.webView else { return }
            guard let session = session else {
                self.setConnectivity(.failed, reason: "session")
                return
            }
            self.mountedIdle = idle
            if let version = session.pageVersion { self.cacheKey = version }
            let address = GraineProtocol.engineUrl(
                baseUrl: self.graine.config.baseUrl,
                voiceAgentId: session.webcallAgentId,
                transport: self.graine.config.transport ?? session.preferredTransport,
                cacheKey: self.cacheKey,
                idle: idle,
                publishableKey: self.graine.config.publishableKey,
                accent: session.accent
            )
            guard let url = URL(string: address) else {
                self.setConnectivity(.failed, reason: "url")
                return
            }
            engine.load(URLRequest(url: url))
        }
    }

    /// A page that never loaded has no URL to reload: load it, which also refetches a session that failed.
    private func reloadEngine() {
        guard let engine = webView else { return }
        if engine.url == nil {
            load(idle: mountedIdle)
        } else {
            engine.reload()
        }
    }

    private func beginCall() {
        startedCall = true
        endNotified = true
        configureAudioSession()
        post(GraineProtocol.out(GraineProtocol.Out.startCall))
    }

    // MARK: - Delivering into the page

    private func post(_ message: [String: Any]) {
        guard let engine = webView else { return }
        let type = JSON.string(message["type"])
        if graine.config.debug { GraineLog.trace("→ page \(type) \(GraineProtocol.redactForLog(message))") }
        guard let js = GraineProtocol.deliver(message) else {
            GraineLog.error("Could not serialise \(type); it was not sent.")
            return
        }
        engine.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Who the customer is for memory: `{type: "graine:identity", value, installId, memory, timezone}`, used on the page's next session.
    private func postIdentity() {
        let f = graine.identityFields(callId: nil)
        post(GraineProtocol.out(GraineProtocol.Out.identity, [
            "value": f.value,
            "installId": f.installId,
            "memory": f.memory,
            "timezone": f.timezone,
        ]))
    }

    private func postContext(_ frame: [String: Any]) {
        var message = frame
        message["type"] = GraineProtocol.Out.appContext
        post(message)
    }

    // MARK: - What the page says

    fileprivate func receive(_ raw: String) {
        if graine.config.debug { GraineLog.trace("← page \(raw.prefix(600))") }
        guard let message = GraineProtocol.parse(raw) else { return }
        handle(message)
    }

    fileprivate func receiveConsole(_ line: String) {
        if graine.config.debug { GraineLog.trace("page console \(line)") }
    }

    private func handle(_ msg: PageMessage) {
        switch msg {
        case .ready:
            ready = true
            checkLoadItem?.cancel()
            checkLoadItem = nil
            ladder.reset()
            setConnectivity(.ready, reason: nil)
            // Who the customer is, before anything else: the greeting is composed from these
            // and nothing later can repair it.
            post(GraineProtocol.out(GraineProtocol.Out.variables, ["variables": graine.currentVariables()]))
            postIdentity()
            if let frame = graine.currentContextFrame() { postContext(frame) }
            if pendingStart && GraineVoice.micGranted() {
                pendingStart = false
                beginCall()
            } else if !startedCall {
                // Ready and idle: warm it — mint, load the SIP stack, REGISTER — so the tap is instant.
                post(GraineProtocol.out(GraineProtocol.Out.warm))
            }

        case let .call(isConnected, isConnecting):
            if isConnected {
                endNotified = false
                reconnecting = false
                // An answered call is not still retrying, and did not fail.
                setAttempt(attempt.after(.connected))
                endWatchdogItem?.cancel()
                endWatchdogItem = nil
            }
            // The page announces "not connected" as it loads. With a start queued behind it,
            // that is not idle — the customer pressed the button, and the bar must keep saying "connecting".
            let held = pendingStart && !isConnected
            setCall(connected: isConnected, connecting: isConnecting || held)
            if isConnected, let frame = graine.currentContextFrame() { postContext(frame) }
            if !isConnected && !isConnecting { startedCall = false }

        case .muted(let value):
            muted = value

        case let .caption(role, text, live):
            let line = GraineCaption(role: role, text: text, live: live)
            let awaiting = CaptionLog.awaitsAgent(awaitingAgent, after: line)
            if awaiting != awaitingAgent { awaitingAgent = awaiting }
            captions = CaptionLog.fold(captions, line)
            report { $0.onCaption(role: role, text: text, live: live) }

        case .widget(let widget):
            graine.componentArrived(widget)

        case .widgetPending(let hint):
            report { $0.onWidgetPending(hint) }

        case let .appAction(actionId, name, arguments):
            // The runtime is BLOCKED on this answer; it goes back the way the request came.
            graine.executeAction(name: name, arguments: arguments) { [weak self] result in
                self?.post(GraineProtocol.out(GraineProtocol.Out.appActionResult, [
                    "actionId": actionId,
                    "status": result.status.rawValue,
                    "message": result.message,
                    "data": result.data,
                ]))
            }

        case .ended:
            endWatchdogItem?.cancel()
            endWatchdogItem = nil
            reconnecting = false
            if awaitingAgent { awaitingAgent = false }
            setCall(connected: false, connecting: false)
            startedCall = false
            setQuality(.unknown)
            scheduleAudioRestore()
            if !endNotified {
                endNotified = true
                report { $0.onEnded() }
            }

        case .micDenied(let reason):
            pendingStart = false
            setCall(connected: false, connecting: false)
            report { $0.onMicDenied(reason: reason) }

        case let .transport(transport, requested, reason, text):
            report { $0.onTransport(transport, requested: requested, reason: reason, message: text) }
            // A MISCONFIGURATION IS AN ERROR, even though the call survived it: `not_configured`
            // never recovers on its own, and its only symptom is a call on the transport nobody chose.
            if reason == "not_configured", let text = text {
                report { $0.onError(text) }
            }

        case let .quality(rtt, jitter, loss):
            setQuality(GraineConnectionQuality.classify(rttMs: rtt, jitterMs: jitter, loss: loss))

        case .network(let isOnline):
            online = isOnline
            report { $0.onNetwork(online: isOnline) }
            if !isOnline { setQuality(.lost) }

        case .reconnecting(let active):
            reconnecting = active
            if active { setCall(connected: connected, connecting: true) }
            report { $0.onReconnecting(active: active) }

        case .progress(let progress):
            setAttempt(attempt.after(.progress(progress)))
            // "failed" closes the connect: neither transport could carry the call. The bar stops
            // saying "connecting" and offers another try; start() makes it.
            if ConnectAttempt.stopsConnecting(progress) {
                startedCall = false
                pendingStart = false
                setCall(connected: connected, connecting: false)
                scheduleAudioRestore()
            }
        }
    }

    // MARK: - The connect's own state

    private var attempt: ConnectAttempt {
        ConnectAttempt(stage: connectStage, failed: callFailed)
    }

    private func setAttempt(_ next: ConnectAttempt) {
        if connectStage != next.stage { connectStage = next.stage }
        if callFailed != next.failed { callFailed = next.failed }
    }

    /// A voice bar came on screen (or left it). Only while one is, is a page still loading somebody's wait.
    func viewerAppeared() {
        viewers += 1
        refreshConnectWait()
    }

    func viewerDisappeared() {
        viewers = max(0, viewers - 1)
        refreshConnectWait()
    }

    /// Arms or clears "Still connecting…" — a clock on the customer's wait, not on the network.
    private func refreshConnectWait() {
        let watched = (viewers > 0 && webView != nil) || connecting
        slowClock.update(waiting: ConnectWait.waiting(
            watched: watched, connected: connected, callFailed: callFailed, connecting: connecting, ready: ready
        ))
    }

    // MARK: - State

    private func setCall(connected isConnected: Bool, connecting isConnecting: Bool) {
        let changed = isConnected != connected || isConnecting != connecting
        let liveChanged = isConnected != connected
        if connected != isConnected { connected = isConnected }
        if connecting != isConnecting { connecting = isConnecting }
        // The friction clock runs only during a live call.
        if liveChanged { graine.callStateChanged(live: isConnected) }
        if changed { report { $0.onCallState(connected: isConnected, connecting: isConnecting) } }
    }

    private func setConnectivity(_ state: GraineConnectivity, reason: String?) {
        if connectivity != state { connectivity = state }
        let attempt = ladder.attempt
        report { $0.onConnectivity(state, attempt: attempt, reason: reason) }
    }

    private func setQuality(_ next: GraineConnectionQuality) {
        if next == quality { return }
        quality = next
        report { $0.onQuality(next) }
    }

    private func report(_ call: (GraineListener) -> Void) {
        graine.notifyListeners(call)
    }

    // MARK: - The page's load, watched

    fileprivate func pageStarted() {
        ready = false
        // A new page has no connect in flight: whatever stage the old one reached is gone with it.
        if connectStage != nil { connectStage = nil }
        watchdog.start(now: GraineVoice.uptimeMs())
        scheduleLoadCheck(afterMs: min(Int64(graine.config.timing.stallMs), 1_000))
    }

    fileprivate func pageFinished() {
        watchdog.loaded(now: GraineVoice.uptimeMs())
        if graine.config.debug { webView?.evaluateJavaScript(EngineScripts.socketTrace, completionHandler: nil) }
    }

    fileprivate func loadFailed(_ error: Error) {
        let ns = error as NSError
        // Superseded by a newer navigation, or interrupted by our own policy: not a failure.
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }
        scheduleRetry(reason: "load-error:\(ns.code)")
    }

    fileprivate func httpError(status: Int) {
        scheduleRetry(reason: "http-\(status)")
    }

    private func scheduleLoadCheck(afterMs ms: Int64) {
        checkLoadItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onWatchdogTick() }
        checkLoadItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(max(0, ms))), execute: item)
    }

    private func onWatchdogTick() {
        checkLoadItem = nil
        if ready { return }
        let now = GraineVoice.uptimeMs()
        let verdict = watchdog.check(now: now)
        if verdict == .wait {
            scheduleLoadCheck(afterMs: watchdog.nextCheckInMs(now: now))
        } else {
            scheduleRetry(reason: verdict.rawValue)
        }
    }

    private func scheduleRetry(reason: String) {
        checkLoadItem?.cancel()
        checkLoadItem = nil
        // A reload mid-call would drop the call to fix a page that is evidently working.
        if connected { return }
        guard let delay = ladder.next() else {
            setConnectivity(.failed, reason: reason)
            pendingStart = false
            setCall(connected: false, connecting: false)
            report { $0.onError("The assistant could not load. Check your connection and try again.") }
            return
        }
        ready = false
        setConnectivity(.retrying, reason: reason)
        retryItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.retryItem = nil
            self?.reloadEngine()
        }
        retryItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(delay)), execute: item)
    }

    /// The page never confirmed the hang-up. Force it: state, the callback, and a reload that tears the media down.
    private func forceEnd() {
        endWatchdogItem = nil
        GraineLog.warning("The page did not confirm the call ended; ending it locally.")
        setCall(connected: false, connecting: false)
        startedCall = false
        if !endNotified {
            endNotified = true
            report { $0.onEnded() }
        }
        scheduleAudioRestore()
        reloadEngine()
    }

    /// The web content process died under us. Rebuild rather than leave a dead engine mounted.
    fileprivate func processTerminated() {
        let target = container
        unwatch.forEach { $0() }
        unwatch = []
        cancelTimers()
        teardownEngine(grace: false)
        ready = false
        startedCall = false
        pendingStart = false
        if connectStage != nil { connectStage = nil }
        setCall(connected: false, connecting: false)
        if !endNotified {
            endNotified = true
            report { $0.onEnded() }
        }
        scheduleAudioRestore()
        if let target = target {
            DispatchQueue.main.async { [weak self] in self?.attach(to: target) }
        }
    }

    private func cancelTimers() {
        for item in [checkLoadItem, retryItem, endWatchdogItem, backgroundConfirmItem] { item?.cancel() }
        checkLoadItem = nil
        retryItem = nil
        endWatchdogItem = nil
        backgroundConfirmItem = nil
        endBackgroundWork()
    }

    /**
     * Take the engine out. With `grace`, the old page is kept in the window a
     * moment longer — disconnected from this object — so the end-call just
     * posted can reach its socket: a stop frame that leaves is the difference
     * between a hangup and a dropped call in the record.
     */
    private func teardownEngine(grace: Bool) {
        progressObservation?.invalidate()
        progressObservation = nil
        let engine = webView
        let hostView = host
        let content = contentController
        let hadConsole = consoleBridge != nil
        // Nothing the old page says from here on reaches this object. The handlers stay
        // installed until the end, so the page's own posts do not throw mid-hangup.
        bridge?.voice = nil
        consoleBridge?.voice = nil
        bridge = nil
        consoleBridge = nil
        engine?.navigationDelegate = nil
        engine?.uiDelegate = nil
        webView = nil
        host = nil
        contentController = nil
        let finish = {
            content?.removeScriptMessageHandler(forName: GraineProtocol.messageHandlerName)
            if hadConsole { content?.removeScriptMessageHandler(forName: EngineScripts.consoleHandlerName) }
            engine?.stopLoading()
            hostView?.removeFromSuperview()
        }
        if grace {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(750), execute: finish)
        } else {
            finish()
        }
    }

    // MARK: - Navigation and permission policy

    /// The engine never leaves Graine's origin; anything else is refused rather than opened inside the call.
    fileprivate func allowsNavigation(to url: URL?) -> Bool {
        guard let url = url else { return false }
        if url.scheme?.lowercased() == "about" { return true }
        guard let base = URL(string: graine.config.baseUrl) else { return false }
        return url.scheme?.lowercased() == base.scheme?.lowercased() && url.host?.lowercased() == base.host?.lowercased()
    }

    /**
     * The page asks for the microphone. Granted only to Graine's origin, only
     * for the microphone (never the camera), and only when the APP holds record
     * permission — a web view cannot hold a permission the app does not.
     */
    fileprivate func mediaCaptureDecision(originHost: String, type: WKMediaCaptureType) -> WKPermissionDecision {
        let ours = originHost.lowercased() == (URL(string: graine.config.baseUrl)?.host?.lowercased() ?? "")
        if type == .microphone && ours && GraineVoice.micGranted() { return .grant }
        if type == .microphone || type == .cameraAndMicrophone {
            report { $0.onMicDenied(reason: "NotAllowedError") }
        }
        return .deny
    }

    // MARK: - The app's lifecycle

    /**
     * Hang up when the app leaves the foreground — confirmed after two seconds,
     * because the app switcher and system dialogs are transient. iOS suspends a
     * background web view's audio without telling the socket, so a call left
     * running bills for silence. A short background task keeps the app awake
     * long enough for the end-call to leave. No auto-resume: a call is
     * something a person chose to start.
     */
    private func foregroundChanged(_ foreground: Bool) {
        backgroundConfirmItem?.cancel()
        backgroundConfirmItem = nil
        if foreground {
            endBackgroundWork()
            // Back: whatever screen the app is on now is the one the agent must see.
            if connected, let frame = graine.currentContextFrame() { postContext(frame) }
            // And idle: the warm registration very likely died while the app slept.
            // Warm now rather than at the tap (see Warm).
            if Warm.onForeground(ready: ready, startedCall: startedCall, connected: connected, connecting: connecting) {
                post(GraineProtocol.out(GraineProtocol.Out.warm))
            }
            return
        }
        guard graine.config.endOnBackground, connected || connecting else { return }
        beginBackgroundWork()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.backgroundConfirmItem = nil
            if !self.graine.foreground {
                self.end()
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1_500)) { [weak self] in
                    self?.endBackgroundWork()
                }
            } else {
                self.endBackgroundWork()
            }
        }
        backgroundConfirmItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(2_000), execute: item)
    }

    private func beginBackgroundWork() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "graine-end-call") { [weak self] in
            self?.endBackgroundWork()
        }
    }

    private func endBackgroundWork() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Audio session and microphone

    /**
     * Play and record, out of the speaker (not the earpiece), with Bluetooth
     * headsets allowed. It also plays with the ringer switch on silent — "no
     * sound on iPhone" is otherwise the first support ticket. The app's own
     * category is put back a moment after the call ends.
     */
    private func configureAudioSession() {
        audioRestoreItem?.cancel()
        audioRestoreItem = nil
        let session = AVAudioSession.sharedInstance()
        if savedAudio == nil {
            savedAudio = SavedAudioSession(category: session.category, mode: session.mode, options: session.categoryOptions)
        }
        // The same option (0x4) under two names: the iOS 26 SDK renamed allowBluetooth to
        // allowBluetoothHFP (available from iOS 1.0) and deprecated the old one. Consumers build
        // this source with their own Xcode, and only Xcode 26 (Swift 6.2) has the new name.
        #if compiler(>=6.2)
        let bluetooth: AVAudioSession.CategoryOptions = .allowBluetoothHFP
        #else
        let bluetooth: AVAudioSession.CategoryOptions = .allowBluetooth
        #endif
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, bluetooth])
            try session.setActive(true, options: [])
        } catch {
            GraineLog.warning("Could not configure the audio session: \(GraineInApp.describe(error))")
        }
    }

    /// After the goodbye has had a moment to finish playing.
    private func scheduleAudioRestore() {
        guard savedAudio != nil else { return }
        audioRestoreItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.restoreAudioSession() }
        audioRestoreItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1_500), execute: item)
    }

    private func restoreAudioSession() {
        audioRestoreItem = nil
        guard let saved = savedAudio, !connected, !connecting, !startedCall else { return }
        savedAudio = nil
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            if graine.config.debug { GraineLog.trace("audio session deactivate: \(GraineInApp.describe(error))") }
        }
        do {
            try session.setCategory(saved.category, mode: saved.mode, options: saved.options)
        } catch {
            if graine.config.debug { GraineLog.trace("audio session restore: \(GraineInApp.describe(error))") }
        }
    }

    static func micGranted() -> Bool {
        if #available(iOS 17.0, *) {
            return AVAudioApplication.shared.recordPermission == .granted
        }
        return AVAudioSession.sharedInstance().recordPermission == .granted
    }

    /// Ask once; an answer the customer already gave comes back at once. Delivered on the main thread.
    static func requestMic(_ done: @escaping (Bool) -> Void) {
        let deliver: (Bool) -> Void = { granted in
            DispatchQueue.main.async { done(granted) }
        }
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission(completionHandler: deliver)
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission(deliver)
        }
    }

    // MARK: - Helpers

    static func uptimeMs() -> Int64 {
        Int64(ProcessInfo.processInfo.systemUptime * 1000)
    }

    static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.filter { $0.activationState == .foregroundActive }
        for scene in active + scenes {
            if let window = scene.windows.first(where: { $0.isKeyWindow }) { return window }
        }
        return scenes.flatMap { $0.windows }.first
    }
}

/// The engine's host view, which also reports the window's light or dark as it changes.
private final class EngineHostView: UIView {
    var onStyleChange: ((UIUserInterfaceStyle) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { onStyleChange?(traitCollection.userInterfaceStyle) }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            onStyleChange?(traitCollection.userInterfaceStyle)
        }
    }
}

private struct SavedAudioSession {
    let category: AVAudioSession.Category
    let mode: AVAudioSession.Mode
    let options: AVAudioSession.CategoryOptions
}

/**
 * The page calls `window.ReactNativeWebView.postMessage(json)`, which the
 * bridge script forwards here. Holds the voice weakly: WKUserContentController
 * retains its handlers, and a strong reference would keep the engine alive
 * forever.
 */
private final class ScriptBridge: NSObject, WKScriptMessageHandler {
    enum Kind {
        case messages
        case console
    }

    weak var voice: GraineVoice?
    let kind: Kind

    init(voice: GraineVoice, kind: Kind) {
        self.voice = voice
        self.kind = kind
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body as? String ?? String(describing: message.body)
        switch kind {
        case .messages: voice?.receive(body)
        case .console: voice?.receiveConsole(body)
        }
    }
}

/// WebKit's callbacks, forwarded. A separate object so GraineVoice's public API carries no WebKit conformances.
private final class EngineDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var voice: GraineVoice?

    init(voice: GraineVoice) {
        self.voice = voice
        super.init()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        voice?.pageStarted()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        voice?.pageFinished()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        voice?.loadFailed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        voice?.loadFailed(error)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // A new window is never opened from the engine.
        guard navigationAction.targetFrame != nil, let voice = voice else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(voice.allowsNavigation(to: navigationAction.request.url) ? .allow : .cancel)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if navigationResponse.isForMainFrame,
           let http = navigationResponse.response as? HTTPURLResponse,
           http.statusCode >= 400 {
            voice?.httpError(status: http.statusCode)
        }
        decisionHandler(.allow)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        voice?.processTerminated()
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        guard let voice = voice else {
            decisionHandler(.deny)
            return
        }
        decisionHandler(voice.mediaCaptureDecision(originHost: origin.host, type: type))
    }
}
#endif
