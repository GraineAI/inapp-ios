import Foundation
import Testing
@_spi(GraineRTC) @testable import GraineInApp

/*
 * THE AGENT'S FACE — the frame's reader and the host messages against
 * contract/avatar.json, the hand-over rules against contract/avatar-voice.json
 * (both generated from the TypeScript the web engine runs), and one call's
 * face (AvatarFace) with a stand-in viewer, a stand-in network and the clock
 * moved by hand.
 */

@Suite struct AvatarWireContractTests {
    @Test func everyFrameCaseReadsAsTheWebReadsIt() throws {
        let c = try ContractFile.load("avatar.json")
        let cases = try #require(c["cases"] as? [[String: Any]])
        #expect(cases.count >= 20)
        for v in cases {
            let name = v["name"] as? String ?? "?"
            let got = AvatarWire.read(v["frame"])
            let want = v["read"] as? [String: Any]
            guard let want = want else {
                #expect(got == nil, "\(name)")
                continue
            }
            switch got {
            case .ready(let s)?:
                let ws = try #require(want["session"] as? [String: Any], "\(name)")
                #expect(want["state"] as? String == "ready", "\(name)")
                #expect(s.id == ws["id"] as? String, "\(name)")
                #expect(s.url == ws["url"] as? String, "\(name)")
                #expect(s.token == ws["token"] as? String, "\(name)")
                #expect(s.expiresAt == (ws["expiresAt"] as? NSNumber)?.doubleValue, "\(name)")
            case .unavailable(let reason)?:
                #expect(want["state"] as? String == "unavailable", "\(name)")
                #expect(reason == want["reason"] as? String, "\(name)")
            case .ended?:
                #expect(want["state"] as? String == "ended", "\(name)")
            case nil:
                Issue.record("\(name): read nothing, the web reads \(want)")
            }
        }
    }

    @Test func hostMessagesAndSurfaces() throws {
        let c = try ContractFile.load("avatar.json")
        let host = try #require(c["host"] as? [String: Any])
        #expect(host["to_host"] as? String == AvatarWire.hostState)
        #expect(host["to_page"] as? String == AvatarWire.surface)
        for v in try #require(host["cases"] as? [[String: Any]]) {
            let got = AvatarWire.hostMessage(state: v["state"] as? String ?? "", reason: v["reason"] as? String)
            let want = v["message"] as? [String: Any]
            #expect((got as NSDictionary?) == (want as NSDictionary?), "\(v)")
            // What a host reads back from the page is what the page sends.
            if let want = want {
                let read = try #require(AvatarWire.readHostMessage(want))
                #expect(read.state == want["state"] as? String)
                #expect(read.reason == want["reason"] as? String)
            }
        }
        for v in try #require(host["surfaces"] as? [[String: Any]]) {
            #expect(AvatarWire.readSurface(v["message"]) == v["shown"] as? Bool, "\(v)")
        }
        #expect(AvatarWire.readSurface(AvatarWire.surfaceMessage(shown: true)) == true)
    }

    @Test func stateForABridge() {
        #expect(AvatarWire.stateJSON(.off) == #"{"phase":"off","reason":null}"#)
        #expect(AvatarWire.stateJSON(GraineAvatarState(phase: .off, reason: "busy")) == #"{"phase":"off","reason":"busy"}"#)
        #expect(AvatarWire.stateJSON(GraineAvatarState(phase: .live, reason: "busy")) == #"{"phase":"live","reason":null}"#)
    }
}

@Suite struct AvatarFoldContractTests {
    private func event(_ e: [String: Any]) throws -> AvatarFoldEvent {
        let at = (e["at"] as? NSNumber)?.doubleValue ?? 0
        switch e["type"] as? String {
        case "frame": return .frame(try #require(AvatarWire.read(e["frame"])), at: at)
        case "surface": return .surface(e["shown"] as? Bool ?? false, at: at)
        case "playing": return .playing(at: at)
        case "blocked": return .blocked(at: at)
        case "failed": return .failed(at: at)
        case "call_ended": return .callEnded(at: at)
        case "sample":
            return .sample(at: at, frames: (e["frames"] as? NSNumber)?.doubleValue, face: (e["face"] as? NSNumber)?.doubleValue,
                           agent: (e["agent"] as? NSNumber)?.doubleValue ?? 0)
        default:
            throw ContractFile.NotFound(name: "event \(e)", searchedFrom: "")
        }
    }

    @Test func constantsAreTheWebEngines() throws {
        let c = try #require(try ContractFile.load("avatar-voice.json")["constants"] as? [String: Double])
        #expect(c["sample_ms"] == AvatarFold.sampleMs)
        #expect(c["stall_ms"] == AvatarFold.stallMs)
        #expect(c["first_frame_ms"] == AvatarFold.firstFrameMs)
        #expect(c["resume_ms"] == AvatarFold.resumeMs)
        #expect(c["stalled_max_ms"] == AvatarFold.stalledMaxMs)
        #expect(c["max_stalls"] == Double(AvatarFold.maxStalls))
        #expect(c["quiet_samples"] == Double(AvatarFold.quietSamples))
        #expect(c["quiet_level"] == AvatarFold.quietLevel)
        #expect(c["speech_level"] == AvatarFold.speechLevel)
        #expect(c["face_quiet"] == AvatarFold.faceQuiet)
        #expect(c["face_heard"] == AvatarFold.faceHeard)
        #expect(c["voice_window"] == Double(AvatarFold.voiceWindow))
        #expect(c["voice_speech_min"] == Double(AvatarFold.voiceSpeechMin))
    }

    @Test func everyScenarioStepByStep() throws {
        let scenarios = try #require(try ContractFile.load("avatar-voice.json")["scenarios"] as? [[String: Any]])
        #expect(scenarios.count >= 15)
        for sc in scenarios {
            let name = sc["name"] as? String ?? "?"
            var s = AvatarFoldState(shown: sc["shown"] as? Bool ?? false)
            for (i, step) in (sc["steps"] as? [[String: Any]] ?? []).enumerated() {
                s = AvatarFold.fold(s, try event(step["event"] as? [String: Any] ?? [:]))
                let want = try #require(step["expect"] as? [String: Any])
                let at = "\(name) step \(i)"
                #expect(s.phase.rawValue == want["phase"] as? String, "\(at)")
                #expect(s.reason == want["reason"] as? String, "\(at)")
                #expect(s.session?.id == want["session"] as? String, "\(at)")
                #expect(AvatarFold.agentAudible(s) == want["agent_audible"] as? Bool, "\(at)")
                #expect(AvatarFold.faceAudible(s) == want["face_audible"] as? Bool, "\(at)")
                #expect(AvatarFold.mounted(s) == want["mounted"] as? Bool, "\(at)")
                #expect(AvatarFold.visible(s) == want["visible"] as? Bool, "\(at)")
                let host = try #require(want["host"] as? [String: Any])
                let got = AvatarFold.hostState(s)
                #expect(got.state == host["state"] as? String, "\(at)")
                #expect(got.reason == host["reason"] as? String, "\(at)")
                #expect(AvatarFold.agentAudible(s) != AvatarFold.faceAudible(s), "\(at): one voice, exactly")
            }
        }
    }

    @Test func meterScale() {
        #expect(AvatarFold.meterLevel(meanAbs: 0) == 0)
        #expect(AvatarFold.meterLevel(meanAbs: 0.25) == 1)
        #expect(AvatarFold.meterLevel(meanAbs: 0.01) == 0.2)
        #expect(AvatarFold.meterLevel(meanAbs: .nan) == 0)
    }
}

@Suite struct AvatarViewerWireTests {
    let session = GraineAvatarSession(id: "f:1", url: "https://face.example.com/v", token: "tok", expiresAt: 2_000)

    @Test func requests() throws {
        #expect(AvatarViewerWire.iceURL(session)?.absoluteString == "https://face.example.com/v/v1/sessions/f%3A1/ice")
        #expect(AvatarViewerWire.offerURL(session)?.absoluteString == "https://face.example.com/v/v1/sessions/f%3A1/offer")
        #expect(AvatarViewerWire.authorization(session) == "Bearer tok")
        #expect(AvatarViewerWire.expired(session, now: 2_001))
        #expect(!AvatarViewerWire.expired(session, now: 1_999))
        let body = try #require(JSON.object(from: AvatarViewerWire.offerBody(sdp: "v=0\r\n")))
        #expect(body["type"] as? String == "offer" && body["sdp"] as? String == "v=0\r\n")
        #expect(AvatarViewerWire.answer(from: Data(#"{"type":"answer","sdp":"v=0"}"#.utf8)) == "v=0")
        #expect(AvatarViewerWire.answer(from: Data(#"{"type":"offer","sdp":"v=0"}"#.utf8)) == nil)
    }

    @Test func iceServersAreKeptOnlyWhenTheyAreIceServers() {
        let body = Data(#"""
        {"iceServers":[{"urls":"stun:stun.example.com:3478"},
         {"urls":["turn:t.example.com:3478?transport=udp","turns:t.example.com:443?transport=tcp"],"username":"u","credential":"c"},
         {"urls":"face:not-ice"},{"urls":[]},{"nothing":1}]}
        """#.utf8)
        let servers = AvatarViewerWire.iceServers(from: body)
        #expect(servers.count == 2)
        #expect(servers[1].urls.count == 2 && servers[1].username == "u" && servers[1].credential == "c")
        #expect(AvatarViewerWire.iceServers(from: Data("{}".utf8)).isEmpty)
    }

    @Test func theClock() {
        var clock = AvatarClock()
        #expect(clock.receive(#"{"type":"clock","epoch":3,"samples":4800}"#) == .ack(samples: 4800, epoch: 3, delayMs: 150))
        #expect(clock.receive(#"{"type":"clock","epoch":3,"samples":4800}"#) == nil, "the same sample once")
        clock.playoutDelayMs = 90
        #expect(clock.receive(#"{"type":"interrupted","epoch":4}"#) == .interrupted(muteMs: 150))
        #expect(!clock.current(3) && clock.current(4))
        #expect(clock.receive(#"{"type":"error","message":"x"}"#) == .failed)
        #expect(clock.receive(#"{"type":"speaking"}"#) == nil)
        #expect(AvatarViewerWire.playedMessage(samples: 4800, epoch: 3) == #"{"type":"played","samples":4800,"epoch":3}"#)
        #expect(AvatarViewerWire.playoutDelayMs(jitterBufferDelay: 0.6, emittedCount: 10) == 100)
        #expect(AvatarViewerWire.playoutDelayMs(jitterBufferDelay: 60, emittedCount: 10) == 500)
        #expect(AvatarViewerWire.playoutDelayMs(jitterBufferDelay: 0, emittedCount: 10) == 60)
        #expect(AvatarViewerWire.playoutDelayMs(jitterBufferDelay: 1, emittedCount: 0) == nil)
    }
}

// MARK: - One call's face, with stand-ins

final class FakeAvatarViewer: GraineAvatarViewer {
    var onEvent: ((GraineAvatarViewerEvent) -> Void)?
    var offeredWith: [GraineAvatarIceServer]?
    var answer: String?
    var sent: [String] = []
    var audible: [Bool] = []
    var closed = false
    var frames: Double = 0
    var face: Double? = 0
    var videoView: AnyObject? { self }

    func offer(iceServers: [GraineAvatarIceServer], gatherSeconds: Double, done: @escaping (String?, String?) -> Void) {
        offeredWith = iceServers
        done("v=0 offer", nil)
    }

    func applyAnswer(_ sdp: String, done: @escaping (String?) -> Void) {
        answer = sdp
        done(nil)
    }

    func send(_ text: String) { sent.append(text) }
    func setAudible(_ audible: Bool) { self.audible.append(audible) }
    func sample(_ done: @escaping (Double?, Double?, Double?, Double?) -> Void) { done(frames, face, 0.6, 10) }
    func close() { closed = true }
}

final class FakeAvatarHTTP: AvatarHTTP {
    var requests: [(method: String, url: String, auth: String?)] = []
    var iceStatus = 200
    var offerStatuses: [Int] = []

    func request(_ url: URL, method: String, headers: [String: String], body: Data?, timeout: Double, done: @escaping (Int?, Data?) -> Void) {
        requests.append((method, url.absoluteString, headers["Authorization"]))
        if url.path.hasSuffix("/ice") {
            done(iceStatus, Data(#"{"iceServers":[{"urls":"turns:turn.example.com:443?transport=tcp","username":"u","credential":"c"}]}"#.utf8))
        } else {
            let status = offerStatuses.isEmpty ? 200 : offerStatuses.removeFirst()
            done(status, status == 200 ? Data(#"{"type":"answer","sdp":"v=0 answer"}"#.utf8) : Data())
        }
    }
}

final class AvatarFaceRig {
    let scheduler = ManualScheduler()
    let http = FakeAvatarHTTP()
    var viewers: [FakeAvatarViewer] = []
    var canView = true
    var agentLevel = 0.0
    var agentAudible: [Bool] = []
    var states: [GraineAvatarState] = []
    var shownViewer: GraineAvatarViewer?
    lazy var face = AvatarFace(scheduler: scheduler, http: http, wallClock: { 1_000 }, hooks: AvatarFace.Hooks(
        makeViewer: { [unowned self] in
            guard self.canView else { return nil }
            let v = FakeAvatarViewer()
            self.viewers.append(v)
            return v
        },
        agentLevel: { [unowned self] in self.agentLevel },
        setAgentAudible: { [unowned self] in self.agentAudible.append($0) },
        onState: { [unowned self] in self.states.append($0) },
        onViewer: { [unowned self] in self.shownViewer = $0 }
    ))

    static let ready: [String: Any] = [
        "type": "avatar", "state": "ready",
        "session": ["id": "face_1", "url": "https://face.example.com", "token": "tok", "expires_at": 2_000, "publisher_token": "never"],
    ]

    var viewer: FakeAvatarViewer { viewers.last! }

    /// Frames flowing for `seconds` (6 every sample).
    func flow(_ seconds: Double, face level: Double = 0, agent: Double = 0) {
        let steps = Int((seconds / 0.25).rounded())
        for _ in 0..<steps {
            viewers.last?.frames += 6
            viewers.last?.face = level
            agentLevel = agent
            scheduler.advance(0.25)
        }
    }
}

@Suite struct AvatarFaceTests {
    @Test func aFaceNobodyCanSeeIsNeverWatched() {
        let rig = AvatarFaceRig()
        rig.face.surface(false)
        rig.face.frame(AvatarFaceRig.ready)
        #expect(rig.viewers.isEmpty && rig.http.requests.isEmpty)
        #expect(rig.states.last == GraineAvatarState(phase: .available), "the app is told: show your avatar view")
        rig.face.surface(true)
        #expect(rig.viewers.count == 1)
    }

    @Test func connectsOverWebRTCAndTakesTheVoiceAtAGap() {
        let rig = AvatarFaceRig()
        rig.face.surface(true)
        rig.face.frame(AvatarFaceRig.ready)
        // The viewer's own requests, with its bearer token only.
        #expect(rig.http.requests.map { $0.method } == ["GET", "POST"])
        #expect(rig.http.requests[0].url == "https://face.example.com/v1/sessions/face_1/ice")
        #expect(rig.http.requests.allSatisfy { $0.auth == "Bearer tok" })
        #expect(rig.viewer.offeredWith?.first?.urls == ["turns:turn.example.com:443?transport=tcp"])
        #expect(rig.viewer.answer == "v=0 answer")
        #expect(rig.viewer.audible == [false], "silent until it carries the voice")
        rig.viewer.onEvent?(.channelOpen)
        #expect(rig.viewer.sent == [AvatarViewerWire.readyMessage])
        rig.viewer.onEvent?(.connection("connected"))
        #expect(rig.shownViewer === rig.viewer, "drawn once it plays")
        // The agent speaking: no hand-over.
        rig.flow(1, face: 0.3, agent: 0.5)
        #expect(rig.agentAudible.isEmpty)
        // A gap: the face takes the voice, the call's copy is silenced.
        rig.flow(0.5)
        #expect(rig.agentAudible == [false])
        #expect(rig.viewer.audible.last == true)
        #expect(rig.states.last == GraineAvatarState(phase: .live))
        // Frames stop: within 2 s the voice is the call's again, and the face is silent.
        rig.scheduler.advance(2.25)
        #expect(rig.agentAudible.last == true)
        #expect(rig.viewer.audible.last == false)
        // The call ends: the viewer goes.
        rig.face.callEnded()
        #expect(rig.viewer.closed)
        #expect(rig.states.last?.phase == .off)
    }

    @Test func aCallWithNoViewerIsUnsupportedAndStaysVoiceOnly() {
        let rig = AvatarFaceRig()
        rig.canView = false
        rig.face.surface(true)
        rig.face.frame(AvatarFaceRig.ready)
        #expect(rig.states.last == GraineAvatarState(phase: .off, reason: "unsupported"))
        #expect(rig.http.requests.isEmpty)
        #expect(rig.agentAudible.isEmpty)
        rig.scheduler.advance(20)
        #expect(rig.states.last == GraineAvatarState(phase: .off, reason: "unsupported"))
    }

    @Test func theClockIsAnsweredOnceHeardAndAnInterruptionSilencesTheFace() {
        let rig = AvatarFaceRig()
        rig.face.surface(true)
        rig.face.frame(AvatarFaceRig.ready)
        rig.viewer.onEvent?(.channelOpen)
        rig.viewer.onEvent?(.connection("connected"))
        rig.flow(0.5)
        #expect(rig.states.last?.phase == .live)
        rig.viewer.onEvent?(.message(#"{"type":"clock","epoch":0,"samples":2400}"#))
        #expect(!rig.viewer.sent.contains { $0.contains("played") }, "never acked on arrival")
        rig.viewer.frames += 6
        rig.scheduler.advance(0.2)
        #expect(rig.viewer.sent.last == AvatarViewerWire.playedMessage(samples: 2400, epoch: 0))
        rig.viewer.onEvent?(.message(#"{"type":"clock","epoch":0,"samples":4800}"#))
        rig.viewer.onEvent?(.message(#"{"type":"interrupted","epoch":1}"#))
        #expect(rig.viewer.audible.last == false, "stale audio drains silently")
        rig.viewer.frames += 6
        rig.scheduler.advance(0.2)
        #expect(!rig.viewer.sent.contains { $0.contains("4800") }, "an interrupted epoch is never acked")
        rig.flow(0.25)
        #expect(rig.viewer.audible.last == true, "heard again once drained")
        // A ping keeps the viewer from looking idle.
        rig.flow(15)
        #expect(rig.viewer.sent.contains(AvatarViewerWire.pingMessage))
    }

    @Test func aLostConnectionIsMadeAgainWithAFreshOfferPatiently() {
        let rig = AvatarFaceRig()
        rig.face.surface(true)
        rig.face.frame(AvatarFaceRig.ready)
        rig.viewer.onEvent?(.connection("connected"))
        rig.flow(0.5)
        #expect(rig.states.last?.phase == .live)
        let first = rig.viewer
        // The service still holds the dead viewer for a moment: 409, then it answers.
        rig.http.offerStatuses = [409, 200]
        first.onEvent?(.connection("failed"))
        #expect(first.closed)
        #expect(rig.viewers.count == 2, "a fresh peer and offer at once")
        #expect(rig.viewers[1].closed, "its 409: let go, tried again in 2 s")
        rig.scheduler.advance(2)
        #expect(rig.viewers.count == 3)
        #expect(rig.viewer.answer == "v=0 answer")
        #expect(rig.agentAudible == [false, true], "frames stopped: the voice went back to the call meanwhile")
        rig.viewer.onEvent?(.connection("connected"))
        rig.flow(1.25)
        rig.flow(0.5)
        #expect(rig.states.last?.phase == .live, "back with the voice once frames flow for a second and a gap comes")
        #expect(rig.agentAudible.last == false)
        // Disconnected for 4 s is lost too; every attempt failing for 40 s ends the face, and the voice is the call's.
        rig.viewer.onEvent?(.connection("disconnected"))
        rig.scheduler.advance(3.9)
        #expect(rig.viewers.count == 3)
        rig.scheduler.advance(0.2)
        #expect(rig.viewers.count == 4)
        for _ in 0..<30 {
            rig.viewer.onEvent?(.connection("failed"))
            rig.scheduler.advance(2)
        }
        #expect(rig.states.last == GraineAvatarState(phase: .off, reason: "failed"))
        #expect(rig.agentAudible.last == true)
        #expect(rig.viewers.allSatisfy { $0.closed })
    }

    @Test func aFinalRefusalAndNoFirstFrameWithin25sAndExpiredTokensFail() {
        let rig = AvatarFaceRig()
        rig.face.surface(true)
        rig.http.iceStatus = 401
        rig.face.frame(AvatarFaceRig.ready)
        #expect(rig.states.last == GraineAvatarState(phase: .off, reason: "failed"))
        #expect(rig.viewer.closed)

        let busy = AvatarFaceRig()
        busy.face.surface(true)
        busy.http.offerStatuses = Array(repeating: 503, count: 20)
        busy.face.frame(AvatarFaceRig.ready)
        busy.scheduler.advance(16)
        #expect(busy.states.last == GraineAvatarState(phase: .available), "still trying within 20 s")
        busy.scheduler.advance(4)
        #expect(busy.states.last == GraineAvatarState(phase: .off, reason: "failed"))

        let late = AvatarFaceRig()
        late.face.surface(true)
        late.face.frame(AvatarFaceRig.ready)
        late.scheduler.advance(24.75)
        #expect(late.states.last == GraineAvatarState(phase: .available))
        late.scheduler.advance(0.5)
        #expect(late.states.last == GraineAvatarState(phase: .off, reason: "failed"))

        let expired = AvatarFaceRig()
        expired.face.surface(true)
        var frame = AvatarFaceRig.ready
        frame["session"] = ["id": "face_1", "url": "https://face.example.com", "token": "tok", "expires_at": 999]
        expired.face.frame(frame)
        #expect(expired.http.requests.isEmpty)
        #expect(expired.states.last == GraineAvatarState(phase: .off, reason: "failed"))
    }

    @Test func unavailableAndHiddenGiveTheVoiceBackAtOnce() {
        let rig = AvatarFaceRig()
        rig.face.surface(true)
        rig.face.frame(AvatarFaceRig.ready)
        rig.viewer.onEvent?(.connection("connected"))
        rig.flow(0.5)
        #expect(rig.agentAudible == [false])
        rig.face.surface(false)
        #expect(rig.agentAudible == [false, true])
        #expect(rig.viewer.closed, "a face nobody can see is not watched")
        rig.face.surface(true)
        #expect(rig.viewers.count == 2)
        rig.viewer.onEvent?(.connection("connected"))
        rig.flow(0.5)
        #expect(rig.agentAudible.last == false)
        rig.face.frame(["type": "avatar", "state": "unavailable", "reason": "busy"])
        #expect(rig.agentAudible.last == true)
        #expect(rig.states.last == GraineAvatarState(phase: .off, reason: "busy"))
    }
}
