import Foundation
import Testing
@testable import GraineInApp

/*
 * SERVER TOKENS, KEYS AND THE BOT CHECK — the contract's vectors
 * (CLIENT-TOKENS.md, client-tokens.json), every case of each: the six codes as
 * this SDK's error type with their retry rule and reasons, what a token says
 * about its own life (`sdk.decode`), when each is refreshed (`sdk.schedule`, by
 * the rule and by the token manager itself), when a connection may use one
 * (`sdk.usable`), the backoff (`sdk.backoffSeconds`), and the words and numbers
 * every SDK shares. A missing contract file fails.
 */
@Suite struct ClientTokensContractTests {
    private let contract: [String: Any]

    init() throws {
        contract = try ContractFile.load("client-tokens.json")
    }

    private var sdk: [String: Any] { contract["sdk"] as? [String: Any] ?? [:] }

    private func cases(_ object: [String: Any], _ name: String) throws -> [[String: Any]] {
        let list = try #require(object[name] as? [[String: Any]], "\(name) is a list")
        #expect(!list.isEmpty, "section \(name) is empty")
        return list
    }

    private func token(_ name: String) -> String? {
        ((contract["token"] as? [String: Any])?["tokens"] as? [String: Any])?[name] as? String
    }

    private func number(_ o: [String: Any], _ key: String) -> Double? {
        guard let value = o[key], !(value is NSNull), let n = value as? NSNumber else { return nil }
        return n.doubleValue
    }

    /// The contract's `swift` names, each one of this SDK's cases.
    private static let swiftCases: [String: GraineErrorCode] = [
        "tokenRequired": .tokenRequired, "tokenInvalid": .tokenInvalid, "tokenExpired": .tokenExpired,
        "tokenScope": .tokenScope, "keyRevoked": .keyRevoked, "botCheckFailed": .botCheckFailed,
    ]

    // MARK: - The codes

    @Test func everyCodeIsThisSdksWithItsWireWordAndItsRetryRule() throws {
        let codes = try cases(contract, "errorCodes")
        for c in codes {
            let wire = try #require(c["wire"] as? String)
            let code = GraineErrorCode(wire: wire)
            #expect(code.wire == wire)
            #expect(Self.swiftCases[c["swift"] as? String ?? ""] == code, "the Swift name of \(wire)")
            if case .unknown = code { Issue.record("\(wire) is a code this build knows") }
            #expect(GraineErrorCode(wire: "  \(wire.uppercased()) ") == code, "case and spaces never matter")
            switch c["retry"] as? String {
            case "refresh_then_retry_once":
                // A fresh token can lift it: asked for again, and the request goes once more.
                #expect(ClientTokenRules.refreshableCodes.contains(wire), "\(wire)")
            case "never", "website_challenge_then_retry_once":
                // Final for the request (an app never answers a website's challenge): surfaced, never looped.
                #expect(!ClientTokenRules.refreshableCodes.contains(wire), "\(wire)")
            default:
                Issue.record("a retry rule this SDK does not know: \(String(describing: c["retry"]))")
            }
        }
        #expect(Set(codes.compactMap { $0["wire"] as? String }) == ClientTokenRules.refusalCodes,
                "every refusal of the contract, and only those, is final for a conversation")
    }

    @Test func aRefusalIsReadWithItsStatusSentenceAndReason() throws {
        let reasons = contract["reasons"] as? [String: [String]] ?? [:]
        #expect(!reasons.isEmpty)
        for c in try cases(contract, "errorCodes") {
            let wire = try #require(c["wire"] as? String)
            let status = try #require(c["status"] as? Int)
            let said: [String?] = reasons[wire].map { $0.map { Optional($0) } } ?? [nil]
            for reason in said {
                var body: [String: Any] = ["error": "Refused.", "code": wire]
                if let reason = reason { body["reason"] = reason }
                // Every request's reading of a refusal: the code, Graine's sentence, its reason.
                let e = GraineServiceError.from(status: status, body: body)
                #expect(e.code.wire == wire && e.message == "Refused." && e.reason == reason && e.status == status, "\(wire) \(reason ?? "-")")
                // A conversation's reading: the same, final.
                let r = try #require(ClientTokenRules.refusal(status: status, body: try JSONSerialization.data(withJSONObject: body)))
                #expect(r == e)
                // Graine without a sentence: the SDK's own, never the allowed-domains one.
                let bare = try #require(ClientTokenRules.refusal(status: status, body: Data(#"{"code":"\#(wire)"}"#.utf8)))
                #expect(bare.message == ClientTokenRules.sentence(wire))
                #expect(!bare.message.contains("app://"))
                #expect(GraineServiceError.from(status: status, body: ["code": wire]).message == ClientTokenRules.sentence(wire))
            }
        }
        #expect(ClientTokenRules.refusal(status: 403, body: Data(#"{"code":"origin_refused"}"#.utf8)) == nil, "any other refusal goes where it always went")
        #expect(ClientTokenRules.refusal(status: 200, body: Data(#"{"code":"token_scope"}"#.utf8)) == nil)
        #expect(ClientTokenRules.refusal(status: 503, body: Data("not json".utf8)) == nil)
        #expect(ClientTokenRules.callError(GraineServiceError(code: .keyRevoked, message: "Revoked.")) == "key_revoked: Revoked.",
                "a call that could not start says the code first")
        // The session's own reading: Graine's (or the SDK's) words for a token or key refusal, never the app:// ones.
        let session = GraineInApp.session(from: .init(status: 403, data: Data(#"{"code":"token_scope","reason":"agent"}"#.utf8), failure: nil))
        guard case .failure(let error as GraineServiceError) = session else {
            Issue.record("refused")
            return
        }
        #expect(error.code == .tokenScope && error.reason == "agent" && !error.message.contains("app://"))
    }

    // MARK: - What a token says about its own life

    @Test func everyTokenDecodesAsTheVectorsSay() throws {
        for c in try cases(sdk, "decode") {
            let name = try #require(c["token"] as? String)
            let claims = ClientTokenRules.decode(try #require(token(name), "the vector token \(name)"))
            #expect(claims.iat == number(c, "iat"), "\(name) iat")
            #expect(claims.exp == number(c, "exp"), "\(name) exp")
        }
        #expect(ClientTokenRules.decode(nil) == ClientTokenRules.Claims())
        #expect(ClientTokenRules.decode("") == ClientTokenRules.Claims())
        #expect(ClientTokenRules.decode("a..c") == ClientTokenRules.Claims())
        #expect(ClientTokenRules.localExpiry(ClientTokenRules.decode("not-a-token"), receivedAt: 1_000) == nil,
                "no readable expiry: nothing in the background")
    }

    @Test func everyScheduleIsTheVectorsOwn() throws {
        for c in try cases(sdk, "schedule") {
            let name = c["name"] as? String ?? "?"
            let claims = ClientTokenRules.Claims(iat: number(c, "iat"), exp: number(c, "exp"))
            let receivedAt = try #require(number(c, "receivedAt"))
            let life = try #require(ClientTokenRules.lifetime(claims))
            let localExp = try #require(ClientTokenRules.localExpiry(claims, receivedAt: receivedAt))
            #expect(localExp == number(c, "localExp"), "\(name) localExp")
            #expect(ClientTokenRules.lead(lifetime: life) == number(c, "lead"), "\(name) lead")
            #expect(localExp - ClientTokenRules.lead(lifetime: life) == number(c, "refreshAt"), "\(name) refreshAt")
            #expect(ClientTokenRules.maxJitter(lifetime: life) == number(c, "maxJitter"), "\(name) maxJitter")
        }
    }

    /**
     * The same vectors through the token manager itself: a token minted with
     * each case's `iat` and `exp`, arriving at `receivedAt`, is asked for again
     * at `refreshAt` less its jitter (none, then the most) — and never sooner
     * than 30 s after it arrived.
     */
    @Test func theTokenManagerRefreshesAtEachVectorsMoment() throws {
        for c in try cases(sdk, "schedule") {
            for draw in [0.0, 1.0] {
                let name = c["name"] as? String ?? "?"
                let sched = ManualScheduler()
                let start = sched.now
                let receivedAt = try #require(number(c, "receivedAt"))
                let minted = TestTokens.mint(iat: try #require(number(c, "iat")), exp: try #require(number(c, "exp")))
                let provider = TestProvider { minted }
                let tokens = ClientTokens(
                    fetch: provider.fetch,
                    clock: { receivedAt + (sched.now - start) },
                    random: { draw },
                    schedule: { sched.after($0, $1) },
                    background: { $0() }
                )
                tokens.start()
                #expect(provider.asked == 1, "\(name)")
                let jitter = draw * (try #require(number(c, "maxJitter")))
                let refreshAt = try #require(number(c, "refreshAt"))
                let due = max(refreshAt - jitter, receivedAt + ClientTokenRules.backgroundMinInterval) - receivedAt
                sched.advance(due - 0.01)
                #expect(provider.asked == 1, "\(name) (jitter \(jitter)): not before its moment")
                sched.advance(0.01)
                #expect(provider.asked == 2, "\(name) (jitter \(jitter)): at its moment")
            }
        }
    }

    @Test func aConnectionUsesATokenAsTheVectorsSay() throws {
        for c in try cases(sdk, "usable") {
            let usable = ClientTokenRules.usable(localExp: number(c, "localExp"), now: try #require(number(c, "now")))
            #expect(usable == (c["usable"] as? Bool), "\(c)")
        }
        #expect(ClientTokenRules.usable(localExp: nil, now: 0), "no readable expiry: the token is used, and Graine judges it")
    }

    @Test func theBackoffIsTheVectorsOwn() throws {
        let list = try #require(sdk["backoffSeconds"] as? [Double])
        #expect(list.count >= 6)
        for (i, seconds) in list.enumerated() {
            #expect(ClientTokenRules.backoff(failures: i + 1) == seconds, "failure \(i + 1)")
        }
        #expect(sdk["backoffJitter"] as? Double == ClientTokenRules.backoffJitter)
    }

    @Test func theWordsAndNumbersAreTheContracts() throws {
        #expect(sdk["wireField"] as? String == ClientTokenRules.field)
        let page = try #require(sdk["pageMessages"] as? [String: Any])
        #expect(page["toPage"] as? String == GraineProtocol.Out.clientToken)
        #expect(page["toHost"] as? String == GraineProtocol.In.needClientToken)
        #expect((page["pageWaitMs"] as? Double).map { $0 / 1000 } == ClientTokenRules.pushWait)
        if case .needClientToken? = GraineProtocol.parse(#"{"type":"\#(GraineProtocol.In.needClientToken)"}"#) {} else {
            Issue.record("the page's ask for a token is read")
        }
        #expect(sdk["usableForNewConnectionSeconds"] as? Double == ClientTokenRules.usableForConnection)
        #expect(sdk["newConnectionWaitSeconds"] as? Double == ClientTokenRules.connectionWait)
        #expect(sdk["forcedRefreshMinIntervalSeconds"] as? Double == ClientTokenRules.forcedMinInterval)
        #expect(sdk["minSecondsBetweenBackgroundRefreshes"] as? Double == ClientTokenRules.backgroundMinInterval)
        #expect(contract["sdkVersion"] as? String == GraineVersion.name)
        // The calls host's event, and the page's message, as the contract names them (CLIENT-TOKENS.md §2.2, §2.4).
        #expect(CallsHostEvent.needClientToken == "needClientToken")
        #expect(GraineProtocol.redactForLog(GraineProtocol.out(GraineProtocol.Out.clientToken, ["token": "eyJ.payload.sig"])) == "token=set",
                "a token never reaches a log")
        #expect(GraineProtocol.redactForLog(GraineProtocol.out(GraineProtocol.Out.clientToken, ["token": nil])) == "token=none")
    }
}

/// Tokens for the tests: a header, a payload with `iat` and `exp`, and a signature nobody checks — the SDK reads only the two.
enum TestTokens {
    private static func part(_ json: String) -> String {
        Data(json.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }

    static func mint(iat: Double, exp: Double, id: String = "ct_test") -> String {
        part(#"{"alg":"EdDSA","typ":"JWT","kid":"test-key-000000"}"#) + "." +
            part(#"{"iss":"graine","aud":"graine-embed","sub":"user-123","scp":["chat","call"],"iat":\#(Int(iat)),"exp":\#(Int(exp)),"jti":"\#(id)"}"#) +
            ".c2ln"
    }

    /// The `jti` a test token was minted with.
    static func id(_ token: String?) -> String? {
        guard let parts = token?.split(separator: "."), parts.count > 1, let data = ClientTokenRules.base64url(String(parts[1])) else { return nil }
        return JSON.object(from: data)?["jti"] as? String
    }
}

/// A provider whose answer the test decides, counting its questions; `manual` keeps each until the test answers it.
final class TestProvider {
    var answer: () -> String?
    private(set) var asked = 0
    var manual = false
    private(set) var pending: [@Sendable (String?) -> Void] = []

    init(_ answer: @escaping () -> String? = { nil }) {
        self.answer = answer
    }

    func fetch(_ done: @escaping @Sendable (String?) -> Void) {
        asked += 1
        if manual { pending.append(done) } else { done(answer()) }
    }

    /// Answer the oldest question still held.
    func reply(_ token: String?) {
        guard !pending.isEmpty else { return }
        pending.removeFirst()(token)
    }
}
