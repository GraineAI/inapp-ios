import Foundation
import Testing
@testable import GraineInApp

/*
 * 0.14.3, PAST SESSIONS (sdk/contract/PUBLIC-STATE.md "Past sessions"; the wire and
 * its vectors: sdk/contract/past-sessions.json — every section run, never skipped):
 *
 *   pages        a list answer → the sessions the SDK keeps, and the next page's cursor
 *   append       refresh, then load more, … on a real chat → the ids and hasMore after each
 *   transcripts  a transcript answer → its turns in the SDK's words
 *   refusals     a status and a body → `pastSessions.error`, and the word a transcript throws
 *
 * Then the rules around them, on a real instance with the network faked: whose the list
 * is (an identity change clears it, and a page still on its way for the identity before
 * is never shown), nobody identified (identity_required, nothing sent), when load more
 * waits, the bodies — and the Objective-C facade a bridge reads them through.
 */

private let listPath = "/api/embed/sessions/list"
private let transcriptPath = "/api/embed/sessions/transcript"
private let field: [String: Any] = ["identity": ["field": "user_id"]]

/// JSON text of a value as the contract file holds it.
private func text(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return "null" }
    return String(decoding: data, as: UTF8.self)
}

/// A page of the list, as Graine answers it: these ids, a minute apart, and the next page's cursor.
private func page(_ ids: [String], next: String? = nil) -> String {
    text([
        "sessions": ids.enumerated().map { i, id in
            ["id": id, "startedAt": "2026-10-21T10:\(String(format: "%02d", i)):00Z", "channel": "chat", "status": "completed", "turns": 2, "preview": "Hi"] as [String: Any]
        },
        "next": next.map { $0 as Any } ?? NSNull(),
    ] as [String: Any])
}

private enum Vectors {
    static func section(_ name: String) throws -> [[String: Any]] {
        let file = try ContractFile.load("past-sessions.json")
        let list = try #require(file[name] as? [[String: Any]], "past-sessions.json has no \(name)")
        #expect(!list.isEmpty, "past-sessions.json's \(name) is empty")
        return list
    }

    /// A time as the contract writes it, read without the SDK's own reader.
    static func time(_ raw: Any?) -> Date? {
        guard let s = raw as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// A session as the contract expects the SDK to keep it.
    static func session(_ o: [String: Any]) throws -> GraineSessionSummary {
        GraineSessionSummary(
            id: try #require(o["id"] as? String),
            startedAt: try #require(time(o["startedAt"])),
            endedAt: time(o["endedAt"]),
            durationSeconds: (o["durationSeconds"] as? NSNumber)?.intValue,
            channel: try #require(GraineSessionChannel(rawValue: o["channel"] as? String ?? "")),
            direction: (o["direction"] as? String).flatMap { GraineSessionDirection(rawValue: $0) },
            status: try #require(o["status"] as? String),
            turns: try #require((o["turns"] as? NSNumber)?.intValue),
            preview: try #require(o["preview"] as? String)
        )
    }

    /// A turn as the contract expects it, in the SDK's words (`agent`, `customer`).
    static func turn(_ o: [String: Any]) throws -> GraineSessionTurn {
        GraineSessionTurn(
            role: try #require(GraineRole(rawValue: o["role"] as? String ?? "")),
            text: try #require(o["text"] as? String),
            at: try #require(time(o["at"]))
        )
    }
}

// MARK: - The contract's vectors, on the parser

@Suite struct PastSessionsContractTests {
    @Test func everyPageIsKeptAsTheContractSays() throws {
        let cases = try Vectors.section("pages")
        #expect(cases.count >= 3)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let response = try #require(c["response"] as? [String: Any])
            let page = PastSessionsWire.page(response)
            let want = try (try #require(c["sessions"] as? [[String: Any]], "\(name)")).map { try Vectors.session($0) }
            #expect(page.sessions == want, "\(name)")
            #expect(page.next == c["next"] as? String, "\(name): the next page's cursor")
        }
    }

    @Test func everyTranscriptKeepsTheContractsTurnsInTheSDKsWords() throws {
        for c in try Vectors.section("transcripts") {
            let name = c["name"] as? String ?? "?"
            let response = try #require(c["response"] as? [String: Any])
            let got = PastSessionsWire.transcript(response, id: "asked")
            let want = try (try #require(c["turns"] as? [[String: Any]], "\(name)")).map { try Vectors.turn($0) }
            #expect(got.turns == want, "\(name)")
            #expect(got.id == response["id"] as? String, "\(name)")
            #expect(got.startedAt == Vectors.time(response["startedAt"]), "\(name)")
            #expect(got.endedAt == Vectors.time(response["endedAt"]), "\(name)")
            #expect(got.durationSeconds == (response["durationSeconds"] as? NSNumber)?.intValue, "\(name)")
            #expect(got.channel.rawValue == response["channel"] as? String, "\(name)")
            #expect(got.direction == nil, "\(name): null on the wire")
            #expect(got.status == response["status"] as? String, "\(name)")
        }
    }

    /// The contract's rules at their edges: a boolean is never a number, a repeated id is kept once, a fraction of a second is read.
    @Test func looseFieldsFallBackAsTheRulesSay() throws {
        let page = PastSessionsWire.page(["sessions": [
            ["id": "b1", "startedAt": "2026-10-21T12:00:05.500Z", "durationSeconds": true, "turns": true, "channel": " CALL ", "direction": "Outbound", "status": " ended_by_agent ", "preview": NSNull()] as [String: Any],
            ["id": "b1", "startedAt": "2026-10-21T12:00:06Z", "preview": "the same id again"] as [String: Any],
            ["id": "   ", "startedAt": "2026-10-21T12:00:05Z"] as [String: Any],
            ["id": 7, "startedAt": "2026-10-21T12:00:05Z"] as [String: Any],
            ["id": "b2", "startedAt": 1_791_882_000] as [String: Any],
            ["id": "b3", "startedAt": "2026-10-21T12:00:05+05:30", "durationSeconds": 12.6, "turns": 2.0] as [String: Any],
            ["id": "b4", "startedAt": "2026-10-21T12:00:05Z", "durationSeconds": -1, "turns": 2.5] as [String: Any],
            "not a session",
        ] as [Any], "next": "   "] as [String: Any])
        #expect(page.sessions.map(\.id) == ["b1", "b3", "b4"], "no id, a blank id, a number for an id, a number for a time: skipped; b1 once")
        #expect(page.next == nil, "a blank cursor is the end")
        let b1 = try #require(page.sessions.first)
        #expect(b1.startedAt == Date(timeIntervalSince1970: 1_792_584_005.5))
        #expect(b1.durationSeconds == nil, "a boolean is no duration")
        #expect(b1.turns == 0, "a boolean is no count")
        #expect(b1.channel == .call)
        #expect(b1.direction == .outbound)
        #expect(b1.status == " ended_by_agent ", "passed through as sent")
        #expect(b1.preview == "")
        #expect(page.sessions[1].startedAt == Date(timeIntervalSince1970: 1_792_564_205), "an offset is read")
        #expect(page.sessions[1].durationSeconds == 13, "whole seconds, rounded")
        #expect(page.sessions[1].turns == 2, "2.0 is a whole number")
        #expect(page.sessions[2].durationSeconds == nil, "a negative duration is none")
        #expect(page.sessions[2].turns == 0, "2.5 is not a count")
        #expect(PastSessionsWire.page(["sessions": "nope"] as [String: Any]).sessions.isEmpty)
        #expect(PastSessionsWire.page([:]).next == nil)

        let bare = PastSessionsWire.transcript(["startedAt": "soon", "turns": [["role": "USER ", "text": "", "at": "2026-10-21T12:00:05Z"] as [String: Any], "x"] as [Any]] as [String: Any], id: "asked")
        #expect(bare == GraineSessionTranscript(id: "asked", turns: [GraineSessionTurn(role: .customer, text: "", at: Date(timeIntervalSince1970: 1_792_584_005))]))
    }

    /// What a bridge reads back is the wire's own shape: read with the same rules, it is the same sessions.
    @Test func writtenBackItIsTheWiresShape() throws {
        let first = try #require(try Vectors.section("pages").first)
        let read = PastSessionsWire.page(try #require(first["response"] as? [String: Any]))
        let state = GrainePastSessions(sessions: read.sessions, loading: false, hasMore: true, error: nil)
        let written = try #require(JSON.object(from: ObjCBridge.text(PastSessionsWire.json(state))))
        #expect(JSON.canonical(written["sessions"]) == JSON.canonical(first["sessions"]), "byte for byte the contract's sessions")
        #expect(PastSessionsWire.page(written).sessions == read.sessions)
        #expect(written["hasMore"] as? Bool == true)
        #expect(written["error"] is NSNull)
        let fraction = GraineSessionSummary(id: "f", startedAt: Date(timeIntervalSince1970: 1_792_584_005.25))
        #expect(PastSessionsWire.json(fraction)["startedAt"] as? String == "2026-10-21T12:00:05.250Z", "milliseconds only when it has them")

        let transcript = try #require(try Vectors.section("transcripts").first)
        let t = PastSessionsWire.transcript(try #require(transcript["response"] as? [String: Any]), id: "x")
        let again = try #require(JSON.object(from: ObjCBridge.text(PastSessionsWire.json(t))))
        #expect(PastSessionsWire.transcript(again, id: "y") == t, "read back with the contract's rules: the same")
        #expect((again["turns"] as? [[String: Any]])?.map { $0["role"] as? String } == ["assistant", "user", "assistant"], "the wire's words")
    }
}

// MARK: - On a real chat

@Suite @MainActor struct PastSessionsChatTests {
    /// An instance with the agent's settings loaded, and `value` identified (nobody for nil).
    private func identified(_ value: String? = "u-1") -> PlatformRig {
        let rig = PlatformRig()
        rig.session(field)
        if let value = value { rig.graine.identify(["user_id": value]) }
        return rig
    }

    private func ids(_ rig: PlatformRig) -> [String] { rig.graine.chat.pastSessions.sessions.map(\.id) }

    @Test func everyAppendCaseLeavesTheContractsStateAfterEachStep() throws {
        for c in try Vectors.section("append") {
            let name = c["name"] as? String ?? "?"
            let rig = identified()
            defer { rig.sandbox.clean() }
            let steps = try #require(c["steps"] as? [[String: Any]])
            let states = try #require(c["states"] as? [[String: Any]])
            #expect(steps.count == states.count, "\(name)")
            var cursor: String?
            for (i, step) in steps.enumerated() {
                let before = rig.network.bodies(listPath).count
                let more = step["more"] != nil
                let answer = try #require(step["refresh"] ?? step["more"], "\(name) step \(i): refresh or more")
                rig.network.replies[listPath] = (200, text(answer))
                if more { rig.graine.chat.loadMorePastSessions() } else { rig.graine.chat.refreshPastSessions() }
                let sent = rig.network.bodies(listPath)
                #expect(sent.count == before + 1, "\(name) step \(i): one request")
                #expect(sent.last?["cursor"] as? String == (more ? cursor : nil), "\(name) step \(i): load more carries the cursor before it")
                let state = rig.graine.chat.pastSessions
                #expect(state.sessions.map(\.id) == states[i]["ids"] as? [String], "\(name) step \(i)")
                #expect(state.hasMore == states[i]["hasMore"] as? Bool, "\(name) step \(i)")
                #expect(!state.loading && state.error == nil, "\(name) step \(i)")
                cursor = (answer as? [String: Any])?["next"] as? String
            }
        }
    }

    @Test func everyRefusalIsKeptAsItsWordAndThrownByATranscript() async throws {
        for c in try Vectors.section("refusals") {
            let name = c["name"] as? String ?? "?"
            let status = try #require((c["status"] as? NSNumber)?.intValue)
            let body = text(try #require(c["body"]))
            let word = try #require(c["error"] as? String)
            let rig = identified()
            defer { rig.sandbox.clean() }
            rig.network.replies[listPath] = (200, page(["a1"], next: "c2"))
            rig.graine.chat.refreshPastSessions()
            let kept = rig.graine.chat.pastSessions.sessions
            rig.network.replies[listPath] = (status, body)
            rig.graine.chat.refreshPastSessions()
            #expect(rig.graine.chat.pastSessions == GrainePastSessions(sessions: kept, loading: false, hasMore: true, error: word), "\(name): what was loaded stays")
            rig.graine.chat.loadMorePastSessions()
            #expect(rig.network.bodies(listPath).last?["cursor"] as? String == "c2", "\(name)")
            #expect(rig.graine.chat.pastSessions.error == word, "\(name): load more refused the same way")
            rig.graine.chat.loadMorePastSessions()
            #expect(rig.network.bodies(listPath).count == 4, "\(name): asked again, for the same page")
            #expect(rig.network.bodies(listPath).last?["cursor"] as? String == "c2", "\(name)")

            rig.network.replies[transcriptPath] = (status, body)
            do {
                _ = try await rig.graine.chat.sessionTranscript(id: "ex-7a1c0001")
                Issue.record("\(name): expected \(word)")
            } catch let error as GraineServiceError {
                #expect(error.code.wire == word, "\(name)")
                #expect(error.status == status, "\(name)")
            }
        }
    }

    @Test func noAnswerAtAllIsNetwork() {
        let rig = identified()
        defer { rig.sandbox.clean() }
        rig.network.replies[listPath] = (0, nil)
        rig.graine.chat.refreshPastSessions()
        #expect(rig.graine.chat.pastSessions == GrainePastSessions(error: "network"))
    }

    @Test func aTranscriptIsAskedForTheIdentifiedUserAndReadInTheSDKsWords() async throws {
        let vector = try #require(try Vectors.section("transcripts").first)
        let rig = identified()
        defer { rig.sandbox.clean() }
        rig.network.replies[transcriptPath] = (200, text(try #require(vector["response"])))
        let transcript = try await rig.graine.chat.sessionTranscript(id: "  ex-7a1c0001 ")
        let want = try (try #require(vector["turns"] as? [[String: Any]])).map { try Vectors.turn($0) }
        #expect(transcript.turns == want)
        #expect(transcript.id == "ex-7a1c0001")
        #expect(transcript.channel == .chat && transcript.status == "completed" && transcript.durationSeconds == 276)
        let body = try #require(rig.network.bodies(transcriptPath).first)
        #expect(body["id"] as? String == "ex-7a1c0001", "the id, trimmed")
        #expect((body["identity"] as? [String: Any])?["value"] as? String == "u-1")
        #expect(body["installId"] as? String == "3f2504e0-4f89-11d3-9a0c-0305e82c3301")
        #expect(body["publishableKey"] as? String == "pk_test_rig")
        #expect(rig.graine.chat.pastSessions == GrainePastSessions(), "a transcript is not the list")
    }

    @Test func aBlankIdOrNobodyIdentifiedAsksNothing() async throws {
        let rig = identified(nil)
        defer { rig.sandbox.clean() }
        await #expect(throws: GraineServiceError(code: .invalidRequest, message: "No session id.")) {
            _ = try await rig.graine.chat.sessionTranscript(id: "  ")
        }
        do {
            _ = try await rig.graine.chat.sessionTranscript(id: "ex-1")
            Issue.record("expected identity_required")
        } catch let error as GraineServiceError {
            #expect(error.code == .identityRequired)
        }
        #expect(rig.network.bodies(transcriptPath).isEmpty, "nobody to ask about: no request")

        rig.graine.chat.refreshPastSessions()
        #expect(rig.graine.chat.pastSessions == GrainePastSessions(error: "identity_required"))
        rig.graine.chat.loadMorePastSessions()
        #expect(rig.network.bodies(listPath).isEmpty, "nothing sent for nobody, and no page to load more of")
    }

    @Test func theListIsAskedForTheIdentifiedUserAndLoadMoreCarriesTheCursor() throws {
        let rig = identified()
        defer { rig.sandbox.clean() }
        rig.network.replies[listPath] = (200, page(["a1", "a2"], next: "c2"))
        rig.graine.chat.refreshPastSessions()
        let refresh = try #require(rig.network.bodies(listPath).first)
        #expect((refresh["identity"] as? [String: Any])?["value"] as? String == "u-1")
        #expect(refresh["installId"] as? String == "3f2504e0-4f89-11d3-9a0c-0305e82c3301")
        #expect(refresh["publishableKey"] as? String == "pk_test_rig")
        #expect(refresh["cursor"] == nil && refresh["limit"] == nil, "the first page, at Graine's own size")
        rig.network.replies[listPath] = (200, page(["a2", "a3"]))
        rig.graine.chat.loadMorePastSessions()
        let more = try #require(rig.network.bodies(listPath).last)
        #expect(more["cursor"] as? String == "c2")
        #expect((more["identity"] as? [String: Any])?["value"] as? String == "u-1")
        #expect(ids(rig) == ["a1", "a2", "a3"], "a2 is not listed twice")
        #expect(!rig.graine.chat.pastSessions.hasMore)
        rig.graine.chat.loadMorePastSessions()
        #expect(rig.network.bodies(listPath).count == 2, "the last page was the last")
    }

    @Test func loadMoreWaitsForAPageAndForTheOneOnItsWay() {
        let rig = identified()
        defer { rig.sandbox.clean() }
        rig.graine.chat.loadMorePastSessions()
        #expect(rig.network.bodies(listPath).isEmpty, "before any page: nothing to load more of")
        #expect(rig.graine.chat.pastSessions == GrainePastSessions())

        rig.network.holding = [listPath]
        rig.network.replies[listPath] = (200, page(["a1"], next: "c2"))
        rig.graine.chat.refreshPastSessions()
        #expect(rig.graine.chat.pastSessions == GrainePastSessions(loading: true))
        rig.graine.chat.loadMorePastSessions()
        #expect(rig.network.bodies(listPath).count == 1, "while a page is loading, load more waits")
        rig.network.release(listPath)
        #expect(rig.graine.chat.pastSessions == GrainePastSessions(sessions: rig.graine.chat.pastSessions.sessions, loading: false, hasMore: true))
        #expect(ids(rig) == ["a1"])

        rig.network.replies[listPath] = (200, page(["a1", "a2"]))
        rig.graine.chat.loadMorePastSessions()
        #expect(rig.graine.chat.pastSessions.loading)
        #expect(ids(rig) == ["a1"], "what was loaded stays while the next page loads")
        rig.graine.chat.loadMorePastSessions()
        #expect(rig.network.bodies(listPath).count == 2, "one page at a time")
        rig.network.release(listPath)
        #expect(ids(rig) == ["a1", "a2"])
        #expect(!rig.graine.chat.pastSessions.loading && !rig.graine.chat.pastSessions.hasMore)
    }

    @Test func aRefreshOnItsWayIsReplacedByTheNextOne() {
        let rig = identified()
        defer { rig.sandbox.clean() }
        rig.network.holding = [listPath]
        rig.network.replies[listPath] = (200, page(["old"], next: "c-old"))
        rig.graine.chat.refreshPastSessions()
        rig.network.replies[listPath] = (200, page(["new"]))
        rig.graine.chat.refreshPastSessions()
        #expect(rig.network.bodies(listPath).count == 2)
        rig.network.release(listPath)
        #expect(ids(rig) == ["new"], "the answer to the refresh before is not shown")
        #expect(!rig.graine.chat.pastSessions.hasMore && !rig.graine.chat.pastSessions.loading)
    }

    @Test func anotherUserOrSigningOutClearsThePastSessions() throws {
        let rig = identified()
        defer { rig.sandbox.clean() }
        rig.network.replies[listPath] = (200, page(["a1", "a2"], next: "c2"))
        rig.graine.chat.refreshPastSessions()
        #expect(ids(rig) == ["a1", "a2"])

        rig.graine.identify(["user_id": "u-2"])
        #expect(rig.graine.chat.pastSessions == GrainePastSessions(), "u-1's sessions are not u-2's")
        rig.graine.chat.loadMorePastSessions()
        #expect(rig.network.bodies(listPath).count == 1, "u-1's next page is nobody's to load")
        rig.graine.chat.refreshPastSessions()
        #expect((rig.network.bodies(listPath).last?["identity"] as? [String: Any])?["value"] as? String == "u-2")
        #expect(ids(rig) == ["a1", "a2"])

        rig.graine.identify(nil)
        #expect(rig.graine.chat.pastSessions == GrainePastSessions(), "signed out: nobody's")
        rig.graine.chat.refreshPastSessions()
        #expect(rig.graine.chat.pastSessions == GrainePastSessions(error: "identity_required"))
        #expect(rig.network.bodies(listPath).count == 2, "nothing asked for nobody")

        rig.graine.identify(["user_id": "u-1"])
        #expect(rig.graine.chat.pastSessions == GrainePastSessions(), "signing in clears the word for nobody too")
    }

    @Test func aPageOnItsWayForTheUserBeforeIsNeverShown() {
        let rig = identified()
        defer { rig.sandbox.clean() }
        rig.network.holding = [listPath]
        rig.network.replies[listPath] = (200, page(["a1"], next: "c2"))
        rig.graine.chat.refreshPastSessions()
        #expect(rig.graine.chat.pastSessions.loading)
        rig.graine.identify(["user_id": "u-2"])
        #expect(rig.graine.chat.pastSessions == GrainePastSessions(), "cleared, and not loading")
        rig.network.release(listPath)
        #expect(rig.graine.chat.pastSessions == GrainePastSessions(), "u-1's page is never shown to u-2")

        // A next page on its way when the identity changes goes the same way.
        rig.network.holding = []
        rig.network.replies[listPath] = (200, page(["b1"], next: "c2"))
        rig.graine.chat.refreshPastSessions()
        rig.network.holding = [listPath]
        rig.network.replies[listPath] = (200, page(["b2"]))
        rig.graine.chat.loadMorePastSessions()
        rig.graine.identify(nil)
        rig.network.release(listPath)
        #expect(rig.graine.chat.pastSessions == GrainePastSessions())
    }

    @Test func theSameIdentityWithOtherTraitsOrAnotherMemoryChoiceKeepsThem() {
        let rig = identified()
        defer { rig.sandbox.clean() }
        rig.network.replies[listPath] = (200, page(["a1"], next: "c2"))
        rig.graine.chat.refreshPastSessions()
        let before = rig.graine.chat.pastSessions
        rig.graine.identify(["user_id": "u-1", "name": "Meera", "plan": "Gold"], memory: false)
        rig.graine.setMemory(true)
        #expect(rig.graine.chat.pastSessions == before)
        rig.network.replies[listPath] = (200, page(["a2"]))
        rig.graine.chat.loadMorePastSessions()
        #expect(rig.network.bodies(listPath).last?["cursor"] as? String == "c2", "the next page is still theirs")
        #expect(ids(rig) == ["a1", "a2"])
    }

    @Test func aTranscriptThatArrivesAfterTheIdentityChangedIsNotFound() async throws {
        let rig = identified()
        defer { rig.sandbox.clean() }
        let vector = try #require(try Vectors.section("transcripts").first)
        rig.network.replies[transcriptPath] = (200, text(try #require(vector["response"])))
        // Another user signs in while the request is on its way.
        rig.network.beforeAnswer[transcriptPath] = {
            let other = { rig.graine.identify(["user_id": "u-2"]) }
            if Thread.isMainThread { other() } else { DispatchQueue.main.sync(execute: other) }
        }
        do {
            _ = try await rig.graine.chat.sessionTranscript(id: "ex-7a1c0001")
            Issue.record("expected not_found")
        } catch let error as GraineServiceError {
            #expect(error.code == .notFound, "u-1's session is not u-2's")
        }
        #expect((rig.network.bodies(transcriptPath).first?["identity"] as? [String: Any])?["value"] as? String == "u-1")
    }
}

// MARK: - Through the Objective-C facade, as a bridge reads it

@Suite @MainActor struct PastSessionsObjCTests {
    private func parse(_ text: String?) -> Any? {
        text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
    }

    @Test func aBridgeReadsThePastSessionsAndATranscriptInTheWiresShape() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session(field)
        let graine = GraineObjC(graine: rig.graine)
        graine.identify(["user_id": "P-1"])
        let pages = try Vectors.section("pages")
        rig.network.replies[listPath] = (200, text(try #require(pages[0]["response"])))
        var changes = 0
        let registration = graine.chat.observe { changes += 1 }
        defer { registration.unregister() }

        let empty = try #require(parse(graine.chat.pastSessionsJSON) as? [String: Any])
        #expect(JSON.canonical(empty) == JSON.canonical(["sessions": [], "loading": false, "hasMore": false, "error": NSNull()] as [String: Any]))
        graine.chat.refreshPastSessions()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(changes > 0, "observers hear the change")
        let state = try #require(parse(graine.chat.pastSessionsJSON) as? [String: Any])
        #expect(JSON.canonical(state["sessions"]) == JSON.canonical(pages[0]["sessions"]), "the contract's sessions, in the wire's shape")
        #expect(state["loading"] as? Bool == false)
        #expect(state["hasMore"] as? Bool == true)
        #expect(state["error"] is NSNull)

        rig.network.replies[listPath] = (200, text(try #require(pages[2]["response"])))
        graine.chat.loadMorePastSessions()
        #expect(rig.network.bodies(listPath).last?["cursor"] as? String == "c2")
        let more = try #require(parse(graine.chat.pastSessionsJSON) as? [String: Any])
        #expect((more["sessions"] as? [[String: Any]])?.map { $0["id"] as? String } == ["ex-7a1c0001", "ex-31f00002", "ex-voice0004"])
        #expect((more["sessions"] as? [[String: Any]])?.last?["direction"] as? String == "inbound")
        #expect(more["hasMore"] as? Bool == false)

        let vector = try #require(try Vectors.section("transcripts").first)
        rig.network.replies[transcriptPath] = (200, text(try #require(vector["response"])))
        let answered = await withCheckedContinuation { c in
            graine.chat.sessionTranscriptJSON(id: "ex-7a1c0001") { json, error in c.resume(returning: (json, error)) }
        }
        #expect(answered.1 == nil)
        let transcript = try #require(parse(answered.0) as? [String: Any])
        #expect(transcript["id"] as? String == "ex-7a1c0001")
        #expect(transcript["direction"] is NSNull)
        #expect((transcript["durationSeconds"] as? NSNumber)?.intValue == 276)
        let turns = try #require(transcript["turns"] as? [[String: Any]])
        #expect(turns.map { $0["role"] as? String } == ["assistant", "user", "assistant"], "the wire's words")
        #expect(turns.map { $0["at"] as? String } == ["2026-10-21T12:00:05Z", "2026-10-21T12:00:20Z", "2026-10-21T12:00:25Z"])

        rig.network.replies[transcriptPath] = (404, #"{"error":"Session not found.","code":"not_found"}"#)
        let refused = await withCheckedContinuation { c in
            graine.chat.sessionTranscriptJSON(id: "ex-someone-else") { json, error in c.resume(returning: (json, error)) }
        }
        #expect(refused.0 == nil)
        #expect(refused.1?.domain == "ai.graine.inapp")
        #expect(refused.1?.code == 404)
        #expect(refused.1?.userInfo["code"] as? String == "not_found")
        #expect(refused.1?.localizedDescription == "Session not found.")

        graine.identifyJSON(nil)
        let cleared = try #require(parse(graine.chat.pastSessionsJSON) as? [String: Any])
        #expect((cleared["sessions"] as? [Any])?.isEmpty == true, "signed out: cleared")
    }
}
