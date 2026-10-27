import Foundation
import Testing
@testable import GraineInApp

/*
 * WORKFLOWS THE APP STARTS — `GraineInApp.startWorkflow` (PUBLIC-STATE.md §7),
 * on fakes: the run is the identified user's (nobody identified, nothing is
 * asked); who the run is for never leaves the device in `data`; what could
 * never be kept is left out; every call carries an idempotency key, and a
 * request that got no answer is asked once more with the SAME key; Graine's
 * refusals arrive as their codes.
 */
/// The agent's session, held (a slow network) until the test answers it.
private final class HeldSession {
    private(set) var asked = 0
    private var waiting: [(Result<GraineSessionConfig, Error>) -> Void] = []

    func install(on graine: GraineInApp) {
        graine.sessionFetch = { [unowned self] done in
            self.asked += 1
            self.waiting.append(done)
        }
    }

    func answer(field: String) {
        let session = GraineSessionConfig.parse(["agentId": "agent-1", "webcallAgentId": "web-1", "identity": ["field": field]])
        let pending = waiting
        waiting = []
        pending.forEach { $0(.success(session)) }
    }
}

@Suite @MainActor struct WorkflowTests {
    private let route = "/api/embed/workflows/start"
    private let run = #"{"runId":"oex_2c9e8f1a7b3d4c5e6f7a8b9c","workflowId":"owf_8a1d4e7c2b90f1a2b3c4d5e6","alreadyRunning":false}"#

    private func refusal(_ work: () async throws -> GraineWorkflowRun) async -> GraineServiceError? {
        do {
            _ = try await work()
            Issue.record("expected a refusal")
            return nil
        } catch let error as GraineServiceError {
            return error
        } catch {
            Issue.record("not a GraineServiceError: \(error)")
            return nil
        }
    }

    @Test func theRunIsStartedForTheIdentifiedUserAndAnswered() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session(["identity": ["field": "user_id"]])
        rig.graine.identify(["user_id": "P-1234", "name": "Asha"])
        rig.network.replies[route] = (201, run)
        let started = try await rig.graine.startWorkflow("  Welcome call ", data: ["plan": "gold", "seats": 3, "trial": true])
        #expect(started == GraineWorkflowRun(runId: "oex_2c9e8f1a7b3d4c5e6f7a8b9c", workflowId: "owf_8a1d4e7c2b90f1a2b3c4d5e6", alreadyRunning: false))
        let body = try #require(rig.network.bodies(route).first)
        #expect(body["publishableKey"] as? String == "pk_test_rig")
        #expect(body["installId"] as? String == "3f2504e0-4f89-11d3-9a0c-0305e82c3301")
        #expect((body["identity"] as? [String: Any])?["value"] as? String == "P-1234")
        #expect(body["workflow"] as? String == "Welcome call", "trimmed")
        let data = try #require(body["data"] as? [String: Any])
        #expect(data.count == 3)
        #expect(data["plan"] as? String == "gold")
        #expect((data["seats"] as? NSNumber)?.intValue == 3)
        #expect(data["trial"] as? Bool == true)
        let key = try #require(body["idempotencyKey"] as? String)
        #expect(Workflows.isIdempotencyKey(key), "every call carries a key")
    }

    @Test func aRunAskedForOneCustomerIsNeverStartedForTheNextOne() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        let held = HeldSession()
        held.install(on: rig.graine)
        rig.graine.identify(["user_id": "A-1"])
        rig.network.replies[route] = (201, run)
        let started = Task { try await rig.graine.startWorkflow("Welcome call", data: ["plan": "gold"]) }
        for _ in 0..<200 where held.asked == 0 { try? await Task.sleep(nanoseconds: 5_000_000) }
        // A signs out and B signs in on the same phone while the agent's settings are still on their way.
        rig.graine.identify(nil)
        rig.graine.identify(["user_id": "B-2"])
        held.answer(field: "user_id")
        let refused = await refusal { try await started.value }
        #expect(refused?.code == .identityRequired)
        #expect(refused?.message.hasPrefix("Someone else was identified while the agent's settings were loading") == true)
        #expect(rig.network.bodies(route).isEmpty, "no run is started for B, who never asked")
    }

    @Test func nobodyIdentifiedIsRefusedOnTheDeviceNamingTheTrait() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session(["identity": ["field": "patient_id"]])
        let nobody = await refusal { try await rig.graine.startWorkflow("Welcome call") }
        #expect(nobody?.code == .identityRequired)
        #expect(nobody?.message.contains("patient_id") == true)
        rig.graine.identify(["user_id": "P-1"])
        #expect(await refusal { try await rig.graine.startWorkflow("Welcome call") }?.code == .identityRequired, "another trait is nobody for this agent")
        #expect(rig.network.bodies(route).isEmpty, "nothing was asked")
    }

    @Test func aForgedIdNeverLeavesTheDeviceAndWhatCouldNeverBeKeptIsLeftOut() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session(["identity": ["field": "user_id"]])
        rig.graine.identify(["user_id": "P-1234"])
        rig.network.replies[route] = (201, run)
        let optional: String? = nil
        _ = try await rig.graine.startWorkflow("Welcome call", data: [
            "user_id": "someone-else", "user_field": "email", "reference_id": "ref-forged", "graine_user_key": "u1_x", "GRAINE_CALL_ID": "c",
            "mobile_number": "+15550000002", "email": "x@evil.example", "fields": "x",
            "plan": "gold", "long": String(repeating: "x", count: 201), "emoji": String(repeating: "🙂", count: 200),
            "list": [1, 2], "nested": ["a": 1], "nothing": NSNull(), "absent": optional as Any, "nan": Double.nan, "bad name": "x",
        ])
        let body = try #require(rig.network.bodies(route).first)
        #expect((body["identity"] as? [String: Any])?["value"] as? String == "P-1234", "the identity, untouched by data")
        let data = try #require(body["data"] as? [String: Any])
        #expect(Set(data.keys) == ["plan", "emoji"], "an emoji is one character, as Graine counts")
    }

    @Test func atMostTwelveFieldsGoTheFirstTwelveByName() {
        var many: [String: Any] = ["list": [1]]
        for i in 0..<15 { many[String(format: "f%02d", i)] = i }
        #expect(Workflows.fields(many).map { $0.0 } == (0..<12).map { String(format: "f%02d", $0) })
        #expect(Workflows.fields([:]).isEmpty)
    }

    @Test func aWorkflowNameIsNeededAndAKeyMustBeOneBeforeAnythingIsAsked() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session(["identity": ["field": "user_id"]])
        rig.graine.identify(["user_id": "P-1234"])
        for bad in ["", "   ", String(repeating: "w", count: 121)] {
            #expect(await refusal { try await rig.graine.startWorkflow(bad) }?.code == .invalidRequest, "\(bad.count)")
        }
        for bad in ["short", "has a space", String(repeating: "k", count: 129)] {
            #expect(await refusal { try await rig.graine.startWorkflow("Welcome call", idempotencyKey: bad) }?.code == .invalidRequest, "\(bad)")
        }
        #expect(rig.network.bodies(route).isEmpty)
        #expect(Workflows.name(String(repeating: "w", count: 120)) != nil)
    }

    @Test func noAnswerIsAskedOnceMoreWithTheSameKeyAndARefusalNever() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session(["identity": ["field": "user_id"]])
        rig.graine.identify(["user_id": "P-1234"])
        // The first ask gets no answer (status 0); the next is answered.
        rig.network.replies[route] = (0, nil)
        rig.network.beforeAnswer[route] = { [network = rig.network, run] in network.replies["/api/embed/workflows/start"] = (200, run) }
        let started = try await rig.graine.startWorkflow("Welcome call")
        #expect(started.runId == "oex_2c9e8f1a7b3d4c5e6f7a8b9c")
        let keys = rig.network.bodies(route).map { $0["idempotencyKey"] as? String }
        #expect(keys.count == 2)
        #expect(keys[0] != nil && keys[0] == keys[1], "the same key: Graine answers the start it made")

        let twice = PlatformRig()
        defer { twice.sandbox.clean() }
        twice.session(["identity": ["field": "user_id"]])
        twice.graine.identify(["user_id": "P-1234"])
        twice.network.replies[route] = (0, nil)
        #expect(await refusal { try await twice.graine.startWorkflow("Welcome call", idempotencyKey: "order-1042:welcome") }?.code == .network)
        #expect(twice.network.bodies(route).map { $0["idempotencyKey"] as? String } == ["order-1042:welcome", "order-1042:welcome"], "once more, and no more")

        let refused = PlatformRig()
        defer { refused.sandbox.clean() }
        refused.session(["identity": ["field": "user_id"]])
        refused.graine.identify(["user_id": "P-1234"])
        refused.network.replies[route] = (503, #"{"error":"This workspace can't start workflows right now.","code":"unavailable"}"#)
        #expect(await refusal { try await refused.graine.startWorkflow("Welcome call") }?.code == .unavailable)
        #expect(refused.network.bodies(route).count == 1, "Graine answered: not asked again")
    }

    @Test func grainesRefusalsArriveAsTheirCodes() async throws {
        let cases: [(Int, String, GraineErrorCode)] = [
            (403, "not_allowed", .notAllowed), (403, "not_verified", .notVerified), (400, "identity_required", .identityRequired),
            (400, "invalid_request", .invalidRequest), (503, "unavailable", .unavailable),
        ]
        for (status, word, code) in cases {
            let rig = PlatformRig()
            defer { rig.sandbox.clean() }
            rig.session(["identity": ["field": "user_id"]])
            rig.graine.identify(["user_id": "P-1234"])
            rig.network.replies[route] = (status, #"{"error":"said \#(word)","code":"\#(word)"}"#)
            let error = await refusal { try await rig.graine.startWorkflow("Welcome call") }
            #expect(error?.code == code)
            #expect(error?.message == "said \(word)")
            #expect(error?.status == status)
        }
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session(["identity": ["field": "user_id"]])
        rig.graine.identify(["user_id": "P-1234"])
        rig.network.replies[route] = (429, #"{"error":"Too many workflows started from this device in the last hour.","code":"rate_limited"}"#)
        rig.network.headers[route] = ["retry-after": "600"]
        let limited = await refusal { try await rig.graine.startWorkflow("Welcome call") }
        #expect(limited?.code == .rateLimited)
        #expect(limited?.retryAfterSeconds == 600)
        #expect(GraineErrorCode(wire: "not_allowed").wire == "not_allowed")
        #expect(GraineErrorCode(wire: "not_verified") == .notVerified)
    }

    @Test func theRunIsReadFromTheAnswer() {
        #expect(Workflows.run(["run_id": "oex_1", "workflow_id": "owf_1", "already_running": true]) == GraineWorkflowRun(runId: "oex_1", workflowId: "owf_1", alreadyRunning: true))
        #expect(Workflows.run(["runId": "oex_1"]) == GraineWorkflowRun(runId: "oex_1", workflowId: nil, alreadyRunning: false))
        #expect(Workflows.run(["workflowId": "owf_1"]) == nil)
    }
}
