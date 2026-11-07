import Foundation
import Testing
@testable import GraineInApp

/*
 * TALK AUTHENTICATES AS THIS APP — the engine page's asks (Core/HostAsk.swift):
 * the website loader's messages, read here; the ticket minted natively through
 * the SDK's own door (ConversationTicket: no Origin, the app's declaration,
 * proof and server token); and the answers said back as the loader says them.
 */

@Suite struct HostAskWireTests {
    @Test func readsTheLoadersQuestionsAndNothingElse() {
        #expect(HostAskWire.read(["type": "graine:need-session"]) == .session)
        #expect(HostAskWire.read(["type": "graine:need-ticket", "purpose": "vouch"]) == .ticket(mode: nil, purpose: "vouch"))
        #expect(HostAskWire.read(["type": "graine:need-ticket", "mode": "voice"]) == .ticket(mode: "voice", purpose: nil))
        #expect(HostAskWire.read(["type": "graine:need-ticket", "mode": "fax", "purpose": "anything"]) == .ticket(mode: nil, purpose: nil),
                "anything else the page could say is ignored")
        #expect(HostAskWire.read(["type": "graine:ready"]) == nil)
        #expect(HostAskWire.read("graine:need-session") == nil)
    }

    @Test func aVouchCarriesNoModeAndTheCallsTicketIsAVoiceTicket() throws {
        let identity = IdentityWire.Fields(value: "u-1", installId: "3f2504e0-4f89-11d3-9a0c-0305e82c3301", memory: true, timezone: "Asia/Kolkata", callId: nil)
        let vouch = HostAskWire.ticketFields(publishableKey: "pk_live_x", mode: nil, purpose: "vouch", metadata: [("first_name", "Asha")], identity: identity)
        let v = try #require(JSON.object(from: WireJSON.object(vouch).text))
        #expect(v["purpose"] as? String == "vouch")
        #expect(v["mode"] == nil, "a vouch opens no conversation")
        #expect(v["metadata"] == nil)
        #expect(v["installId"] as? String == "3f2504e0-4f89-11d3-9a0c-0305e82c3301", "who the user is, as every ticket of this SDK's")
        let voice = HostAskWire.ticketFields(publishableKey: "pk_live_x", mode: "voice", purpose: nil, metadata: [("first_name", "Asha")], identity: nil)
        let c = try #require(JSON.object(from: WireJSON.object(voice).text))
        #expect(c["mode"] as? String == "voice")
        #expect((c["metadata"] as? [String: Any])?["first_name"] as? String == "Asha")
    }

    @Test func answersAsTheLoaderDoes() {
        let ok = HostAskWire.ticketAnswer(.ticket(ticket: "v1.a.b", wsUrl: "wss://ws.graine.ai/embed/v1/web-1"), mode: "voice", purpose: nil)
        #expect(ok["type"] as? String == "graine:ticket")
        #expect(ok["ticket"] as? String == "v1.a.b")
        #expect(ok["wsUrl"] as? String == "wss://ws.graine.ai/embed/v1/web-1")
        #expect(ok["mode"] as? String == "voice")
        #expect(ok["purpose"] == nil)
        let none = HostAskWire.ticketAnswer(.direct(status: 503), mode: nil, purpose: "vouch")
        #expect(none["ticket"] is NSNull, "no ticket: the page carries on as it would have")
        #expect(none["purpose"] as? String == "vouch")
        let refusal = GraineServiceError(code: .appNotVerified, message: "Not verified.", status: 403, reason: "missing")
        let refused = HostAskWire.ticketAnswer(.refused(refusal), mode: nil, purpose: "vouch")
        #expect(refused["ticket"] is NSNull)
        let said = refused["error"] as? [String: Any]
        #expect(said?["code"] as? String == "app_not_verified")
        #expect(said?["status"] as? Int == 403)
        #expect(said?["reason"] as? String == "missing")
        let session = HostAskWire.sessionAnswer(["agentId": "main", "webcallAgentId": "web"])
        #expect(session["type"] as? String == "graine:session")
        #expect((session["session"] as? [String: Any])?["webcallAgentId"] as? String == "web")
        #expect(HostAskWire.sessionAnswer(nil)["session"] is NSNull)
    }

    @Test func theLogNeverShowsATicketOrASession() {
        let line = GraineProtocol.redactForLog(HostAskWire.ticketAnswer(.ticket(ticket: "v1.secret.sig", wsUrl: "wss://ws.graine.ai"), mode: "voice", purpose: nil))
        #expect(!line.contains("v1.secret.sig"))
        #expect(line.contains("ticket=set"))
        let s = GraineProtocol.redactForLog(HostAskWire.sessionAnswer(["variables": ["first_name": "Asha"]]))
        #expect(!s.contains("Asha"))
        #expect(s == "session=set")
    }

    @Test func theSessionAsServedIsKeptForThePage() {
        let served: [String: Any] = ["agentId": "main", "webcallAgentId": "web", "design": ["config": ["preset": "signature"]], "wsHost": "wss://ws.graine.ai"]
        let session = GraineSessionConfig.parse(served)
        #expect(session.served["webcallAgentId"] as? String == "web")
        #expect((session.served["design"] as? [String: Any]) != nil)
        #expect(GraineSessionConfig(agentId: "a", webcallAgentId: "b").served.isEmpty)
    }

    @Test func theTicketIsMintedNativelyThroughTheSdksOwnDoor() async throws {
        let network = FakeNetwork()
        network.ticketReply = (200, Data(#"{"ticket":"v1.vouch.sig","wsUrl":"wss://ws.graine.ai/embed/v1/web-1"}"#.utf8))
        let url = try #require(URL(string: "https://www.graine.ai/api/embed/ticket"))
        let answer: [String: Any] = await withCheckedContinuation { done in
            ConversationTicket.ask(
                url: url,
                fields: { HostAskWire.ticketFields(publishableKey: "pk_live_x", mode: nil, purpose: "vouch", metadata: nil, identity: nil) },
                security: nil,
                network: network
            ) { outcome in done.resume(returning: HostAskWire.ticketAnswer(outcome, mode: nil, purpose: "vouch")) }
        }
        #expect(answer["ticket"] as? String == "v1.vouch.sig")
        #expect(answer["purpose"] as? String == "vouch")
        let posted = try #require(network.posts.first)
        #expect(posted.url.path == "/api/embed/ticket")
        let body = try #require(JSON.object(from: posted.body))
        #expect(body["purpose"] as? String == "vouch")
        #expect(body["publishableKey"] as? String == "pk_live_x")
    }

    @Test func aRefusalIsSaidBackAndNeverGoneAround() async throws {
        let network = FakeNetwork()
        network.ticketReply = (403, Data(#"{"error":"This app is not one of the agent's apps.","code":"app_not_allowed"}"#.utf8))
        let url = try #require(URL(string: "https://www.graine.ai/api/embed/ticket"))
        let answer: [String: Any] = await withCheckedContinuation { done in
            ConversationTicket.ask(
                url: url,
                fields: { HostAskWire.ticketFields(publishableKey: "pk_live_x", mode: "voice", purpose: nil, metadata: nil, identity: nil) },
                security: nil,
                network: network
            ) { outcome in done.resume(returning: HostAskWire.ticketAnswer(outcome, mode: "voice", purpose: nil)) }
        }
        #expect(answer["ticket"] is NSNull)
        #expect((answer["error"] as? [String: Any])?["code"] as? String == "app_not_allowed")
        #expect(answer["mode"] as? String == "voice")
    }
}
