import Foundation
import Testing
@testable import GraineInApp

/*
 * Who the customer is, for memory (contract §1): which values are an identity
 * (the shared vectors, contract/identity-vectors.json), the install id, the
 * memory choice, the sign-outs, and what reaches the wire — the raw value on
 * the identity channel only, never in the variables or the context.
 */

@Suite struct IdentityVectorTests {
    private func vectors() throws -> [String: Any] {
        try ContractFile.load("identity-vectors.json")
    }

    @Test func everyFieldNormalisesAsTheServerDoes() throws {
        let cases = try #require(try vectors()["user_keys"] as? [[String: Any]])
        #expect(cases.count >= 25)
        for c in cases {
            let expected = c["normalised_field"] as? String
            #expect(IdentityRules.normaliseField(c["field"]) == expected, "field \(String(describing: c["field"]))")
        }
    }

    @Test func aValueIsAnIdentityExactlyWhenTheServerWouldKeyIt() throws {
        let cases = try #require(try vectors()["user_keys"] as? [[String: Any]])
        for c in cases {
            guard let field = c["normalised_field"] as? String else { continue }
            let value: Any? = c["value"] is NSNull ? nil : c["value"]
            let expected = c["normalised_value"] as? String
            #expect(IdentityRules.normalisedValue(field: field, value: value) == expected,
                    "\(field) = \(String(describing: c["value"]))")
            // What is sent is the value as given; it is sent only when it is an identity at all.
            let sent = IdentityRules.value(in: [field: value], field: field)
            #expect((sent != nil) == (expected != nil), "\(field) = \(String(describing: c["value"]))")
        }
    }

    @Test func installIdsTheServerAcceptsAreTheOnesThisSdkWouldKeep() throws {
        let cases = try #require(try vectors()["install_refs"] as? [[String: Any]])
        for c in cases {
            let raw = (c["install_id"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased()
            let accepted = !(c["install_ref"] is NSNull) && c["install_ref"] != nil
            #expect(InstallId.isValid(raw) == accepted, "install id \(String(describing: c["install_id"]))")
        }
    }
}

@Suite struct IdentityRuleTests {
    @Test func theRawTextIsAStringAsGivenOrAWholeNumber() {
        #expect(IdentityRules.rawText("  P-1234 ") == "  P-1234 ")
        #expect(IdentityRules.rawText(4242) == "4242")
        #expect(IdentityRules.rawText(NSNumber(value: 4242.0)) == "4242", "a bridge's whole double is a whole number")
        #expect(IdentityRules.rawText(4242.5) == nil, "a fraction is no identity")
        #expect(IdentityRules.rawText(true) == nil)
        #expect(IdentityRules.rawText(NSNull()) == nil)
        #expect(IdentityRules.rawText(["a": 1]) == nil)
        #expect(IdentityRules.rawText(nil) == nil)
    }

    @Test func theConfiguredTraitIsReadAndAPlaceholderIsNobody() {
        let traits: [String: Any?] = ["name": "Asha", "user_id": "P-1234", "email": "[EMAIL]", "patient_id": "guest"]
        #expect(IdentityRules.value(in: traits, field: "user_id") == "P-1234")
        #expect(IdentityRules.value(in: traits, field: "email") == nil, "a masked value names nobody")
        #expect(IdentityRules.value(in: traits, field: "patient_id") == nil)
        #expect(IdentityRules.value(in: traits, field: "phone") == nil, "absent")
        #expect(IdentityRules.value(in: ["User_ID": "x-1"], field: "user_id") == "x-1", "the same name in another case")
        #expect(IdentityRules.value(in: nil, field: "user_id") == nil)
    }

    @Test func theSettingIsReadLeniently() {
        #expect(GraineIdentitySettings.parse(["field": " Email ", "devicesPerUser": 3]) == GraineIdentitySettings(field: "email", devicesPerUser: 3))
        #expect(GraineIdentitySettings.parse(["field": "bad field!"])?.field == "user_id")
        #expect(GraineIdentitySettings.parse(["devicesPerUser": 9])?.devicesPerUser == 5)
        #expect(GraineIdentitySettings.parse(["devicesPerUser": 0])?.devicesPerUser == 1)
        #expect(GraineIdentitySettings.parse("user_id") == nil)
        #expect(GraineIdentitySettings.parse(nil) == nil)
    }

    @Test func theIdentityFieldsGoInOrderAndOnlyWhenTheyHaveSomethingToSay() {
        let full = IdentityWire.Fields(value: "P-1", installId: "i-1", memory: false, timezone: "Asia/Kolkata", callId: "call_1")
        #expect(WireJSON.object(IdentityWire.pairs(full)).text ==
                #"{"identity":{"value":"P-1"},"installId":"i-1","memory":false,"timezone":"Asia/Kolkata","callId":"call_1"}"#)
        let anonymous = IdentityWire.Fields(value: nil, installId: "i-1", memory: true, timezone: "UTC", callId: nil)
        #expect(WireJSON.object(IdentityWire.pairs(anonymous)).text == #"{"installId":"i-1","memory":true,"timezone":"UTC"}"#)
    }
}

@Suite struct InstallIdTests {
    @Test func aKeptIdIsUsedAsItIs() {
        let store = MemoryInstallIdStore("3F2504E0-4F89-11D3-9A0C-0305E82C3301")
        let resolved = InstallId.resolve(store)
        #expect(resolved.id == "3f2504e0-4f89-11d3-9a0c-0305e82c3301")
        #expect(resolved.kept)
        #expect(store.writes == 0)
    }

    @Test func aFirstLaunchMakesAndKeepsALowerCaseUuid() throws {
        let store = MemoryInstallIdStore()
        let resolved = InstallId.resolve(store)
        #expect(resolved.kept)
        #expect(InstallId.isValid(resolved.id))
        #expect(resolved.id == resolved.id.lowercased())
        #expect(UUID(uuidString: resolved.id) != nil)
        #expect(store.value == resolved.id)
        #expect(InstallId.resolve(store).id == resolved.id, "the second launch reads the first one's")
    }

    @Test func aKeychainThatWillNotKeepItStillGivesThisLaunchAnId() {
        let store = MemoryInstallIdStore()
        store.failWrites = true
        let resolved = InstallId.resolve(store)
        #expect(!resolved.kept)
        #expect(InstallId.isValid(resolved.id))
    }

    @Test func aDamagedKeptIdIsReplaced() {
        let store = MemoryInstallIdStore("not an id")
        let resolved = InstallId.resolve(store)
        #expect(resolved.id != "not an id")
        #expect(store.value == resolved.id)
    }
}

@Suite struct MemoryChoiceTests {
    @Test func aChoiceIsKeptPerCustomerAndNeverUnderTheirIdentifier() throws {
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        let choices = MemoryChoices(defaults: sandbox.defaults)
        #expect(choices.choice(field: "email", value: "asha@example.com") == nil)
        choices.remember(false, field: "email", value: "Asha@Example.com ")
        #expect(choices.choice(field: "email", value: "asha@example.com") == false, "the same customer, however it was typed")
        #expect(choices.choice(field: "email", value: "ravi@example.com") == nil)
        let stored = try #require(sandbox.defaults.dictionary(forKey: MemoryChoices.key))
        let text = String(describing: stored)
        #expect(!text.contains("asha"), "the identifier is never written to disk")
    }

    @Test func theOldestChoicesGoFirst() {
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        let choices = MemoryChoices(defaults: sandbox.defaults)
        for i in 0..<(MemoryChoices.cap + 5) {
            choices.remember(false, field: "user_id", value: "u\(i)", now: Date(timeIntervalSince1970: Double(1_000 + i)))
        }
        #expect(sandbox.defaults.dictionary(forKey: MemoryChoices.key)?.count == MemoryChoices.cap)
        #expect(choices.choice(field: "user_id", value: "u0") == nil)
        #expect(choices.choice(field: "user_id", value: "u\(MemoryChoices.cap + 4)") == false)
    }
}

@Suite struct IdentityStateTests {
    private func state(_ sandbox: Sandbox) -> IdentityState {
        IdentityState(choices: MemoryChoices(defaults: sandbox.defaults))
    }

    @Test func theValueWaitsForTheSessionToNameTheField() {
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        let s = state(sandbox)
        s.identify(["name": "Asha", "email": "asha@example.com", "user_id": "P-1"], memory: nil)
        #expect(s.snapshot().value == nil, "no field yet: a ticket is never minted before the session anyway")
        s.setField("email")
        #expect(s.snapshot() == .init(value: "asha@example.com", memory: true))
    }

    @Test func aCustomerWhoStopsBeingTheCustomerIsSignedOutOnce() {
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        let s = state(sandbox)
        s.setField("user_id")
        s.identify(["user_id": "A"], memory: nil)
        s.identify(["user_id": "A", "plan": "Gold"], memory: nil)
        #expect(s.takeSignOuts().isEmpty, "the same customer again is not a sign-out")
        s.identify(["user_id": "B"], memory: nil)
        #expect(s.takeSignOuts() == ["A"])
        s.identify(nil, memory: nil)
        #expect(s.takeSignOuts() == ["B"])
        #expect(s.takeSignOuts().isEmpty)
        #expect(s.snapshot().value == nil)
    }

    @Test func aCustomerBackBeforeTheirSignOutLeftIsNotSignedOut() {
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        let s = state(sandbox)
        s.setField("user_id")
        s.identify(["user_id": "A"], memory: nil)
        s.identify(nil, memory: nil)
        s.identify(["user_id": "A"], memory: nil)
        #expect(s.takeSignOuts().isEmpty)
    }

    @Test func theMemoryChoiceIsKeptForTheCustomerAndOnlyForThem() {
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        let s = state(sandbox)
        s.setField("user_id")
        s.identify(["user_id": "A"], memory: false)
        #expect(s.snapshot().memory == false)
        s.identify(["user_id": "B"], memory: nil)
        #expect(s.snapshot().memory == true, "another customer has their own choice")
        s.identify(["user_id": "A"], memory: nil)
        #expect(s.snapshot().memory == false, "kept for A: the app need not repeat it")
        s.setMemory(true)
        let next = state(sandbox)
        next.setField("user_id")
        next.identify(["user_id": "A"], memory: nil)
        #expect(next.snapshot().memory == true, "and it survives the launch")
    }

    @Test func aChoiceMadeBeforeTheSessionIsFiledWhenItArrives() {
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        let s = state(sandbox)
        s.identify(["user_id": "A"], memory: false)
        s.setField("user_id")
        #expect(s.snapshot() == .init(value: "A", memory: false))
        let next = state(sandbox)
        next.setField("user_id")
        next.identify(["user_id": "A"], memory: nil)
        #expect(next.snapshot().memory == false)
    }
}

/// The instance: what the variables, the context and the requests carry.
@Suite @MainActor struct IdentityInstanceTests {
    @Test func theIdentifierNeverEntersTheVariablesOrTheContext() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session(["identity": ["field": "user_id"]])
        rig.graine.identify(["user_id": "P-1234", "name": "Asha", "email": "asha@example.com"])
        let vars = rig.graine.currentVariables()
        #expect(vars["user_id"] == nil)
        #expect(vars["name"] == "Asha")
        #expect(vars["email"] == "[EMAIL]")
        let frame = try #require(rig.graine.currentContextFrame())
        let text = try #require(JSON.string(from: frame))
        #expect(!text.contains("P-1234"))
        #expect(rig.graine.identityFields(callId: nil).value == "P-1234", "it goes on the identity channel")
    }

    @Test func anEmailFieldTravelsRawOnlyOnTheIdentityChannel() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session(["identity": ["field": "email"]])
        rig.graine.identify(["email": "Asha@Example.com", "name": "Asha"], memory: false)
        let f = rig.graine.identityFields(callId: "call_9")
        #expect(f == IdentityWire.Fields(value: "Asha@Example.com", installId: "3f2504e0-4f89-11d3-9a0c-0305e82c3301",
                                         memory: false, timezone: TimeZone.current.identifier, callId: "call_9"))
        #expect(rig.graine.currentVariables()["email"] == nil)
        #expect(rig.graine.memoryChoice == false)
    }

    @Test func signingOutTellsGraineAboutTheCustomerWhoLeft() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session()
        rig.graine.identify(["user_id": "P-1"])
        #expect(rig.network.bodies("/api/embed/identity/signout").isEmpty)
        rig.graine.identify(nil)
        let body = try #require(rig.network.bodies("/api/embed/identity/signout").first)
        #expect(body["publishableKey"] as? String == "pk_test_rig")
        #expect(body["installId"] as? String == "3f2504e0-4f89-11d3-9a0c-0305e82c3301")
        #expect((body["identity"] as? [String: Any])?["value"] as? String == "P-1")
        rig.graine.identify(nil)
        #expect(rig.network.bodies("/api/embed/identity/signout").count == 1, "once")
    }

    @Test func aSignOutBeforeTheSessionWaitsForIt() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.graine.identify(["user_id": "P-1"])
        rig.session()
        rig.graine.identify(["user_id": "P-2"])
        #expect(rig.network.bodies("/api/embed/identity/signout").count == 1)
    }

    @Test func forgettingNeedsSomeoneToForget() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session()
        await #expect(throws: GraineServiceError.self) { try await rig.graine.forgetMemory() }
        do {
            try await rig.graine.forgetMemory()
        } catch let error as GraineServiceError {
            #expect(error.code == .identityRequired)
        }
        rig.graine.identify(["user_id": "P-1"])
        rig.network.replies["/api/embed/memory/forget"] = (200, #"{"deleted":3}"#)
        #expect(try await rig.graine.forgetMemory() == 3, "how many were deleted")
        let body = try #require(rig.network.bodies("/api/embed/memory/forget").first)
        #expect((body["identity"] as? [String: Any])?["value"] as? String == "P-1")
        #expect(body["installId"] as? String == "3f2504e0-4f89-11d3-9a0c-0305e82c3301")
    }

    @Test func aRefusedForgetSaysWhy() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session()
        rig.graine.identify(["user_id": "P-1"])
        rig.network.replies["/api/embed/memory/forget"] = (403, #"{"error":"This device is not bound to that user.","code":"device_limit"}"#)
        do {
            try await rig.graine.forgetMemory()
            Issue.record("expected a refusal")
        } catch let error as GraineServiceError {
            #expect(error.code == .deviceLimit)
            #expect(error.status == 403)
            #expect(error.message == "This device is not bound to that user.")
        }
    }

    @Test func whatTheAgentRemembersIsListedForTheCustomerOnly() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session()
        do {
            _ = try await rig.graine.memories()
            Issue.record("expected identity_required")
        } catch let error as GraineServiceError {
            #expect(error.code == .identityRequired)
        }
        #expect(rig.network.bodies("/api/embed/memory/list").isEmpty, "nobody to ask about: no request")
        rig.graine.identify(["user_id": "P-1"])
        rig.network.replies["/api/embed/memory/list"] = (200, #"{"memories":[{"id":"m2","text":"Prefers Hindi","createdAt":"2026-10-13T09:00:00Z","updatedAt":null},{"id":"m1","text":"Has a Gold card","created_at":"2026-10-01T09:00:00.500Z"},{"id":"","text":"no id"},{"id":"m0"}]}"#)
        let memories = try await rig.graine.memories()
        #expect(memories.map { $0.id } == ["m2", "m1"], "the server's order; unusable entries skipped")
        #expect(memories[0] == GraineMemory(id: "m2", text: "Prefers Hindi", createdAt: Date(timeIntervalSince1970: 1_791_882_000), updatedAt: nil))
        #expect(memories[1].createdAt == Date(timeIntervalSince1970: 1_790_845_200.5))
        let body = try #require(rig.network.bodies("/api/embed/memory/list").first)
        #expect((body["identity"] as? [String: Any])?["value"] as? String == "P-1")
        #expect(body["installId"] as? String == "3f2504e0-4f89-11d3-9a0c-0305e82c3301")
        rig.network.replies["/api/embed/memory/list"] = (403, #"{"error":"This device is not one of that user's.","code":"device_limit"}"#)
        await #expect(throws: GraineServiceError(code: .deviceLimit, message: "This device is not one of that user's.", status: 403)) {
            _ = try await rig.graine.memories()
        }
    }

    @Test func theInstallIdIsReadOnceAndKept() {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        #expect(rig.graine.installId == "3f2504e0-4f89-11d3-9a0c-0305e82c3301")
        rig.installs.value = "ffffffff-ffff-4fff-8fff-ffffffffffff"
        #expect(rig.graine.installId == "3f2504e0-4f89-11d3-9a0c-0305e82c3301", "one id per launch")
    }
}
