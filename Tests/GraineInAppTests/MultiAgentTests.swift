import Foundation
import Testing
@testable import GraineInApp

/*
 * Several agents in one app (MULTI-AGENT.md): each its own key, session, chat,
 * scheduling and memory routes; one person, one device, one screen and one
 * conversation at a time between them; a hosted ring routed by its agent_id.
 * Every agent here is built on fakes and a registry of the test's own.
 */

/// Two agents — "support" (the default) and "sales" — sharing a registry, a device and its defaults.
@MainActor
private final class AgentPair {
    let registry = GraineAgentRegistry()
    let sandbox = Sandbox()
    let supportNetwork = RoutedNetwork()
    let salesNetwork = RoutedNetwork()
    let support: GraineInApp
    let sales: GraineInApp

    init() {
        let installs = MemoryInstallIdStore("3f2504e0-4f89-11d3-9a0c-0305e82c3301")
        support = GraineInApp(
            config: GraineConfig(baseUrl: "https://www.graine.ai", publishableKey: "pk_test_support"),
            installIds: installs, defaults: sandbox.defaults,
            sessionCache: SessionCache(directory: sandbox.folder, agent: "default"),
            network: supportNetwork, chatScheduler: ManualScheduler(), name: "default", registry: registry
        )
        sales = GraineInApp(
            config: GraineConfig(baseUrl: "https://www.graine.ai", publishableKey: "pk_test_sales"),
            installIds: MemoryInstallIdStore("ffffffff-ffff-4fff-8fff-ffffffffffff"), defaults: sandbox.defaults,
            sessionCache: SessionCache(directory: sandbox.folder, agent: "sales"),
            network: salesNetwork, chatScheduler: ManualScheduler(), name: "sales", registry: registry
        )
        registry.add(support)
        registry.add(sales)
    }

    func sessions(support supportExtra: [String: Any] = [:], sales salesExtra: [String: Any] = [:]) {
        var a: [String: Any] = ["agentId": "agent-support", "webcallAgentId": "web-support"]
        for (k, v) in supportExtra { a[k] = v }
        var b: [String: Any] = ["agentId": "agent-sales", "webcallAgentId": "web-sales"]
        for (k, v) in salesExtra { b[k] = v }
        support.finishSession(.success(GraineSessionConfig.parse(a)))
        sales.finishSession(.success(GraineSessionConfig.parse(b)))
    }

    deinit { sandbox.clean() }
}

@Suite @MainActor struct MultiAgentTests {
    @Test func eachAgentSpeaksWithItsOwnKey() throws {
        let pair = AgentPair()
        pair.sessions()
        pair.support.chat.open()
        pair.sales.chat.open()
        let supportTicket = try #require(pair.supportNetwork.bodies("/api/embed/ticket").first)
        let salesTicket = try #require(pair.salesNetwork.bodies("/api/embed/ticket").first)
        #expect(supportTicket["publishableKey"] as? String == "pk_test_support")
        #expect(salesTicket["publishableKey"] as? String == "pk_test_sales")
        #expect(pair.salesNetwork.socket?.url.absoluteString.contains("pk_test_support") == false)
    }

    @Test func oneAgentsChatNeverShowsInAnothers() throws {
        let pair = AgentPair()
        pair.sessions()
        pair.support.chat.send("my card is blocked")
        #expect(pair.support.chat.turns.map { $0.text } == ["my card is blocked"])
        #expect(pair.sales.chat.turns.isEmpty)
        #expect(pair.salesNetwork.bodies("/api/embed/ticket").isEmpty)
    }

    @Test func oneConversationAtATimeAcrossAgents() throws {
        let pair = AgentPair()
        pair.sessions()
        pair.support.chat.open()
        #expect(pair.support.chat.isOpen)
        pair.sales.chat.open()
        #expect(pair.sales.chat.isOpen)
        #expect(!pair.support.chat.isOpen, "opening one agent's chat closed the other's")
    }

    @Test func identifyingOnOneIdentifiesForAllEachByItsOwnField() throws {
        let pair = AgentPair()
        pair.sessions(support: ["identity": ["field": "user_id"]], sales: ["identity": ["field": "email"]])
        pair.sales.identify(["user_id": "P-1", "email": "asha@example.com", "name": "Asha"], memory: false)
        #expect(pair.support.identityFields(callId: nil).value == "P-1")
        #expect(pair.sales.identityFields(callId: nil).value == "asha@example.com")
        #expect(pair.support.currentVariables()["name"] == "Asha")
        #expect(pair.support.memoryChoice == false && pair.sales.memoryChoice == false, "one memory choice for the person")
        pair.support.setMemory(true)
        #expect(pair.sales.memoryChoice == true)
        // Signing out on one signs out everywhere, each with its own key.
        pair.support.identify(nil)
        #expect(pair.support.identityFields(callId: nil).value == nil && pair.sales.identityFields(callId: nil).value == nil)
        #expect((pair.supportNetwork.bodies("/api/embed/identity/signout").first?["identity"] as? [String: Any])?["value"] as? String == "P-1")
        #expect((pair.salesNetwork.bodies("/api/embed/identity/signout").first?["identity"] as? [String: Any])?["value"] as? String == "asha@example.com")
        #expect(pair.salesNetwork.bodies("/api/embed/identity/signout").first?["publishableKey"] as? String == "pk_test_sales")
    }

    @Test func oneDeviceOneInstallId() {
        let pair = AgentPair()
        #expect(pair.support.installId == pair.sales.installId, "the first agent to ask settles it for all")
    }

    @Test func theScreenIsTheAppsAndEveryAgentHearsIt() throws {
        let pair = AgentPair()
        pair.support.setScreen(GraineScreen(screen: "plans", title: "Plans"))
        let frame = try #require(pair.sales.currentContextFrame())
        #expect((frame["context"] as? [String: Any])?["screen"] as? String == "plans")
        pair.sales.tap("Upgrade")
        let events = try #require((pair.support.currentContextFrame()?["context"] as? [String: Any])?["recent_events"] as? [[String: Any]])
        #expect(events.last?["name"] as? String == "tap:Upgrade")
        pair.sales.clearScreen("plans")
        #expect(!pair.support.hasScreen)
    }

    @Test func anAgentConfiguredLaterTakesOnThePersonAndTheScreen() throws {
        let pair = AgentPair()
        pair.registry.rememberIdentify(["user_id": "P-7"], memory: false)
        pair.registry.rememberScreen(GraineScreen(screen: "home"))
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        let care = GraineInApp(
            config: GraineConfig(baseUrl: "https://www.graine.ai", publishableKey: "pk_test_care"),
            installIds: MemoryInstallIdStore(), defaults: sandbox.defaults, sessionCache: SessionCache(directory: sandbox.folder, agent: "care"),
            network: RoutedNetwork(), chatScheduler: ManualScheduler(), name: "care", registry: pair.registry
        )
        pair.registry.add(care)
        care.adoptShared()
        care.finishSession(.success(GraineSessionConfig.parse(["agentId": "agent-care"])))
        #expect(care.identityFields(callId: nil).value == "P-7")
        #expect(care.memoryChoice == false)
        #expect(care.hasScreen)
    }

    @Test func schedulingAndMemoryGoToTheAgentsOwnRoutes() async throws {
        let pair = AgentPair()
        pair.sessions(sales: ["calls": ["hosted": true, "scheduling": ["usersCanBook": true]]])
        pair.support.identify(["user_id": "P-1"])
        let at = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 86_400).rounded())
        pair.salesNetwork.replies["/api/embed/calls/schedule"] = (201, #"{"call":{"id":"s1","at":"\#(Scheduling.isoTime(at))","status":"scheduled","source":"sdk","reason":null}}"#)
        _ = try await pair.sales.scheduleCall(at: at)
        #expect(pair.salesNetwork.bodies("/api/embed/calls/schedule").first?["publishableKey"] as? String == "pk_test_sales")
        #expect(pair.supportNetwork.bodies("/api/embed/calls/schedule").isEmpty)
        // The support agent does not let customers book: its own rules say so, whatever the sales agent allows.
        await #expect(throws: GraineServiceError.self) { _ = try await pair.support.scheduleCall(at: at) }
        _ = try await pair.sales.memories()
        #expect(pair.salesNetwork.bodies("/api/embed/memory/list").count == 1)
        #expect(pair.supportNetwork.bodies("/api/embed/memory/list").isEmpty)
    }

    @Test func aHostedRingIsRoutedByItsAgentIdAndDrawnInThatAgentsDesign() throws {
        let pair = AgentPair()
        let design: [String: Any] = ["light": ["colors": [
            "background": "#FFFFFF", "surface": "#F7F7F5", "surfaceRaised": "#FFFFFF", "text": "#101318", "textMuted": "#5F6672",
            "border": "#E5E4E0", "accent": "#E91E63", "onAccent": "#FFFFFF", "accentSoft": "#FCE4EC", "success": "#1FAD5B",
            "warning": "#F5A524", "danger": "#E5484D", "userBubble": "#E91E63", "userBubbleText": "#FFFFFF",
            "agentBubble": "#F1F1EF", "agentBubbleText": "#101318", "scrim": "#000000",
        ], "call": ["background": "#3A0F1F", "statusText": ["scheduled": "Sales is calling you back"]]]]
        var dark = design["light"] as! [String: Any]
        dark["call"] = ["background": "#200810"]
        pair.sessions(sales: ["design": ["light": design["light"]!, "dark": dark]])
        let byTwin = try #require(pair.registry.agent(forAgentId: "web-sales"))
        #expect(byTwin === pair.sales)
        #expect(pair.registry.agent(forAgentId: "agent-sales") === pair.sales)
        #expect(pair.registry.agent(forAgentId: "agent-support") === pair.support)
        #expect(pair.registry.agent(forAgentId: "agent-unknown") == nil, "nobody: the calls use the default, and say so")
        #expect(pair.registry.agent(forAgentId: "  ") == nil)
        let tokens = byTwin.sessionOrCached?.design?.tokens(deviceDark: false)
        #expect(CallScreen.tokens(tokens).background == "#3A0F1F")
        #expect(CallScreen.status(.ringing, direction: .incoming, call: CallScreen.tokens(tokens), elapsed: nil, speaking: false, hosted: true)
                == "Sales is calling you back")
    }

    @Test func aRingAfterARestartIsRoutedFromTheSessionsKeptForEachAgent() async throws {
        let pair = AgentPair()
        pair.sessions()
        // A cold start: the sessions are on disk, not yet fetched.
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: pair.sandbox.folder.appendingPathComponent(SessionCache.fileName(agent: "sales")).path) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let registry = GraineAgentRegistry()
        let cold = GraineInApp(
            config: GraineConfig(baseUrl: "https://www.graine.ai", publishableKey: "pk_test_sales"),
            installIds: MemoryInstallIdStore(), defaults: pair.sandbox.defaults,
            sessionCache: SessionCache(directory: pair.sandbox.folder, agent: "sales"),
            network: RoutedNetwork(), chatScheduler: ManualScheduler(), name: "sales", registry: registry
        )
        registry.add(cold)
        #expect(cold.session == nil)
        #expect(registry.agent(forAgentId: "web-sales") === cold)
    }

    @Test func theDeviceIsRegisteredWithEveryAgentThatRingsIt() throws {
        let pair = AgentPair()
        pair.sessions(support: ["calls": ["hosted": true]], sales: ["calls": ["hosted": true, "platforms": ["ios"]]])
        pair.support.registerDeviceEverywhere(token: "abc123", appId: "ai.acme.app", apnsEnvironment: "sandbox")
        let supportDevice = try #require(pair.supportNetwork.bodies("/api/embed/devices").first)
        let salesDevice = try #require(pair.salesNetwork.bodies("/api/embed/devices").first)
        #expect(supportDevice["publishableKey"] as? String == "pk_test_support")
        #expect(salesDevice["publishableKey"] as? String == "pk_test_sales")
        #expect(salesDevice["token"] as? String == "abc123" && salesDevice["apnsEnvironment"] as? String == "sandbox")
        #expect(supportDevice["installId"] as? String == salesDevice["installId"] as? String, "one device")
        // Done for each: not again until something changes or a day passes.
        pair.sales.registerDeviceEverywhere(token: "abc123", appId: "ai.acme.app", apnsEnvironment: "sandbox")
        #expect(pair.supportNetwork.bodies("/api/embed/devices").count == 1)
        #expect(pair.salesNetwork.bodies("/api/embed/devices").count == 1)
        #expect(DeviceRegistration.load(pair.sandbox.defaults, agent: "sales") != nil)
        #expect(DeviceRegistration.load(pair.sandbox.defaults, agent: "default") != nil)
    }

    @Test func anAgentWhoseWorkspaceDoesNotRingTheAppIsNotRegistered() throws {
        let pair = AgentPair()
        pair.sessions(support: ["calls": ["hosted": true]])
        pair.support.registerDeviceEverywhere(token: "abc123", appId: "ai.acme.app", apnsEnvironment: "production")
        #expect(pair.supportNetwork.bodies("/api/embed/devices").count == 1)
        #expect(pair.salesNetwork.bodies("/api/embed/devices").isEmpty)
    }
}

@Suite struct AgentRegistryTests {
    @Test func namesAreTrimmedAndEmptyIsTheDefault() {
        #expect(GraineAgentRegistry.normalise("  support ") == "support")
        #expect(GraineAgentRegistry.normalise("") == "default")
        #expect(GraineAgentRegistry.normalise("   ") == "default")
    }

    @Test func eachNameIsMadeOnceAndTheDefaultLeads() {
        let registry = GraineAgentRegistry()
        let config = GraineConfig(baseUrl: "https://www.graine.ai", publishableKey: "pk_test")
        let sales = registry.agent(named: "sales") { GraineInApp(config: config, name: "sales", registry: registry) }
        #expect(sales.created)
        #expect(registry.primary === sales.agent, "no default: the first configured")
        let again = registry.agent(named: "sales") { GraineInApp(config: config, name: "sales", registry: registry) }
        #expect(!again.created && again.agent === sales.agent)
        let main = registry.agent(named: "default") { GraineInApp(config: config, name: "default", registry: registry) }
        #expect(registry.primary === main.agent)
        #expect(Set(registry.all.keys) == ["default", "sales"])
        #expect(registry.named("sales") === sales.agent)
        #expect(registry.named("care") == nil)
    }

    @Test func eachAgentKeepsItsOwnSessionAndRegistration() {
        #expect(SessionCache.fileName(agent: "default") == "session.json", "a single-agent app keeps its file")
        let a = SessionCache.fileName(agent: "sales")
        let b = SessionCache.fileName(agent: "sa/les")
        #expect(a != b && a.hasPrefix("session-sales-") && !b.contains("/"))
        #expect(DeviceRegistration.storageKey(agent: "default") == DeviceRegistration.key)
        #expect(DeviceRegistration.storageKey(agent: "sales") == DeviceRegistration.key + ".sales")
    }

    @Test func thePushSaysWhichAgentIsCalling() throws {
        guard case .success(let call) = CallPush.parse(["type": "agent_call", "call_id": "c1", "hosted": "1", "agent_id": "web-sales"]) else {
            Issue.record("push"); return
        }
        #expect(call.agentId == "web-sales")
        #expect(CallPush.agentId(["data": ["agent_id": " agent-9 "]]) == "agent-9")
        #expect(CallPush.agentId(["type": "agent_call"]) == nil)
    }
}
