import Foundation
import Testing
@testable import GraineInApp

/*
 * The Objective-C facade (Sources/GraineInApp/ObjC) on fakes: every selector
 * a bridge binds to is answered at run time by that name, and each method
 * reaches the SDK — and hands back its answers — in the facade's own shapes.
 */
@Suite @MainActor struct ObjCFacadeTests {
    /// JSON text the facade handed back, read as Foundation reads it.
    private func parse(_ text: String?) -> Any? {
        text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
    }

    // MARK: The selectors a bridge binds to

    /// What Kotlin Multiplatform's binding (sdk/kmp …/GraineObjC.h) and Objective-C apps call, by name.
    @Test func everySelectorIsAnsweredByItsName() throws {
        let selectors: [String: (instance: [String], klass: [String])] = [
            "GraineObjC": ([
                "name", "installId", "memoryChoice", "session", "sessionJSON", "themeJSON", "chat", "calls", "voice", "bookingAvailable",
                "identify:", "identify:memory:", "identifyJSON:", "identifyJSON:memory:", "setMemory:",
                "forgetMemoryWithCompletion:", "memoriesWithCompletion:", "memoriesJSONWithCompletion:",
                "setVariables:", "setVariablesJSON:", "currentVariables", "currentVariablesJSON", "setScreen:", "setScreenJSON:", "updateField:", "updateFieldJSON:",
                "removeField:", "clearScreen:", "track:data:", "trackEvent:dataJSON:", "tap:", "noteInteraction",
                "registerAction:handler:", "registerJSONAction:handler:",
                "scheduleCallAt:reason:completion:", "scheduleCallJSONAt:reason:completion:",
                "scheduledCallsWithCompletion:", "scheduledCallsJSONWithCompletion:", "cancelScheduledCall:completion:",
                "addListener:", "removeListener:", "observeEvents:",
                // 0.14.0, public state (PUBLIC-STATE.md).
                "bookingUnavailableReason", "bookingSlotsJSONForDay:",
                "componentJSON", "componentPending", "componentPendingKind", "observeComponent:",
                // 0.14.4, workflows the app starts (PUBLIC-STATE.md §7).
                "startWorkflowJSON:dataJSON:idempotencyKey:completion:",
                // 0.14.4, your app and your users (APP-IDENTITY.md §4).
                "identify:identityToken:", "identify:memory:identityToken:", "identifyJSON:identityToken:", "identifyJSON:memory:identityToken:",
                "setIdentityToken:", "setIdentityTokenRefresher:", "hasIdentityTokenRefresher", "prepareAppVerificationWithCompletion:",
                "verificationApp", "verificationAppReason", "verificationUser", "verificationUserReason", "verificationJSON",
                "observeVerification:", "debugTokenMode", "setDebugTokenMode:", "debugToken",
            ], [
                "errorDomain", "current", "configureWithBaseUrl:publishableKey:", "configureWithBaseUrl:publishableKey:variables:",
                "configureWithBaseUrl:publishableKey:appVersion:debug:endOnBackground:captureTaps:transport:variablesJSON:",
                "configureWithBaseUrl:publishableKey:appVersion:debug:endOnBackground:captureTaps:transport:variablesJSON:name:",
                "configureWithBaseUrl:publishableKey:appVersion:debug:endOnBackground:captureTaps:transport:variablesJSON:name:chatSize:",
                "configureWithBaseUrl:publishableKey:appVersion:debug:endOnBackground:captureTaps:transport:variablesJSON:name:chatSize:chatCloseDelaySeconds:",
                // 0.14.4, server tokens: the block the Kotlin Multiplatform library rides.
                "configureWithBaseUrl:publishableKey:appVersion:debug:endOnBackground:captureTaps:transport:variablesJSON:name:chatSize:chatCloseDelaySeconds:tokenProvider:",
                "named:",
            ]),
            "GraineObjCChat": ([
                "turns", "status", "reconnectAttempt", "typing", "isOpen", "snapshotJSON",
                "open", "openWithSize:", "newConversationWithCompletion:", "close", "send:", "retry", "clear",
                "upcomingCalls", "answerWidgetWithId:dataJSON:summary:", "refreshUpcomingCalls", "cancelUpcomingCall:",
                "addListener:", "removeListener:", "observe:",
                "quickReplies", "sendQuickReply:", "ended", "rating", "rateWithStyle:value:", "observeRatings:",
                "pinned", "pinWithTitle:subtitle:imageUrl:badge:", "clearPin", "setAttachHandler:",
                "setShown:", "disconnected", "wasOnline", "newConversationBefore", "dismissWidgetWithId:",
                // 0.14.3, past sessions (PUBLIC-STATE.md "Past sessions"), and how long an unseen chat is kept.
                "pastSessionsJSON", "refreshPastSessions", "loadMorePastSessions", "sessionTranscriptJSONWithId:completion:",
                "closeDelaySeconds", "setCloseDelaySeconds:",
                // 0.14.4, why the chat could not connect (server tokens, a revoked key).
                "error",
            ], []),
            "GraineObjCQuickReply": (["label", "text", "initWithLabel:text:"], []),
            "GraineObjCChatRating": (["style", "value", "scale", "json"], []),
            "GraineObjCChatPin": (["title", "subtitle", "imageUrl", "badge"], []),
            "GraineObjCCalls": ([
                "configureWithDisplayName:ringtoneSound:ringTimeout:includesCallsInRecents:", "enableVoIPPushes",
                "startCallWithReason:variables:", "startCallJSONWithReason:variablesJSON:", "prepareCallJSONWithReason:variablesJSON:", "answer", "decline", "end",
                "setMuted:", "setSpeaker:", "callBack", "dismissMissedCall", "state", "endReason", "callId", "callerName",
                "direction", "muted", "speakerOn", "agentSpeaking", "reconnecting", "hosted", "agent", "showsCallScreen", "snapshotJSON",
                "addListener:", "removeListener:", "observe:", "observeOutcomes:", "observeIncoming:",
                "callPermissionsJSON", "requestCallPermissionsJSONWithCompletion:", "openCallSettings:", "callSetupProblemsJSON",
                "reason", "agentLevel", "agentLevelHeard", "connectedAt", "connectionJSON",
            ], []),
            "GraineObjCVoice": ([
                "attach", "start", "end", "setMuted:", "connected", "connecting", "muted", "snapshotJSON", "observe:",
                "captionsOn", "setCaptionsOn:", "clearCaptions",
                "status", "error", "agentLevel", "micLevel", "transport", "transportFallbackReason", "micDenied",
            ], []),
            "GraineObjCRegistration": (["unregister"], []),
            "GraineObjCActionResult": (["status", "message", "data"], ["ok:", "ok:data:", "refused:", "error:"]),
            "GraineObjCMemory": (["identifier", "text", "createdAt", "updatedAt"], []),
            "GraineObjCScheduledCall": (["identifier", "at", "status", "source", "reason", "isUpcoming", "canCancel"], []),
            "GraineObjCSession": (["agentId", "memoryEnabled", "identityField", "devicesPerUser", "usersCanBook", "hostedRinging", "callName", "json"], []),
            "GraineObjCChatTurn": (["identifier", "role", "text", "live", "delivery", "at", "proactive", "restored", "channel"], []),
            "GraineObjCCallOutcome": (["callId", "outcome", "reason", "durationSeconds", "hosted", "agent", "connectionJSON", "json"], []),
        ]
        for (name, sels) in selectors {
            let cls = try #require(NSClassFromString(name) as? NSObject.Type, "\(name) is an Objective-C class by that name")
            for s in sels.instance { #expect(cls.instancesRespond(to: NSSelectorFromString(s)), "-[\(name) \(s)]") }
            for s in sels.klass { #expect(cls.responds(to: NSSelectorFromString(s)), "+[\(name) \(s)]") }
        }
        #expect(GraineObjC.errorDomain == "ai.graine.inapp")
    }

    // MARK: Who, and memory

    @Test func identifyJSONIsWhoTheUserIsAndTheirMemoryChoice() {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session(["identity": ["field": "patient_id", "devicesPerUser": 1]])
        let graine = GraineObjC(graine: rig.graine)
        graine.identifyJSON(#"{"patient_id":"MRN-000981","name":"Riya","age":41}"#, memory: false)
        #expect(rig.graine.identity.snapshot().value == "MRN-000981")
        #expect(graine.memoryChoice == false)
        #expect(rig.graine.currentVariables()["name"] == "Riya")
        #expect(rig.graine.currentVariables()["patient_id"] == nil, "the identifier never becomes a variable")
        graine.setMemory(true)
        #expect(graine.memoryChoice)
        graine.identifyJSON(nil)
        #expect(rig.graine.identity.snapshot().value == nil)
    }

    @Test func forgettingSaysHowManyAndWhyNot() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session()
        let graine = GraineObjC(graine: rig.graine)
        let refused = await withCheckedContinuation { c in graine.forgetMemory { n, e in c.resume(returning: (n, e)) } }
        let error = try #require(refused.1)
        #expect(error.domain == "ai.graine.inapp")
        #expect(error.code == 0)
        #expect(error.userInfo["code"] as? String == "identity_required")
        graine.identify(["user_id": "P-1"])
        rig.network.replies["/api/embed/memory/forget"] = (200, #"{"deleted":3}"#)
        let done = await withCheckedContinuation { c in graine.forgetMemory { n, e in c.resume(returning: (n, e)) } }
        #expect(done.0 == 3)
        #expect(done.1 == nil)
        let body = try #require(rig.network.bodies("/api/embed/memory/forget").first)
        #expect((body["identity"] as? [String: Any])?["value"] as? String == "P-1")
    }

    @Test func memoriesComeAsObjectsOrJSON() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session()
        let graine = GraineObjC(graine: rig.graine)
        graine.identify(["user_id": "P-1"])
        rig.network.replies["/api/embed/memory/list"] = (200, #"{"memories":[{"id":"m1","text":"Takes metformin at 8 pm","createdAt":"2026-10-13T09:00:00Z","updatedAt":null}]}"#)
        let json = await withCheckedContinuation { c in graine.memoriesJSON { j, _ in c.resume(returning: j) } }
        let list = try #require(parse(json) as? [[String: Any]])
        #expect(list.first?["id"] as? String == "m1")
        #expect((list.first?["createdAt"] as? NSNumber)?.int64Value == 1_791_882_000_000)
        #expect(list.first?["updatedAt"] is NSNull)
        let objects = await withCheckedContinuation { c in graine.memories { m, _ in c.resume(returning: m) } }
        #expect(objects?.first?.identifier == "m1")
        rig.network.replies["/api/embed/memory/list"] = (403, #"{"error":"This device is not one of theirs.","code":"device_limit"}"#)
        let refused = await withCheckedContinuation { c in graine.memoriesJSON { _, e in c.resume(returning: e) } }
        #expect(refused?.code == 403)
        #expect(refused?.userInfo["code"] as? String == "device_limit")
        #expect(refused?.localizedDescription == "This device is not one of theirs.")
    }

    // MARK: The screen

    @Test func aScreenFromJSONIsWhatTheAgentSees() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        let graine = GraineObjC(graine: rig.graine)
        graine.setScreenJSON(#"{"screen":"kyc","title":"Upload","journey":{"name":"KYC","step":2,"of":4},"fields":[{"name":"pan","label":"PAN","value":"ABCDE1234F","status":"invalid","error":"Not recognised"},{"name":"note","optional":true}],"data":{"attempts":2},"availableActions":[]}"#)
        var context = try #require(rig.graine.currentContextFrame()?["context"] as? [String: Any])
        #expect(context["screen"] as? String == "kyc")
        #expect((context["journey"] as? [String: Any])?["step"] as? Int == 2)
        var fields = try #require(context["fields"] as? [[String: Any]])
        #expect(fields.map { $0["name"] as? String } == ["pan", "note"])
        #expect(fields[0]["status"] as? String == "invalid")
        #expect(fields[1]["optional"] as? Bool == true)
        #expect(rig.graine.currentContextFrame()?["availableActions"] as? [String] == [], "an empty list stays a list: nothing here")
        graine.updateFieldJSON(#"{"name":"otp","status":"empty"}"#)
        graine.removeField("note")
        fields = try #require((rig.graine.currentContextFrame()?["context"] as? [String: Any])?["fields"] as? [[String: Any]])
        #expect(fields.map { $0["name"] as? String } == ["pan", "otp"])
        graine.clearScreen("another")
        #expect((rig.graine.currentContextFrame()?["context"] as? [String: Any])?["screen"] as? String == "kyc", "a late close of another screen changes nothing")
        graine.trackEvent("otp_retry", dataJSON: #"{"n":2}"#)
        context = try #require(rig.graine.currentContextFrame()?["context"] as? [String: Any])
        #expect((context["recent_events"] as? [[String: Any]])?.last?["name"] as? String == "otp_retry")
        graine.clearScreen("kyc")
        #expect((rig.graine.currentContextFrame()?["context"] as? [String: Any])?["screen"] == nil)
    }

    // MARK: Actions

    private func run(_ rig: PlatformRig, _ name: String, _ arguments: [String: Any]) async -> GraineActionResult {
        await withCheckedContinuation { c in rig.graine.executeAction(name: name, arguments: arguments) { c.resume(returning: $0) } }
    }

    @Test func aJSONActionGetsItsArgumentsAsJSONAndAnswersInWords() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        let graine = GraineObjC(graine: rig.graine)
        var heard: String?
        let registration = graine.registerJSONAction("mark_done") { args, answer in
            heard = args
            answer("refused", "Which one?", #"{"options":["a","b"]}"#)
        }
        let result = await run(rig, "mark_done", ["item": "metformin", "count": 2, "ok": true])
        let args = try #require(parse(heard) as? [String: Any])
        #expect(args["item"] as? String == "metformin")
        #expect(args["count"] as? Int == 2)
        #expect(args["ok"] as? Bool == true)
        #expect(result.status == .refused)
        #expect(result.message == "Which one?")
        #expect(result.data["options"] as? [String] == ["a", "b"])
        registration.unregister()
        registration.unregister()
        #expect(await run(rig, "mark_done", [:]).status == .refused)
        #expect(await run(rig, "mark_done", [:]).message == "This app build does not implement \"mark_done\".")
    }

    @Test func anObjectiveCActionAnswersWithAResultObject() async {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        let graine = GraineObjC(graine: rig.graine)
        _ = graine.registerAction("open_screen") { args, answer in
            answer(GraineObjCActionResult.ok("Opened \(args["screen"] as? String ?? "?").", data: ["screen": args["screen"] ?? ""]))
        }
        let result = await run(rig, "open_screen", ["screen": "calls"])
        #expect(result.status == .ok)
        #expect(result.message == "Opened calls.")
        #expect(result.data["screen"] as? String == "calls")
        #expect(GraineObjCActionResult.error("No.").result.status == .error)
        #expect(GraineObjCActionResult.refused("Not here.").status == "refused")
    }

    // MARK: Scheduled calls

    @Test func aBookingAListAndACancelInTheFacadesShapes() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session(["calls": ["hosted": true, "scheduling": ["usersCanBook": true]]])
        let graine = GraineObjC(graine: rig.graine)
        rig.network.replies["/api/embed/calls/schedule"] = (201, #"{"call":{"id":"sc_1","at":"2026-10-14T12:30:00Z","status":"scheduled","source":"sdk","reason":"Weekly check-in"}}"#)
        // Tomorrow: inside the agent's rules, which the SDK checks before it asks. The answer is the server's.
        let at = Date().addingTimeInterval(86_400)
        let booked = await withCheckedContinuation { c in graine.scheduleCallJSON(at: at, reason: "Weekly check-in") { j, e in c.resume(returning: (j, e)) } }
        #expect(booked.1 == nil)
        let call = try #require(parse(booked.0) as? [String: Any])
        #expect(call["id"] as? String == "sc_1")
        #expect(call["status"] as? String == "scheduled")
        #expect(call["source"] as? String == "sdk")
        #expect((call["at"] as? NSNumber)?.int64Value == 1_791_981_000_000)

        rig.network.replies["/api/embed/calls/list"] = (200, #"{"calls":[{"id":"sc_1","at":null,"status":"no_device"}]}"#)
        let listed = await withCheckedContinuation { c in graine.scheduledCalls { calls, _ in c.resume(returning: calls) } }
        #expect(listed?.first?.status == "no_device")
        #expect(listed?.first?.at == nil)
        #expect(listed?.first?.isUpcoming == false)

        rig.network.replies["/api/embed/calls/cancel"] = (200, #"{"ok":true}"#)
        let cancelled = await withCheckedContinuation { c in graine.cancelScheduledCall("sc_1") { s, _ in c.resume(returning: s) } }
        #expect(cancelled == "cancelled")
        #expect(rig.network.bodies("/api/embed/calls/cancel").first?["callId"] as? String == "sc_1")
        rig.network.replies["/api/embed/calls/cancel"] = (404, #"{"error":"No such call.","code":"not_found"}"#)
        let missing = await withCheckedContinuation { c in graine.cancelScheduledCall("sc_9") { _, e in c.resume(returning: e) } }
        #expect(missing?.userInfo["code"] as? String == "not_found")

        let asked = rig.network.bodies("/api/embed/calls/schedule").count
        let soon = await withCheckedContinuation { c in graine.scheduleCallJSON(at: Date().addingTimeInterval(60), reason: nil) { _, e in c.resume(returning: e) } }
        #expect(soon?.userInfo["code"] as? String == "too_soon")
        #expect(soon?.code == 0, "refused on the device: no answer from Graine")
        #expect(rig.network.bodies("/api/embed/calls/schedule").count == asked, "nothing was sent")
    }

    // MARK: Workflows the app starts

    @Test func aWorkflowStartInTheFacadesShapes() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session(["identity": ["field": "user_id"]])
        let graine = GraineObjC(graine: rig.graine)
        let nobody = await withCheckedContinuation { c in graine.startWorkflowJSON("Welcome call", dataJSON: nil, idempotencyKey: nil) { _, e in c.resume(returning: e) } }
        #expect(nobody?.userInfo["code"] as? String == "identity_required")
        #expect(rig.network.bodies("/api/embed/workflows/start").isEmpty, "nobody identified: nothing is asked")

        rig.graine.identify(["user_id": "P-1234"])
        rig.network.replies["/api/embed/workflows/start"] = (201, #"{"runId":"oex_1","workflowId":"owf_1","alreadyRunning":false}"#)
        let started = await withCheckedContinuation { c in
            graine.startWorkflowJSON("Welcome call", dataJSON: #"{"plan":"gold","seats":3,"trial":true,"user_id":"someone-else"}"#, idempotencyKey: "order-1042:welcome") { j, e in c.resume(returning: (j, e)) }
        }
        #expect(started.1 == nil)
        let run = try #require(parse(started.0) as? [String: Any])
        #expect(run["runId"] as? String == "oex_1")
        #expect(run["workflowId"] as? String == "owf_1")
        #expect((run["alreadyRunning"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && !$0.boolValue } == true, "a boolean, not a 0")
        let body = try #require(rig.network.bodies("/api/embed/workflows/start").first)
        #expect(body["idempotencyKey"] as? String == "order-1042:welcome")
        let data = try #require(body["data"] as? [String: Any])
        #expect(data["plan"] as? String == "gold")
        #expect((data["seats"] as? NSNumber)?.intValue == 3)
        #expect(data["trial"] as? Bool == true)
        #expect(data["user_id"] == nil, "who the run is for never leaves the device in data")

        rig.network.replies["/api/embed/workflows/start"] = (403, #"{"error":"Your app can't start that workflow.","code":"not_allowed"}"#)
        let refused = await withCheckedContinuation { c in graine.startWorkflowJSON("Off", dataJSON: nil, idempotencyKey: nil) { _, e in c.resume(returning: e) } }
        #expect(refused?.userInfo["code"] as? String == "not_allowed")
        #expect(refused?.code == 403)
    }

    @Test func errorsCarryTheirWordTheirStatusAndHowLongToWait() {
        let limited = ObjCBridge.nsError(GraineServiceError(code: .rateLimited, message: "Slow down.", status: 429, retryAfterSeconds: 30))
        #expect(limited.domain == "ai.graine.inapp")
        #expect(limited.code == 429)
        #expect(limited.userInfo["code"] as? String == "rate_limited")
        #expect(limited.userInfo["retryAfterSeconds"] as? Int == 30)
        #expect(limited.localizedDescription == "Slow down.")
        let unknown = ObjCBridge.nsError(GraineServiceError(code: .unknown("snoozed"), message: "Later."))
        #expect(unknown.userInfo["code"] as? String == "snoozed", "a word this build does not know is passed on")
        #expect(unknown.userInfo["retryAfterSeconds"] == nil)
        struct Odd: Error {}
        #expect(ObjCBridge.nsError(Odd()).userInfo["code"] as? String == "server_error")
    }

    // MARK: Several agents

    @Test func eachAgentHasItsOwnFacadeAndTheUserIsEveryAgents() {
        let registry = GraineAgentRegistry()
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        func agent(_ name: String, key: String) -> GraineInApp {
            let made = GraineInApp(
                config: GraineConfig(baseUrl: "https://graine.invalid", publishableKey: key),
                installIds: MemoryInstallIdStore("3f2504e0-4f89-11d3-9a0c-0305e82c3301"), defaults: sandbox.defaults,
                sessionCache: SessionCache(directory: sandbox.folder, agent: name),
                network: RoutedNetwork(), chatScheduler: ManualScheduler(), name: name, registry: registry
            )
            registry.add(made)
            return made
        }
        let main = agent("default", key: "pk_test_main")
        let help = agent("help", key: "pk_test_help")
        let mainFacade = GraineObjC.facade(for: main)
        let helpFacade = GraineObjC.facade(for: help)
        #expect(mainFacade !== helpFacade)
        #expect(GraineObjC.facade(for: help) === helpFacade, "one facade per agent")
        #expect(mainFacade.name == "default")
        #expect(helpFacade.name == "help")
        #expect(helpFacade.chat !== mainFacade.chat, "each agent has its own chat")
        helpFacade.identifyJSON(#"{"user_id":"P-1","name":"Asha"}"#, memory: false)
        #expect(main.currentVariables()["name"] == "Asha", "who the user is is the app's: every agent has them")
        #expect(mainFacade.memoryChoice == false, "one memory choice for the person")
        #expect(GraineObjC.named("nobody-configured-this") == nil)
    }

    // MARK: The session, the chat and events

    @Test func theSessionIsJSONWithWhatTheServerSaid() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        let graine = GraineObjC(graine: rig.graine)
        #expect(graine.sessionJSON == nil)
        rig.session([
            "memory": ["enabled": true],
            "identity": ["field": "patient_id", "devicesPerUser": 1],
            "calls": ["hosted": true, "platforms": ["ios"], "ringTimeoutSeconds": 45, "callName": "Asha · Graine Care",
                      "scheduling": ["usersCanBook": true, "maxDaysAhead": 7, "minLeadMinutes": 10, "maxPendingPerUser": 2]],
        ])
        let s = try #require(parse(graine.sessionJSON) as? [String: Any])
        #expect(s["agentId"] as? String == "agent-1")
        #expect(s["memoryEnabled"] as? Bool == true)
        #expect((s["identity"] as? [String: Any])?["field"] as? String == "patient_id")
        let calls = try #require(s["calls"] as? [String: Any])
        #expect(calls["usersCanBook"] as? Bool == true)
        #expect(calls["minLeadMinutes"] as? Int == 10)
        #expect(calls["callName"] as? String == "Asha · Graine Care")
        #expect(graine.session?.identityField == "patient_id")
        #expect(graine.session?.usersCanBook == true)
    }

    @Test func theChatIsAJSONSnapshotAndAMessageWaitsAsSending() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session()
        let graine = GraineObjC(graine: rig.graine)
        var snapshot = try #require(parse(graine.chat.snapshotJSON) as? [String: Any])
        #expect(snapshot["status"] as? String == "idle")
        #expect((snapshot["turns"] as? [Any])?.isEmpty == true)
        var changes = 0
        let registration = graine.chat.observe { changes += 1 }
        graine.chat.send("Where is my order?")
        await Task.yield()
        try await Task.sleep(nanoseconds: 50_000_000)
        snapshot = try #require(parse(graine.chat.snapshotJSON) as? [String: Any])
        let turn = try #require((snapshot["turns"] as? [[String: Any]])?.first)
        #expect(turn["role"] as? String == "user")
        #expect(turn["text"] as? String == "Where is my order?")
        #expect(turn["delivery"] as? String == "sending")
        #expect(graine.chat.turns.first?.delivery == "sending")
        #expect(changes > 0, "the observer heard the change")
        registration.unregister()
        graine.chat.close()
    }

    @Test func aComponentIsAnsweredFromJSONOnTheChatThatDrewIt() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session()
        let graine = GraineObjC(graine: rig.graine)
        graine.chat.open()
        let socket = try #require(rig.network.socket)
        socket.open()
        socket.frame(["type": "widget", "widget": ["widget_id": "w9", "kind": "choices"]])
        socket.clearSent()
        graine.chat.answerWidget(id: "w9", dataJSON: #"{"choice":"yes","count":2}"#, summary: "Yes, please")
        #expect(socket.sentTypes == ["widget_result", "text"])
        let result = try #require(socket.sentFrames.first)
        #expect(result["widget_id"] as? String == "w9")
        #expect((result["data"] as? [String: Any])?["count"] as? Int == 2)
        #expect(rig.graine.componentFrame == nil, "answered: nothing left to draw")
        graine.chat.close()
    }

    @Test func theUpcomingCallsRideTheSnapshotAndTheObserverHearsThem() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session(["calls": ["hosted": true]])
        let at = Date().addingTimeInterval(3_600)
        rig.network.replies["/api/embed/calls/list"] = (200, #"{"calls":[{"id":"soon","at":"\#(Scheduling.isoTime(at))","status":"scheduled","source":"agent","reason":"Delivery"}]}"#)
        let graine = GraineObjC(graine: rig.graine)
        var changes = 0
        let registration = graine.chat.observe { changes += 1 }
        graine.chat.open()
        try await Task.sleep(nanoseconds: 80_000_000)
        let snapshot = try #require(parse(graine.chat.snapshotJSON) as? [String: Any])
        let call = try #require((snapshot["upcomingCalls"] as? [[String: Any]])?.first)
        #expect(call["id"] as? String == "soon")
        #expect(call["source"] as? String == "agent")
        #expect(call["reason"] as? String == "Delivery")
        #expect(call["at"] is NSNumber, "epoch milliseconds, as every time the facade hands over")
        #expect(graine.chat.upcomingCalls.map { $0.identifier } == ["soon"])
        #expect(changes > 0)
        graine.chat.cancelUpcomingCall("soon")
        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(graine.chat.upcomingCalls.isEmpty, "cancelled: off the card")
        #expect(rig.network.bodies("/api/embed/calls/cancel").first?["callId"] as? String == "soon")
        graine.chat.refreshUpcomingCalls()
        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(rig.network.bodies("/api/embed/calls/list").count >= 2, "asked again")
        registration.unregister()
        graine.chat.close()
    }

    /// Chat window v2 for a bridge: the agent's quick replies, the end of the conversation and its rating, the pin, the paperclip.
    @Test func quickRepliesTheRatingThePinAndTheAttachHandlerCrossTheBridge() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session()
        let graine = GraineObjC(graine: rig.graine)
        graine.chat.open()
        let socket = try #require(rig.network.socket)
        socket.open()
        socket.frame(["type": "text", "data": "<beginning_of_stream>Shall I go ahead?<end_of_stream>"])
        socket.frame(["type": "quick_replies", "replies": ["Yes", ["label": "Later", "text": "Maybe later"]]])
        #expect(graine.chat.quickReplies.map { "\($0.label)|\($0.text)" } == ["Yes|Yes", "Later|Maybe later"])
        var snapshot = try #require(parse(graine.chat.snapshotJSON) as? [String: Any])
        #expect((snapshot["quickReplies"] as? [[String: String]])?.last == ["label": "Later", "text": "Maybe later"])
        #expect(snapshot["ended"] as? Bool == false && snapshot["rating"] is NSNull && snapshot["pin"] is NSNull)
        socket.clearSent()
        graine.chat.sendQuickReply(GraineObjCQuickReply(label: "Later", text: "Maybe later"))
        #expect(socket.sent == [ChatWire.textFrame("Maybe later")])
        #expect(graine.chat.quickReplies.isEmpty)

        var heard: [String] = []
        let registration = graine.chat.observeRatings { heard.append("\($0.style):\($0.value)/\($0.scale)") }
        socket.frame(["type": "conversation_end"])
        #expect(graine.chat.ended)
        graine.chat.rate(style: "emoji", value: 5)
        graine.chat.rate(style: "emoji", value: 1)
        #expect(heard == ["emoji:5/5"], "one answer per conversation")
        #expect(graine.chat.rating?.style == "emoji" && graine.chat.rating?.value == 5)
        #expect((parse(graine.chat.rating?.json) as? [String: Any])?["scale"] as? Int == 5)
        snapshot = try #require(parse(graine.chat.snapshotJSON) as? [String: Any])
        #expect((snapshot["rating"] as? [String: Any])?["style"] as? String == "emoji")
        registration.unregister()

        graine.chat.pin(title: "Your plan", subtitle: "Renews on 14 Nov", imageUrl: "https://cdn.example.com/p.png", badge: nil)
        #expect(graine.chat.pinned?.title == "Your plan" && graine.chat.pinned?.imageUrl == "https://cdn.example.com/p.png")
        snapshot = try #require(parse(graine.chat.snapshotJSON) as? [String: Any])
        #expect((snapshot["pin"] as? [String: Any])?["badge"] is NSNull)
        graine.chat.clearPin()
        #expect(graine.chat.pinned == nil)

        var attached = 0
        graine.chat.setAttachHandler { attached += 1 }
        rig.graine.chat.onAttach?()
        #expect(attached == 1)
        graine.chat.setAttachHandler(nil)
        #expect(rig.graine.chat.onAttach == nil)
        graine.chat.close()
    }

    @Test func theMergedVariablesAreReadAsTheSdkMergesThem() throws {
        let rig = PlatformRig(variables: ["plan": "Free", "city": "Pune"])
        defer { rig.sandbox.clean() }
        let graine = GraineObjC(graine: rig.graine)
        graine.setVariablesJSON(#"{"plan":"Plus","cart_total":1299}"#)
        let json = try #require(ObjCBridge.object(graine.currentVariablesJSON) as? [String: String])
        #expect(json == rig.graine.currentVariables(), "the SDK's merged set, as JSON")
        #expect(json["plan"] == "Plus", "the app's runtime value beats the build's")
        #expect(json["city"] == "Pune")
        #expect(json["cart_total"] == "1299", "a string: it goes into a sentence")
        #expect(graine.currentVariables == json)
    }

    @Test func everyDesignsTokensCrossTheBridgeWhole() throws {
        let cases = try #require(try ContractFile.load("design.json")["cases"] as? [[String: Any]])
        var crossed = 0
        for c in cases {
            guard let design = GraineDesign.parse(c["design"]) else { continue }
            for tokens in [design.light, design.dark] {
                // As a bridge reads it: JSON text, then the SDK's own reader — the same tokens back, chat and call included.
                let json = try #require(ObjCBridge.object(ObjCBridge.text(ObjCBridge.theme(tokens))))
                #expect(DesignTokens.parse(json, scheme: tokens.scheme) == tokens, "\(tokens.preset) \(tokens.scheme)")
                #expect(json["v"] as? Int == 1)
                #expect((json["motion"] as? [String: Any])?["durationMs"] is Int, "whole milliseconds, as Android writes them")
                crossed += 1
            }
        }
        #expect(crossed >= 2)
    }

    @Test func theThemeIsJSONOnceTheSessionBringsADesignAndTheEventSaysSo() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        let graine = GraineObjC(graine: rig.graine)
        #expect(graine.themeJSON == nil, "no session, no tokens")
        var heard: [String] = []
        let registration = graine.observeEvents { name, _ in heard.append(name) }
        let raw = try #require((try ContractFile.load("design.json")["cases"] as? [[String: Any]])?.first?["design"])
        rig.session(["design": raw])
        let tokens = try #require(rig.graine.theme)
        let json = try #require(ObjCBridge.object(graine.themeJSON))
        #expect((json["colors"] as? [String: Any])?["accent"] as? String == tokens.colors.accent)
        #expect(json["scheme"] as? String == tokens.scheme)
        #expect(heard.contains("theme"), "the tokens arriving are news for a bridge")
        registration.unregister()
    }

    @Test func theChatWindowsSizeIsTheConfiguresAndAnOpens() {
        func size(_ word: String?) -> GraineChatSize? {
            GraineObjC.config(
                baseUrl: "https://graine.invalid", publishableKey: "pk_test_size", appVersion: nil, debug: false,
                endOnBackground: true, captureTaps: true, transport: nil, variablesJSON: nil, chatSize: word
            ).chatSize
        }
        #expect(size("compact") == .compact)
        #expect(size("large") == .large)
        #expect(size("full") == .full)
        #expect(size("huge") == nil, "a word this build does not know follows the dashboard")
        #expect(size(nil) == nil)

        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        let graine = GraineObjC(graine: rig.graine)
        graine.chat.open(size: "large")
        #expect(rig.graine.chat.openedSize == .large)
        graine.chat.open(size: "huge")
        #expect(rig.graine.chat.openedSize == nil, "an unknown size is this open's none: the app's, then the dashboard's")
        graine.chat.open(size: "full")
        #expect(rig.graine.chat.openedSize == .full)
        graine.chat.close()
        #expect(rig.graine.chat.openedSize == nil, "the size lasts until close")
    }

    @Test func aRestoredTurnCrossesTheBridgeWithItsChannel() {
        let call = GraineChatTurn(
            id: "b00000000001", role: .agent, text: "Hi, this is Asha.", live: false, delivery: .sent,
            at: Date(timeIntervalSince1970: 1_760_349_600), proactive: false, restored: true, channel: .voice
        )
        let json = ObjCBridge.turn(call)
        #expect(json["restored"] as? Bool == true)
        #expect(json["channel"] as? String == "voice")
        #expect((json["at"] as? NSNumber)?.int64Value == 1_760_349_600_000)
        let objc = GraineObjCChatTurn(call)
        #expect(objc.restored)
        #expect(objc.channel == "voice")
        let typed = ObjCBridge.turn(GraineChatTurn(id: "t1", role: .customer, text: "Hello", live: false, delivery: .sending, at: Date(), proactive: false))
        #expect(typed["restored"] as? Bool == false)
        #expect(typed["channel"] as? String == "chat")
    }

    @Test func aNewConversationClearsTheChatAndARefusalIsTheError() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session()
        let graine = GraineObjC(graine: rig.graine)
        graine.chat.send("Where is my order?")
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(graine.chat.turns.count == 1)
        let anonymous = await withCheckedContinuation { c in graine.chat.newConversation { c.resume(returning: $0) } }
        #expect(anonymous == nil, "nobody signed in: nothing was kept, so only the screen clears")
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(graine.chat.turns.isEmpty)
        #expect(rig.network.bodies("/api/embed/conversation/new").isEmpty, "nothing to ask Graine for")

        graine.identify(["user_id": "P-1"])
        rig.network.replies["/api/embed/conversation/new"] = (403, #"{"error":"This device is not one of theirs.","code":"device_limit"}"#)
        let refused = await withCheckedContinuation { c in graine.chat.newConversation { c.resume(returning: $0) } }
        #expect(refused?.domain == "ai.graine.inapp")
        #expect(refused?.userInfo["code"] as? String == "device_limit")
        rig.network.replies["/api/embed/conversation/new"] = (200, #"{"ok":true}"#)
        let done = await withCheckedContinuation { c in graine.chat.newConversation { c.resume(returning: $0) } }
        #expect(done == nil)
        let body = try #require(rig.network.bodies("/api/embed/conversation/new").last)
        #expect((body["identity"] as? [String: Any])?["value"] as? String == "P-1")
    }

    @Test func eventsReachObserversAsNameAndJSON() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        let graine = GraineObjC(graine: rig.graine)
        var heard: [(String, String)] = []
        let registration = graine.observeEvents { name, json in heard.append((name, json)) }
        rig.session()
        _ = graine.registerJSONAction("open_screen") { _, answer in answer("ok", "Opened.", nil) }
        _ = await run(rig, "open_screen", [:])
        #expect(heard.map { $0.0 } == ["sessionReady", "actionRequested", "actionCompleted"])
        let completed = try #require(parse(heard[2].1) as? [String: Any])
        #expect(completed["status"] as? String == "ok")
        registration.unregister()
        _ = await run(rig, "open_screen", [:])
        #expect(heard.count == 3, "a stopped observer hears nothing more")
    }

    // MARK: Calls (idle where there is no CallKit) and the rules for outcomes

    @Test func callsAndVoiceAreSnapshots() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        let graine = GraineObjC(graine: rig.graine)
        let calls = try #require(parse(graine.calls.snapshotJSON) as? [String: Any])
        #expect(calls["state"] as? String == "idle")
        #expect(calls["showsCallScreen"] as? Bool == false)
        #expect(calls["agent"] is NSNull, "no call: no agent")
        #expect(graine.calls.agent == nil)
        #expect(calls["reconnecting"] as? Bool == false, "the bridge's key, beside agentSpeaking")
        #expect(!graine.calls.reconnecting)
        let voice = try #require(parse(graine.voice.snapshotJSON) as? [String: Any])
        #expect(voice["connected"] as? Bool == false)
        #expect(voice["captionsOn"] as? Bool == true, "the captions switch is on until it is turned off")
        #expect((voice["captions"] as? [Any])?.isEmpty == true)
        #expect(graine.voice.captionsOn)
    }

    @Test func agentNamesAreTrimmedAndEmptyIsTheDefault() {
        #expect(GraineObjC.agentName(" support ") == "support")
        #expect(GraineObjC.agentName("") == "default")
        #expect(GraineObjC.agentName("Support") == "Support", "names keep their case")
    }

    @Test func outcomesSayWhyHowLongAndWhoRang() {
        let missed = ObjCBridge.outcome(.missed, callId: "c1", busy: true, connectedSeconds: nil, hosted: true)
        #expect(missed["outcome"] as? String == "missed")
        #expect(missed["reason"] as? String == "busy")
        #expect(missed["hosted"] as? Bool == true)
        #expect(ObjCBridge.outcome(.missed, callId: "c1", busy: false, connectedSeconds: nil, hosted: false)["reason"] as? String == "no_answer")
        let ended = ObjCBridge.outcome(.ended(.remote), callId: "c1", busy: false, connectedSeconds: 62.6, hosted: false)
        #expect(ended["reason"] as? String == "remote")
        #expect(ended["durationSeconds"] as? Int == 63)
        #expect(ObjCBridge.outcome(.failed(""), callId: "c1", busy: false, connectedSeconds: nil, hosted: false)["reason"] as? String == "failed")
        #expect(ObjCBridge.outcome(.answered, callId: "c1", busy: false, connectedSeconds: nil, hosted: false)["reason"] == nil)
        let outcome = GraineObjCCallOutcome(ended)
        #expect(outcome.durationSeconds?.intValue == 63)
        #expect(outcome.reason == "remote")
        #expect(outcome.agent == nil, "not known: not said")
        #expect(ended["agent"] == nil)
        let named = ObjCBridge.outcome(.ended(.local), callId: "c1", busy: false, connectedSeconds: 3, hosted: false, agent: "support")
        #expect(named["agent"] as? String == "support")
        #expect(GraineObjCCallOutcome(named).agent == "support")
        #expect((parse(GraineObjCCallOutcome(named).json) as? [String: Any])?["agent"] as? String == "support")
    }
}
