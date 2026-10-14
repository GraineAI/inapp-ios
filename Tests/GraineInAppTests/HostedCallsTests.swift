import Foundation
import Testing
@testable import GraineInApp

/*
 * Calls Graine rings (contract §3) and calls the customer books (§4.2): what
 * the session says, when the device registers its token, which APNs its token
 * belongs to, what each ring's outcome is reported as, the push's `hosted`
 * flag, the scheduling routes' bodies and answers, and what a cold start keeps.
 */

@Suite struct HostedSettingsTests {
    @Test func theSessionSaysWhetherGraineRingsThisApp() throws {
        let calls = try #require(GraineHostedCallsSettings.parse([
            "hosted": true, "platforms": ["ios", "Android"], "ringTimeoutSeconds": 45, "callName": " Acme Care ",
            "scheduling": ["usersCanBook": true, "maxDaysAhead": 14, "minLeadMinutes": 5, "maxPendingPerUser": 3],
        ]))
        #expect(calls.hosted && calls.ringsThisPlatform)
        #expect(calls.platforms == ["ios", "android"])
        #expect(calls.ringTimeoutSeconds == 45)
        #expect(calls.callName == "Acme Care")
        #expect(calls.usersCanBook)
        #expect(calls.maxDaysAhead == 14 && calls.minLeadMinutes == 5 && calls.maxPendingPerUser == 3)
    }

    @Test func androidOnlyOrNotHostedIsNoRingHere() throws {
        #expect(GraineHostedCallsSettings.parse(["hosted": true, "platforms": ["android"]])?.ringsThisPlatform == false)
        #expect(GraineHostedCallsSettings.parse(["hosted": false, "platforms": ["ios"]])?.ringsThisPlatform == false)
        #expect(GraineHostedCallsSettings.parse(["hosted": true])?.ringsThisPlatform == true, "no list: every platform")
        #expect(GraineHostedCallsSettings.parse(["hosted": "yes"])?.hosted == false, "a word is not a boolean")
        #expect(GraineHostedCallsSettings.parse(nil) == nil)
        #expect(GraineHostedCallsSettings.parse(["ringTimeoutSeconds": -3])?.ringTimeoutSeconds == nil)
        // The dashboard's range, as every SDK reads it: 20–60 seconds.
        #expect(GraineHostedCallsSettings.parse(["ringTimeoutSeconds": 600])?.ringTimeoutSeconds == 60)
        #expect(GraineHostedCallsSettings.parse(["ringTimeoutSeconds": 5])?.ringTimeoutSeconds == 20)
    }

    @Test func theSessionCarriesIdentityMemoryAndCalls() throws {
        let session = GraineSessionConfig.parse([
            "agentId": "a1",
            "identity": ["field": "phone", "devicesPerUser": 1],
            "memory": ["enabled": true],
            "calls": ["hosted": true],
            "variables": ["plan": "Pro"],
        ])
        #expect(session.identity == GraineIdentitySettings(field: "phone", devicesPerUser: 1))
        #expect(session.memoryEnabled == true)
        #expect(session.calls?.hosted == true)
        #expect(Set(session.cacheable.keys) == ["agentId", "identity", "memory", "calls"], "variables are not kept on disk")
        let older = GraineSessionConfig.parse(["agentId": "a1"])
        #expect(older.identity == nil && older.memoryEnabled == nil && older.calls == nil)
        #expect(older.identitySettings.field == "user_id")
    }
}

@Suite struct SessionCacheTests {
    @Test func theLastSessionIsKeptForAColdStart() async throws {
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        let cache = SessionCache(directory: sandbox.folder)
        #expect(cache.load() == nil)
        let session = GraineSessionConfig.parse([
            "agentId": "a1", "webcallAgentId": "w1", "wsHost": "wss://ws.graine.ai",
            "appearance": ["title": "Acme", "logo": "logos/acme.png"], "calls": ["hosted": true, "callName": "Acme"],
        ])
        cache.save(session)
        // Written off the caller's thread; give it the moment it takes.
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: sandbox.folder.appendingPathComponent("session.json").path) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let next = SessionCache(directory: sandbox.folder).load()
        #expect(next?.webcallAgentId == "w1")
        #expect(next?.wsHost == "wss://ws.graine.ai")
        #expect(next?.calls?.callName == "Acme")
        #expect(next?.appearance["title"] as? String == "Acme")
    }

    @Test func anUnreadableCacheIsNoCache() throws {
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        try FileManager.default.createDirectory(at: sandbox.folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: sandbox.folder.appendingPathComponent("session.json"))
        #expect(SessionCache(directory: sandbox.folder).load() == nil)
    }
}

@Suite struct DeviceRegistrationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aNewTokenOrANewCustomerRegistersAtOnceOtherwiseDaily() {
        let fp = DeviceRegistration.fingerprint(token: "abc", fields: [("identity", "P-1"), ("tz", "Asia/Kolkata")])
        #expect(DeviceRegistration.due(last: nil, fingerprint: fp, now: now))
        let last = DeviceRegistration(fingerprint: fp, at: now)
        #expect(!DeviceRegistration.due(last: last, fingerprint: fp, now: now.addingTimeInterval(3_600)))
        #expect(DeviceRegistration.due(last: last, fingerprint: fp, now: now.addingTimeInterval(24 * 3_600)))
        #expect(DeviceRegistration.due(last: last, fingerprint: fp, now: now.addingTimeInterval(-60)), "a clock that went back")
        let anotherCustomer = DeviceRegistration.fingerprint(token: "abc", fields: [("identity", "P-2"), ("tz", "Asia/Kolkata")])
        #expect(anotherCustomer != fp)
        #expect(DeviceRegistration.due(last: last, fingerprint: anotherCustomer, now: now))
        #expect(DeviceRegistration.fingerprint(token: "abd", fields: [("identity", "P-1"), ("tz", "Asia/Kolkata")]) != fp)
    }

    @Test func whatWasSentIsKeptAsAHashNeverTheTokenOrTheCustomer() throws {
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        let fp = DeviceRegistration.fingerprint(token: "deadbeef", fields: [("identity", "asha@example.com")])
        DeviceRegistration(fingerprint: fp, at: now).save(sandbox.defaults)
        #expect(DeviceRegistration.load(sandbox.defaults) == DeviceRegistration(fingerprint: fp, at: now))
        let stored = String(describing: sandbox.defaults.dictionary(forKey: DeviceRegistration.key) ?? [:])
        #expect(!stored.contains("deadbeef") && !stored.contains("asha"))
    }
}

@Suite struct ApnsEnvironmentTests {
    private func profile(_ environment: String?) -> Data {
        let entitlements = environment.map { "<key>aps-environment</key><string>\($0)</string>" } ?? ""
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Name</key><string>Acme</string>
        <key>Entitlements</key><dict>\(entitlements)<key>application-identifier</key><string>T.ai.acme</string></dict></dict></plist>
        """
        // A CMS envelope around the property list, as a real profile has.
        return Data([0x30, 0x82, 0x2F, 0x01]) + Data(plist.utf8) + Data([0xA0, 0x82, 0x00])
    }

    @Test func aDevelopmentBuildsTokensAreSandboxTokens() {
        #expect(ApnsEnvironment.from(provisioningProfile: profile("development")) == "sandbox")
    }

    @Test func aStoreBuildOrAProductionProfileIsProduction() {
        #expect(ApnsEnvironment.from(provisioningProfile: nil) == "production", "the App Store embeds no profile")
        #expect(ApnsEnvironment.from(provisioningProfile: profile("production")) == "production")
        #expect(ApnsEnvironment.from(provisioningProfile: profile(nil)) == "production")
        #expect(ApnsEnvironment.from(provisioningProfile: Data("garbage".utf8)) == "production")
    }
}

@Suite struct HostedOutcomeTests {
    @Test func everyOutcomeIsReportedInTheRoutesWords() {
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(HostedOutcome.report(.answered, callId: "c1", connectedAt: nil).outcome == "answered")
        #expect(HostedOutcome.report(.declined, callId: "c1", connectedAt: nil).outcome == "declined")
        #expect(HostedOutcome.report(.missed, callId: "c1", connectedAt: nil).outcome == "missed")
        let ended = HostedOutcome.report(.ended(.remote), callId: "c1", connectedAt: start, now: start.addingTimeInterval(83.4))
        #expect(ended == .init(callId: "c1", outcome: "ended", reason: "remote", durationSeconds: 83))
        let failed = HostedOutcome.report(.failed("The microphone permission was not granted."), callId: "c1", connectedAt: nil)
        #expect(failed.outcome == "failed" && failed.reason == "The microphone permission was not granted.")
        #expect(HostedOutcome.ringing(callId: "c1").outcome == "ringing")
        #expect(HostedOutcome.busy(callId: "c2") == .init(callId: "c2", outcome: "missed", reason: "busy", durationSeconds: nil))
    }

    @Test func theBodyCarriesOnlyWhatItHas() {
        let body = WireJSON.object(HostedOutcome.fields(.init(callId: "c1", outcome: "ended", reason: "local", durationSeconds: 12), installId: "i-1")).text
        #expect(body == #"{"installId":"i-1","callId":"c1","outcome":"ended","reason":"local","durationSeconds":12}"#)
        let bare = WireJSON.object(HostedOutcome.fields(HostedOutcome.ringing(callId: "c1"), installId: "i-1")).text
        #expect(bare == #"{"installId":"i-1","callId":"c1","outcome":"ringing"}"#)
    }

    @Test func aPushGraineSentSaysSo() throws {
        guard case .success(let call) = CallPush.parse(["type": "agent_call", "call_id": "c9", "caller_name": "Acme", "hosted": "1"]) else {
            Issue.record("hosted push"); return
        }
        #expect(call.hosted)
        #expect(call.callerName == "Acme")
        #expect(call.reason == nil, "a hosted push carries no reason")
        guard case .success(let own) = CallPush.parse(["type": "agent_call", "call_id": "c9"]) else { Issue.record("push"); return }
        #expect(!own.hosted)
        #expect(CallPush.hosted(["data": ["type": "agent_call", "call_id": "x", "hosted": true]]))
        #expect(CallPush.hosted(["hosted": "1", "type": "nonsense"]), "even a push this SDK cannot ring")
        #expect(!CallPush.hosted(["hosted": "0"]))
    }

    @Test func aRingGraineSentIsAScheduledCallToTheAgentAndTheAppsOwnIsTheAgents() {
        // The contract's words (§3.4): the agent hears "scheduled" for a call Graine rang at a booked time.
        #expect(CallEngine.whoCalled(hosted: true) == "scheduled")
        #expect(CallEngine.whoCalled(hosted: false) == "agent")
        // A push's own who_called never wins.
        let merged = CallEngine.variables(sdk: ["who_called": "customer"], whoCalled: CallEngine.whoCalled(hosted: true), reason: nil, own: ["who_called": "agent"])
        #expect(merged.first?.0 == "who_called" && merged.first?.1 == "scheduled")
    }
}

@Suite struct SchedulingRuleTests {
    @Test func theTimeGoesWithTheDevicesOwnOffset() throws {
        let date = Date(timeIntervalSince1970: 1_791_979_200) // 2026-10-14 12:00:00 UTC
        let india = try #require(TimeZone(identifier: "Asia/Kolkata"))
        #expect(Scheduling.isoTime(date, timeZone: india) == "2026-10-14T17:30:00+05:30")
        let utc = try #require(TimeZone(identifier: "UTC"))
        #expect(Scheduling.isoTime(date, timeZone: utc) == "2026-10-14T12:00:00Z")
    }

    @Test func anAnswerIsReadAsTheWireSaysAndLeniently() throws {
        let a = try #require(Scheduling.booked(["call": [
            "id": "s1", "at": "2026-10-14T12:00:00Z", "status": "scheduled", "source": "sdk", "reason": "KYC",
        ]]))
        #expect(a == GraineScheduledCall(id: "s1", at: Date(timeIntervalSince1970: 1_791_979_200), status: .scheduled, source: .app, reason: "KYC"))
        let b = try #require(Scheduling.booked(["callId": "s2", "scheduledAt": "2026-10-14T12:00:00.250Z"]))
        #expect(b.id == "s2" && b.status == .scheduled && b.reason == nil && b.source == nil)
        #expect(b.at == Date(timeIntervalSince1970: 1_791_979_200.25))
        let c = try #require(Scheduling.booked(["call_id": "s3", "scheduled_at": 1_791_979_200_000]))
        #expect(c.at == Date(timeIntervalSince1970: 1_791_979_200))
        let timeless = try #require(Scheduling.booked(["call": ["id": "s4", "at": NSNull(), "status": "no_device", "source": NSNull()]]))
        #expect(timeless.at == nil && timeless.status == .noDevice && timeless.source == nil, "a null time is a call with no time")
        #expect(Scheduling.booked(["ok": true]) == nil)
        let list = Scheduling.listed(["calls": [
            ["id": "soon", "at": "2026-10-14T12:00:00Z", "status": "ringing"],
            ["id": "late", "at": "2026-10-15T12:00:00Z", "status": "scheduled"],
            ["id": "odd", "at": NSNull(), "status": "teleported"],
            ["no": "id"],
        ]])
        #expect(list.map { $0.id } == ["soon", "late", "odd"], "the server's order, upcoming first")
        #expect(list[0].isUpcoming && !list[0].canCancel, "ringing now: still to come, too late to call off")
        #expect(list[1].isUpcoming && list[1].canCancel)
        #expect(list[2].status == .unknown("teleported"), "an unknown status passes through")
        #expect(!list[2].isUpcoming && !list[2].canCancel)
    }

    @Test func aReasonIsTrimmedAndKeptShort() {
        #expect(Scheduling.clippedReason("  ") == nil)
        #expect(Scheduling.clippedReason(nil) == nil)
        #expect(Scheduling.clippedReason(String(repeating: "a", count: 200))?.count == 120)
    }
}

@Suite @MainActor struct SchedulingInstanceTests {
    private let booking: [String: Any] = ["calls": ["hosted": true, "scheduling": ["usersCanBook": true, "minLeadMinutes": 5, "maxDaysAhead": 14]]]

    /// A whole second, a day from now: inside every default rule, and exact on the wire.
    private func tomorrow() -> Date {
        Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 86_400).rounded())
    }

    @Test func bookingSendsWhoWhenAndWhy() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session(booking)
        rig.graine.identify(["user_id": "P-1"])
        let at = tomorrow()
        rig.network.replies["/api/embed/calls/schedule"] = (201, #"{"call":{"id":"s1","at":"\#(Scheduling.isoTime(at))","status":"scheduled","source":"sdk","reason":"Help me finish KYC"}}"#)
        let call = try await rig.graine.scheduleCall(at: at, reason: "Help me finish KYC")
        #expect(call == GraineScheduledCall(id: "s1", at: at, status: .scheduled, source: .app, reason: "Help me finish KYC"))
        let body = try #require(rig.network.bodies("/api/embed/calls/schedule").first)
        #expect(body["publishableKey"] as? String == "pk_test_rig")
        #expect(body["installId"] as? String == "3f2504e0-4f89-11d3-9a0c-0305e82c3301")
        #expect((body["identity"] as? [String: Any])?["value"] as? String == "P-1")
        #expect(body["at"] as? String == Scheduling.isoTime(at))
        #expect(body["reason"] as? String == "Help me finish KYC")
        #expect(body["timezone"] as? String == TimeZone.current.identifier)
    }

    @Test func aTimeOutsideTheRulesIsRefusedHereBeforeAnythingIsSent() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session(booking)
        for (at, expected) in [(Date().addingTimeInterval(60), GraineErrorCode.tooSoon), (Date().addingTimeInterval(15 * 86_400), .tooFar)] {
            do {
                _ = try await rig.graine.scheduleCall(at: at)
                Issue.record("expected \(expected)")
            } catch let error as GraineServiceError {
                #expect(error.code == expected)
                #expect(error.status == 0)
            }
        }
        #expect(rig.network.bodies("/api/embed/calls/schedule").isEmpty)
    }

    @Test func anAgentThatTakesNoBookingsIsToldSoWithoutAsking() async throws {
        for session in [["calls": ["hosted": true, "scheduling": ["usersCanBook": false]]], [String: Any]()] {
            let rig = PlatformRig()
            defer { rig.sandbox.clean() }
            rig.session(session)
            do {
                _ = try await rig.graine.scheduleCall(at: tomorrow())
                Issue.record("expected a refusal")
            } catch let error as GraineServiceError {
                #expect(error.code == .schedulingOff, "a session that says nothing lets nobody book")
            }
            #expect(rig.network.bodies("/api/embed/calls/schedule").isEmpty)
        }
    }

    @Test func aRefusalCarriesTheServersCode() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session(booking)
        rig.network.replies["/api/embed/calls/schedule"] = (422, #"{"error":"That is outside the agent's calling hours.","code":"outside_window"}"#)
        do {
            _ = try await rig.graine.scheduleCall(at: tomorrow())
            Issue.record("expected a refusal")
        } catch let error as GraineServiceError {
            #expect(error.code == .outsideWindow)
            #expect(error.message == "That is outside the agent's calling hours.")
            #expect(error.status == 422)
        }
    }

    @Test func tooManyRequestsSaysHowLongToWait() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session(booking)
        rig.network.replies["/api/embed/calls/schedule"] = (429, #"{"error":"Too many bookings. Try again in a minute.","code":"rate_limited"}"#)
        rig.network.headers["/api/embed/calls/schedule"] = ["retry-after": "60"]
        do {
            _ = try await rig.graine.scheduleCall(at: tomorrow())
            Issue.record("expected a refusal")
        } catch let error as GraineServiceError {
            #expect(error.code == .rateLimited)
            #expect(error.retryAfterSeconds == 60)
        }
    }

    @Test func listingAndCancellingAreThisCustomersOwn() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session()
        rig.network.replies["/api/embed/calls/list"] = (200, #"{"calls":[{"id":"s1","at":"2026-10-14T12:00:00Z","status":"scheduled","source":"agent","reason":null}]}"#)
        let listed = try await rig.graine.scheduledCalls()
        #expect(listed.map { $0.id } == ["s1"])
        #expect(listed.first?.source == .agent)
        let list = try #require(rig.network.bodies("/api/embed/calls/list").first)
        #expect(list["identity"] == nil, "nobody identified: this install's calls")
        #expect(list["installId"] as? String == "3f2504e0-4f89-11d3-9a0c-0305e82c3301")
        rig.network.replies["/api/embed/calls/cancel"] = (200, #"{"ok":true,"status":"cancelled"}"#)
        #expect(try await rig.graine.cancelScheduledCall(id: "s1") == .cancelled)
        let cancel = try #require(rig.network.bodies("/api/embed/calls/cancel").first)
        #expect(cancel["callId"] as? String == "s1")
        #expect(cancel["identity"] == nil)
        rig.network.replies["/api/embed/calls/cancel"] = (200, #"{"ok":true}"#)
        rig.graine.identify(["user_id": "P-1"])
        #expect(try await rig.graine.cancelScheduledCall(id: "s2") == .cancelled, "no status in the answer: cancelled")
        let mine = try #require(rig.network.bodies("/api/embed/calls/cancel").last)
        #expect((mine["identity"] as? [String: Any])?["value"] as? String == "P-1", "cancel carries who is asking")
        _ = try await rig.graine.scheduledCalls()
        let listedMine = try #require(rig.network.bodies("/api/embed/calls/list").last)
        #expect((listedMine["identity"] as? [String: Any])?["value"] as? String == "P-1")
        rig.network.replies["/api/embed/calls/cancel"] = (404, #"{"error":"No such call.","code":"not_found"}"#)
        await #expect(throws: GraineServiceError(code: .notFound, message: "No such call.", status: 404)) {
            try await rig.graine.cancelScheduledCall(id: "nope")
        }
    }

    @Test func theRulesComeFromTheSessionWithDefaults() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        #expect(rig.graine.schedulingRules == GraineSchedulingRules(), "before any session: no booking, the defaults")
        rig.session(["calls": ["hosted": true, "platforms": ["ios", "android", "web"], "ringTimeoutSeconds": 30, "callName": "Acme",
                               "scheduling": ["usersCanBook": true, "minLeadMinutes": 10, "maxDaysAhead": 7, "maxPendingPerUser": 2]]])
        let rules = rig.graine.schedulingRules
        #expect(rules == GraineSchedulingRules(usersCanBook: true, minLeadMinutes: 10, maxDaysAhead: 7, maxPendingPerUser: 2,
                                               ringTimeoutSeconds: 30, callName: "Acme", hostedRinging: true, platforms: [.ios, .android]))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(rules.earliest(now: now) == now.addingTimeInterval(600))
        #expect(rules.latest(now: now) == now.addingTimeInterval(7 * 86_400))
        let partial = GraineSchedulingRules.from(GraineHostedCallsSettings.parse(["hosted": true]))
        #expect(partial == GraineSchedulingRules(hostedRinging: true), "calls without scheduling: the defaults, no booking")
    }
}

@Suite struct ScheduledCallWordTests {
    @Test func statusesAndSourcesReadTheWireAndKeepUnknownWords() {
        let statuses = ["scheduled", "ringing", "answered", "completed", "declined", "missed", "failed", "cancelled", "expired", "no_device"]
        for word in statuses {
            #expect(GraineCallStatus(wire: word).wire == word)
            #expect(GraineCallStatus(wire: word) != .unknown(word))
        }
        #expect(GraineCallStatus(wire: "no_device") == .noDevice)
        #expect(GraineCallStatus(wire: " Ringing ") == .ringing)
        #expect(GraineCallStatus(wire: "paused") == .unknown("paused"))
        #expect(GraineCallSource(wire: "sdk") == .app && GraineCallSource.app.wire == "sdk")
        #expect(GraineCallSource(wire: "dashboard") == .dashboard)
        #expect(GraineCallSource(wire: "campaign") == .unknown("campaign"))
        #expect(GraineErrorCode(wire: "too_many_pending") == .tooManyPending && GraineErrorCode.tooManyPending.wire == "too_many_pending")
        #expect(GraineErrorCode(wire: "brand_new") == .unknown("brand_new"))
    }
}

@Suite struct EmbedRequestTests {
    @Test func aRefusalWithoutABodyStillHasACode() {
        #expect(GraineServiceError.from(status: 0, body: nil).code == .network)
        #expect(GraineServiceError.from(status: 401, body: nil).code == .invalidKey)
        #expect(GraineServiceError.from(status: 403, body: nil).code == .originRefused)
        #expect(GraineServiceError.from(status: 429, body: nil).code == .rateLimited)
        #expect(GraineServiceError.from(status: 400, body: nil).code == .invalidRequest)
        #expect(GraineServiceError.from(status: 503, body: nil).code == .unavailable)
        #expect(GraineServiceError.from(status: 400, body: ["error": "at is required", "code": "invalid_request"]).message == "at is required")
        #expect(GraineServiceError.from(status: 500, body: ["error": "boom"]) == GraineServiceError(code: .unknown("http_500"), message: "boom", status: 500))
    }

    @Test func retryAfterIsSecondsOrADate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(GraineServiceError.from(status: 429, body: nil, headers: ["retry-after": "30"], now: now).retryAfterSeconds == 30)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let date = formatter.string(from: now.addingTimeInterval(90))
        #expect(GraineServiceError.from(status: 429, body: nil, headers: ["retry-after": date], now: now).retryAfterSeconds == 90)
        #expect(GraineServiceError.from(status: 429, body: ["retryAfterSeconds": 12], now: now).retryAfterSeconds == 12)
        #expect(GraineServiceError.from(status: 429, body: nil, now: now).retryAfterSeconds == nil)
    }

    @Test func everyBodyLeadsWithTheKey() {
        let requests = EmbedRequests(baseUrl: "https://www.graine.ai/", publishableKey: "pk_1", network: RoutedNetwork())
        #expect(String(decoding: requests.body([("installId", .string("i"))]), as: UTF8.self) == #"{"publishableKey":"pk_1","installId":"i"}"#)
    }
}

@Suite struct CallTicketIdentityTests {
    @Test func aCallsTicketCarriesItsIdAndWhoTheCustomerIs() throws {
        let rig = EngineRig()
        rig.identity = IdentityWire.Fields(value: "P-1", installId: "i-1", memory: true, timezone: "Asia/Kolkata", callId: "call_42")
        rig.engine.start()
        let post = try #require(rig.network.posts.first)
        let body = try #require(JSON.object(from: post.body))
        #expect(body["mode"] as? String == "voice")
        #expect(body["callId"] as? String == "call_42")
        #expect((body["identity"] as? [String: Any])?["value"] as? String == "P-1")
        #expect(body["installId"] as? String == "i-1")
        #expect(body["memory"] as? Bool == true)
        #expect(body["timezone"] as? String == "Asia/Kolkata")
        let socket = try #require(rig.network.socket)
        #expect(!socket.url.absoluteString.contains("P-1"))
    }
}
