import Foundation

/*
 * THE CALLS HOST, WITHOUT THE PHONE — every rule for driving the native call
 * engine from React Native and Flutter, in Foundation, so a Mac proves it.
 *
 * Those packages reach the engine through one object, GraineCallsHost, and
 * speak JSON-safe values only: strings, numbers, booleans, null, lists and
 * string-keyed maps. Their own code only marshals values and hops threads. An
 * `if` about calls inside a wrapper is a rule this SDK's tests never see, so
 * every one lives here instead: the options (checked, normalised and kept for
 * a cold start), the screen and an action's answer as JavaScript or Dart
 * describe them, the call's snapshot and events, where each event goes, and
 * what each method does (`CallsHostCore`). GraineCallsHost is that core with
 * its hands on iOS.
 */

/// Why the host refused a call from React Native or Flutter: a code for the platform's error (`invalid_options`) and a sentence for the developer.
public struct GraineCallsHostError: LocalizedError, Equatable {
    public let code: String
    public let message: String

    public var errorDescription: String? { message }

    static func invalidOptions(_ message: String) -> GraineCallsHostError {
        GraineCallsHostError(code: "invalid_options", message: message)
    }
}

// MARK: - Options

/// Who draws the call while the app is open: the SDK's call screen, or the app's own.
enum CallsHostCallScreen: String {
    case sdk
    case app
}

/**
 * THE OPTIONS a wrapper's `configure` passes, checked and normalised:
 *
 *   publishableKey   string, required, non-empty
 *   displayName      string, required, non-empty once trimmed
 *   baseUrl          string; https://www.graine.ai by default, no trailing "/"
 *   ringtoneSound    string or null: a sound file in the app's bundle
 *   ringTimeoutMs    number; 30000 by default, and for anything not above 0
 *   appVersion       string or null
 *   callScreen       "sdk" (the default) or "app"
 *   android          { smallIcon: string or null }
 *   ios              { iconTemplate: string or null, includesCallsInRecents: bool }
 *
 * Unknown keys are ignored, so an older SDK reads a newer package's options,
 * and null is the same as absent. A known key of the wrong type is refused,
 * naming it ("ringTimeoutMs must be a number"), rather than quietly becoming
 * its default: a ring that gives up at 30 s when the app asked for 45 is a bug
 * nobody finds. `android` is Android's, but it is checked here too, so one set
 * of options is valid on both platforms or on neither.
 */
struct CallsHostOptions: Equatable {
    static let defaultBaseUrl = "https://www.graine.ai"
    static let defaultRingTimeoutMs = 30_000

    var publishableKey: String
    var displayName: String
    var baseUrl = CallsHostOptions.defaultBaseUrl
    var ringtoneSound: String?
    var ringTimeoutMs = CallsHostOptions.defaultRingTimeoutMs
    var appVersion: String?
    var callScreen = CallsHostCallScreen.sdk
    var androidSmallIcon: String?
    var iosIconTemplate: String?
    var iosIncludesCallsInRecents = false

    /// The ring timeout in seconds, as `GraineCallsConfig` takes it.
    var ringTimeout: TimeInterval { Double(ringTimeoutMs) / 1_000 }

    static func parse(_ raw: Any?) throws -> CallsHostOptions {
        var map: [String: Any] = [:]
        if let value = JSON.unwrap(raw), !(value is NSNull) {
            guard let object = CallsHostValues.map(value) else {
                throw GraineCallsHostError.invalidOptions("options must be an object")
            }
            map = object
        }
        guard let key = try string(map, "publishableKey"), !key.isEmpty else {
            throw GraineCallsHostError.invalidOptions("publishableKey is required")
        }
        guard let name = try string(map, "displayName").flatMap(nonBlank) else {
            throw GraineCallsHostError.invalidOptions("displayName is required")
        }
        var options = CallsHostOptions(publishableKey: key, displayName: name)
        if let base = try string(map, "baseUrl").flatMap(nonBlank) {
            let trimmed = GraineProtocol.trimTrailingSlashes(base)
            if !trimmed.isEmpty { options.baseUrl = trimmed }
        }
        options.ringtoneSound = try string(map, "ringtoneSound").flatMap(nonBlank)
        if let ms = try number(map, "ringTimeoutMs"), ms.isFinite, ms > 0 {
            // Bounded before it becomes an Int: a huge number must not take the app down.
            options.ringTimeoutMs = Int(min(ms, Double(Int32.max)).rounded(.up))
        }
        options.appVersion = try string(map, "appVersion").flatMap(nonBlank)
        if let word = try string(map, "callScreen") {
            guard let screen = CallsHostCallScreen(rawValue: word) else {
                throw GraineCallsHostError.invalidOptions("callScreen must be \"sdk\" or \"app\"")
            }
            options.callScreen = screen
        }
        if let android = try object(map, "android") {
            options.androidSmallIcon = try string(android, "smallIcon", named: "android.smallIcon").flatMap(nonBlank)
        }
        if let ios = try object(map, "ios") {
            options.iosIconTemplate = try string(ios, "iconTemplate", named: "ios.iconTemplate").flatMap(nonBlank)
            options.iosIncludesCallsInRecents =
                try bool(ios, "includesCallsInRecents", named: "ios.includesCallsInRecents") ?? false
        }
        return options
    }

    /// What is kept for a cold start: every key, normalised, so that `parse(json)` gives these options back.
    var json: [String: Any] {
        var out: [String: Any] = [
            "publishableKey": publishableKey,
            "displayName": displayName,
            "baseUrl": baseUrl,
            "ringTimeoutMs": ringTimeoutMs,
            "callScreen": callScreen.rawValue,
        ]
        if let sound = ringtoneSound { out["ringtoneSound"] = sound }
        if let version = appVersion { out["appVersion"] = version }
        if let icon = androidSmallIcon { out["android"] = ["smallIcon": icon] }
        var ios: [String: Any] = ["includesCallsInRecents": iosIncludesCallsInRecents]
        if let icon = iosIconTemplate { ios["iconTemplate"] = icon }
        out["ios"] = ios
        return out
    }

    // MARK: Reading one key

    /// The value under `key`, or nil when it is absent or null.
    private static func value(_ map: [String: Any], _ key: String) -> Any? {
        guard let value = JSON.unwrap(map[key]), !(value is NSNull) else { return nil }
        return value
    }

    private static func string(_ map: [String: Any], _ key: String, named: String? = nil) throws -> String? {
        guard let raw = value(map, key) else { return nil }
        guard let text = raw as? String else {
            throw GraineCallsHostError.invalidOptions("\(named ?? key) must be a string")
        }
        return text
    }

    private static func number(_ map: [String: Any], _ key: String) throws -> Double? {
        guard let raw = value(map, key) else { return nil }
        guard let number = JSON.number(raw) else {
            throw GraineCallsHostError.invalidOptions("\(key) must be a number")
        }
        return number.doubleValue
    }

    private static func bool(_ map: [String: Any], _ key: String, named: String) throws -> Bool? {
        guard let raw = value(map, key) else { return nil }
        guard let flag = JSON.bool(raw) else {
            throw GraineCallsHostError.invalidOptions("\(named) must be a boolean")
        }
        return flag
    }

    private static func object(_ map: [String: Any], _ key: String) throws -> [String: Any]? {
        guard let raw = value(map, key) else { return nil }
        guard let object = CallsHostValues.map(raw) else {
            throw GraineCallsHostError.invalidOptions("\(key) must be an object")
        }
        return object
    }

    private static func nonBlank(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Values from a wrapper

/// JSON-safe values from JavaScript or Dart, read the lenient way the rest of the SDK reads JSON.
enum CallsHostValues {
    /// A string-keyed map, or nil. A key that is not a string is dropped: the values are JSON.
    static func map(_ raw: Any?) -> [String: Any]? {
        guard let value = JSON.unwrap(raw), !(value is NSNull) else { return nil }
        if let object = value as? [String: Any] { return object }
        guard let any = value as? [AnyHashable: Any] else { return nil }
        var out: [String: Any] = [:]
        for (key, item) in any {
            if let name = key.base as? String { out[name] = item }
        }
        return out
    }

    /// A list of names: strings only, never empty, each once, in the order given.
    static func names(_ raw: Any?) -> [String] {
        guard let list = JSON.unwrap(raw) as? [Any] else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for item in list {
            guard let name = JSON.unwrap(item) as? String, !name.isEmpty, seen.insert(name).inserted else { continue }
            out.append(name)
        }
        return out
    }

    /**
     * THE SCREEN, as the app's JavaScript or Dart describes it: `{screen,
     * title?, journey?: {name, step?, of?, next?}, fields?: [{name, label?,
     * value?, status?, error?, optional?}], error?, data?, availableActions?}`.
     *
     * No screen name, no screen. A field's value is text whatever it was sent
     * as, a number written the way JavaScript writes it (1299 is "1299", never
     * "1299.0": the agent reads it out). A status this SDK does not know is no
     * status, never a guess. `availableActions` keeps its two meanings apart:
     * absent allows every action, an empty list allows none.
     */
    static func screen(_ raw: Any?) -> GraineScreen? {
        guard let object = CallsHostValues.map(raw),
              let name = text(object["screen"])?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        var out = GraineScreen(screen: name, title: text(object["title"]), error: text(object["error"]))
        if let journey = CallsHostValues.map(object["journey"]), let journeyName = text(journey["name"]) {
            out.journey = GraineScreen.Journey(
                name: journeyName,
                step: integer(journey["step"]),
                of: integer(journey["of"]),
                next: text(journey["next"])
            )
        }
        if let fields = JSON.unwrap(object["fields"]) as? [Any] {
            out.fields = fields.compactMap { CallsHostValues.field($0) }
        }
        if let data = CallsHostValues.map(object["data"]), let clean = JSON.normalize(data) as? [String: Any] {
            out.data = clean
        }
        if let actions = JSON.unwrap(object["availableActions"]), actions is [Any] {
            out.availableActions = names(actions)
        }
        return out
    }

    private static func field(_ raw: Any) -> GraineField? {
        guard let object = CallsHostValues.map(raw), let name = text(object["name"]) else { return nil }
        return GraineField(
            name: name,
            label: text(object["label"]),
            value: JSON.text(object["value"]),
            status: JSON.text(object["status"]).flatMap { GraineField.Status(rawValue: $0) },
            error: text(object["error"]),
            isOptional: JSON.flag(object["optional"])
        )
    }

    /**
     * AN ACTION'S ANSWER: `{status, message?, data?}`. A status other than
     * `ok`, `refused` or `error` is an error: the agent must never be told that
     * something happened when nobody said it did.
     */
    static func actionResult(_ raw: Any?) -> GraineActionResult {
        guard let object = CallsHostValues.map(raw) else { return .error("The app answered without a result.") }
        let message = JSON.text(object["message"]) ?? ""
        let data = CallsHostValues.map(object["data"]).flatMap { JSON.normalize($0) as? [String: Any] } ?? [:]
        let word = JSON.text(object["status"])
        guard let status = word.flatMap({ GraineActionResult.Status(rawValue: $0) }) else {
            let why = word.map { "The app answered with an unknown status \"\($0)\"." } ?? "The app answered without a status."
            return GraineActionResult(status: .error, message: message.isEmpty ? why : message, data: data)
        }
        return GraineActionResult(status: status, message: message, data: data)
    }

    /// `startCall`'s options: `{reason?, variables?}`.
    static func callRequest(_ raw: Any?) -> (reason: String?, variables: [String: Any]) {
        let request = CallsHostValues.map(raw) ?? [:]
        let reason = text(request["reason"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (reason, CallsHostValues.map(request["variables"]) ?? [:])
    }

    /// A scalar as text; nil when it is absent, null, blank or not a scalar.
    private static func text(_ raw: Any?) -> String? {
        guard let text = JSON.text(raw), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// A whole number from a number or a numeric string; nil for anything else, or anything out of range.
    private static func integer(_ raw: Any?) -> Int? {
        guard let value = JSON.unwrap(raw), !(value is NSNull) else { return nil }
        if let number = JSON.number(value) {
            let d = number.doubleValue
            guard d.isFinite, abs(d) <= Double(Int32.max) else { return nil }
            return Int(d.rounded())
        }
        if let text = value as? String { return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }
}

// MARK: - The snapshot

/**
 * THE CALL AS A CALL SCREEN DRAWS IT: the `state` event and `snapshot()`.
 *
 * Every key is always there (null, never missing), so JavaScript and Dart
 * never read `undefined`. At idle nothing of a call shows except `error`: why
 * the call that just ended could not connect stays until the next one rings or
 * is placed, so a screen can still say so after the system's call UI is gone.
 */
struct CallsHostSnapshot: Equatable {
    var state: GraineCallState = .idle
    var callId: String?
    var direction: GraineCallDirection?
    /// The push's reason, or startCall's.
    var reason: String?
    var callerName: String?
    var muted = false
    var speakerOn = false
    var agentSpeaking = false
    var caption: GraineCaption?
    var connectedAt: Date?
    /// Why the last call failed; cleared when the next call starts.
    var error: String?

    /// The idle rule applied and blanks made null: what is shown, and what is compared.
    var settled: CallsHostSnapshot {
        guard state != .idle else { return CallsHostSnapshot(error: CallsHostSnapshot.present(error)) }
        var out = self
        out.callId = CallsHostSnapshot.present(callId)
        out.reason = CallsHostSnapshot.present(reason)
        out.callerName = CallsHostSnapshot.present(callerName)
        out.error = CallsHostSnapshot.present(error)
        return out
    }

    var json: [String: Any] {
        let s = settled
        var caption: Any = NSNull()
        if let line = s.caption {
            caption = ["role": line.role.rawValue, "text": line.text, "live": line.live] as [String: Any]
        }
        var connectedAt: Any = NSNull()
        if let date = s.connectedAt {
            // Milliseconds since the Unix epoch, as JavaScript's Date and Dart's DateTime take them.
            connectedAt = NSNumber(value: Int64((date.timeIntervalSince1970 * 1_000).rounded()))
        }
        return [
            "state": CallsHostSnapshot.word(s.state),
            "callId": CallsHostSnapshot.orNull(s.callId),
            "direction": CallsHostSnapshot.orNull(s.direction?.rawValue),
            "reason": CallsHostSnapshot.orNull(s.reason),
            "callerName": CallsHostSnapshot.orNull(s.callerName),
            "muted": s.muted,
            "speakerOn": s.speakerOn,
            "agentSpeaking": s.agentSpeaking,
            "caption": caption,
            "connectedAt": connectedAt,
            "error": CallsHostSnapshot.orNull(s.error),
        ]
    }

    static func word(_ state: GraineCallState) -> String {
        switch state {
        case .idle: return "idle"
        case .ringing: return "ringing"
        case .connecting: return "connecting"
        case .active: return "active"
        case .ended: return "ended"
        }
    }

    private static func orNull(_ text: String?) -> Any {
        text ?? NSNull()
    }

    private static func present(_ text: String?) -> String? {
        guard let text = text, !text.isEmpty else { return nil }
        return text
    }
}

/**
 * ONE `state` EVENT PER TURN OF THE MAIN LOOP, and only when something a call
 * screen draws has changed. The engine's properties change one at a time — a
 * connect moves the state, the direction, the id and the name in a row — and
 * a JavaScript screen re-rendered four times for one change is three renders
 * of nothing. Starts at idle, so an idle engine says nothing at all.
 */
struct CallsHostStateGate {
    private(set) var last = CallsHostSnapshot()
    private(set) var scheduled = false

    /// Something may have changed. True when a turn must be scheduled to look (none is pending).
    mutating func changed() -> Bool {
        guard !scheduled else { return false }
        scheduled = true
        return true
    }

    /// The scheduled turn: the snapshot to send, or nil when nothing a screen draws changed.
    mutating func flush(_ current: CallsHostSnapshot) -> CallsHostSnapshot? {
        scheduled = false
        let next = current.settled
        guard next != last else { return nil }
        last = next
        return next
    }
}

// MARK: - Events

/**
 * THE EVENTS, by name, with their payloads — the same names and shapes on
 * Android. React Native renames them (`GraineCallState`, `GraineCallOutcome`,
 * `GraineIncomingCall`, `GraineVoIPToken`, `GraineActionRequest`); Flutter
 * streams `{"event": name, "data": payload}`.
 */
enum CallsHostEvent {
    static let state = "state"
    static let outcome = "outcome"
    static let incoming = "incoming"
    static let voipToken = "voipToken"
    static let action = "action"

    /// `{callId, outcome, reason?, error?}`: `reason` (local, remote, failed) only with `ended`, `error` only with `failed`.
    static func outcomePayload(_ outcome: GraineCallOutcome, callId: String) -> [String: Any] {
        var out: [String: Any] = ["callId": callId, "outcome": outcome.wire]
        if let reason = outcome.endReason { out["reason"] = reason.rawValue }
        if let error = outcome.error { out["error"] = error }
        return out
    }

    /// `{callId, reason, callerName}`, as the push said them.
    static func incomingPayload(_ call: GraineIncomingCall) -> [String: Any] {
        let reason: Any = call.reason ?? NSNull()
        let callerName: Any = call.callerName ?? NSNull()
        return ["callId": call.callId, "reason": reason, "callerName": callerName]
    }

    /// `{token}`: hex, or null once it is invalidated.
    static func tokenPayload(_ token: String?) -> [String: Any] {
        let value: Any = token ?? NSNull()
        return ["token": value]
    }

    static func actionPayload(requestId: String, name: String, arguments: [String: Any]) -> [String: Any] {
        ["requestId": requestId, "name": name, "arguments": JSON.normalize(arguments)]
    }
}

// MARK: - Sinks

/**
 * WHERE EVENTS GO. React Native adds one sink; Flutter adds one per engine (its
 * main isolate, and a background messaging isolate). Every event reaches every
 * sink, except an action request, which goes only to the sink that last listed
 * a non-empty set of actions: one handler runs an action once, never once per
 * engine. Outcomes and rings raised while no sink is attached — a call that
 * rang, was answered and ended before any JavaScript ran — wait, the last 20,
 * for the first sink to arrive. The state never waits: a new sink reads the
 * snapshot, which is newer than anything that could have waited.
 */
final class CallsHostSinks {
    typealias Sink = (_ event: String, _ payload: [String: Any]) -> Void

    static let queueLimit = 20

    private var sinks: [(token: Int, sink: Sink)] = []
    private var nextToken = 1
    /// The sink that last listed a non-empty set of actions, attached or not.
    private(set) var actionSink: Int?
    private(set) var queued: [(event: String, payload: [String: Any])] = []

    var count: Int { sinks.count }

    /// Add a sink. The first one also receives everything that waited, in order.
    func add(_ sink: @escaping Sink) -> Int {
        let token = nextToken
        nextToken += 1
        sinks.append((token, sink))
        if !queued.isEmpty {
            let waited = queued
            queued = []
            for item in waited { sink(item.event, item.payload) }
        }
        return token
    }

    func remove(_ token: Int) {
        sinks.removeAll { $0.token == token }
    }

    func contains(_ token: Int?) -> Bool {
        guard let token = token else { return false }
        return sinks.contains { $0.token == token }
    }

    /// A list of actions arrived from `token`. Only a non-empty one makes its sender the one that answers.
    func listedActions(_ names: [String], by token: Int?) {
        if !names.isEmpty { actionSink = token }
    }

    /// Everything but an action request: to every sink, or (an outcome or a ring) to the queue.
    func emit(_ event: String, _ payload: [String: Any]) {
        guard !sinks.isEmpty else {
            guard event == CallsHostEvent.outcome || event == CallsHostEvent.incoming else { return }
            queued.append((event, payload))
            if queued.count > CallsHostSinks.queueLimit { queued.removeFirst(queued.count - CallsHostSinks.queueLimit) }
            return
        }
        for entry in sinks { entry.sink(event, payload) }
    }

    /// An action request, to the action sink only. False when it is gone: the request must be refused at once.
    func emitAction(_ payload: [String: Any]) -> Bool {
        guard let token = actionSink, let entry = sinks.first(where: { $0.token == token }) else { return false }
        entry.sink(CallsHostEvent.action, payload)
        return true
    }
}

// MARK: - Variables

/**
 * A WRAPPER'S setVariables REPLACES. The app's JavaScript or Dart holds the
 * whole map and sends all of it every time, while the SDK's setVariables
 * merges. So a key the last map set and this one leaves out is sent as a
 * removal, or a variable the app dropped would reach every call after it. A
 * value that cannot be a variable (null, a list, an object) is a removal too:
 * the variables become exactly what this map can say.
 */
struct CallsHostVariables {
    private(set) var keys: Set<String> = []

    /// The change for `GraineInApp.setVariables`: this map's values, and nil under every key to remove.
    mutating func replace(with values: [String: Any]?) -> [String: Any?] {
        var out: [String: Any?] = [:]
        var kept = Set<String>()
        for (key, value) in values ?? [:] where !key.isEmpty {
            if VariableStore.flattenOne(value) != nil {
                out[key] = .some(value)
                kept.insert(key)
            } else {
                out.updateValue(nil, forKey: key)
            }
        }
        for key in keys where !kept.contains(key) { out.updateValue(nil, forKey: key) }
        keys = kept
        return out
    }
}

// MARK: - Actions

/**
 * THE ACTIONS A WRAPPER ANSWERS, and the requests waiting on it.
 *
 * Each request has an id; the first answer to it wins, and a late, repeated or
 * unknown one is ignored. By then the SDK has already answered the agent (its
 * own six-second deadline), and a second answer must never reach it.
 */
final class CallsHostActions {
    typealias Answer = (GraineActionResult) -> Void

    private struct Waiting {
        let sink: Int?
        let answer: Answer
    }

    private var waiting: [String: Waiting] = [:]
    /// The names listed last, in order.
    private(set) var names: [String] = []

    var pendingCount: Int { waiting.count }

    /// A new list: what to register, and what to unregister.
    func list(_ next: [String]) -> (added: [String], removed: [String]) {
        let added = next.filter { !names.contains($0) }
        let removed = names.filter { !next.contains($0) }
        names = next
        return (added, removed)
    }

    /// A request sent to `sink`. Returns its id.
    func begin(sink: Int?, answer: @escaping Answer) -> String {
        let id = UUID().uuidString.lowercased()
        waiting[id] = Waiting(sink: sink, answer: answer)
        return id
    }

    /// The answer to one request. False when it is unknown or already answered.
    @discardableResult
    func resolve(_ id: String, _ result: GraineActionResult) -> Bool {
        guard let entry = waiting.removeValue(forKey: id) else { return false }
        entry.answer(result)
        return true
    }

    /// The sink a request went to is gone: nobody is left to answer it.
    func refuse(sink: Int, _ message: String) {
        let ids = waiting.filter { $0.value.sink == sink }.map { $0.key }
        for id in ids { resolve(id, .refused(message)) }
    }
}

// MARK: - Kept for a cold start

/**
 * THE OPTIONS, KEPT FOR A COLD START. A VoIP push can wake an app that is not
 * running, and iOS stops delivering VoIP pushes to an app that does not report
 * every one to CallKit during launch, long before any JavaScript or Dart runs.
 * So `configure` keeps the options, and whether VoIP pushes were enabled,
 * under one key (`ai.graine.inapp.calls` → `{"options": {…}, "voip": bool}`),
 * and `restore()` reads them at launch.
 */
struct CallsHostStore {
    static let key = "ai.graine.inapp.calls"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> (options: [String: Any]?, voip: Bool) {
        guard let saved = defaults.dictionary(forKey: CallsHostStore.key) else { return (nil, false) }
        let voip = JSON.unwrap(saved["voip"]).flatMap { JSON.bool($0) } ?? false
        return (CallsHostValues.map(saved["options"]), voip)
    }

    func saveOptions(_ options: [String: Any]) {
        write(options, voip: load().voip)
    }

    func saveVoip(_ voip: Bool) {
        write(load().options, voip: voip)
    }

    private func write(_ options: [String: Any]?, voip: Bool) {
        var value: [String: Any] = ["voip": voip]
        if let options = options { value["options"] = options }
        // A value a property list cannot hold raises inside UserDefaults: a crash, not an error.
        guard PropertyListSerialization.propertyList(value, isValidFor: .binary) else {
            GraineLog.warning("The call options could not be kept for the next launch.")
            return
        }
        defaults.set(value, forKey: CallsHostStore.key)
    }
}

// MARK: - The SDK's call screen

/**
 * THE SDK'S CALL SCREEN over the app, when the app chose it (`callScreen:
 * "sdk"`): up while a call is live and the app is active — so a call answered
 * on the lock screen gets it the moment the app is opened — and down at idle,
 * not at "ended", so "Call ended" is read before it goes. With the app's own
 * screen (`"app"`), nothing is ever put over the app.
 */
enum CallsHostCallScreenRule {
    enum Step: Equatable {
        case present
        case dismiss
        case stay
    }

    static func step(callScreen: CallsHostCallScreen?, state: GraineCallState, active: Bool, shown: Bool) -> Step {
        guard callScreen == .sdk else { return shown ? .dismiss : .stay }
        if state == .idle { return shown ? .dismiss : .stay }
        return state.isLive && active && !shown ? .present : .stay
    }
}

// MARK: - The host's rules

/// What the host acts on: the SDK instance, its calls and the app around them. GraineCallsHost is the iOS one; the tests drive a fake.
protocol CallsHostPlatform: AnyObject {
    /// Make the SDK instance (one per process) and say which key and base URL it really runs with: the app may have made it first.
    func makeInstance(_ options: CallsHostOptions) -> (publishableKey: String, baseUrl: String)
    func configureCalls(_ options: CallsHostOptions)
    func enableVoIPPushes(onToken: @escaping (String?) -> Void)
    func startCall(reason: String?, variables: [String: Any]) -> String?
    func answer()
    func end()
    func setMuted(_ muted: Bool)
    func setSpeaker(_ on: Bool)
    func identify(_ traits: [String: Any]?)
    func setVariables(_ values: [String: Any?])
    func setScreen(_ screen: GraineScreen?)
    func registerAction(_ name: String, handler: @escaping GraineInApp.DeferredActionHandler) -> () -> Void
    /// The engine's half of the snapshot: everything but `reason` and `error`, which are the host's own.
    func callFields() -> CallsHostSnapshot
    /// In the foreground and active: not behind the lock screen, the app switcher or a system sheet.
    var appActive: Bool { get }
    func presentCallScreen()
    func dismissCallScreen()
    /// Run `block` on the next turn of the main loop.
    func nextTurn(_ block: @escaping () -> Void)
    /// Run `block` on the main loop after `seconds`.
    func after(_ seconds: TimeInterval, _ block: @escaping () -> Void)
}

/**
 * WHAT EACH OF THE HOST'S METHODS DOES. Main thread only: GraineCallsHost hops
 * there first.
 *
 * The first `configure` makes the SDK instance from the key, base URL and app
 * version; later ones update the calls' configuration, and a different key or
 * base URL is kept for the next launch (the instance is one per process).
 * `restore()` applies the kept options at launch, without keeping them again.
 * Identity, variables, the screen and actions sent before there is an
 * instance are held and applied when it is made. The snapshot's `reason` (the
 * push's, or startCall's) and `error` (why the last call could not connect)
 * are tracked here; the rest is the engine's.
 */
final class CallsHostCore {
    typealias Sink = CallsHostSinks.Sink

    /// A request the app never answered is forgotten after this: the SDK's own deadline (six seconds) has long since answered the agent.
    static let forgetActionAfter: TimeInterval = 10

    private let platform: CallsHostPlatform
    private let store: CallsHostStore
    let sinks = CallsHostSinks()
    let actions = CallsHostActions()
    private var variables = CallsHostVariables()
    private var gate = CallsHostStateGate()

    private(set) var options: CallsHostOptions?
    private var instance: (publishableKey: String, baseUrl: String)?
    private(set) var reason: String?
    private(set) var error: String?
    private var voipWanted = false
    private var voipRegistered = false
    private var tokenKnown = false
    private var token: String?
    private var registered: [String: () -> Void] = [:]
    private var screenShown = false

    /// Something a wrapper set before there was an instance to set it on; the value may itself be nil (cleared).
    private struct Held<Value> {
        let value: Value
    }
    private var heldIdentity: Held<[String: Any]?>?
    private var heldVariables: Held<[String: Any]?>?
    private var heldScreen: Held<GraineScreen?>?

    /// Where the host's warnings go; the SDK's log unless a test listens.
    var log: (String) -> Void = { GraineLog.warning($0) }

    init(platform: CallsHostPlatform, store: CallsHostStore) {
        self.platform = platform
        self.store = store
    }

    // MARK: Setting up

    func configure(_ raw: Any?) throws {
        let next = try CallsHostOptions.parse(raw)
        store.saveOptions(next.json)
        apply(next)
    }

    /// The kept options, applied at launch. False when there were none, or when this launch is already configured.
    @discardableResult
    func restore() -> Bool {
        guard options == nil else { return false }
        let saved = store.load()
        guard let raw = saved.options else { return false }
        let kept: CallsHostOptions
        do {
            kept = try CallsHostOptions.parse(raw)
        } catch {
            log("The kept call options could not be read (\(GraineInApp.describe(error))); calls wait for configure().")
            return false
        }
        if saved.voip { voipWanted = true }
        apply(kept)
        return true
    }

    private func apply(_ next: CallsHostOptions) {
        if instance == nil {
            let made = platform.makeInstance(next)
            instance = (made.publishableKey, GraineProtocol.trimTrailingSlashes(made.baseUrl))
            releaseHeld()
        }
        if let running = instance, running.publishableKey != next.publishableKey || running.baseUrl != next.baseUrl {
            log("The calls run with the publishableKey and baseUrl this launch started with; the new ones are kept and take effect at the next launch.")
        }
        options = next
        platform.configureCalls(next)
        if voipWanted { registerVoIP() }
        changed()
    }

    // MARK: VoIP pushes

    func enableVoIPPushes() {
        store.saveVoip(true)
        voipWanted = true
        // Replayed: the token may have arrived at launch, before anything listened for it.
        if tokenKnown { sinks.emit(CallsHostEvent.voipToken, CallsHostEvent.tokenPayload(token)) }
        if options != nil { registerVoIP() }
    }

    private func registerVoIP() {
        guard !voipRegistered else { return }
        voipRegistered = true
        platform.enableVoIPPushes { [weak self] token in self?.tokenArrived(token) }
    }

    private func tokenArrived(_ value: String?) {
        let news = !tokenKnown || value != token
        tokenKnown = true
        token = value
        if news { sinks.emit(CallsHostEvent.voipToken, CallsHostEvent.tokenPayload(value)) }
    }

    // MARK: Calls

    /// The customer calls the agent. Nil when the calls are not configured, or a call is live.
    func startCall(_ raw: Any?) -> String? {
        guard options != nil, !platform.callFields().state.isLive else { return nil }
        let request = CallsHostValues.callRequest(raw)
        let before = (reason, error)
        reason = request.reason
        error = nil
        guard let id = platform.startCall(reason: request.reason, variables: request.variables) else {
            (reason, error) = before
            return nil
        }
        changed()
        return id
    }

    func answer() {
        platform.answer()
    }

    /// iOS has no decline of its own: it is `end` while the call rings, and nothing otherwise.
    func decline() {
        if platform.callFields().state == .ringing { platform.end() }
    }

    func end() {
        platform.end()
    }

    func setMuted(_ muted: Bool) {
        platform.setMuted(muted)
    }

    func setSpeaker(_ on: Bool) {
        platform.setSpeaker(on)
    }

    // MARK: Who, what and where

    func setIdentity(_ raw: Any?) {
        let traits = CallsHostValues.map(raw)
        guard instance != nil else {
            heldIdentity = Held(value: traits)
            return
        }
        platform.identify(traits)
    }

    func setVariables(_ raw: Any?) {
        let values = CallsHostValues.map(raw)
        guard instance != nil else {
            heldVariables = Held(value: values)
            return
        }
        platform.setVariables(variables.replace(with: values))
    }

    func setScreen(_ raw: Any?) {
        let screen = CallsHostValues.screen(raw)
        guard instance != nil else {
            heldScreen = Held(value: screen)
            return
        }
        platform.setScreen(screen)
    }

    private func releaseHeld() {
        if let held = heldIdentity { platform.identify(held.value) }
        if let held = heldVariables { platform.setVariables(variables.replace(with: held.value)) }
        if let held = heldScreen { platform.setScreen(held.value) }
        heldIdentity = nil
        heldVariables = nil
        heldScreen = nil
        for name in actions.names { register(name) }
    }

    // MARK: Actions

    /// The names the wrapper (the sink `sink`) answers. New names get a deferred handler; names no longer listed lose theirs.
    func setActions(_ raw: Any?, sink: Int?) {
        let change = actions.list(CallsHostValues.names(raw))
        sinks.listedActions(actions.names, by: sink)
        guard instance != nil else { return }
        for name in change.removed { registered.removeValue(forKey: name)?() }
        for name in change.added { register(name) }
    }

    private func register(_ name: String) {
        registered.removeValue(forKey: name)?()
        registered[name] = platform.registerAction(name) { [weak self] arguments, answer in
            guard let self = self else {
                answer(.refused("The app is not listening for \"\(name)\" right now."))
                return
            }
            self.ask(name, arguments, answer)
        }
    }

    /// The agent asked for an action: to the sink that answers actions, or refused at once when it is gone.
    private func ask(_ name: String, _ arguments: [String: Any], _ answer: @escaping (GraineActionResult) -> Void) {
        let id = actions.begin(sink: sinks.actionSink, answer: answer)
        guard sinks.emitAction(CallsHostEvent.actionPayload(requestId: id, name: name, arguments: arguments)) else {
            actions.resolve(id, .refused("The app is not listening for \"\(name)\" right now."))
            return
        }
        // Answered here too, harmlessly, so a JavaScript that never answers holds nothing.
        platform.after(CallsHostCore.forgetActionAfter) { [weak self] in
            self?.actions.resolve(id, .error("The app did not answer in time."))
        }
    }

    func resolveAction(_ requestId: String, _ result: Any?) {
        actions.resolve(requestId, CallsHostValues.actionResult(result))
    }

    // MARK: Sinks

    func addSink(_ sink: @escaping Sink) -> Int {
        sinks.add(sink)
    }

    func removeSink(_ token: Int) {
        sinks.remove(token)
        actions.refuse(sink: token, "The app stopped listening before it answered.")
    }

    // MARK: What the engine reports

    /// One of the calls' published properties is about to change; it is read once the turn is over.
    func engineChanged() {
        changed()
    }

    func callStateChanged(_ state: GraineCallState) {
        switch state {
        case .ringing:
            // A new call: its reason comes with the ring, and the last call's error is old news.
            reason = nil
            error = nil
        case .idle:
            reason = nil
        default:
            break
        }
        changed()
    }

    func incoming(_ call: GraineIncomingCall) {
        reason = call.reason
        error = nil
        sinks.emit(CallsHostEvent.incoming, CallsHostEvent.incomingPayload(call))
        changed()
    }

    func outcome(_ outcome: GraineCallOutcome, callId: String) {
        if let why = outcome.error {
            // A push refused during a live call is another call's failure, not this one's.
            let live = platform.callFields()
            if !live.state.isLive || live.callId == callId { error = why }
        }
        sinks.emit(CallsHostEvent.outcome, CallsHostEvent.outcomePayload(outcome, callId: callId))
        changed()
    }

    /// The app came to the foreground: a call answered on the lock screen gets its screen now.
    func appBecameActive() {
        changed()
    }

    // MARK: The snapshot

    func snapshot() -> [String: Any] {
        current().json
    }

    private func current() -> CallsHostSnapshot {
        var snapshot = platform.callFields()
        snapshot.reason = reason
        snapshot.error = error
        return snapshot
    }

    private func changed() {
        guard gate.changed() else { return }
        platform.nextTurn { [weak self] in self?.flush() }
    }

    private func flush() {
        let now = current()
        if let next = gate.flush(now) { sinks.emit(CallsHostEvent.state, next.json) }
        switch CallsHostCallScreenRule.step(
            callScreen: options?.callScreen, state: now.state, active: platform.appActive, shown: screenShown
        ) {
        case .present:
            screenShown = true
            platform.presentCallScreen()
        case .dismiss:
            screenShown = false
            platform.dismissCallScreen()
        case .stay:
            break
        }
    }
}
