import Combine
import Foundation

/**
 * What became of a call, as WIRE.md has it: `ringing`, `answered`,
 * `declined`, `missed` (reason `busy` or `no_answer`), `failed` (reason: why)
 * or `ended` (reason `local`, `remote` or `failed`, and how long it lasted).
 */
@objc(GraineObjCCallOutcome)
public final class GraineObjCCallOutcome: NSObject {
    @objc public let callId: String
    @objc public let outcome: String
    @objc public let reason: String?
    /// Seconds a call that connected lasted (`ended` only).
    @objc public let durationSeconds: NSNumber?
    /// Graine rang it: a call booked by the agent, the user or the dashboard.
    @objc public let hosted: Bool
    /// The agent the call was with, by name (`default` for the default agent); nil when it is not known.
    @objc public let agent: String?
    /// The same, as JSON.
    @objc public let json: String

    init(_ o: [String: Any]) {
        callId = JSON.string(o["callId"])
        outcome = JSON.string(o["outcome"])
        reason = JSON.nonEmpty(o["reason"])
        durationSeconds = ObjCBridge.int(o["durationSeconds"]).map { NSNumber(value: $0) }
        hosted = JSON.flag(o["hosted"])
        agent = JSON.nonEmpty(o["agent"])
        json = ObjCBridge.text(o)
    }
}

/// Hears the calls: any change to the call (state, controls, caption), each outcome, each ring. Main thread. Held weakly.
@objc(GraineObjCCallsListener)
public protocol GraineObjCCallsListener: AnyObject {
    @objc(graineCallsChanged:)
    func graineCallsChanged(_ calls: GraineObjCCalls)
    @objc(graineCallOutcome:)
    func graineCallOutcome(_ outcome: GraineObjCCallOutcome)
    @objc(graineIncomingCall:callerName:hosted:)
    func graineIncomingCall(_ callId: String, callerName: String?, hosted: Bool)
}

/**
 * NATIVE CALLS, FOR OBJECTIVE-C — `GraineCalls` (CallKit and VoIP pushes):
 * the user calls the agent (`startCallWithReason:variables:`), or the agent
 * rings the user (`enableVoIPPushes` at every launch). iOS only; elsewhere
 * every method does nothing and the call stays idle.
 *
 * The phone has one call at a time, whichever agent it is with: every
 * agent's `calls` is the same call. A call placed here is with this facade's
 * agent.
 */
@objc(GraineObjCCalls)
public final class GraineObjCCalls: NSObject {
    fileprivate let graine: GraineInApp
    private let observers = ObjCObservers<GraineObjCCallsListener>()
    private var outcomeBlocks: [UUID: (String) -> Void] = [:]
    private var incomingBlocks: [UUID: (String) -> Void] = [:]
    private var pending = false
    #if os(iOS)
    private var watching: AnyCancellable?
    private lazy var relay = ObjCCallsRelay(self)
    fileprivate var hostedIds = Set<String>()
    fileprivate var activeSince: (id: String, at: Date)?
    #endif

    init(graine: GraineInApp) {
        self.graine = graine
        super.init()
        #if os(iOS)
        let calls = graine.calls
        watching = calls.objectWillChange.sink { [weak self] _ in self?.changed() }
        calls.addListener(relay)
        #endif
    }

    // MARK: Setting up

    /// How calls ring and what they show. Call once, at launch, before `enableVoIPPushes`. Empty name: the app's.
    @objc(configureWithDisplayName:ringtoneSound:ringTimeout:includesCallsInRecents:)
    public func configure(displayName: String, ringtoneSound: String?, ringTimeout: Double, includesCallsInRecents: Bool) {
        #if os(iOS)
        graine.calls.configure(GraineCallsConfig(
            displayName: displayName,
            ringtoneSound: ringtoneSound,
            includesCallsInRecents: includesCallsInRecents,
            ringTimeout: ringTimeout > 0 ? ringTimeout : 30
        ))
        #endif
    }

    /**
     * The road the calls' audio takes: "auto" (the default — WebRTC when the
     * app includes GraineInAppRTC), "websocket" or "webrtc". Anything else is "auto".
     */
    @objc public var callTransport: String {
        get {
            #if os(iOS)
            return objcOnMainSync { graine.calls.config.callTransport.rawValue }
            #else
            return GraineCallTransport.auto.rawValue
            #endif
        }
        set {
            #if os(iOS)
            let transport = GraineCallTransport.from(newValue) ?? .auto
            onMain {
                var config = self.graine.calls.config
                config.callTransport = transport
                self.graine.calls.configure(config)
            }
            #endif
        }
    }

    /// Receive the agent's calls as VoIP pushes. Call at every launch.
    @objc(enableVoIPPushes)
    public func enableVoIPPushes() {
        #if os(iOS)
        graine.calls.enableVoIPPushes()
        #endif
    }

    // MARK: The call

    /// The user calls this facade's agent. The call's id, or nil when another call is live.
    @objc(startCallWithReason:variables:)
    public func startCall(reason: String?, variables: [String: Any]?) -> String? {
        #if os(iOS)
        return graine.calls.startCall(reason: reason, variables: variables ?? [:], agent: graine.name)
        #else
        return nil
        #endif
    }

    /// `startCallWithReason:variables:` for a bridge: the variables as a JSON object.
    @objc(startCallJSONWithReason:variablesJSON:)
    public func startCallJSON(reason: String?, variablesJSON: String?) -> String? {
        startCall(reason: reason, variables: ObjCBridge.object(variablesJSON))
    }

    /**
     * Get this facade's agent's next call ready before the user taps, so that
     * `startCallJSONWithReason:variablesJSON:` with the same reason and
     * variables connects in about a second. Cheap to call whenever a screen
     * that offers a call appears: nothing is sent while a call prepared the
     * same way is less than four minutes old, and nothing is dialled or billed
     * until the call starts. `variablesJSON` is a JSON object.
     */
    @objc(prepareCallJSONWithReason:variablesJSON:)
    public func prepareCallJSON(reason: String?, variablesJSON: String?) {
        #if os(iOS)
        graine.calls.prepareCall(reason: reason, variables: ObjCBridge.object(variablesJSON) ?? [:], agent: graine.name)
        #endif
    }

    @objc(answer)
    public func answer() {
        #if os(iOS)
        graine.calls.answer()
        #endif
    }

    /// Decline the ringing call.
    @objc(decline)
    public func decline() {
        #if os(iOS)
        if graine.calls.state == .ringing { graine.calls.end() }
        #endif
    }

    /// Hang up — or decline, while it rings.
    @objc(end)
    public func end() {
        #if os(iOS)
        graine.calls.end()
        #endif
    }

    @objc(setMuted:)
    public func setMuted(_ muted: Bool) {
        #if os(iOS)
        graine.calls.setMuted(muted)
        #endif
    }

    @objc(setSpeaker:)
    public func setSpeaker(_ on: Bool) {
        #if os(iOS)
        graine.calls.setSpeaker(on)
        #endif
    }

    /// Return the missed call. The new call's id, or nil.
    @objc(callBack)
    public func callBack() -> String? {
        #if os(iOS)
        return graine.calls.callBack()
        #else
        return nil
        #endif
    }

    @objc(dismissMissedCall)
    public func dismissMissedCall() {
        #if os(iOS)
        graine.calls.dismissMissedCall()
        #endif
    }

    // MARK: Permissions and setup

    /// The call permissions as JSON `{microphone, notifications, fullScreen}`, each `granted`, `denied`, `blocked` or `notNeeded` (`GraineCalls.callPermissions`).
    @objc public var callPermissionsJSON: String {
        #if os(iOS)
        return ObjCBridge.text(objcOnMainSync { graine.calls.callPermissions.fields })
        #else
        return ObjCBridge.text(GraineCallPermissions(microphone: .notNeeded, notifications: .notNeeded, fullScreen: .notNeeded).fields)
        #endif
    }

    /// Ask for the call permissions the system can still ask for (`GraineCalls.requestCallPermissions`); `completion` gets them as `callPermissionsJSON` has them, on the main thread.
    @objc(requestCallPermissionsJSONWithCompletion:)
    public func requestCallPermissionsJSON(completion: @escaping (String) -> Void) {
        #if os(iOS)
        graine.calls.requestCallPermissions { completion(ObjCBridge.text($0.fields)) }
        #else
        completion(callPermissionsJSON)
        #endif
    }

    /// Open the Settings page for `microphone`, `notifications` or `fullScreen`: YES when one was asked to open.
    @objc(openCallSettings:)
    public func openCallSettings(_ item: String) -> Bool {
        #if os(iOS)
        guard let permission = CallsHostValues.permission(item) else { return false }
        return graine.calls.openCallSettings(permission)
        #else
        return false
        #endif
    }

    /// What the app's setup still lacks for calls, as JSON `[{code, message}]` (`GraineCalls.callSetupProblems`); `[]` when nothing is missing.
    @objc public var callSetupProblemsJSON: String {
        #if os(iOS)
        return ObjCBridge.text(graine.calls.callSetupProblems.map(\.fields))
        #else
        return "[]"
        #endif
    }

    // MARK: The state

    /// `idle`, `ringing`, `connecting`, `active` or `ended`.
    @objc public var state: String { snapshot()["state"] as? String ?? "idle" }
    /// Who ended the call, while `state` is `ended`: `local`, `remote`, `failed`, `declined` or `missed`.
    @objc public var endReason: String? { snapshot()["endReason"] as? String }
    @objc public var callId: String? { snapshot()["callId"] as? String }
    @objc public var callerName: String { snapshot()["callerName"] as? String ?? "" }
    /// `incoming` or `outgoing`; nil with no call.
    @objc public var direction: String? { snapshot()["direction"] as? String }
    @objc public var muted: Bool { snapshot()["muted"] as? Bool ?? false }
    @objc public var speakerOn: Bool { snapshot()["speakerOn"] as? Bool ?? false }
    @objc public var agentSpeaking: Bool { snapshot()["agentSpeaking"] as? Bool ?? false }
    @objc public var hosted: Bool { snapshot()["hosted"] as? Bool ?? false }
    /// The agent the call is with, by name (`default` for the default agent): the one a call was placed with, or a ring routed to. Nil with no call.
    @objc public var agent: String? { snapshot()["agent"] as? String }
    /// A call screen has something to show: a call, or a missed ring to call back.
    @objc public var showsCallScreen: Bool { snapshot()["showsCallScreen"] as? Bool ?? false }
    /// The road the call's audio runs on: "webrtc" or "websocket"; nil before it is decided.
    @objc public var transport: String? { snapshot()["transport"] as? String }
    /// Why a call that tried WebRTC runs on the WebSocket ("no_answer", "ice_timeout", …); nil otherwise.
    @objc public var transportFallbackReason: String? { snapshot()["transportFallbackReason"] as? String }

    /// The call as JSON, for a bridge: every field above, plus `caption` and `missedCall`.
    @objc public var snapshotJSON: String { ObjCBridge.text(snapshot()) }

    func snapshot() -> [String: Any] {
        objcOnMainSync {
            var o: [String: Any] = [
                "state": "idle", "endReason": NSNull(), "callId": NSNull(), "callerName": "", "direction": NSNull(),
                "hosted": false, "muted": false, "speakerOn": false, "agentSpeaking": false, "showsCallScreen": false,
                "agent": NSNull(), "transport": NSNull(), "transportFallbackReason": NSNull(),
            ]
            #if os(iOS)
            let c = graine.calls
            let state = ObjCBridge.callState(c.state)
            o["state"] = state.word
            o["endReason"] = state.endReason ?? NSNull()
            o["callId"] = c.callId ?? NSNull()
            o["callerName"] = c.callerName
            o["direction"] = c.direction?.rawValue ?? NSNull()
            o["hosted"] = c.hosted
            o["muted"] = c.muted
            o["speakerOn"] = c.speakerOn
            o["agentSpeaking"] = c.agentSpeaking
            o["showsCallScreen"] = c.showsCallScreen
            o["agent"] = c.agent ?? NSNull()
            o["transport"] = c.transport?.rawValue ?? NSNull()
            o["transportFallbackReason"] = c.transportFallbackReason ?? NSNull()
            if let caption = c.caption {
                o["caption"] = ["role": caption.role == .agent ? "agent" : "user", "text": caption.text, "live": caption.live] as [String: Any]
            }
            if let m = c.missedCall {
                o["missedCall"] = [
                    "callId": m.callId, "callerName": m.callerName, "reason": m.reason ?? NSNull(), "hosted": m.hosted,
                    "at": ObjCBridge.millis(m.at),
                ] as [String: Any]
            }
            #endif
            return o
        }
    }

    // MARK: Hearing about it

    @objc(addListener:)
    public func addListener(_ listener: GraineObjCCallsListener) {
        onMain { self.observers.add(listener: listener) }
    }

    @objc(removeListener:)
    public func removeListener(_ listener: GraineObjCCallsListener) {
        onMain { self.observers.remove(listener: listener) }
    }

    /// For a bridge: `observer` runs after every change to the call, until the registration is stopped.
    @objc(observe:)
    public func observe(_ observer: @escaping () -> Void) -> GraineObjCRegistration {
        objcOnMainSync { observers.add(observer) }
    }

    /// For a bridge: each outcome as JSON `{callId, outcome, reason, durationSeconds, hosted, agent}` (`agent` when known).
    @objc(observeOutcomes:)
    public func observeOutcomes(_ observer: @escaping (String) -> Void) -> GraineObjCRegistration {
        let id = UUID()
        onMain { self.outcomeBlocks[id] = observer }
        return GraineObjCRegistration { [weak self] in self?.onMain { self?.outcomeBlocks.removeValue(forKey: id) } }
    }

    /// For a bridge: each ring as JSON `{callId, callerName, reason, hosted, agent}` (`agent`: the configured agent it rings for, when known).
    @objc(observeIncoming:)
    public func observeIncoming(_ observer: @escaping (String) -> Void) -> GraineObjCRegistration {
        let id = UUID()
        onMain { self.incomingBlocks[id] = observer }
        return GraineObjCRegistration { [weak self] in self?.onMain { self?.incomingBlocks.removeValue(forKey: id) } }
    }

    private func changed() {
        if pending { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.pending = false
            self.observers.notify { $0.graineCallsChanged(self) }
        }
    }

    /// Main thread.
    fileprivate func report(outcome o: [String: Any]) {
        let outcome = GraineObjCCallOutcome(o)
        for block in Array(outcomeBlocks.values) { block(outcome.json) }
        observers.notify { $0.graineCallOutcome(outcome) }
    }

    /// Main thread.
    fileprivate func report(incoming callId: String, callerName: String?, reason: String?, hosted: Bool, agent: String?) {
        var ring: [String: Any] = ["callId": callId, "callerName": callerName ?? NSNull(), "reason": reason ?? NSNull(), "hosted": hosted]
        if let agent = agent { ring["agent"] = agent }
        let json = ObjCBridge.text(ring)
        for block in Array(incomingBlocks.values) { block(json) }
        observers.notify { $0.graineIncomingCall(callId, callerName: callerName, hosted: hosted) }
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }
}

#if os(iOS)
/**
 * The calls' listener, turned into WIRE.md's outcomes: `ringing` when a ring
 * starts, `busy` for a ring refused because another call was live, how long
 * an ended call lasted, whether Graine rang it, and the agent it is with.
 */
final class ObjCCallsRelay: GraineCallsListener {
    private weak var facade: GraineObjCCalls?

    init(_ facade: GraineObjCCalls) {
        self.facade = facade
    }

    func onIncomingCall(_ call: GraineIncomingCall) {
        guard let f = facade else { return }
        if call.hosted { f.hostedIds.insert(call.callId) }
        // The configured agent the push was routed to, named before the ring is reported.
        let agent = f.graine.calls.agentName(forCall: call.callId)
        f.report(incoming: call.callId, callerName: call.callerName, reason: call.reason, hosted: call.hosted, agent: agent)
        var ringing: [String: Any] = ["callId": call.callId, "outcome": "ringing", "hosted": call.hosted]
        if let agent = agent { ringing["agent"] = agent }
        f.report(outcome: ringing)
    }

    func onCallState(_ state: GraineCallState, callId: String?) {
        guard let f = facade, case .active = state, let id = callId else { return }
        if f.activeSince?.id != id { f.activeSince = (id, Date()) }
    }

    func onCallOutcome(_ outcome: GraineCallOutcome, callId: String) {
        guard let f = facade else { return }
        let calls = f.graine.calls
        // A miss for a call that is not the one in progress is a ring refused because another call was live.
        let busy = outcome == .missed && calls.callId != callId
        let seconds = f.activeSince?.id == callId ? f.activeSince.map { Date().timeIntervalSince($0.at) } : nil
        let hosted = f.hostedIds.contains(callId) || (calls.callId == callId && calls.hosted)
        f.report(outcome: ObjCBridge.outcome(
            outcome, callId: callId, busy: busy, connectedSeconds: seconds, hosted: hosted, agent: calls.agentName(forCall: callId)
        ))
        if outcome != .answered {
            // The last word on this call.
            f.hostedIds.remove(callId)
            if f.activeSince?.id == callId { f.activeSince = nil }
        }
    }
}
#endif

/**
 * THE VOICE BAR'S CALL, FOR OBJECTIVE-C — `GraineVoice`: the agent talking
 * inside the app. `start` mounts the engine in the key window first if
 * nothing has. iOS only; elsewhere it stays idle.
 */
@objc(GraineObjCVoice)
public final class GraineObjCVoice: NSObject {
    private let graine: GraineInApp
    private let observers = ObjCObservers<NSObject>()
    private var pending = false
    #if os(iOS)
    private var watching: AnyCancellable?
    #endif

    init(graine: GraineInApp) {
        self.graine = graine
        super.init()
        #if os(iOS)
        watching = graine.voice.objectWillChange.sink { [weak self] _ in self?.changed() }
        #endif
    }

    /// Mount the engine in the key window, idle. `start` does it by itself.
    @objc(attach)
    public func attach() {
        #if os(iOS)
        graine.voice.attach()
        #endif
    }

    @objc(start)
    public func start() {
        #if os(iOS)
        let voice = graine.voice
        if !voice.isAttached { voice.attach() }
        voice.start()
        #endif
    }

    @objc(end)
    public func end() {
        #if os(iOS)
        graine.voice.end()
        #endif
    }

    @objc(setMuted:)
    public func setMuted(_ muted: Bool) {
        #if os(iOS)
        graine.voice.setMuted(muted)
        #endif
    }

    /// The captions switch (`GraineVoice.setCaptionsOn(_:)`): the bar shows the line being said only while it is on.
    @objc(setCaptionsOn:)
    public func setCaptionsOn(_ on: Bool) {
        #if os(iOS)
        graine.voice.setCaptionsOn(on)
        #endif
    }

    /// Forget what has been said without ending the call (`GraineVoice.clearCaptions()`).
    @objc(clearCaptions)
    public func clearCaptions() {
        #if os(iOS)
        graine.voice.clearCaptions()
        #endif
    }

    @objc public var connected: Bool { snapshot()["connected"] as? Bool ?? false }
    @objc public var connecting: Bool { snapshot()["connecting"] as? Bool ?? false }
    @objc public var muted: Bool { snapshot()["muted"] as? Bool ?? false }
    /// The captions switch; on until it is turned off.
    @objc public var captionsOn: Bool { snapshot()["captionsOn"] as? Bool ?? true }

    /// `{connected, connecting, muted, captionsOn, captions: [{role, text, live}]}` as JSON, for a bridge.
    @objc public var snapshotJSON: String { ObjCBridge.text(snapshot()) }

    func snapshot() -> [String: Any] {
        objcOnMainSync {
            #if os(iOS)
            let v = graine.voice
            return [
                "connected": v.connected, "connecting": v.connecting, "muted": v.muted, "captionsOn": v.captionsOn,
                "captions": v.captions.map { ["role": $0.role == .agent ? "agent" : "user", "text": $0.text, "live": $0.live] as [String: Any] },
            ]
            #else
            return ["connected": false, "connecting": false, "muted": false, "captionsOn": true, "captions": [Any]()]
            #endif
        }
    }

    /// `observer` runs on the main thread after every change, until the registration is stopped.
    @objc(observe:)
    public func observe(_ observer: @escaping () -> Void) -> GraineObjCRegistration {
        objcOnMainSync { observers.add(observer) }
    }

    private func changed() {
        if pending { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.pending = false
            self.observers.notify { _ in }
        }
    }
}
