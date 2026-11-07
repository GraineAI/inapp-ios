import Foundation

/**
 * THE ENGINE PAGE ASKS ITS APP — what Talk (the voice bar's web view) cannot
 * get by itself.
 *
 * The engine page's own requests carry Graine's Origin and no app
 * declaration, so an agent that admits only its apps ("app://", "Only my
 * apps", "Require a verified app") refuses them: the session, the ticket, the
 * WebRTC credential. The page asks its host instead, with the website
 * loader's own messages (public/embed/v1.js), and this SDK answers natively —
 * no Origin, the app's declaration, its proof and the server token, exactly as
 * every request of its own:
 *
 *   graine:need-session            → graine:session {session}: the session this
 *                                    SDK fetched (as served)
 *   graine:need-ticket {purpose: "vouch"} → graine:ticket {ticket, wsUrl,
 *                                    purpose: "vouch"}: a ticket that vouches for
 *                                    this app — the page's WebRTC credential is
 *                                    then judged as the app's
 *   graine:need-ticket {mode: "voice"}    → graine:ticket {ticket, wsUrl,
 *                                    mode: "voice"}: the call's ticket, for a call
 *                                    on the WebSocket (through the gateway)
 *
 * A refusal answers `ticket: null` with the server's `error` (code, message,
 * status, reason) — the page never goes around it. Nothing here is logged but
 * whether an answer carried anything.
 */
enum HostAskWire {
    static let needSession = "graine:need-session"
    static let needTicket = "graine:need-ticket"
    static let session = "graine:session"
    static let ticket = "graine:ticket"

    enum Ask: Equatable {
        case session
        /// `mode` "voice" or nil; `purpose` "vouch" or nil — anything else the page could say is ignored.
        case ticket(mode: String?, purpose: String?)
    }

    /// The page's ask, or nil when the message is something else.
    static func read(_ message: Any?) -> Ask? {
        guard let m = JSON.unwrap(message) as? [String: Any], let type = JSON.unwrap(m["type"]) as? String else { return nil }
        switch type {
        case needSession:
            return .session
        case needTicket:
            let mode = (JSON.unwrap(m["mode"]) as? String) == "voice" ? "voice" : nil
            let purpose = (JSON.unwrap(m["purpose"]) as? String) == "vouch" ? "vouch" : nil
            return .ticket(mode: mode, purpose: purpose)
        default:
            return nil
        }
    }

    /**
     * The ticket's request, before the one door adds the app's declaration,
     * proof and server token: a vouch (it opens no conversation, so it carries
     * no mode) or the call's ticket with its variables — and who the user is,
     * as every ticket of this SDK's carries.
     */
    static func ticketFields(
        publishableKey: String,
        mode: String?,
        purpose: String?,
        metadata: [(String, String)]?,
        identity: IdentityWire.Fields?
    ) -> [(String, WireJSON)] {
        if purpose == "vouch" {
            var fields: [(String, WireJSON)] = [("publishableKey", .string(publishableKey)), ("purpose", .string("vouch"))]
            if let identity = identity { fields += IdentityWire.pairs(identity) }
            return fields
        }
        return CallWire.ticketFields(publishableKey: publishableKey, metadata: metadata, mode: mode == "voice" ? "voice" : "text", identity: identity)
    }

    /// `graine:session` with the session as served — `null` when there is none (the page then asks the server, as before).
    static func sessionAnswer(_ session: [String: Any]?) -> [String: Any] {
        ["type": HostAskWire.session, "session": session ?? NSNull()]
    }

    /// `graine:ticket` for an ask, from the mint's outcome, saying back its mode and purpose as the loader does.
    static func ticketAnswer(_ outcome: ConversationTicket.Outcome, mode: String?, purpose: String?) -> [String: Any] {
        var answer: [String: Any] = ["type": HostAskWire.ticket]
        switch outcome {
        case let .ticket(ticket, wsUrl):
            answer["ticket"] = ticket
            answer["wsUrl"] = wsUrl
        case .direct:
            answer["ticket"] = NSNull()
        case .refused(let error):
            answer["ticket"] = NSNull()
            var said: [String: Any] = ["code": error.code.wire, "message": error.message]
            if error.status > 0 { said["status"] = error.status }
            if let reason = error.reason { said["reason"] = reason }
            answer["error"] = said
        }
        if mode == "voice" { answer["mode"] = "voice" }
        if purpose == "vouch" { answer["purpose"] = "vouch" }
        return answer
    }

    /// What the debug log shows for an answer: whether it carried anything — never a ticket or a session.
    static func redactForLog(_ message: [String: Any]) -> String? {
        switch JSON.string(message["type"]) {
        case session:
            let s = JSON.unwrap(message["session"])
            return "session=" + (s == nil || s is NSNull ? "none" : "set")
        case ticket:
            let t = JSON.unwrap(message["ticket"])
            var line = "ticket=" + (t == nil || t is NSNull ? "none" : "set")
            if let mode = message["mode"] as? String { line += " mode=\(mode)" }
            if let purpose = message["purpose"] as? String { line += " purpose=\(purpose)" }
            if let error = message["error"] as? [String: Any], let code = error["code"] as? String { line += " refused=\(code)" }
            return line
        default:
            return nil
        }
    }
}
