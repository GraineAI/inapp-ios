import Foundation
import Testing
@_spi(GraineRTC) @testable import GraineInApp

/*
 * A CONFIG POINTED AT ITS OWN INSTALL TAKES EVERY ADDRESS FROM IT (docs: "Use your own Graine
 * install"). `GraineConfig.baseUrl` is the one address an app gives; the session's answer names
 * the only other one, the install's socket host (`wsHost`). Every URL the SDK builds from them —
 * the logo, glyphs and typefaces, the engine page, the direct sockets, a call's mint and control
 * channel, the calls host's agents — is pinned here for an install's addresses, and the hosted
 * defaults are pinned unchanged beside them.
 */

@Suite struct OwnInstallTests {
    private let own = "https://agents.example.com"
    private let ownWs = "wss://api.agents.example.com"

    @Test func theLogoGlyphsAndTypefacesComeFromTheInstall() throws {
        let look = Appearance.resolve(["logo": "org/wordmark.png"], accent: Appearance.defaultAccent, heading: "Assistant", origin: own + "/")
        #expect(look.logoUrl == own + "/api/embed/logo?k=org%2Fwordmark.png")
        #expect(GraineGlyph.url(origin: own, id: "mic", color: "#FFFFFF", sizePx: 96).hasPrefix(own + "/api/embed/glyph?id=mic&"))
        let face = try #require(GraineFonts.face(family: "Inter", weight: 400, origin: own))
        #expect(face.url.hasPrefix(own + "/api/embed/font?f=Inter&w=400"))
        // Hosted, as before.
        let hosted = Appearance.resolve(["logo": "org/wordmark.png"], accent: Appearance.defaultAccent, heading: "Assistant")
        #expect(hosted.logoUrl == "https://www.graine.ai/api/embed/logo?k=org%2Fwordmark.png")
    }

    @Test func theEnginePageIsTheInstallsOwn() {
        let url = GraineProtocol.engineUrl(
            baseUrl: own + "/", voiceAgentId: "w", transport: .websocket, cacheKey: "local",
            idle: true, publishableKey: "pk_live_x", accent: nil
        )
        #expect(url.hasPrefix(own + "/embed/w?mode=voice&"))
    }

    @Test func theSocketsAreTheOnesTheInstallNames() {
        let session = GraineSessionConfig.parse(["agentId": "a", "webcallAgentId": "w", "wsHost": ownWs + "/"])
        #expect(session.wsHost == ownWs + "/")
        #expect(CallWire.directUrl(wsHost: session.wsHost, baseUrl: own, agentId: "w") == ownWs + "/chat/v1/w?webcall=1")
        #expect(CallWire.directUrl(wsHost: session.wsHost, baseUrl: own, agentId: "w", textChat: true) == ownWs + "/chat/v1/w?text_chat=1")
        #expect(CallConversation.controlHost(session, baseUrl: own) == ownWs)
    }

    @Test func aWebRTCCallMintsAndListensOnTheInstall() {
        let setup = CallEngine.Setup(
            publishableKey: "pk_live_x", baseUrl: own, variables: [], contextFrame: { nil },
            session: { $0(nil) }, runAction: { _, _, answer in answer(.ok("")) }
        )
        let session = GraineSessionConfig.parse(["agentId": "a", "webcallAgentId": "w", "wsHost": ownWs])
        let request = CallConversation.rtcRequest(setup: setup, session: session, debug: false)
        #expect(request.baseUrl == own)
        #expect(request.controlHost == ownWs)
        // A session that names no host: no control host at all — never Graine's.
        let bare = CallConversation.rtcRequest(setup: setup, session: GraineSessionConfig.parse(["agentId": "a", "webcallAgentId": "w"]), debug: false)
        #expect(bare.controlHost == "")
    }

    // MARK: - No host named: an error the app sees, never Graine's cloud

    @Test func onlyGrainesOwnAddressesAreGrainesPlatform() {
        // Graine's own platform, exactly; its other names are built from that list, so the package spells out no host
        // but the ones it may name.
        #expect(CallWire.graineCloudHosts == ["graine.ai", "www.graine.ai", "app.graine.ai"])
        let platform = CallWire.graineCloudHosts.sorted().map { "https://" + $0 }
        for hosted in platform + ["https://www.graine.ai/", "HTTPS://WWW.GRAINE.AI", " https://www.graine.ai ", "https://www.graine.ai:443"] {
            #expect(CallWire.isGraineCloud(hosted), "\(hosted)")
        }
        for other in [own, own + "/", "http://www.graine.ai", "https://www.graine.ai:8443", "https://" + "acme.graine.ai",
                      "https://graine.ai.example.com", "https://www.graine.ai" + ".", "www.graine.ai", "", "not a url"] {
            #expect(!CallWire.isGraineCloud(other), "\(other)")
        }
    }

    @Test func anInstallsConversationHostIsOnlyTheOneItsSessionNames() {
        #expect(CallWire.socketHost(wsHost: ownWs, baseUrl: own) == ownWs)
        #expect(CallWire.socketHost(wsHost: " ws://install.example:8080/ ", baseUrl: own) == "ws://install.example:8080/")
        // Missing, or not a WebSocket address: none — the conversation is not opened, on Graine's host or any other.
        for missing: String? in [nil, "", "   ", "https://api.agents.example.com", "api.agents.example.com", "wss://", "not a url"] {
            #expect(CallWire.socketHost(wsHost: missing, baseUrl: own) == nil, "\(String(describing: missing))")
            #expect(CallWire.directUrl(wsHost: missing, baseUrl: own, agentId: "w") == nil)
            #expect(CallConversation.controlHost(GraineSessionConfig(agentId: "a", webcallAgentId: "w", wsHost: missing), baseUrl: own) == nil)
        }
        // Graine's own platform, exactly as before: the session's host as it came, else Graine's.
        #expect(CallWire.socketHost(wsHost: nil, baseUrl: "https://www.graine.ai") == "wss://ws.graine.ai")
        #expect(CallWire.socketHost(wsHost: "", baseUrl: "https://www.graine.ai") == "wss://ws.graine.ai")
        #expect(CallWire.socketHost(wsHost: "wss://ws.graine.ai/", baseUrl: "https://www.graine.ai") == "wss://ws.graine.ai/")
        #expect(CallConversation.controlHost(GraineSessionConfig(agentId: "a", webcallAgentId: "w"), baseUrl: "https://www.graine.ai") == "wss://ws.graine.ai")
    }

    @Test func anInstallCallWithNoHostEndsWithTheReasonAndOpensNothing() {
        let rig = EngineRig()
        rig.baseUrl = own
        rig.session = GraineSessionConfig(agentId: "agent-1", webcallAgentId: "web-1")
        rig.network.ticketReply = (503, Data(#"{"error":"Connection tickets aren't available on this deployment."}"#.utf8))
        rig.engine.start()
        #expect(rig.network.sockets.isEmpty, "no socket: not on Graine's host, not on any other")
        #expect(rig.endings == [.couldNotOpen(CallWire.noSocketHost)])
    }

    @Test func anInstallCallWithNoHostStillOpensOnTheInstallsTicket() throws {
        let rig = EngineRig()
        rig.baseUrl = own
        rig.session = GraineSessionConfig(agentId: "agent-1", webcallAgentId: "web-1")
        rig.network.ticketReply = (200, Data(#"{"ticket":"tkt-1","wsUrl":"wss://api.agents.example.com/embed/v1/web-1"}"#.utf8))
        rig.engine.start()
        let socket = try #require(rig.network.socket)
        #expect(socket.url.absoluteString == "wss://api.agents.example.com/embed/v1/web-1")
        #expect(rig.endings.isEmpty)
    }

    @Test func aHostedCallWithNoHostStillDialsGrainesOwnAsBefore() throws {
        let rig = EngineRig()
        rig.session = GraineSessionConfig(agentId: "agent-1", webcallAgentId: "web-1")
        rig.network.ticketReply = (503, nil)
        rig.engine.start()
        let socket = try #require(rig.network.socket)
        #expect(socket.url.absoluteString.hasPrefix("wss://ws.graine.ai/chat/v1/web-1?webcall=1"))
    }

    @Test func anInstallChatWithNoHostNeverOpensASocket() {
        let rig = ChatRig()
        rig.baseUrl = own
        rig.session = GraineSessionConfig(agentId: "agent-1", webcallAgentId: "web-1")
        rig.network.ticket = (503, #"{"error":"Connection tickets aren't available on this deployment."}"#)
        rig.chat.open()
        for delay in ChatWire.reconnectDelays { rig.scheduler.advance(delay + 0.01) }
        #expect(rig.network.sockets.isEmpty, "no socket: not on Graine's host, not on any other")
        #expect(rig.chat.status == .failed)
        // Hosted, as before: the same answer opens Graine's own socket.
        let hosted = ChatRig()
        hosted.session = GraineSessionConfig(agentId: "agent-1", webcallAgentId: "web-1")
        hosted.network.ticket = (503, nil)
        hosted.chat.open()
        #expect(hosted.network.socket?.url.absoluteString.hasPrefix("wss://ws.graine.ai/chat/v1/web-1?text_chat=1") == true)
    }

    @Test func anInstallWebRTCCallWithNoHostNeverTriesWebRTCAndGoesOnTheSocket() throws {
        let rig = ConversationRig()
        rig.baseUrl = own
        rig.session = GraineSessionConfig(agentId: "agent-1", webcallAgentId: "web-1")
        rig.network.ticketReply = (200, Data(#"{"ticket":"tkt-1","wsUrl":"wss://api.agents.example.com/embed/v1/web-1"}"#.utf8))
        let conversation = rig.make()
        conversation.start()
        #expect(rig.module.calls.isEmpty, "no WebRTC call without a control channel")
        #expect(rig.reports == [CallTransportReport(transport: .websocket, requested: .webrtc, reason: GraineRtcFallback.error.rawValue)])
        let socket = try #require(rig.network.socket)
        #expect(socket.url.host == "api.agents.example.com")
    }

    @Test func theCallsHostGivesEveryAgentTheInstallsAddress() throws {
        let options = try CallsHostOptions.parse([
            "publishableKey": "pk_live_a", "displayName": "Acme Assistant", "baseUrl": own + "/",
            "agents": ["support": ["publishableKey": "pk_live_b"]],
        ])
        #expect(options.baseUrl == own)
        #expect(options.agents["support"]?.baseUrl == own)
        // Without one, the hosted platform, as before.
        #expect(try CallsHostOptions.parse(["publishableKey": "pk_live_a", "displayName": "Acme Assistant"]).baseUrl == "https://www.graine.ai")
    }
}
