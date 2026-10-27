import Foundation

/**
 * A CONVERSATION'S TICKET, ASKED AS APP-IDENTITY.md SAYS — for the chat
 * (`mode: "text"`) and the native call on the voice socket alike:
 *
 *   before   what is worth waiting for, waited for (10 s at most): a proof of
 *            the app the agent requires, an identity token about to expire
 *   sealed   the body leaves with the app's declaration and, inside
 *            `identity`, the token and pass for exactly that value
 *   heard    the answer's `verification` is kept (the passes, the public state)
 *   cured    `app_not_verified` / `identity_unverified`: the app proven or the
 *            token refreshed, and the ticket asked once more
 *   refused  the agent's own refusal of the app or the user ends there — the
 *            conversation does not open, and never on the direct socket,
 *            which would be refused the same way
 *
 * Anything else that is not a ticket (no gateway here, a network error) goes
 * to the direct socket, as before. Foundation only.
 */
enum ConversationTicket {
    enum Outcome {
        case ticket(ticket: String, wsUrl: String)
        /// No ticket — a 503 "no gateway here", a network error: the direct socket, as before.
        case direct(status: Int)
        /// The agent refused this app or this user, or Graine the server token, the key or the bot check: the conversation does not open.
        case refused(GraineServiceError)
    }

    /// The refusals that are about the app or the user: never answered by the direct socket.
    static let securityCodes: Set<String> = ["app_not_allowed", "app_not_verified", "identity_unverified"]

    /// `fields` is read at each attempt (a retry carries the cured proof). `done` once, on any thread.
    static func ask(
        url: URL,
        fields: @escaping () -> [(String, WireJSON)],
        security: EmbedProof?,
        tokens: ClientTokens? = nil,
        network: CallNetwork,
        done: @escaping (Outcome) -> Void
    ) {
        func attempt(cured: Bool) {
            let built = fields()
            let body = Data(WireJSON.object(EmbedSeal.seal(built, security)).text.utf8)
            // Inside the seal, the agent's server token: a new connection waits for a usable one, and a refusal a
            // fresh one can lift goes once more (ClientTokenWire, CLIENT-TOKENS.md §2.2).
            ClientTokenWire.post(tokens, body: body, newConnection: true, send: { json, answer in
                network.postWithHeaders(url, body: json, completion: answer)
            }) { status, data, headers in
                let parsed = JSON.object(from: data)
                security?.heard(status: status, body: parsed, identityValue: EmbedSeal.identityValue(built))
                if (200...299).contains(status), let ticket = JSON.nonEmpty(parsed?["ticket"]), let ws = JSON.nonEmpty(parsed?["wsUrl"]) {
                    return done(.ticket(ticket: ticket, wsUrl: ws))
                }
                // Refused for the server token, the key or the bot check: final — the direct socket would only be another way past it.
                if let refusal = ClientTokenRules.refusal(status: status, body: data) { return done(.refused(refusal)) }
                guard status != 0, !(200...299).contains(status), let word = JSON.nonEmpty(parsed?["code"]),
                      securityCodes.contains(word.lowercased()) else { return done(.direct(status: status)) }
                let error = GraineServiceError.from(status: status, body: parsed, headers: headers)
                guard !cured, error.code != .appNotAllowed, let security = security else { return done(.refused(error)) }
                security.cure(error) { retry in
                    if retry { attempt(cured: true) } else { done(.refused(error)) }
                }
            }
        }
        guard let security = security else { return attempt(cured: false) }
        security.beforeConversation { attempt(cured: false) }
    }
}
