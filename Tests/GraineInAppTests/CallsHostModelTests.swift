import Foundation
import Testing
@testable import GraineInApp

/*
 * The calls host's rules — everything the React Native and Flutter packages
 * rely on when they drive the native call engine — proven on a Mac: the options
 * and their errors, the screen and an action's answer as JavaScript or Dart
 * send them, the snapshot, the events and where they go, setVariables as a
 * replacement, the kept options, and what each of the host's methods does,
 * against a fake platform standing in for iOS.
 */

// MARK: - Helpers

/// Every event a sink received, in order.
private final class HostEventLog {
    private(set) var events: [(name: String, payload: [String: Any])] = []

    var names: [String] { events.map { $0.name } }

    func record(_ name: String, _ payload: [String: Any]) {
        events.append((name, payload))
    }

    func payloads(_ name: String) -> [[String: Any]] {
        events.filter { $0.name == name }.map { $0.payload }
    }
}

/// A variables change as text: each value as the prompt will read it, or "<removed>".
private func describe(_ change: [String: Any?]) -> [String: String] {
    change.mapValues { value in value.map { JSON.jsString($0) } ?? "<removed>" }
}

private func invalid(_ message: String) -> GraineCallsHostError {
    .invalidOptions(message)
}

/// A UserDefaults suite of its own, emptied when the body is done.
private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
    let name = "ai.graine.inapp.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    try body(defaults)
}

/// iOS, as the host sees it: every call recorded, the main loop's turns and timers run by hand.
private final class FakeCallsHostPlatform: CallsHostPlatform {
    var fields = CallsHostSnapshot()
    /// What makeInstance reports; the options' own key, base URL and debug setting when nil.
    var runningWith: (publishableKey: String, baseUrl: String, debug: Bool)?
    var nextCallId: String? = "call-1"
    var appActive = true
    var missedCallPending = false

    private(set) var made: [CallsHostOptions] = []
    private(set) var configured: [CallsHostOptions] = []
    private(set) var voipRegistrations = 0
    private(set) var onToken: ((String?) -> Void)?
    private(set) var placed: [(reason: String?, variables: [String: Any])] = []
    private(set) var answers = 0
    private(set) var ends = 0
    private(set) var muted: [Bool] = []
    private(set) var speaker: [Bool] = []
    private(set) var identities: [[String: Any]?] = []
    private(set) var variableChanges: [[String: Any?]] = []
    private(set) var screens: [GraineScreen?] = []
    private(set) var handlers: [String: GraineInApp.DeferredActionHandler] = [:]
    private(set) var unregistered: [String] = []
    private(set) var presented = 0
    private(set) var dismissed = 0
    private(set) var timers: [(seconds: TimeInterval, block: () -> Void)] = []
    private var turns: [() -> Void] = []

    var pendingTurns: Int { turns.count }

    func runTurns() {
        while !turns.isEmpty {
            let now = turns
            turns = []
            for turn in now { turn() }
        }
    }

    func fireTimers() {
        let now = timers
        timers = []
        for timer in now { timer.block() }
    }

    func makeInstance(_ options: CallsHostOptions) -> (publishableKey: String, baseUrl: String, debug: Bool) {
        made.append(options)
        return runningWith ?? (options.publishableKey, options.baseUrl, options.debug)
    }

    func configureCalls(_ options: CallsHostOptions) {
        configured.append(options)
    }

    func enableVoIPPushes(onToken: @escaping (String?) -> Void) {
        voipRegistrations += 1
        self.onToken = onToken
    }

    private(set) var placedAgents: [String?] = []

    func startCall(reason: String?, variables: [String: Any], agent: String?) -> String? {
        placed.append((reason, variables))
        placedAgents.append(agent)
        if let id = nextCallId {
            fields = CallsHostSnapshot(state: .connecting, callId: id, direction: .outgoing, callerName: "Acme")
        }
        return nextCallId
    }

    func answer() { answers += 1 }
    func end() { ends += 1 }
    func setMuted(_ value: Bool) { muted.append(value) }
    func setSpeaker(_ on: Bool) { speaker.append(on) }
    func identify(_ traits: [String: Any]?) { identities.append(traits) }
    private(set) var memoryChoices: [Bool] = []
    var installIdValue: String? = "3f2504e0-4f89-11d3-9a0c-0305e82c3301"
    func setMemory(_ enabled: Bool) { memoryChoices.append(enabled) }
    var installId: String? { installIdValue }
    func setVariables(_ values: [String: Any?]) { variableChanges.append(values) }
    func setScreen(_ screen: GraineScreen?) { screens.append(screen) }

    func registerAction(_ name: String, handler: @escaping GraineInApp.DeferredActionHandler) -> () -> Void {
        handlers[name] = handler
        return { [weak self] in
            self?.handlers.removeValue(forKey: name)
            self?.unregistered.append(name)
        }
    }

    func callFields() -> CallsHostSnapshot { fields }
    /// The agent each call (by id) is with, as GraineCalls knows it.
    var callAgents: [String: String] = [:]
    func agentName(forCall callId: String) -> String? { callAgents[callId] }
    /// Whether Graine rang the call in progress, as GraineCalls.hosted says it.
    var callHosted = false
    /// The time now, for an ended call's length.
    var clock = Date(timeIntervalSince1970: 1_000)
    func now() -> Date { clock }
    func presentCallScreen() { presented += 1 }
    func dismissCallScreen() { dismissed += 1 }
    func nextTurn(_ block: @escaping () -> Void) { turns.append(block) }
    func after(_ seconds: TimeInterval, _ block: @escaping () -> Void) { timers.append((seconds, block)) }
}

/// A host core on the fake platform, with a store of its own and (by default) one sink listening.
private final class HostRig {
    let suite = "ai.graine.inapp.tests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let platform = FakeCallsHostPlatform()
    let core: CallsHostCore
    let events = HostEventLog()
    private(set) var logs: [String] = []
    private(set) var sink: Int?

    init(listening: Bool = true) {
        defaults = UserDefaults(suiteName: suite)!
        core = CallsHostCore(platform: platform, store: CallsHostStore(defaults: defaults))
        core.log = { [weak self] in self?.logs.append($0) }
        if listening {
            let events = self.events
            sink = core.addSink { events.record($0, $1) }
        }
    }

    deinit {
        defaults.removePersistentDomain(forName: suite)
    }

    var store: CallsHostStore { CallsHostStore(defaults: defaults) }

    func configure(_ extra: [String: Any] = [:]) throws {
        var options: [String: Any] = ["publishableKey": "pk_test_rig", "displayName": "Acme"]
        for (key, value) in extra { options[key] = value }
        try core.configure(options)
    }

    func keep(_ options: [String: Any] = ["publishableKey": "pk_test_rig", "displayName": "Acme"], voip: Bool = false) throws {
        store.saveOptions(try CallsHostOptions.parse(options).json)
        if voip { store.saveVoip(true) }
    }

    func handler(_ name: String) throws -> GraineInApp.DeferredActionHandler {
        try #require(platform.handlers[name])
    }
}

// MARK: - Options

@Suite struct CallsHostOptionsTests {
    private let minimal: [String: Any] = ["publishableKey": "pk_test_1", "displayName": "Acme"]

    private func with(_ extra: [String: Any]) -> [String: Any] {
        var out = minimal
        for (key, value) in extra { out[key] = value }
        return out
    }

    private func refusal(_ raw: Any?) -> GraineCallsHostError? {
        do {
            _ = try CallsHostOptions.parse(raw)
            return nil
        } catch let error as GraineCallsHostError {
            return error
        } catch {
            Issue.record("not a host error: \(error)")
            return nil
        }
    }

    @Test func aKeyAndANameAreEnoughAndEverythingElseHasItsDefault() throws {
        let options = try CallsHostOptions.parse(minimal)
        #expect(options.publishableKey == "pk_test_1")
        #expect(options.displayName == "Acme")
        #expect(options.baseUrl == "https://www.graine.ai")
        #expect(options.ringtoneSound == nil)
        #expect(options.ringTimeoutMs == 30_000)
        #expect(options.ringTimeout == 30)
        #expect(options.appVersion == nil)
        #expect(options.callScreen == .sdk)
        #expect(!options.debug)
        #expect(options.androidSmallIcon == nil)
        #expect(options.iosIconTemplate == nil)
        #expect(!options.iosIncludesCallsInRecents)
    }

    @Test func everyOptionIsRead() throws {
        let options = try CallsHostOptions.parse(with([
            "baseUrl": "https://graine.example.com/",
            "ringtoneSound": "ring.caf",
            "ringTimeoutMs": 45_000,
            "appVersion": "2.4.0",
            "callScreen": "app",
            "debug": true,
            "android": ["smallIcon": "ic_call"],
            "ios": ["iconTemplate": "CallIcon", "includesCallsInRecents": true] as [String: Any],
        ]))
        #expect(options.baseUrl == "https://graine.example.com")
        #expect(options.ringtoneSound == "ring.caf")
        #expect(options.ringTimeoutMs == 45_000)
        #expect(options.ringTimeout == 45)
        #expect(options.appVersion == "2.4.0")
        #expect(options.callScreen == .app)
        #expect(options.debug)
        #expect(options.androidSmallIcon == "ic_call")
        #expect(options.iosIconTemplate == "CallIcon")
        #expect(options.iosIncludesCallsInRecents)
    }

    @Test func theKeyAndTheNameAreRequired() {
        #expect(refusal(["displayName": "Acme"]) == invalid("publishableKey is required"))
        #expect(refusal(["publishableKey": "", "displayName": "Acme"]) == invalid("publishableKey is required"))
        #expect(refusal(["publishableKey": NSNull(), "displayName": "Acme"]) == invalid("publishableKey is required"))
        #expect(refusal(["publishableKey": "pk_test_1"]) == invalid("displayName is required"))
        #expect(refusal(["publishableKey": "pk_test_1", "displayName": "  \n"]) == invalid("displayName is required"))
        #expect(refusal(nil) == invalid("publishableKey is required"))
        #expect(refusal(NSNull()) == invalid("publishableKey is required"))
        #expect(refusal("pk_test_1") == invalid("options must be an object"))
        #expect(refusal(["displayName": "Acme"])?.code == "invalid_options")
        #expect(refusal(["displayName": "Acme"])?.errorDescription == "publishableKey is required")
    }

    @Test func aKnownKeyOfTheWrongTypeIsRefusedByName() {
        let cases: [([String: Any], String)] = [
            (["publishableKey": 42, "displayName": "Acme"], "publishableKey must be a string"),
            (["publishableKey": "pk_test_1", "displayName": true], "displayName must be a string"),
            (with(["baseUrl": 1]), "baseUrl must be a string"),
            (with(["ringtoneSound": ["ring.caf"]]), "ringtoneSound must be a string"),
            (with(["ringTimeoutMs": "30000"]), "ringTimeoutMs must be a number"),
            (with(["ringTimeoutMs": true]), "ringTimeoutMs must be a number"),
            (with(["appVersion": 2.4]), "appVersion must be a string"),
            (with(["callScreen": 1]), "callScreen must be a string"),
            (with(["callScreen": "web"]), "callScreen must be \"sdk\" or \"app\""),
            (with(["callScreen": "SDK"]), "callScreen must be \"sdk\" or \"app\""),
            (with(["debug": "yes"]), "debug must be a boolean"),
            (with(["debug": 1]), "debug must be a boolean"),
            (with(["android": "ic_call"]), "android must be an object"),
            (with(["android": ["smallIcon": 7]]), "android.smallIcon must be a string"),
            (with(["ios": [true]]), "ios must be an object"),
            (with(["ios": ["iconTemplate": false]]), "ios.iconTemplate must be a string"),
            (with(["ios": ["includesCallsInRecents": "yes"]]), "ios.includesCallsInRecents must be a boolean"),
            (with(["ios": ["includesCallsInRecents": 1]]), "ios.includesCallsInRecents must be a boolean"),
        ]
        for (raw, message) in cases {
            #expect(refusal(raw) == invalid(message), "\(message)")
        }
    }

    @Test func valuesAsTheBridgesDeliverThemAreRead() throws {
        // NSDictionary, NSString and NSNumber — booleans as CFBoolean — are what both bridges hand over.
        let raw: NSDictionary = [
            "publishableKey": NSString(string: "pk_test_1"),
            "displayName": NSString(string: "Acme"),
            "ringTimeoutMs": NSNumber(value: 12_000),
            "debug": NSNumber(value: true),
            "ios": NSDictionary(dictionary: ["includesCallsInRecents": NSNumber(value: true)]),
        ]
        let options = try CallsHostOptions.parse(raw)
        #expect(options.ringTimeoutMs == 12_000)
        #expect(options.debug)
        #expect(options.iosIncludesCallsInRecents)
        #expect(try CallsHostOptions.parse(with(["ringTimeoutMs": NSNumber(value: 1_500.2)])).ringTimeoutMs == 1_501)
        let falseFlag: [String: Any] = ["includesCallsInRecents": NSNumber(value: false)]
        #expect(try !CallsHostOptions.parse(with(["ios": falseFlag])).iosIncludesCallsInRecents)
    }

    @Test func aRingTimeoutThatIsNotAboveZeroIsThirtySeconds() throws {
        let notAboveZero: [Any] = [0, -5, -0.1, NSNull()]
        for value in notAboveZero {
            #expect(try CallsHostOptions.parse(with(["ringTimeoutMs": value])).ringTimeoutMs == 30_000, "\(value)")
        }
        #expect(try CallsHostOptions.parse(with(["ringTimeoutMs": 0.2])).ringTimeoutMs == 1, "above zero is never rounded to zero")
        #expect(try CallsHostOptions.parse(with(["ringTimeoutMs": 1e300])).ringTimeoutMs == Int(Int32.max), "bounded, never a crash")
    }

    @Test func theBaseUrlLosesItsTrailingSlashesAndABlankOneIsTheDefault() throws {
        #expect(try CallsHostOptions.parse(with(["baseUrl": "https://graine.example.com///"])).baseUrl == "https://graine.example.com")
        #expect(try CallsHostOptions.parse(with(["baseUrl": " https://graine.example.com "])).baseUrl == "https://graine.example.com")
        #expect(try CallsHostOptions.parse(with(["baseUrl": "  "])).baseUrl == "https://www.graine.ai")
        #expect(try CallsHostOptions.parse(with(["baseUrl": "/"])).baseUrl == "https://www.graine.ai")
        #expect(try CallsHostOptions.parse(with(["baseUrl": NSNull()])).baseUrl == "https://www.graine.ai")
    }

    @Test func unknownKeysAreIgnoredAndNullIsAbsent() throws {
        let options = try CallsHostOptions.parse(with([
            "future": ["anything": 1],
            "ringtoneSound": NSNull(),
            "ios": NSNull(),
            "android": NSNull(),
            "callScreen": NSNull(),
            "ringTimeoutMs": NSNull(),
            "debug": NSNull(),
        ]))
        #expect(options == (try CallsHostOptions.parse(minimal)))
    }

    @Test func blankOptionalStringsAreNoneAndTheNameIsTrimmed() throws {
        let options = try CallsHostOptions.parse([
            "publishableKey": "pk_test_1",
            "displayName": "  Acme Assistant ",
            "ringtoneSound": " ",
            "appVersion": "",
            "ios": ["iconTemplate": "  "],
            "android": ["smallIcon": ""],
        ] as [String: Any])
        #expect(options.displayName == "Acme Assistant")
        #expect(options.ringtoneSound == nil)
        #expect(options.appVersion == nil)
        #expect(options.iosIconTemplate == nil)
        #expect(options.androidSmallIcon == nil)
    }

    @Test func whatIsKeptReadsBackAsTheSameOptions() throws {
        let full = try CallsHostOptions.parse(with([
            "baseUrl": "https://graine.example.com",
            "ringtoneSound": "ring.caf",
            "ringTimeoutMs": 45_000,
            "appVersion": "2.4.0",
            "callScreen": "app",
            "debug": true,
            "android": ["smallIcon": "ic_call"],
            "ios": ["iconTemplate": "CallIcon", "includesCallsInRecents": true] as [String: Any],
        ]))
        #expect(try CallsHostOptions.parse(full.json) == full)
        let plain = try CallsHostOptions.parse(minimal)
        #expect(try CallsHostOptions.parse(plain.json) == plain)
        // Through the property list UserDefaults writes, and through JSON.
        let plist = try PropertyListSerialization.data(fromPropertyList: full.json, format: .binary, options: 0)
        #expect(try CallsHostOptions.parse(PropertyListSerialization.propertyList(from: plist, options: [], format: nil)) == full)
        let json = try JSONSerialization.data(withJSONObject: full.json)
        #expect(try CallsHostOptions.parse(JSONSerialization.jsonObject(with: json)) == full)
    }
}

// MARK: - The screen and an action's answer

@Suite struct CallsHostScreenTests {
    @Test func aWholeScreenBecomesAGraineScreen() throws {
        let raw: [String: Any] = [
            "screen": "kyc_documents",
            "title": "Upload your documents",
            "journey": ["name": "KYC", "step": 2, "of": 4, "next": "review"] as [String: Any],
            "fields": [
                ["name": "pan", "label": "PAN", "value": "ABCDE1234F", "status": "invalid", "error": "Not recognised"],
                ["name": "nickname", "optional": true] as [String: Any],
            ] as [[String: Any]],
            "error": "Something went wrong",
            "data": ["plan": "Plus", "limit": 5_000] as [String: Any],
            "availableActions": ["upload_document", "set_tenure"],
        ]
        let screen = try #require(CallsHostValues.screen(raw))
        #expect(screen == GraineScreen(
            screen: "kyc_documents",
            title: "Upload your documents",
            journey: GraineScreen.Journey(name: "KYC", step: 2, of: 4, next: "review"),
            fields: [
                GraineField(name: "pan", label: "PAN", value: "ABCDE1234F", status: .invalid, error: "Not recognised"),
                GraineField(name: "nickname", isOptional: true),
            ],
            error: "Something went wrong",
            data: ["plan": "Plus", "limit": 5_000],
            availableActions: ["upload_document", "set_tenure"]
        ))
    }

    @Test func noScreenNameIsNoScreen() throws {
        #expect(CallsHostValues.screen(nil) == nil)
        #expect(CallsHostValues.screen(NSNull()) == nil)
        #expect(CallsHostValues.screen("home") == nil)
        #expect(CallsHostValues.screen([String: Any]()) == nil)
        #expect(CallsHostValues.screen(["screen": ""]) == nil)
        #expect(CallsHostValues.screen(["screen": "   "]) == nil)
        #expect(CallsHostValues.screen(["title": "Home"]) == nil)
        #expect(try #require(CallsHostValues.screen(["screen": " home "])).screen == "home")
    }

    @Test func aFieldValueIsTextWhateverItWasSentAs() throws {
        let raw: [String: Any] = ["screen": "cart", "fields": [
            ["name": "total", "value": 1299],
            ["name": "rate", "value": 12.5],
            ["name": "agreed", "value": true],
            ["name": "note", "value": ""],
            ["name": "missing", "value": NSNull()],
            ["name": "list", "value": [1, 2]],
        ] as [[String: Any]]]
        let screen = try #require(CallsHostValues.screen(raw))
        #expect(screen.fields.map { $0.value } == ["1299", "12.5", "true", "", nil, nil])
    }

    @Test func anUnknownStatusIsNoStatusAndAFieldWithoutANameIsLeftOut() throws {
        let raw: [String: Any] = ["screen": "kyc", "fields": [
            ["name": "pan", "status": "ok-ish"],
            ["name": "pin", "status": "Filled"],
            ["label": "No name"],
            "not a field",
            ["name": "dob", "status": "empty"],
        ] as [Any]]
        let screen = try #require(CallsHostValues.screen(raw))
        #expect(screen.fields.map { $0.name } == ["pan", "pin", "dob"])
        #expect(screen.fields.map { $0.status } == [nil, nil, .empty])
    }

    @Test func availableActionsKeepAbsentAndEmptyApart() throws {
        let absent = try #require(CallsHostValues.screen(["screen": "home"]))
        #expect(absent.availableActions == nil, "absent allows every action")
        let empty = try #require(CallsHostValues.screen(["screen": "home", "availableActions": [String]()] as [String: Any]))
        #expect(empty.availableActions == [], "an empty list allows none")
        let mixed = try #require(CallsHostValues.screen(["screen": "home", "availableActions": ["a", 7, "", "a", "b"] as [Any]] as [String: Any]))
        #expect(mixed.availableActions == ["a", "b"])
        let wrong = try #require(CallsHostValues.screen(["screen": "home", "availableActions": "a"]))
        #expect(wrong.availableActions == nil)
    }

    @Test func aJourneyNeedsANameAndTakesNumbersOrNumericText() throws {
        let raw: [String: Any] = ["screen": "kyc", "journey": ["name": "KYC", "step": "2", "of": 4.0] as [String: Any]]
        let journey = try #require(CallsHostValues.screen(raw)?.journey)
        #expect(journey == GraineScreen.Journey(name: "KYC", step: 2, of: 4))
        let nameless: [String: Any] = ["screen": "kyc", "journey": ["step": 1]]
        #expect(try #require(CallsHostValues.screen(nameless)).journey == nil)
    }

    @Test func screenDataIsKeptAsJSON() throws {
        let raw: [String: Any] = ["screen": "cart", "data": ["items": [1, 2], "total": 12.5, "gift": NSNull()] as [String: Any]]
        let screen = try #require(CallsHostValues.screen(raw))
        #expect(JSON.canonical(screen.data) == #"{"gift":null,"items":[1,2],"total":12.5}"#)
    }
}

@Suite struct CallsHostActionResultTests {
    @Test func okRefusedAndErrorAreReadWithTheirMessageAndData() {
        let ok = CallsHostValues.actionResult(["status": "ok", "message": "Opened the bill.", "data": ["page": "billing"]] as [String: Any])
        #expect(ok.status == .ok)
        #expect(ok.message == "Opened the bill.")
        #expect(JSON.canonical(ok.data) == #"{"page":"billing"}"#)
        #expect(CallsHostValues.actionResult(["status": "refused", "message": "Locked"]).status == .refused)
        let error = CallsHostValues.actionResult(["status": "error"])
        #expect(error.status == .error)
        #expect(error.message == "")
    }

    @Test func anythingElseIsAnError() {
        let unknown = CallsHostValues.actionResult(["status": "done", "message": "Done!"])
        #expect(unknown.status == .error)
        #expect(unknown.message == "Done!", "the app's own words are kept")
        #expect(CallsHostValues.actionResult(["status": "OK"]).status == .error, "the words are exact")
        #expect(CallsHostValues.actionResult(["status": "maybe"]).message == "The app answered with an unknown status \"maybe\".")
        let statusless = CallsHostValues.actionResult(["message": "hi"])
        #expect(statusless.status == .error)
        #expect(statusless.message == "hi")
        #expect(CallsHostValues.actionResult([String: Any]()).message == "The app answered without a status.")
        #expect(CallsHostValues.actionResult(nil).status == .error)
        #expect(CallsHostValues.actionResult("ok").status == .error)
    }
}

@Suite struct CallsHostCallRequestTests {
    @Test func aReasonAndVariables() {
        let request = CallsHostValues.callRequest(["reason": " card_blocked ", "variables": ["order": "A-1043"]] as [String: Any])
        #expect(request.reason == "card_blocked")
        #expect(request.variables["order"] as? String == "A-1043")
        let none = CallsHostValues.callRequest(nil)
        #expect(none.reason == nil)
        #expect(none.variables.isEmpty)
        #expect(CallsHostValues.callRequest(["reason": " "]).reason == nil)
    }
}

// MARK: - The snapshot and the events

@Suite struct CallsHostSnapshotTests {
    private let keys: Set<String> = [
        "state", "callId", "direction", "reason", "callerName", "muted", "speakerOn", "agentSpeaking",
        "caption", "connectedAt", "error", "agent", "transport", "transportFallbackReason",
    ]

    @Test func everyKeyIsAlwaysThereAndIdleIsNullsAndFalses() {
        let json = CallsHostSnapshot().json
        #expect(Set(json.keys) == keys)
        #expect(json["state"] as? String == "idle")
        for key in ["callId", "direction", "reason", "callerName", "caption", "connectedAt", "error", "agent", "transport", "transportFallbackReason"] {
            #expect(json[key] is NSNull, "\(key)")
        }
        for key in ["muted", "speakerOn", "agentSpeaking"] {
            #expect(json[key] as? Bool == false, "\(key)")
        }
        #expect(JSONSerialization.isValidJSONObject(json))
    }

    @Test func aLiveCallShowsEverything() throws {
        let json = CallsHostSnapshot(
            state: .active, callId: "c1", direction: .incoming, reason: "payment_due", callerName: "Acme",
            muted: true, speakerOn: true, agentSpeaking: true,
            caption: GraineCaption(role: .agent, text: "Hi Asha", live: true),
            connectedAt: Date(timeIntervalSince1970: 1_760_000_000.123), agent: "sales"
        ).json
        #expect(Set(json.keys) == keys)
        #expect(json["agent"] as? String == "sales", "the call's agent, by name")
        #expect(json["state"] as? String == "active")
        #expect(json["callId"] as? String == "c1")
        #expect(json["direction"] as? String == "incoming")
        #expect(json["reason"] as? String == "payment_due")
        #expect(json["callerName"] as? String == "Acme")
        #expect(json["muted"] as? Bool == true)
        #expect(json["speakerOn"] as? Bool == true)
        #expect(json["agentSpeaking"] as? Bool == true)
        #expect((json["connectedAt"] as? NSNumber)?.int64Value == 1_760_000_000_123, "milliseconds since the epoch")
        let caption = try #require(json["caption"] as? [String: Any])
        #expect(JSON.canonical(caption) == #"{"live":true,"role":"agent","text":"Hi Asha"}"#)
        #expect(json["error"] is NSNull)
        #expect(JSONSerialization.isValidJSONObject(json))
    }

    @Test func atIdleOnlyTheErrorSurvives() {
        let stale = CallsHostSnapshot(
            state: .idle, callId: "c1", direction: .outgoing, reason: "support", callerName: "Acme",
            muted: true, speakerOn: true, agentSpeaking: true,
            caption: GraineCaption(role: .customer, text: "hello", live: false),
            connectedAt: Date(), error: "The microphone permission was not granted.", agent: "sales"
        )
        #expect(stale.settled == CallsHostSnapshot(error: "The microphone permission was not granted."))
        #expect(stale.json["agent"] is NSNull, "no call, no agent")
        let json = stale.json
        #expect(json["callId"] is NSNull)
        #expect(json["caption"] is NSNull)
        #expect(json["muted"] as? Bool == false)
        #expect(json["error"] as? String == "The microphone permission was not granted.")
    }

    @Test func theStateIsOneWord() {
        let states: [GraineCallState] = [.idle, .ringing, .connecting, .active, .ended(.local), .ended(.missed)]
        #expect(states.map { CallsHostSnapshot.word($0) } == ["idle", "ringing", "connecting", "active", "ended", "ended"])
    }

    @Test func aBlankIsNull() {
        let json = CallsHostSnapshot(state: .ringing, callId: "c1", reason: "", callerName: "", error: "").json
        #expect(json["callerName"] is NSNull)
        #expect(json["reason"] is NSNull)
        #expect(json["error"] is NSNull)
    }
}

@Suite struct CallsHostStateGateTests {
    @Test func oneLookPerTurnAndOnlyWhenSomethingChanged() {
        var gate = CallsHostStateGate()
        let first = gate.changed()
        let again = gate.changed()
        #expect(first)
        #expect(!again, "a turn is already coming")
        let idle = gate.flush(CallsHostSnapshot())
        #expect(idle == nil, "idle to idle is nothing")
        let next = gate.changed()
        #expect(next, "the turn was taken: the next change asks for another")
        let ringing = CallsHostSnapshot(state: .ringing, callId: "c1")
        let sent = gate.flush(ringing)
        #expect(sent == ringing)
        _ = gate.changed()
        let unchanged = gate.flush(ringing)
        #expect(unchanged == nil)
    }

    @Test func whatIdleHidesIsNotAChange() {
        var gate = CallsHostStateGate()
        _ = gate.changed()
        let stale = gate.flush(CallsHostSnapshot(state: .idle, callId: "stale", muted: true))
        #expect(stale == nil)
        _ = gate.changed()
        let failed = gate.flush(CallsHostSnapshot(state: .idle, error: "No network."))
        #expect(failed == CallsHostSnapshot(error: "No network."))
    }
}

@Suite struct CallsHostEventTests {
    @Test func everyOutcomeHasItsShape() {
        func payload(_ outcome: GraineCallOutcome) -> String {
            JSON.canonical(CallsHostEvent.outcomePayload(outcome, callId: "c1"))
        }
        #expect(payload(.answered) == #"{"callId":"c1","outcome":"answered"}"#)
        #expect(payload(.declined) == #"{"callId":"c1","outcome":"declined"}"#)
        #expect(payload(.missed) == #"{"callId":"c1","outcome":"missed"}"#)
        #expect(payload(.ended(.local)) == #"{"callId":"c1","outcome":"ended","reason":"local"}"#)
        #expect(payload(.ended(.remote)) == #"{"callId":"c1","outcome":"ended","reason":"remote"}"#)
        #expect(payload(.ended(.failed)) == #"{"callId":"c1","outcome":"ended","reason":"failed"}"#)
        #expect(payload(.failed("No network.")) == #"{"callId":"c1","error":"No network.","outcome":"failed"}"#)
    }

    @Test func aRingAndATokenSayNullOutLoud() {
        let ring = CallsHostEvent.incomingPayload(GraineIncomingCall(callId: "c9", reason: "delivery_delayed"))
        // Sorted keys: JSONSerialization puts "callerName" before "callId".
        #expect(JSON.canonical(ring) == #"{"callerName":null,"callId":"c9","reason":"delivery_delayed"}"#)
        let named = CallsHostEvent.incomingPayload(GraineIncomingCall(callId: "c9", callerName: "Acme"))
        #expect(JSON.canonical(named) == #"{"callerName":"Acme","callId":"c9","reason":null}"#)
        #expect(JSON.canonical(CallsHostEvent.tokenPayload(nil)) == #"{"token":null}"#)
        #expect(JSON.canonical(CallsHostEvent.tokenPayload("ab12")) == #"{"token":"ab12"}"#)
    }

    @Test func anOutcomeARingAndAnActionNameTheirAgentWhenItIsKnown() {
        #expect(JSON.canonical(CallsHostEvent.outcomePayload(.missed, callId: "c1", agent: "sales"))
            == #"{"agent":"sales","callId":"c1","outcome":"missed"}"#)
        #expect(JSON.canonical(CallsHostEvent.incomingPayload(GraineIncomingCall(callId: "c9"), agent: "default"))
            == #"{"agent":"default","callerName":null,"callId":"c9","reason":null}"#)
        #expect(JSON.canonical(CallsHostEvent.actionPayload(requestId: "r1", name: "raise_ticket", arguments: [:], agent: "sales"))
            == #"{"agent":"sales","arguments":{},"name":"raise_ticket","requestId":"r1"}"#)
        #expect(CallsHostEvent.outcomePayload(.missed, callId: "c1")["agent"] == nil, "unknown: no key at all")
    }

    @Test func aCallGraineRangSaysSoAndAnEndedCallSaysHowLongItLasted() {
        // The keys React Native's and Flutter's GraineCallOutcome read.
        #expect(JSON.canonical(CallsHostEvent.outcomePayload(.ended(.remote), callId: "h1", hosted: true, durationSeconds: 95))
            == #"{"callId":"h1","durationSeconds":95,"hosted":true,"outcome":"ended","reason":"remote"}"#)
        #expect(JSON.canonical(CallsHostEvent.outcomePayload(.answered, callId: "h1", hosted: true, durationSeconds: 3))
            == #"{"callId":"h1","hosted":true,"outcome":"answered"}"#, "a length only on an ended call")
        #expect(JSON.canonical(CallsHostEvent.outcomePayload(.ended(.local), callId: "c1", durationSeconds: 12))
            == #"{"callId":"c1","durationSeconds":12,"outcome":"ended","reason":"local"}"#, "not hosted: no key")
        #expect(JSON.canonical(CallsHostEvent.ringingPayload(callId: "h1", agent: "sales"))
            == #"{"agent":"sales","callId":"h1","hosted":true,"outcome":"ringing"}"#)
        #expect(JSON.canonical(CallsHostEvent.incomingPayload(GraineIncomingCall(callId: "h1", callerName: "Acme", hosted: true)))
            == #"{"callerName":"Acme","callId":"h1","hosted":true,"reason":null}"#)
    }

    @Test func anActionRequestCarriesJSONArguments() {
        let arguments: [String: Any] = ["page": "billing", "count": 2, "when": Optional<String>.none as Any]
        let payload = CallsHostEvent.actionPayload(requestId: "r1", name: "open_screen", arguments: arguments)
        #expect(JSON.canonical(payload) == #"{"arguments":{"count":2,"page":"billing","when":null},"name":"open_screen","requestId":"r1"}"#)
        #expect(JSONSerialization.isValidJSONObject(payload))
    }
}

// MARK: - Sinks

@Suite struct CallsHostSinksTests {
    @Test func everyEventReachesEverySink() {
        let sinks = CallsHostSinks()
        let a = HostEventLog()
        let b = HostEventLog()
        _ = sinks.add(a.record)
        _ = sinks.add(b.record)
        sinks.emit(CallsHostEvent.state, ["state": "ringing"])
        sinks.emit(CallsHostEvent.voipToken, ["token": "ab"])
        sinks.emit(CallsHostEvent.outcome, ["callId": "c1"])
        #expect(a.names == ["state", "voipToken", "outcome"])
        #expect(b.names == ["state", "voipToken", "outcome"])
        #expect(sinks.count == 2)
    }

    @Test func outcomesAndRingsWithNobodyListeningWaitForTheFirstSink() {
        let sinks = CallsHostSinks()
        sinks.emit(CallsHostEvent.incoming, ["callId": "c1"])
        sinks.emit(CallsHostEvent.state, ["state": "ringing"])
        sinks.emit(CallsHostEvent.voipToken, ["token": "ab"])
        sinks.emit(CallsHostEvent.outcome, ["callId": "c1", "outcome": "answered"])
        #expect(sinks.queued.count == 2, "the state and tokens never wait")
        let first = HostEventLog()
        let second = HostEventLog()
        _ = sinks.add(first.record)
        _ = sinks.add(second.record)
        #expect(first.names == ["incoming", "outcome"])
        #expect(second.names.isEmpty, "delivered once, to the first sink")
        #expect(sinks.queued.isEmpty)
    }

    @Test func theQueueKeepsTheLastTwenty() {
        let sinks = CallsHostSinks()
        for i in 0..<25 { sinks.emit(CallsHostEvent.outcome, ["callId": "c\(i)"]) }
        let log = HostEventLog()
        _ = sinks.add(log.record)
        #expect(log.events.count == 20)
        #expect(log.events.first?.payload["callId"] as? String == "c5")
        #expect(log.events.last?.payload["callId"] as? String == "c24")
    }

    @Test func onceTheLastSinkLeavesEventsWaitAgain() {
        let sinks = CallsHostSinks()
        let log = HostEventLog()
        let token = sinks.add(log.record)
        sinks.remove(token)
        sinks.emit(CallsHostEvent.outcome, ["callId": "c1"])
        #expect(log.events.isEmpty)
        #expect(sinks.queued.count == 1)
        #expect(!sinks.contains(token))
    }

    @Test func anActionGoesOnlyToTheSinkThatLastListedActions() {
        let sinks = CallsHostSinks()
        let main = HostEventLog()
        let background = HostEventLog()
        let a = sinks.add(main.record)
        let b = sinks.add(background.record)
        #expect(!sinks.emitAction(["requestId": "r0"]), "nobody listed actions")
        sinks.listedActions(["open_screen"], by: a)
        sinks.listedActions([], by: b)
        #expect(sinks.actionSink == a, "an empty list takes nothing over")
        #expect(sinks.emitAction(["requestId": "r1"]))
        #expect(main.names == ["action"])
        #expect(background.names.isEmpty)
        sinks.listedActions(["open_screen"], by: b)
        #expect(sinks.emitAction(["requestId": "r2"]))
        #expect(background.names == ["action"])
        sinks.remove(b)
        #expect(!sinks.emitAction(["requestId": "r3"]), "the sink that answers is gone: refused at once")
        #expect(main.names == ["action"], "never handed to another sink")
    }

    @Test func actionsListedByACallerWithNoSinkAreRefused() {
        let sinks = CallsHostSinks()
        let log = HostEventLog()
        let token = sinks.add(log.record)
        sinks.listedActions(["open_screen"], by: token)
        sinks.listedActions(["open_screen"], by: nil)
        #expect(!sinks.emitAction(["requestId": "r1"]))
        #expect(log.events.isEmpty)
    }

    @Test func anActionRequestNeverWaitsInTheQueue() {
        let sinks = CallsHostSinks()
        sinks.listedActions(["open_screen"], by: 1)
        #expect(!sinks.emitAction(["requestId": "r1"]))
        #expect(sinks.queued.isEmpty)
    }
}

// MARK: - Variables

@Suite struct CallsHostVariablesTests {
    @Test func theFirstMapIsSetAsIs() {
        var variables = CallsHostVariables()
        let change = variables.replace(with: ["plan": "Plus", "cart": 1299])
        #expect(describe(change) == ["plan": "Plus", "cart": "1299"])
        #expect(variables.keys == ["plan", "cart"])
    }

    @Test func aKeyTheLastMapSetAndThisOneLeavesOutIsRemoved() {
        var variables = CallsHostVariables()
        _ = variables.replace(with: ["plan": "Plus", "cart": 1299])
        let change = variables.replace(with: ["plan": "Gold"])
        #expect(describe(change) == ["plan": "Gold", "cart": "<removed>"])
        let again = variables.replace(with: ["plan": "Gold"])
        #expect(describe(again) == ["plan": "Gold"], "removed once, not forever")
    }

    @Test func nullClearsEveryKeyTheHostSet() {
        var variables = CallsHostVariables()
        _ = variables.replace(with: ["plan": "Plus", "cart": 1299])
        let cleared = variables.replace(with: nil)
        #expect(describe(cleared) == ["plan": "<removed>", "cart": "<removed>"])
        #expect(variables.keys.isEmpty)
        let nothing = variables.replace(with: nil)
        #expect(nothing.isEmpty)
    }

    @Test func aValueThatCannotBeAVariableIsARemoval() {
        var variables = CallsHostVariables()
        _ = variables.replace(with: ["plan": "Plus", "address": "Pune"])
        let change = variables.replace(with: [
            "plan": NSNull(), "address": ["city": "Pune"], "tags": ["a"], "": "x", "vip": true,
        ])
        #expect(describe(change) == ["plan": "<removed>", "address": "<removed>", "tags": "<removed>", "vip": "true"])
        #expect(variables.keys == ["vip"])
    }

    @Test func theSDKsVariablesBecomeExactlyTheMap() {
        // The SDK's own store merges; the replacement is what makes it exact.
        let store = VariableStore()
        var variables = CallsHostVariables()
        store.setRuntime(variables.replace(with: ["plan": "Plus", "cart": 1299]))
        store.setRuntime(variables.replace(with: ["plan": "Gold", "city": "Pune"]))
        #expect(store.merged() == ["plan": "Gold", "city": "Pune"])
        store.setRuntime(variables.replace(with: nil))
        #expect(store.merged().isEmpty)
    }
}

// MARK: - Actions

@Suite struct CallsHostActionsTests {
    @Test func aNewListSaysWhatToRegisterAndWhatToUnregister() {
        let actions = CallsHostActions()
        let first = actions.list(["open_screen", "set_theme"])
        #expect(first.added == ["open_screen", "set_theme"])
        #expect(first.removed.isEmpty)
        let second = actions.list(["set_theme", "set_ring"])
        #expect(second.added == ["set_ring"])
        #expect(second.removed == ["open_screen"])
        #expect(actions.names == ["set_theme", "set_ring"])
    }

    @Test func theFirstAnswerWinsAndALateOrUnknownOneIsIgnored() {
        let actions = CallsHostActions()
        var answers: [GraineActionResult.Status] = []
        let id = actions.begin(sink: 1) { answers.append($0.status) }
        #expect(actions.pendingCount == 1)
        #expect(actions.resolve(id, .ok("Done")))
        #expect(!actions.resolve(id, .error("again")))
        #expect(!actions.resolve("no-such-request", .ok()))
        #expect(answers == [.ok])
        #expect(actions.pendingCount == 0)
    }

    @Test func everyRequestHasItsOwnId() {
        let actions = CallsHostActions()
        let a = actions.begin(sink: 1) { _ in }
        let b = actions.begin(sink: 1) { _ in }
        #expect(a != b)
        #expect(!a.isEmpty)
    }

    @Test func aSinkThatLeavesHasItsRequestsRefused() {
        let actions = CallsHostActions()
        var answers: [String: GraineActionResult] = [:]
        _ = actions.begin(sink: 1) { answers["one"] = $0 }
        _ = actions.begin(sink: 2) { answers["two"] = $0 }
        actions.refuse(sink: 1, "gone")
        #expect(answers["one"]?.status == .refused)
        #expect(answers["one"]?.message == "gone")
        #expect(answers["two"] == nil)
        #expect(actions.pendingCount == 1)
    }

    @Test func listedNamesAreStringsEachOnce() {
        #expect(CallsHostValues.names(["open_screen", "", 7, "set_theme", "open_screen"] as [Any]) == ["open_screen", "set_theme"])
        #expect(CallsHostValues.names(nil).isEmpty)
        #expect(CallsHostValues.names("open_screen").isEmpty)
    }
}

// MARK: - Kept for a cold start

@Suite struct CallsHostStoreTests {
    @Test func nothingKeptIsNothing() {
        withDefaults { defaults in
            let saved = CallsHostStore(defaults: defaults).load()
            #expect(saved.options == nil)
            #expect(!saved.voip)
        }
    }

    @Test func theOptionsAndVoIPAreKeptApartUnderOneKey() throws {
        try withDefaults { defaults in
            let store = CallsHostStore(defaults: defaults)
            let options = try CallsHostOptions.parse(["publishableKey": "pk_test_1", "displayName": "Acme"])
            store.saveVoip(true)
            store.saveOptions(options.json)
            let saved = store.load()
            #expect(saved.voip, "the options did not overwrite the flag")
            #expect(try CallsHostOptions.parse(saved.options) == options)
            store.saveVoip(false)
            #expect(!store.load().voip)
            #expect(store.load().options != nil, "the flag did not overwrite the options")
            // The documented shape, under the documented key.
            let raw = try #require(defaults.dictionary(forKey: "ai.graine.inapp.calls"))
            #expect(Set(raw.keys) == ["options", "voip"])
            #expect(raw["voip"] as? Bool == false)
            #expect((raw["options"] as? [String: Any])?["publishableKey"] as? String == "pk_test_1")
        }
    }

    @Test func somethingAPropertyListCannotHoldIsNeverWritten() {
        withDefaults { defaults in
            let store = CallsHostStore(defaults: defaults)
            store.saveOptions(["publishableKey": "pk_test_1", "bad": NSNull()])
            #expect(store.load().options == nil, "dropped, never a crash")
        }
    }
}

// MARK: - The SDK's call screen

@Suite struct CallsHostCallScreenRuleTests {
    private func rule(
        _ screen: CallsHostCallScreen?, _ state: GraineCallState, active: Bool = true, shown: Bool = false
    ) -> CallsHostCallScreenRule.Step {
        CallsHostCallScreenRule.step(callScreen: screen, state: state, active: active, shown: shown)
    }

    @Test func upWhileACallIsLiveAndTheAppIsActiveDownAtIdle() {
        #expect(rule(.sdk, .ringing) == .present)
        #expect(rule(.sdk, .connecting) == .present)
        #expect(rule(.sdk, .active) == .present)
        #expect(rule(.sdk, .ringing, active: false) == .stay, "behind the lock screen, the system's call screen")
        #expect(rule(.sdk, .active, shown: true) == .stay)
        #expect(rule(.sdk, .ended(.local), shown: true) == .stay, "\"Call ended\" is read before it goes")
        #expect(rule(.sdk, .ended(.failed)) == .stay, "never put up for a call that is over")
        #expect(rule(.sdk, .idle, shown: true) == .dismiss)
        #expect(rule(.sdk, .idle) == .stay)
    }

    @Test func theAppsOwnScreenMeansNothingIsPutOverIt() {
        #expect(rule(.app, .ringing) == .stay)
        #expect(rule(.app, .active, shown: true) == .dismiss, "switched to the app's screen mid-call")
        #expect(rule(nil, .ringing) == .stay, "not configured")
    }
}

// MARK: - What each method does

@Suite struct CallsHostCoreTests {
    // MARK: configure and restore

    @Test func theFirstConfigureMakesTheInstanceAndLaterOnesUpdateTheCalls() throws {
        let rig = HostRig()
        try rig.configure(["appVersion": "2.4.0", "ringTimeoutMs": 45_000])
        #expect(rig.platform.made.count == 1)
        #expect(rig.platform.made.first?.appVersion == "2.4.0")
        #expect(rig.platform.configured.last?.ringTimeoutMs == 45_000)
        #expect(rig.core.options?.publishableKey == "pk_test_rig")
        try rig.configure(["displayName": "Acme Assistant"])
        #expect(rig.platform.made.count == 1, "one instance per process")
        #expect(rig.platform.configured.count == 2)
        #expect(rig.platform.configured.last?.displayName == "Acme Assistant")
        #expect(rig.logs.isEmpty)
        #expect(rig.store.load().options?["displayName"] as? String == "Acme Assistant", "kept for the next cold start")
    }

    @Test func invalidOptionsAreRefusedAndNothingIsKept() {
        let rig = HostRig()
        do {
            try rig.core.configure(["publishableKey": "pk_test_rig"])
            Issue.record("configure accepted options with no displayName")
        } catch let error as GraineCallsHostError {
            #expect(error == invalid("displayName is required"))
        } catch {
            Issue.record("not a host error: \(error)")
        }
        #expect(rig.platform.made.isEmpty)
        #expect(rig.store.load().options == nil)
    }

    @Test func aDifferentKeyIsKeptForTheNextLaunchAndSaidSo() throws {
        let rig = HostRig()
        try rig.configure()
        try rig.configure(["publishableKey": "pk_test_other"])
        #expect(rig.platform.made.count == 1)
        #expect(rig.logs.count == 1)
        #expect(rig.store.load().options?["publishableKey"] as? String == "pk_test_other")
        try rig.configure(["publishableKey": "pk_test_rig", "baseUrl": "https://graine.example.com"])
        #expect(rig.logs.count == 2, "a different base URL too")
    }

    @Test func anInstanceTheAppMadeWithAnotherKeyIsSaidToo() throws {
        let rig = HostRig()
        rig.platform.runningWith = ("pk_test_native", "https://www.graine.ai/", false)
        try rig.configure()
        #expect(rig.logs.count == 1)
        let same = HostRig()
        same.platform.runningWith = ("pk_test_rig", "https://www.graine.ai/", false)
        try same.configure()
        #expect(same.logs.isEmpty, "a trailing slash is the same base URL")
    }

    @Test func debugIsReadWhenTheInstanceIsMadeAndAChangeWaitsForTheNextLaunch() throws {
        let rig = HostRig()
        try rig.configure(["debug": true])
        #expect(rig.platform.made.first?.debug == true, "the SDK instance is made with the debug log on")
        #expect(rig.logs.isEmpty)
        try rig.configure(["debug": true, "displayName": "Acme Assistant"])
        #expect(rig.logs.isEmpty, "the same setting again is nothing to say")
        try rig.configure(["debug": false])
        #expect(rig.platform.made.count == 1, "one instance per process")
        #expect(rig.logs.count == 1)
        #expect(rig.store.load().options?["debug"] as? Bool == false, "kept for the next launch")
        // The next launch: its cold start makes the instance from what was kept.
        let next = HostRig()
        next.store.saveOptions(try #require(rig.store.load().options))
        #expect(next.core.restore())
        #expect(next.platform.made.first?.debug == false)
    }

    @Test func anInstanceTheAppMadeWithAnotherDebugSettingIsSaidToo() throws {
        let rig = HostRig()
        rig.platform.runningWith = ("pk_test_rig", "https://www.graine.ai", true)
        try rig.configure()
        #expect(rig.logs.count == 1)
        let same = HostRig()
        same.platform.runningWith = ("pk_test_rig", "https://www.graine.ai", true)
        try same.configure(["debug": true])
        #expect(same.logs.isEmpty)
    }

    @Test func restoreAppliesTheKeptOptionsWithoutKeepingThemAgain() throws {
        let rig = HostRig()
        // Kept by an earlier launch, by a newer SDK with a key this one does not know.
        var kept = try CallsHostOptions.parse(["publishableKey": "pk_test_rig", "displayName": "Acme"]).json
        kept["fromANewerSDK"] = true
        rig.store.saveOptions(kept)
        #expect(rig.core.restore())
        #expect(rig.platform.made.count == 1)
        #expect(rig.platform.configured.count == 1)
        #expect(rig.store.load().options?["fromANewerSDK"] as? Bool == true, "restore never rewrites what was kept")
        #expect(rig.platform.voipRegistrations == 0, "VoIP pushes were never enabled")
        #expect(!rig.core.restore(), "once per launch")
        #expect(rig.platform.configured.count == 1)
    }

    @Test func restoreEnablesVoIPPushesAgainWhenTheyWere() throws {
        let rig = HostRig()
        try rig.keep(voip: true)
        #expect(rig.core.restore())
        #expect(rig.platform.voipRegistrations == 1)
    }

    @Test func restoreWithNothingKeptOrAfterConfigureDoesNothing() throws {
        let rig = HostRig()
        #expect(!rig.core.restore())
        #expect(rig.platform.made.isEmpty)
        try rig.configure()
        #expect(!rig.core.restore())
        #expect(rig.platform.configured.count == 1)
    }

    @Test func unreadableKeptOptionsWaitForConfigure() {
        let rig = HostRig()
        rig.store.saveOptions(["displayName": "Acme"])
        #expect(!rig.core.restore())
        #expect(rig.platform.made.isEmpty)
        #expect(rig.logs.count == 1)
    }

    // MARK: VoIP pushes

    @Test func voipPushesAreRegisteredOnceKeptAndTheirTokenReplayed() throws {
        let rig = HostRig()
        try rig.configure()
        rig.core.enableVoIPPushes()
        #expect(rig.platform.voipRegistrations == 1)
        #expect(rig.store.load().voip)
        rig.platform.onToken?("ab12")
        rig.platform.onToken?("ab12")
        #expect(rig.events.payloads("voipToken").map { $0["token"] as? String } == ["ab12"], "the same token twice is said once")
        rig.core.enableVoIPPushes()
        #expect(rig.platform.voipRegistrations == 1)
        #expect(rig.events.payloads("voipToken").map { $0["token"] as? String } == ["ab12", "ab12"], "replayed to whoever asks again")
        rig.platform.onToken?(nil)
        #expect(rig.events.payloads("voipToken").last?["token"] is NSNull, "invalidated")
    }

    @Test func voipPushesAskedForBeforeConfigureStartWithIt() throws {
        let rig = HostRig()
        rig.core.enableVoIPPushes()
        #expect(rig.platform.voipRegistrations == 0, "no calls to register yet")
        #expect(rig.store.load().voip)
        try rig.configure()
        #expect(rig.platform.voipRegistrations == 1)
    }

    @Test func aTokenFromLaunchIsReplayedToTheFirstToAsk() throws {
        let rig = HostRig(listening: false)
        try rig.keep(voip: true)
        #expect(rig.core.restore())
        rig.platform.onToken?("cafe")
        let log = HostEventLog()
        _ = rig.core.addSink(log.record)
        #expect(log.events.isEmpty, "a token never waits in the queue")
        rig.core.enableVoIPPushes()
        #expect(log.payloads("voipToken").map { $0["token"] as? String } == ["cafe"])
        #expect(rig.platform.voipRegistrations == 1)
    }

    // MARK: Calls

    @Test func startCallPlacesTheCallWithItsReasonAndClearsTheLastError() throws {
        let rig = HostRig()
        #expect(rig.core.startCall(["reason": "support"]) == nil, "not configured")
        try rig.configure()
        rig.core.outcome(.failed("No network."), callId: "old")
        #expect(rig.core.error == "No network.")
        let id = rig.core.startCall(["reason": " card_blocked ", "variables": ["order": "A-1043"]] as [String: Any])
        #expect(id == "call-1")
        #expect(rig.platform.placed.first?.reason == "card_blocked")
        #expect(rig.platform.placed.first?.variables["order"] as? String == "A-1043")
        #expect(rig.core.reason == "card_blocked")
        #expect(rig.core.error == nil)
        rig.platform.runTurns()
        let state = try #require(rig.events.payloads("state").last)
        #expect(state["state"] as? String == "connecting")
        #expect(state["reason"] as? String == "card_blocked")
        #expect(state["error"] is NSNull)
    }

    @Test func noSecondCallWhileOneIsLive() throws {
        let rig = HostRig()
        try rig.configure()
        _ = rig.core.startCall(["reason": "first"])
        #expect(rig.core.startCall(["reason": "second"]) == nil)
        #expect(rig.platform.placed.count == 1)
        #expect(rig.core.reason == "first", "the live call keeps its reason")
    }

    @Test func aCallTheEngineRefusesLeavesEverythingAsItWas() throws {
        let rig = HostRig()
        try rig.configure()
        rig.core.outcome(.failed("No network."), callId: "old")
        rig.platform.nextCallId = nil
        #expect(rig.core.startCall(["reason": "support"]) == nil)
        #expect(rig.core.error == "No network.")
        #expect(rig.core.reason == nil)
    }

    @Test func declineIsEndWhileItRingsAndNothingOtherwise() {
        let rig = HostRig()
        rig.core.decline()
        #expect(rig.platform.ends == 0)
        rig.platform.fields.state = .ringing
        rig.core.decline()
        #expect(rig.platform.ends == 1)
        rig.platform.fields.state = .active
        rig.core.decline()
        #expect(rig.platform.ends == 1, "a call that is up is ended, not declined")
        rig.core.end()
        rig.core.answer()
        rig.core.setMuted(true)
        rig.core.setSpeaker(false)
        #expect(rig.platform.ends == 2)
        #expect(rig.platform.answers == 1)
        #expect(rig.platform.muted == [true])
        #expect(rig.platform.speaker == [false])
    }

    // MARK: What the engine reports

    @Test func aRingIsAnEventAndItsReasonIsTheSnapshots() throws {
        let rig = HostRig()
        try rig.configure()
        rig.core.outcome(.failed("No network."), callId: "old")
        rig.platform.fields = CallsHostSnapshot(state: .ringing, callId: "c9", direction: .incoming, callerName: "Acme")
        rig.core.callStateChanged(.ringing)
        #expect(rig.core.error == nil, "a new call rings: the last one's error is old news")
        rig.core.incoming(GraineIncomingCall(callId: "c9", reason: "payment_due", callerName: "Acme"))
        #expect(rig.events.payloads("incoming").map { JSON.canonical($0) } == [#"{"callerName":"Acme","callId":"c9","reason":"payment_due"}"#])
        rig.platform.runTurns()
        let state = try #require(rig.events.payloads("state").last)
        #expect(state["state"] as? String == "ringing")
        #expect(state["direction"] as? String == "incoming")
        #expect(state["reason"] as? String == "payment_due")
        #expect(state["callerName"] as? String == "Acme")
    }

    @Test func whyACallFailedOutlivesItUntilTheNextOne() throws {
        let rig = HostRig()
        try rig.configure()
        _ = rig.core.startCall(["reason": "support"])
        rig.platform.fields.state = .ended(.failed)
        rig.core.callStateChanged(.ended(.failed))
        rig.core.outcome(.failed("The microphone permission was not granted."), callId: "call-1")
        rig.platform.fields = CallsHostSnapshot()
        rig.core.callStateChanged(.idle)
        rig.platform.runTurns()
        let idle = try #require(rig.events.payloads("state").last)
        #expect(idle["state"] as? String == "idle")
        #expect(idle["error"] as? String == "The microphone permission was not granted.")
        #expect(idle["reason"] is NSNull)
        let outcome = try #require(rig.events.payloads("outcome").last)
        #expect(JSON.canonical(outcome) == #"{"callId":"call-1","error":"The microphone permission was not granted.","outcome":"failed"}"#)
        _ = rig.core.startCall(nil)
        #expect(rig.core.error == nil, "cleared when the next call is placed")
    }

    @Test func aPushRefusedDuringACallIsNotThatCallsError() throws {
        let rig = HostRig()
        try rig.configure()
        rig.platform.fields = CallsHostSnapshot(state: .active, callId: "live")
        rig.core.outcome(.failed("The push was not an agent call this SDK can ring."), callId: "other")
        #expect(rig.core.error == nil)
        rig.core.outcome(.missed, callId: "other")
        #expect(rig.events.payloads("outcome").count == 2, "the app still hears about both")
    }

    @Test func changesInOneTurnAreOneStateEventAndNoChangeIsNone() throws {
        let rig = HostRig()
        try rig.configure()
        rig.platform.runTurns()
        #expect(rig.events.payloads("state").isEmpty, "idle is not news")
        rig.platform.fields = CallsHostSnapshot(state: .connecting, callId: "c1", direction: .outgoing, callerName: "Acme")
        rig.core.engineChanged()
        rig.core.engineChanged()
        rig.core.callStateChanged(.connecting)
        rig.core.engineChanged()
        #expect(rig.platform.pendingTurns == 1)
        rig.platform.runTurns()
        #expect(rig.events.payloads("state").count == 1)
        rig.core.engineChanged()
        rig.platform.runTurns()
        #expect(rig.events.payloads("state").count == 1, "nothing a screen draws changed")
        rig.platform.fields.agentSpeaking = true
        rig.core.engineChanged()
        rig.platform.runTurns()
        #expect(rig.events.payloads("state").last?["agentSpeaking"] as? Bool == true)
    }

    @Test func aNewSinkReadsTheSnapshot() throws {
        let rig = HostRig()
        #expect(rig.core.snapshot()["state"] as? String == "idle", "before configure too")
        try rig.configure()
        rig.platform.fields = CallsHostSnapshot(
            state: .active, callId: "c1", direction: .outgoing, callerName: "Acme",
            connectedAt: Date(timeIntervalSince1970: 1_000)
        )
        let snapshot = rig.core.snapshot()
        #expect(snapshot["state"] as? String == "active")
        #expect((snapshot["connectedAt"] as? NSNumber)?.int64Value == 1_000_000)
        #expect(snapshot["reason"] is NSNull)
    }

    @Test func aRingGraineSentRingsOnTheEventsAndItsEndSaysHostedAndHowLong() throws {
        let rig = HostRig()
        try rig.configure()
        rig.platform.callAgents["h1"] = "default"
        rig.platform.fields = CallsHostSnapshot(state: .ringing, callId: "h1", direction: .incoming)
        rig.platform.callHosted = true
        rig.core.incoming(GraineIncomingCall(callId: "h1", reason: "renewal", callerName: "Acme", hosted: true))
        // The ring, then the engine's word to Graine that it is ringing — told to the app too.
        #expect(rig.events.payloads("incoming").map { $0["hosted"] as? Bool } == [true])
        #expect(rig.events.payloads("outcome").map { JSON.canonical($0) } == [#"{"agent":"default","callId":"h1","hosted":true,"outcome":"ringing"}"#])
        rig.core.outcome(.answered, callId: "h1")
        // Connected at 1 000 s; it ends 95 seconds later.
        rig.platform.fields = CallsHostSnapshot(state: .ended(.remote), callId: "h1", direction: .incoming, connectedAt: Date(timeIntervalSince1970: 1_000))
        rig.platform.clock = Date(timeIntervalSince1970: 1_095)
        rig.core.outcome(.ended(.remote), callId: "h1")
        let outcomes = rig.events.payloads("outcome")
        #expect(outcomes.map { $0["outcome"] as? String } == ["ringing", "answered", "ended"])
        #expect(outcomes.map { $0["hosted"] as? Bool } == [true, true, true])
        #expect(outcomes.last?["durationSeconds"] as? Int == 95)
        #expect(outcomes[1]["durationSeconds"] == nil)
        // A ring refused while that call is live is another call's: nothing known about it is said.
        rig.core.outcome(.missed, callId: "other")
        #expect(rig.events.payloads("outcome").last?["hosted"] == nil)
        // The app's own push: no ringing outcome, no hosted.
        rig.platform.callHosted = false
        rig.platform.fields = CallsHostSnapshot(state: .ringing, callId: "c2", direction: .incoming)
        rig.core.incoming(GraineIncomingCall(callId: "c2", reason: "payment_due"))
        #expect(rig.events.payloads("outcome").count == 4, "no ringing for the app's own ring")
        #expect(rig.events.payloads("incoming").last?["hosted"] == nil)
    }

    @Test func outcomesFromBeforeAnythingListenedReachTheFirstSink() throws {
        let rig = HostRig(listening: false)
        try rig.configure()
        rig.core.incoming(GraineIncomingCall(callId: "c1", reason: "payment_due"))
        rig.core.outcome(.answered, callId: "c1")
        rig.core.outcome(.ended(.remote), callId: "c1")
        rig.platform.runTurns()
        let log = HostEventLog()
        _ = rig.core.addSink(log.record)
        #expect(log.names == ["incoming", "outcome", "outcome"])
    }

    // MARK: Who, what and where

    @Test func identityVariablesAndTheScreenReachTheSDK() throws {
        let rig = HostRig()
        try rig.configure()
        rig.core.setIdentity(["name": "Asha"])
        rig.core.setIdentity(nil)
        rig.core.setVariables(["plan": "Plus", "cart": 1299])
        rig.core.setVariables(["plan": "Gold"])
        rig.core.setScreen(["screen": "billing", "title": "Billing"])
        rig.core.setScreen(["title": "no screen name"])
        let identities = rig.platform.identities
        #expect(identities.count == 2)
        #expect(identities[0]?["name"] as? String == "Asha")
        #expect(identities[1] == nil, "sign-out")
        #expect(rig.platform.variableChanges.map(describe) == [
            ["plan": "Plus", "cart": "1299"],
            ["plan": "Gold", "cart": "<removed>"],
        ])
        #expect(rig.platform.screens.map { $0?.screen } == ["billing", nil])
        #expect(rig.platform.screens.compactMap { $0 }.first?.title == "Billing")
    }

    @Test func whatArrivesBeforeConfigureIsHeldUntilThereIsAnInstance() throws {
        let rig = HostRig()
        rig.core.setIdentity(["name": "Asha"])
        rig.core.setVariables(["plan": "Plus"])
        rig.core.setVariables(["plan": "Gold", "city": "Pune"])
        rig.core.setScreen(["screen": "home"])
        rig.core.setActions(["open_screen"], sink: rig.sink)
        #expect(rig.platform.identities.isEmpty)
        #expect(rig.platform.variableChanges.isEmpty)
        #expect(rig.platform.handlers.isEmpty)
        try rig.configure()
        #expect(rig.platform.identities.count == 1)
        #expect(rig.platform.variableChanges.map(describe) == [["plan": "Gold", "city": "Pune"]], "only the latest map")
        #expect(rig.platform.screens.map { $0?.screen } == ["home"])
        #expect(Array(rig.platform.handlers.keys) == ["open_screen"])
        try rig.configure()
        #expect(rig.platform.identities.count == 1, "applied once")
    }

    // MARK: Actions

    @Test func theAgentsActionIsAskedOfTheSinkAndAnsweredOnce() throws {
        let rig = HostRig()
        try rig.configure()
        rig.core.setActions(["open_screen", "open_screen", ""], sink: rig.sink)
        #expect(Array(rig.platform.handlers.keys) == ["open_screen"])
        var answers: [GraineActionResult] = []
        let handler = try rig.handler("open_screen")
        handler(["page": "billing"]) { answers.append($0) }
        let request = try #require(rig.events.payloads("action").first)
        #expect(request["name"] as? String == "open_screen")
        #expect((request["arguments"] as? [String: Any])?["page"] as? String == "billing")
        let id = try #require(request["requestId"] as? String)
        rig.core.resolveAction(id, ["status": "ok", "message": "Opened the bill."])
        rig.core.resolveAction(id, ["status": "error", "message": "late"])
        #expect(answers.map { $0.status } == [.ok])
        #expect(answers.first?.message == "Opened the bill.")
        rig.platform.fireTimers()
        #expect(answers.count == 1, "forgotten later, harmlessly: it was answered")
    }

    @Test func namesNoLongerListedAreUnregistered() throws {
        let rig = HostRig()
        try rig.configure()
        rig.core.setActions(["open_screen", "set_theme"], sink: rig.sink)
        rig.core.setActions(["set_theme"], sink: rig.sink)
        #expect(rig.platform.unregistered == ["open_screen"])
        #expect(Array(rig.platform.handlers.keys) == ["set_theme"])
        rig.core.setActions([String](), sink: rig.sink)
        #expect(rig.platform.handlers.isEmpty)
        #expect(rig.platform.unregistered == ["open_screen", "set_theme"])
    }

    @Test func anActionNobodyCanAnswerIsRefusedAtOnce() throws {
        let rig = HostRig()
        try rig.configure()
        rig.core.setActions(["open_screen"], sink: nil)
        var answers: [GraineActionResult] = []
        let handler = try rig.handler("open_screen")
        handler([:]) { answers.append($0) }
        #expect(answers.map { $0.status } == [.refused])
        #expect(rig.events.payloads("action").isEmpty)
        #expect(rig.core.actions.pendingCount == 0)
        #expect(rig.platform.timers.isEmpty)
    }

    @Test func aSinkThatLeavesHasItsUnansweredRequestsRefused() throws {
        let rig = HostRig()
        try rig.configure()
        rig.core.setActions(["open_screen"], sink: rig.sink)
        var answers: [GraineActionResult] = []
        let handler = try rig.handler("open_screen")
        handler([:]) { answers.append($0) }
        rig.core.removeSink(try #require(rig.sink))
        #expect(answers.map { $0.status } == [.refused])
        handler([:]) { answers.append($0) }
        #expect(answers.map { $0.status } == [.refused, .refused], "and the next request is refused at once")
    }

    @Test func aRequestTheAppNeverAnswersIsForgotten() throws {
        let rig = HostRig()
        try rig.configure()
        rig.core.setActions(["open_screen"], sink: rig.sink)
        var answers: [GraineActionResult] = []
        let handler = try rig.handler("open_screen")
        handler([:]) { answers.append($0) }
        #expect(rig.platform.timers.map { $0.seconds } == [10])
        rig.platform.fireTimers()
        #expect(answers.map { $0.status } == [.error])
        #expect(rig.core.actions.pendingCount == 0)
    }

    // MARK: The SDK's call screen

    @Test func theSDKsCallScreenIsUpForALiveCallAndDownAtIdle() throws {
        let rig = HostRig()
        try rig.configure()
        rig.platform.fields.state = .ringing
        rig.core.callStateChanged(.ringing)
        rig.platform.runTurns()
        #expect(rig.platform.presented == 1)
        rig.platform.fields.state = .active
        rig.core.callStateChanged(.active)
        rig.platform.runTurns()
        #expect(rig.platform.presented == 1, "once per call")
        rig.platform.fields.state = .ended(.local)
        rig.core.callStateChanged(.ended(.local))
        rig.platform.runTurns()
        #expect(rig.platform.dismissed == 0, "\"Call ended\" is read first")
        rig.platform.fields.state = .idle
        rig.core.callStateChanged(.idle)
        rig.platform.runTurns()
        #expect(rig.platform.dismissed == 1)
    }

    @Test func aCallAnsweredOnTheLockScreenGetsItsScreenWhenTheAppOpens() throws {
        let rig = HostRig()
        try rig.configure()
        rig.platform.appActive = false
        rig.platform.fields.state = .active
        rig.core.callStateChanged(.active)
        rig.platform.runTurns()
        #expect(rig.platform.presented == 0)
        rig.platform.appActive = true
        rig.core.appBecameActive()
        rig.platform.runTurns()
        #expect(rig.platform.presented == 1)
    }

    @Test func theAppsOwnCallScreenMeansNothingIsPutOverTheApp() throws {
        let rig = HostRig()
        try rig.configure(["callScreen": "app"])
        rig.platform.fields.state = .ringing
        rig.core.callStateChanged(.ringing)
        rig.platform.runTurns()
        #expect(rig.platform.presented == 0)
    }

    @Test func switchingToTheAppsScreenMidCallTakesTheSDKsDown() throws {
        let rig = HostRig()
        try rig.configure()
        rig.platform.fields.state = .active
        rig.core.engineChanged()
        rig.platform.runTurns()
        #expect(rig.platform.presented == 1)
        try rig.configure(["callScreen": "app"])
        rig.platform.runTurns()
        #expect(rig.platform.dismissed == 1)
    }
}

@Suite struct CallsHostAgentsTests {
    @Test func moreAgentsAreReadKeptAndChecked() throws {
        let options = try CallsHostOptions.parse([
            "publishableKey": "pk_main", "displayName": "Acme",
            "agents": ["sales": ["publishableKey": "pk_sales"], " care ": ["publishableKey": "pk_care", "baseUrl": "https://www.graine.ai/"],
                       "default": ["publishableKey": "pk_ignored"]],
        ] as [String: Any])
        #expect(options.agents == [
            "sales": CallsHostOptions.Agent(publishableKey: "pk_sales", baseUrl: "https://www.graine.ai"),
            "care": CallsHostOptions.Agent(publishableKey: "pk_care", baseUrl: "https://www.graine.ai"),
        ])
        #expect(try CallsHostOptions.parse(options.json) == options, "kept for a cold start, read back the same")
        #expect(throws: GraineCallsHostError.invalidOptions("agents.sales.publishableKey is required")) {
            _ = try CallsHostOptions.parse(["publishableKey": "pk", "displayName": "A", "agents": ["sales": ["baseUrl": "x"]]] as [String: Any])
        }
        #expect(throws: GraineCallsHostError.invalidOptions("agents must be an object")) {
            _ = try CallsHostOptions.parse(["publishableKey": "pk", "displayName": "A", "agents": "sales"] as [String: Any])
        }
        #expect(CallsHostValues.callRequest(["reason": "help", "agent": " sales "]).agent == "sales")
        #expect(CallsHostValues.callRequest(["reason": "help"]).agent == nil)
    }

    @Test func theSnapshotTheRingTheOutcomeAndTheActionNameTheCallsAgent() throws {
        let rig = HostRig()
        try rig.configure(["agents": ["sales": ["publishableKey": "pk_sales"]]])
        rig.core.setActions(["raise_ticket"], sink: rig.sink)
        // A ring Graine routed to the sales agent by the push's agent_id.
        rig.platform.callAgents["h1"] = "sales"
        rig.platform.fields = CallsHostSnapshot(state: .ringing, callId: "h1", direction: .incoming, agent: "sales")
        rig.core.incoming(GraineIncomingCall(callId: "h1", reason: "renewal", callerName: "Sales", hosted: true))
        rig.platform.runTurns()
        #expect(rig.events.payloads("incoming").first?["agent"] as? String == "sales")
        #expect(rig.events.payloads("state").last?["agent"] as? String == "sales")
        #expect(rig.core.snapshot()["agent"] as? String == "sales")
        let handler = try rig.handler("raise_ticket")
        handler([:]) { _ in }
        #expect(rig.events.payloads("action").first?["agent"] as? String == "sales", "the agent on the call asked")
        rig.core.outcome(.answered, callId: "h1")
        // A ring refused while that call is live is its own agent's: the default one here.
        rig.platform.callAgents["h2"] = "default"
        rig.core.outcome(.missed, callId: "h2")
        // An outcome nobody can place says nothing about an agent.
        rig.core.outcome(.missed, callId: "unknown")
        // First the ring itself: Graine rang it, so the app hears it ringing — then what became of it, and of the others.
        #expect(rig.events.payloads("outcome").map { $0["outcome"] as? String } == ["ringing", "answered", "missed", "missed"])
        let agents = rig.events.payloads("outcome").map { $0["agent"] as? String }
        #expect(agents == ["sales", "sales", "default", nil])
        #expect(rig.events.payloads("outcome").last?["agent"] == nil)
        rig.platform.fields = CallsHostSnapshot()
        rig.core.callStateChanged(.idle)
        rig.platform.runTurns()
        #expect(rig.events.payloads("state").last?["agent"] is NSNull, "idle: no agent")
    }

    @Test func aCallIsPlacedWithTheAgentItNames() throws {
        let rig = HostRig()
        try rig.configure(["agents": ["sales": ["publishableKey": "pk_sales"]]])
        #expect(rig.platform.configured.last?.agents["sales"]?.publishableKey == "pk_sales", "the device configures the other agents")
        _ = rig.core.startCall(["reason": "upgrade", "agent": "sales"])
        #expect(rig.platform.placedAgents == ["sales"])
    }
}
