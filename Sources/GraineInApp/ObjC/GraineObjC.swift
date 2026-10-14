import Foundation

/*
 * THE SDK FOR OBJECTIVE-C — and for anything that reaches Swift through the
 * Objective-C runtime: Kotlin Multiplatform (ai.graine:inapp-kmp) and other
 * bridges. `GraineObjC` wraps the same instance `GraineInApp` is, with
 * Foundation types (NSString, NSDictionary, NSNumber, NSDate, NSError) and
 * completion blocks in place of Swift's async and enums.
 *
 *     GraineObjC *graine = [GraineObjC configureWithBaseUrl:@"https://www.graine.ai" publishableKey:@"pk_live_…"];
 *     [graine identify:@{ @"user_id": user.id, @"name": user.name }];
 *     [graine scheduledCallsWithCompletion:^(NSArray<GraineObjCScheduledCall *> *calls, NSError *error) { … }];
 *
 * Every selector is fixed with `@objc(…)`: a bridge binds to them by name, so
 * a renamed Swift parameter must never move one. The `…JSON` methods carry
 * what Foundation values cannot carry exactly across a bridge (a whole number
 * against a boolean, a key that is absent against one that is null): JSON text
 * in, JSON text out, with times as epoch milliseconds.
 *
 * Errors are NSErrors in `GraineObjC.errorDomain`: `userInfo[@"code"]` is the
 * stable code (`identity_required`, `too_soon`, `network`… — branch on it),
 * `userInfo[@"retryAfterSeconds"]` how long a rate limit asked to wait (when
 * it said), `localizedDescription` the sentence, and `code` the HTTP status (0
 * when no answer came back).
 *
 * Several agents: `configureWithBaseUrl:…name:` starts one under its own name
 * and key, `named:` finds it; each facade is its agent's (`chat`, `voice`, its
 * actions and requests), while who the user is, the screen and the phone's
 * calls are the app's.
 */

// MARK: - What crosses the bridge

/// Foundation values ⇄ the SDK's, and the facade's JSON. Pure, so `swift test` proves it on a Mac.
enum ObjCBridge {
    static let errorDomain = "ai.graine.inapp"

    /// Any error the SDK throws, as the facade's NSError.
    static func nsError(_ error: Error) -> NSError {
        let service = (error as? GraineServiceError)
            ?? GraineServiceError(code: .unknown("server_error"), message: GraineInApp.describe(error))
        var info: [String: Any] = [NSLocalizedDescriptionKey: service.message, "code": service.code.wire]
        if let wait = service.retryAfterSeconds { info["retryAfterSeconds"] = wait }
        return NSError(domain: errorDomain, code: service.status, userInfo: info)
    }

    /// A JSON object from text; nil for nil, blank or anything that is not an object.
    static func object(_ text: String?) -> [String: Any]? {
        JSON.object(from: text)
    }

    /// Any value as JSON text — never a crash: what cannot be written becomes its text, as JSON.normalize does.
    static func text(_ value: Any?) -> String {
        let clean = JSON.normalize(value)
        guard JSONSerialization.isValidJSONObject(clean) || clean is NSNull || clean is String || clean is NSNumber,
              let data = try? JSONSerialization.data(withJSONObject: clean, options: [.fragmentsAllowed]),
              let out = String(data: data, encoding: .utf8) else { return "null" }
        return out
    }

    static func millis(_ date: Date?) -> Any {
        guard let date = date else { return NSNull() }
        return NSNumber(value: Int64((date.timeIntervalSince1970 * 1000).rounded()))
    }

    // MARK: Screens

    /// A screen from its dictionary (`screen`, `title`, `journey`, `fields`, `error`, `data`, `availableActions`); nil without `screen`.
    static func screen(_ o: [String: Any]?) -> GraineScreen? {
        guard let o = o, let id = JSON.nonEmpty(o["screen"]) else { return nil }
        var journey: GraineScreen.Journey?
        if let j = JSON.unwrap(o["journey"]) as? [String: Any], let name = JSON.nonEmpty(j["name"]) {
            journey = GraineScreen.Journey(name: name, step: int(j["step"]), of: int(j["of"]), next: JSON.nonEmpty(j["next"]))
        }
        let fields = ((JSON.unwrap(o["fields"]) as? [Any]) ?? []).compactMap { field(JSON.unwrap($0) as? [String: Any]) }
        let actions = (JSON.unwrap(o["availableActions"]) as? [Any])?.compactMap { JSON.nonEmpty($0) }
        return GraineScreen(
            screen: id,
            title: JSON.nonEmpty(o["title"]),
            journey: journey,
            fields: fields,
            error: JSON.nonEmpty(o["error"]),
            data: (JSON.unwrap(o["data"]) as? [String: Any]) ?? [:],
            availableActions: actions
        )
    }

    /// A field from its dictionary (`name`, `label`, `value`, `status`, `error`, `optional`); nil without `name`.
    static func field(_ o: [String: Any]?) -> GraineField? {
        guard let o = o, let name = JSON.nonEmpty(o["name"]) else { return nil }
        return GraineField(
            name: name,
            label: JSON.nonEmpty(o["label"]),
            value: JSON.text(o["value"]),
            status: JSON.nonEmpty(o["status"]).flatMap { GraineField.Status(rawValue: $0.lowercased()) },
            error: JSON.nonEmpty(o["error"]),
            isOptional: JSON.unwrap(o["optional"]).flatMap { JSON.bool($0) } ?? false
        )
    }

    // MARK: What the SDK answers, as the facade's JSON

    static func memory(_ m: GraineMemory) -> [String: Any] {
        ["id": m.id, "text": m.text, "createdAt": millis(m.createdAt), "updatedAt": millis(m.updatedAt)]
    }

    static func scheduledCall(_ c: GraineScheduledCall) -> [String: Any] {
        [
            "id": c.id,
            "at": millis(c.at),
            "status": c.status.wire,
            "source": c.source.map { $0.wire as Any } ?? NSNull(),
            "reason": c.reason.map { $0 as Any } ?? NSNull(),
        ]
    }

    static func session(_ s: GraineSessionConfig) -> [String: Any] {
        var o: [String: Any] = [
            "agentId": s.agentId,
            "webcallAgentId": s.webcallAgentId,
            "memoryEnabled": s.memoryEnabled.map { NSNumber(value: $0) as Any } ?? NSNull(),
            "declaredActions": s.declaredActions.sorted(),
        ]
        if let identity = s.identity {
            o["identity"] = ["field": identity.field, "devicesPerUser": identity.devicesPerUser]
        }
        if let c = s.calls {
            o["calls"] = [
                "hosted": c.hosted,
                "platforms": c.platforms,
                "ringTimeoutSeconds": c.ringTimeoutSeconds.map { $0 as Any } ?? NSNull(),
                "callName": c.callName.map { $0 as Any } ?? NSNull(),
                "usersCanBook": c.usersCanBook,
                "maxDaysAhead": c.maxDaysAhead.map { $0 as Any } ?? NSNull(),
                "minLeadMinutes": c.minLeadMinutes.map { $0 as Any } ?? NSNull(),
                "maxPendingPerUser": c.maxPendingPerUser.map { $0 as Any } ?? NSNull(),
            ] as [String: Any]
        }
        return o
    }

    /// A chat turn in WIRE.md's words: `user` / `agent`, and `sending` for a message waiting to go.
    static func turn(_ t: GraineChatTurn) -> [String: Any] {
        [
            "id": t.id,
            "role": t.role == .customer ? "user" : "agent",
            "text": t.text,
            "live": t.live,
            "delivery": t.delivery.rawValue,
            "at": millis(t.at),
            "proactive": t.proactive,
            "restored": t.restored,
            "channel": t.channel.rawValue,
        ]
    }

    static func chatStatus(_ s: GraineChatStatus) -> (word: String, attempt: Int) {
        switch s {
        case .idle: return ("idle", 0)
        case .connecting: return ("connecting", 0)
        case .online: return ("online", 0)
        case .reconnecting(let attempt): return ("reconnecting", attempt)
        case .offline: return ("offline", 0)
        }
    }

    static func callState(_ s: GraineCallState) -> (word: String, endReason: String?) {
        switch s {
        case .idle: return ("idle", nil)
        case .ringing: return ("ringing", nil)
        case .connecting: return ("connecting", nil)
        case .active: return ("active", nil)
        case .ended(let reason): return ("ended", reason.rawValue)
        }
    }

    /**
     * A call's outcome as WIRE.md has it: why (`busy` or `no_answer` for a
     * miss, who ended a call that connected, why one never did), how long a
     * call that connected lasted, whether Graine rang it, and the agent it was
     * with by name, when known.
     */
    static func outcome(
        _ outcome: GraineCallOutcome, callId: String, busy: Bool, connectedSeconds: Double?, hosted: Bool, agent: String? = nil
    ) -> [String: Any] {
        var o: [String: Any] = ["callId": callId, "outcome": outcome.wire, "hosted": hosted]
        if let agent = agent { o["agent"] = agent }
        switch outcome {
        case .missed: o["reason"] = busy ? "busy" : "no_answer"
        case .ended(let reason):
            o["reason"] = reason.rawValue
            if let s = connectedSeconds { o["durationSeconds"] = Int(max(0, s).rounded()) }
        case .failed(let why): o["reason"] = String((why.isEmpty ? "failed" : why).prefix(200))
        case .answered, .declined: break
        }
        return o
    }

    static func actionResult(status: String, message: String, data: [String: Any]) -> GraineActionResult {
        GraineActionResult(status: GraineActionResult.Status(rawValue: status.lowercased()) ?? .error, message: message, data: data)
    }

    static func int(_ v: Any?) -> Int? {
        guard let raw = JSON.unwrap(v), let n = JSON.number(raw), n.doubleValue.isFinite else { return nil }
        return n.intValue
    }
}

/// Blocks and weakly held listeners, told on the main thread. Main thread only.
final class ObjCObservers<Listener: AnyObject> {
    private var blocks: [UUID: () -> Void] = [:]
    private var listeners: [WeakBox] = []

    private final class WeakBox {
        weak var value: Listener?
        init(_ value: Listener) { self.value = value }
    }

    func add(_ block: @escaping () -> Void) -> GraineObjCRegistration {
        let id = UUID()
        blocks[id] = block
        return GraineObjCRegistration { [weak self] in self?.onMain { self?.blocks.removeValue(forKey: id) } }
    }

    func add(listener: Listener) {
        listeners.removeAll { $0.value == nil || $0.value === listener }
        listeners.append(WeakBox(listener))
    }

    func remove(listener: Listener) {
        listeners.removeAll { $0.value == nil || $0.value === listener }
    }

    /// Every block, then every listener still alive.
    func notify(_ tell: (Listener) -> Void) {
        for block in Array(blocks.values) { block() }
        for box in listeners { if let l = box.value { tell(l) } }
    }

    var isEmpty: Bool { blocks.isEmpty && listeners.allSatisfy { $0.value == nil } }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }
}

// MARK: - Small value types

/// What `register…` and `observe…` return: `unregister` stops it. Idempotent.
@objc(GraineObjCRegistration)
public final class GraineObjCRegistration: NSObject {
    private var stop: (() -> Void)?

    init(_ stop: @escaping () -> Void) {
        self.stop = stop
    }

    @objc(unregister)
    public func unregister() {
        let s = stop
        stop = nil
        s?()
    }
}

/// What an action handler answers. The agent speaks about exactly this, so tell the truth.
@objc(GraineObjCActionResult)
public final class GraineObjCActionResult: NSObject {
    /// `ok`, `refused` or `error`.
    @objc public let status: String
    @objc public let message: String
    @objc public let data: [String: Any]

    init(status: String, message: String, data: [String: Any]) {
        self.status = status
        self.message = message
        self.data = data
    }

    /// It happened.
    @objc(ok:)
    public static func ok(_ message: String) -> GraineObjCActionResult { GraineObjCActionResult(status: "ok", message: message, data: [:]) }

    /// It happened, with a structured result the agent can reason about.
    @objc(ok:data:)
    public static func ok(_ message: String, data: [String: Any]) -> GraineObjCActionResult { GraineObjCActionResult(status: "ok", message: message, data: data) }

    /// It will not happen, and why.
    @objc(refused:)
    public static func refused(_ message: String) -> GraineObjCActionResult { GraineObjCActionResult(status: "refused", message: message, data: [:]) }

    /// It was tried and failed.
    @objc(error:)
    public static func error(_ message: String) -> GraineObjCActionResult { GraineObjCActionResult(status: "error", message: message, data: [:]) }

    var result: GraineActionResult { ObjCBridge.actionResult(status: status, message: message, data: data) }
}

/// One thing the agent remembers about the signed-in user (already redacted).
@objc(GraineObjCMemory)
public final class GraineObjCMemory: NSObject {
    @objc public let identifier: String
    @objc public let text: String
    @objc public let createdAt: Date?
    @objc public let updatedAt: Date?

    init(_ m: GraineMemory) {
        identifier = m.id
        text = m.text
        createdAt = m.createdAt
        updatedAt = m.updatedAt
    }
}

/// A call booked to ring this user (or this install) later.
@objc(GraineObjCScheduledCall)
public final class GraineObjCScheduledCall: NSObject {
    @objc public let identifier: String
    /// When it rings; nil only when the server's time could not be read.
    @objc public let at: Date?
    /// `scheduled`, `ringing`, `answered`, `completed`, `declined`, `missed`, `failed`, `cancelled`, `expired`, `no_device` — or a newer word.
    @objc public let status: String
    /// `agent`, `sdk` (booked from the app), `dashboard`, `api`; nil when the server does not say.
    @objc public let source: String?
    @objc public let reason: String?
    /// Still to come: scheduled, or ringing right now.
    @objc public let isUpcoming: Bool
    /// It can still be called off.
    @objc public let canCancel: Bool

    init(_ c: GraineScheduledCall) {
        identifier = c.id
        at = c.at
        status = c.status.wire
        source = c.source?.wire
        reason = c.reason
        isUpcoming = c.isUpcoming
        canCancel = c.canCancel
    }
}

/// What the dashboard says about the agent.
@objc(GraineObjCSession)
public final class GraineObjCSession: NSObject {
    @objc public let agentId: String
    /// Whether the agent remembers its users; nil when the server does not say.
    @objc public let memoryEnabled: NSNumber?
    /// The trait that names the user: `user_id` unless the dashboard chose another.
    @objc public let identityField: String
    @objc public let devicesPerUser: Int
    /// Users may book calls from the app.
    @objc public let usersCanBook: Bool
    /// Graine rings this workspace's users itself.
    @objc public let hostedRinging: Bool
    /// The name the agent's calls ring with, when the dashboard set one.
    @objc public let callName: String?
    /// The session as the facade's JSON (`sessionJSON`).
    @objc public let json: String

    init(_ s: GraineSessionConfig) {
        agentId = s.agentId
        memoryEnabled = s.memoryEnabled.map { NSNumber(value: $0) }
        identityField = s.identitySettings.field
        devicesPerUser = s.identitySettings.devicesPerUser
        usersCanBook = s.calls?.usersCanBook ?? false
        hostedRinging = s.calls?.hosted ?? false
        callName = s.calls?.callName
        json = ObjCBridge.text(ObjCBridge.session(s))
    }
}

/**
 * Everything the SDK reports that is not a state, for an Objective-C app:
 * `name` and its `payload` (`json` is the same payload as JSON text). Names:
 * `sessionReady`, `caption`, `voiceEnded`, `widget`, `widgetPending`,
 * `chatMessage`, `actionRequested`, `actionCompleted`, `friction`,
 * `micDenied`, `error`. Main thread. Held weakly.
 */
@objc(GraineObjCListener)
public protocol GraineObjCListener: AnyObject {
    @objc(graineEvent:payload:json:)
    func graineEvent(_ name: String, payload: [String: Any], json: String)
}

// MARK: - The facade

@objc(GraineObjC)
public final class GraineObjC: NSObject {
    let graine: GraineInApp
    private let events = ObjCObservers<GraineObjCListener>()
    private var eventBlocks: [UUID: (String, String) -> Void] = [:]
    private lazy var relay = ObjCEventRelay(self)

    /// The chat.
    @objc public private(set) lazy var chat = GraineObjCChat(graine: graine)
    /// Native calls (CallKit and VoIP pushes).
    @objc public private(set) lazy var calls = GraineObjCCalls(graine: graine)
    /// The voice bar's call.
    @objc public private(set) lazy var voice = GraineObjCVoice(graine: graine)

    init(graine: GraineInApp) {
        self.graine = graine
        super.init()
        graine.addListener(relay)
    }

    private static let lock = NSLock()
    /// One facade per agent, made the first time it is asked for. Agents live as long as the app.
    private static var facades: [ObjectIdentifier: GraineObjC] = [:]

    /// The error domain of every NSError the facade hands out.
    @objc(errorDomain)
    public static var errorDomain: String { ObjCBridge.errorDomain }

    /// Start the default agent — `GraineInApp.configure`. Call once, at launch; a second call returns the first.
    @objc(configureWithBaseUrl:publishableKey:)
    public static func configure(baseUrl: String, publishableKey: String) -> GraineObjC {
        configure(GraineConfig(baseUrl: baseUrl, publishableKey: publishableKey))
    }

    /// Start the SDK with build-time prompt variables.
    @objc(configureWithBaseUrl:publishableKey:variables:)
    public static func configure(baseUrl: String, publishableKey: String, variables: [String: Any]?) -> GraineObjC {
        configure(GraineConfig(baseUrl: baseUrl, publishableKey: publishableKey, variables: variables ?? [:]))
    }

    /**
     * Start the SDK with every option, for a bridge: `transport` is `ws`,
     * `rtc` or nil (the dashboard decides); `variablesJSON` a JSON object.
     */
    @objc(configureWithBaseUrl:publishableKey:appVersion:debug:endOnBackground:captureTaps:transport:variablesJSON:)
    public static func configure(
        baseUrl: String, publishableKey: String, appVersion: String?, debug: Bool, endOnBackground: Bool,
        captureTaps: Bool, transport: String?, variablesJSON: String?
    ) -> GraineObjC {
        configure(config(
            baseUrl: baseUrl, publishableKey: publishableKey, appVersion: appVersion, debug: debug,
            endOnBackground: endOnBackground, captureTaps: captureTaps, transport: transport, variablesJSON: variablesJSON
        ))
    }

    /**
     * Start an agent by name, with every option, for a bridge — its own key,
     * its own chat, actions and requests (`GraineInApp.configure(_:name:)`).
     * An empty name is the default agent. A second call for a name already
     * configured returns that agent unchanged. Never nil.
     */
    @objc(configureWithBaseUrl:publishableKey:appVersion:debug:endOnBackground:captureTaps:transport:variablesJSON:name:)
    public static func configure(
        baseUrl: String, publishableKey: String, appVersion: String?, debug: Bool, endOnBackground: Bool,
        captureTaps: Bool, transport: String?, variablesJSON: String?, name: String
    ) -> GraineObjC? {
        configure(config(
            baseUrl: baseUrl, publishableKey: publishableKey, appVersion: appVersion, debug: debug,
            endOnBackground: endOnBackground, captureTaps: captureTaps, transport: transport, variablesJSON: variablesJSON
        ), name: name)
    }

    /**
     * `configure…name:` with the chat window's size, for a bridge: `compact`,
     * `large` or `full` (nil, or any other word, follows the dashboard's
     * Window size). A second call for a name already configured returns that
     * agent unchanged. Never nil.
     */
    @objc(configureWithBaseUrl:publishableKey:appVersion:debug:endOnBackground:captureTaps:transport:variablesJSON:name:chatSize:)
    public static func configure(
        baseUrl: String, publishableKey: String, appVersion: String?, debug: Bool, endOnBackground: Bool,
        captureTaps: Bool, transport: String?, variablesJSON: String?, name: String, chatSize: String?
    ) -> GraineObjC? {
        configure(config(
            baseUrl: baseUrl, publishableKey: publishableKey, appVersion: appVersion, debug: debug,
            endOnBackground: endOnBackground, captureTaps: captureTaps, transport: transport, variablesJSON: variablesJSON,
            chatSize: chatSize
        ), name: name)
    }

    static func configure(_ config: GraineConfig, name: String = GraineAgentRegistry.defaultName) -> GraineObjC {
        facade(for: GraineInApp.configure(config, name: agentName(name)))
    }

    static func config(
        baseUrl: String, publishableKey: String, appVersion: String?, debug: Bool, endOnBackground: Bool,
        captureTaps: Bool, transport: String?, variablesJSON: String?, chatSize: String? = nil
    ) -> GraineConfig {
        GraineConfig(
            baseUrl: baseUrl,
            publishableKey: publishableKey,
            variables: ObjCBridge.object(variablesJSON) ?? [:],
            transport: transport.flatMap { GraineTransport(rawValue: $0) },
            appVersion: appVersion,
            endOnBackground: endOnBackground,
            debug: debug,
            captureTaps: captureTaps,
            chatSize: chatSize.flatMap { GraineChatSize(rawValue: $0) }
        )
    }

    /// The facade over the agent configured under `name` (here or from Swift), or nil.
    @objc(named:)
    public static func named(_ name: String) -> GraineObjC? {
        GraineInApp.named(agentName(name)).map { facade(for: $0) }
    }

    /// A name as agents are kept: trimmed; empty is the default.
    static func agentName(_ name: String) -> String {
        GraineAgentRegistry.normalise(name)
    }

    /// The facade over the default agent (else the first configured); nil before any is configured (from here, or from Swift).
    @objc(current)
    public static var current: GraineObjC? {
        GraineInApp.current.map { facade(for: $0) }
    }

    /// The name this agent was configured under: `default` for the default agent.
    @objc public var name: String { graine.name }

    static func facade(for graine: GraineInApp) -> GraineObjC {
        lock.lock()
        defer { lock.unlock() }
        let key = ObjectIdentifier(graine)
        if let existing = facades[key] { return existing }
        let made = GraineObjC(graine: graine)
        facades[key] = made
        return made
    }

    // MARK: Who, and memory

    /// This install's id, kept in the Keychain. The agent never sees it.
    @objc public var installId: String { graine.installId }

    /// The current user's memory choice (true until they turn it off).
    @objc public var memoryChoice: Bool { graine.memoryChoice }

    /// Who is signed in; nil signs out. Keeps the user's memory choice.
    @objc(identify:)
    public func identify(_ traits: [String: Any]?) {
        graine.identify(traits.map { $0.mapValues { Optional($0) } })
    }

    /// Who is signed in, and whether their conversations are remembered.
    @objc(identify:memory:)
    public func identify(_ traits: [String: Any]?, memory: Bool) {
        graine.identify(traits.map { $0.mapValues { Optional($0) } }, memory: memory)
    }

    /// `identify:` for a bridge: the traits as a JSON object; nil or `null` signs out.
    @objc(identifyJSON:)
    public func identifyJSON(_ traitsJSON: String?) {
        identify(ObjCBridge.object(traitsJSON))
    }

    @objc(identifyJSON:memory:)
    public func identifyJSON(_ traitsJSON: String?, memory: Bool) {
        identify(ObjCBridge.object(traitsJSON), memory: memory)
    }

    @objc(setMemory:)
    public func setMemory(_ enabled: Bool) {
        graine.setMemory(enabled)
    }

    /**
     * Forget everything the agent remembers about the signed-in user. The
     * block hears how many memories were deleted, or the error
     * (`identity_required`, `device_limit`…).
     */
    @objc(forgetMemoryWithCompletion:)
    public func forgetMemory(completion: @escaping (Int, NSError?) -> Void) {
        Task { [graine] in
            do {
                let deleted = try await graine.forgetMemory()
                await MainActor.run { completion(deleted, nil) }
            } catch {
                await MainActor.run { completion(0, ObjCBridge.nsError(error)) }
            }
        }
    }

    /// What the agent remembers about the signed-in user, newest first.
    @objc(memoriesWithCompletion:)
    public func memories(completion: @escaping ([GraineObjCMemory]?, NSError?) -> Void) {
        Task { [graine] in
            do {
                let list = try await graine.memories()
                await MainActor.run { completion(list.map { GraineObjCMemory($0) }, nil) }
            } catch {
                await MainActor.run { completion(nil, ObjCBridge.nsError(error)) }
            }
        }
    }

    /// `memoriesWithCompletion:` for a bridge: a JSON array of `{id, text, createdAt, updatedAt}` (epoch ms).
    @objc(memoriesJSONWithCompletion:)
    public func memoriesJSON(completion: @escaping (String?, NSError?) -> Void) {
        Task { [graine] in
            do {
                let list = try await graine.memories()
                await MainActor.run { completion(ObjCBridge.text(list.map { ObjCBridge.memory($0) }), nil) }
            } catch {
                await MainActor.run { completion(nil, ObjCBridge.nsError(error)) }
            }
        }
    }

    /// Prompt variables from the app's data. Merged; NSNull under a key removes it; nil clears all.
    @objc(setVariables:)
    public func setVariables(_ values: [String: Any]?) {
        graine.setVariables(values.map { $0.mapValues { $0 is NSNull ? nil : Optional($0) } })
    }

    @objc(setVariablesJSON:)
    public func setVariablesJSON(_ json: String?) {
        setVariables(ObjCBridge.object(json))
    }

    // MARK: The screen

    /// What the user is looking at: `screen`, `title`, `journey`, `fields`, `error`, `data`, `availableActions`. Nil: nothing.
    @objc(setScreen:)
    public func setScreen(_ screen: [String: Any]?) {
        graine.setScreen(ObjCBridge.screen(screen))
    }

    @objc(setScreenJSON:)
    public func setScreenJSON(_ json: String?) {
        setScreen(ObjCBridge.object(json))
    }

    /// One field changed: `name`, `label`, `value`, `status`, `error`, `optional`.
    @objc(updateField:)
    public func updateField(_ field: [String: Any]) {
        if let f = ObjCBridge.field(field) { graine.updateField(f) }
    }

    @objc(updateFieldJSON:)
    public func updateFieldJSON(_ json: String) {
        updateField(ObjCBridge.object(json) ?? [:])
    }

    @objc(removeField:)
    public func removeField(_ name: String) {
        graine.removeField(name)
    }

    /// The user left a screen; with an id, only if it is still the one described.
    @objc(clearScreen:)
    public func clearScreen(_ screenId: String?) {
        graine.clearScreen(screenId)
    }

    /// A product event that informs without interrupting.
    @objc(track:data:)
    public func track(_ name: String, data: [String: Any]?) {
        graine.track(name, data: data ?? [:])
    }

    /// `track:data:` for a bridge: the data as a JSON object.
    @objc(trackEvent:dataJSON:)
    public func trackEvent(_ name: String, dataJSON: String?) {
        graine.track(name, data: ObjCBridge.object(dataJSON) ?? [:])
    }

    @objc(tap:)
    public func tap(_ name: String) {
        graine.tap(name)
    }

    @objc(noteInteraction)
    public func noteInteraction() {
        graine.noteInteraction()
    }

    // MARK: What the agent may do

    /**
     * Something the agent can do in the app. The handler runs on the main
     * thread with the arguments, and calls `answer` once, from any thread,
     * within six seconds.
     */
    @objc(registerAction:handler:)
    public func registerAction(
        _ name: String,
        handler: @escaping ([String: Any], @escaping (GraineObjCActionResult) -> Void) -> Void
    ) -> GraineObjCRegistration {
        let unregister = graine.registerAction(name, deferred: { args, done in
            handler(args) { done($0.result) }
        })
        return GraineObjCRegistration(unregister)
    }

    /**
     * `registerAction:handler:` for a bridge: the arguments arrive as a JSON
     * object; `answer` takes the status (`ok`, `refused`, `error`), the message
     * and the structured result as a JSON object (or nil).
     */
    @objc(registerJSONAction:handler:)
    public func registerJSONAction(
        _ name: String,
        handler: @escaping (String, @escaping (String, String, String?) -> Void) -> Void
    ) -> GraineObjCRegistration {
        let unregister = graine.registerAction(name, deferred: { args, done in
            handler(ObjCBridge.text(args)) { status, message, dataJSON in
                done(ObjCBridge.actionResult(status: status, message: message, data: ObjCBridge.object(dataJSON) ?? [:]))
            }
        })
        return GraineObjCRegistration(unregister)
    }

    // MARK: Calls the agent will make

    /// Book a call for `at`; the block hears the booked call or the refusal (`scheduling_off`, `too_soon`, `outside_window`…).
    @objc(scheduleCallAt:reason:completion:)
    public func scheduleCall(at: Date, reason: String?, completion: @escaping (GraineObjCScheduledCall?, NSError?) -> Void) {
        Task { [graine] in
            do {
                let call = try await graine.scheduleCall(at: at, reason: reason)
                await MainActor.run { completion(GraineObjCScheduledCall(call), nil) }
            } catch {
                await MainActor.run { completion(nil, ObjCBridge.nsError(error)) }
            }
        }
    }

    /// `scheduleCallAt:reason:completion:` for a bridge: the call as JSON `{id, at, status, source, reason}`.
    @objc(scheduleCallJSONAt:reason:completion:)
    public func scheduleCallJSON(at: Date, reason: String?, completion: @escaping (String?, NSError?) -> Void) {
        Task { [graine] in
            do {
                let call = try await graine.scheduleCall(at: at, reason: reason)
                await MainActor.run { completion(ObjCBridge.text(ObjCBridge.scheduledCall(call)), nil) }
            } catch {
                await MainActor.run { completion(nil, ObjCBridge.nsError(error)) }
            }
        }
    }

    /// The calls still to come, soonest first.
    @objc(scheduledCallsWithCompletion:)
    public func scheduledCalls(completion: @escaping ([GraineObjCScheduledCall]?, NSError?) -> Void) {
        Task { [graine] in
            do {
                let list = try await graine.scheduledCalls()
                await MainActor.run { completion(list.map { GraineObjCScheduledCall($0) }, nil) }
            } catch {
                await MainActor.run { completion(nil, ObjCBridge.nsError(error)) }
            }
        }
    }

    @objc(scheduledCallsJSONWithCompletion:)
    public func scheduledCallsJSON(completion: @escaping (String?, NSError?) -> Void) {
        Task { [graine] in
            do {
                let list = try await graine.scheduledCalls()
                await MainActor.run { completion(ObjCBridge.text(list.map { ObjCBridge.scheduledCall($0) }), nil) }
            } catch {
                await MainActor.run { completion(nil, ObjCBridge.nsError(error)) }
            }
        }
    }

    /// Call one off. The block hears the call's status afterwards (`cancelled`), or the error (`not_found`…).
    @objc(cancelScheduledCall:completion:)
    public func cancelScheduledCall(_ callId: String, completion: @escaping (String?, NSError?) -> Void) {
        Task { [graine] in
            do {
                let status = try await graine.cancelScheduledCall(id: callId)
                await MainActor.run { completion(status.wire, nil) }
            } catch {
                await MainActor.run { completion(nil, ObjCBridge.nsError(error)) }
            }
        }
    }

    /**
     * Whether this agent can be booked from the app now: Graine rings this
     * iPhone, the agent lets customers book, and the customer is identified.
     * `presentBookingWithReason:completion:` shows the SDK's booking sheet.
     */
    @objc public var bookingAvailable: Bool { graine.bookingAvailable }

    // MARK: The session, and what the SDK reports

    /// The agent's configuration, once it has loaded.
    @objc public var session: GraineObjCSession? { graine.session.map { GraineObjCSession($0) } }

    /// The session as JSON, for a bridge; nil before it has loaded.
    @objc public var sessionJSON: String? { graine.session.map { ObjCBridge.text(ObjCBridge.session($0)) } }

    /// Hear every event (held weakly). Main thread.
    @objc(addListener:)
    public func addListener(_ listener: GraineObjCListener) {
        onMain { self.events.add(listener: listener) }
    }

    @objc(removeListener:)
    public func removeListener(_ listener: GraineObjCListener) {
        onMain { self.events.remove(listener: listener) }
    }

    /// Every event as its name and its payload's JSON, for a bridge, until the registration is stopped. Main thread.
    @objc(observeEvents:)
    public func observeEvents(_ observer: @escaping (String, String) -> Void) -> GraineObjCRegistration {
        let id = UUID()
        onMain { self.eventBlocks[id] = observer }
        return GraineObjCRegistration { [weak self] in self?.onMain { self?.eventBlocks.removeValue(forKey: id) } }
    }

    /// Main thread.
    func emit(_ name: String, _ payload: [String: Any]) {
        let json = ObjCBridge.text(payload)
        for block in Array(eventBlocks.values) { block(name, json) }
        events.notify { $0.graineEvent(name, payload: payload, json: json) }
    }

    func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }
}

/// The SDK's listener, turned into the facade's events. Held by the facade (the SDK holds listeners weakly).
final class ObjCEventRelay: GraineListener {
    private weak var facade: GraineObjC?

    init(_ facade: GraineObjC) {
        self.facade = facade
    }

    func onSessionReady(_ session: GraineSessionConfig) { facade?.emit("sessionReady", ObjCBridge.session(session)) }
    func onCaption(role: GraineRole, text: String, live: Bool) {
        facade?.emit("caption", ["role": role == .agent ? "agent" : "user", "text": text, "live": live])
    }
    func onEnded() { facade?.emit("voiceEnded", [:]) }
    func onWidget(_ widget: [String: Any]) { facade?.emit("widget", ["widget": widget]) }
    func onWidgetPending(_ hint: [String: Any]) { facade?.emit("widgetPending", ["hint": hint]) }
    func onMicDenied(reason: String) { facade?.emit("micDenied", ["reason": reason]) }
    func onActionRequested(name: String) { facade?.emit("actionRequested", ["name": name]) }
    func onActionCompleted(name: String, result: GraineActionResult) {
        facade?.emit("actionCompleted", ["name": name, "status": result.status.rawValue, "message": result.message])
    }
    func onFriction(_ signal: GraineFrictionSignal) {
        facade?.emit("friction", ["name": signal.name, "screen": signal.screen, "detail": signal.detail])
    }
    func onChatMessage(_ turn: GraineChatTurn) { facade?.emit("chatMessage", ["turn": ObjCBridge.turn(turn)]) }
    func onError(_ message: String) { facade?.emit("error", ["message": message]) }
}
