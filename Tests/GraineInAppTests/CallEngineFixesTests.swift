import Foundation
import Testing
@testable import GraineInApp

/*
 * What the live run against production showed the call engine needed:
 * one deadline over everything before the socket, the variables on the
 * direct socket's URL only, a call that waits for CallKit's audio and fails
 * clearly when it never comes, and a call that starts with the session it
 * already has.
 */

/// A network whose ticket answers only when the test says.
private final class HeldNetwork: CallNetwork {
    private(set) var posts = 0
    private var pending: ((Int, Data?) -> Void)?
    private(set) var sockets: [FakeSocket] = []

    func post(_ url: URL, body: Data, completion: @escaping (Int, Data?) -> Void) {
        posts += 1
        pending = completion
    }

    func answerTicket(_ status: Int = 200, _ body: String = #"{"ticket":"tkt-1","wsUrl":"wss://ws.graine.ai/v1/embed"}"#) {
        pending?(status, Data(body.utf8))
        pending = nil
    }

    func openSocket(_ url: URL, protocols: [String], events: CallSocketEvents) -> CallSocket {
        let socket = FakeSocket(url: url, protocols: protocols, events: events)
        sockets.append(socket)
        return socket
    }
}

/// An engine whose session and ticket arrive when the test says.
private final class SlowRig {
    let scheduler = ManualScheduler()
    let network = HeldNetwork()
    let audio = ScriptedAudio()
    private(set) var events: [CallEngine.Event] = []
    private var sessionDone: ((GraineSessionConfig?) -> Void)?
    private(set) lazy var engine = CallEngine(
        setup: CallEngine.Setup(
            publishableKey: "pk_test_rig",
            baseUrl: "https://www.graine.ai",
            variables: [("who_called", "customer")],
            contextFrame: { nil },
            session: { [unowned self] done in self.sessionDone = done },
            runAction: { _, _, answer in answer(.refused("none")) }
        ),
        audio: audio,
        network: network,
        scheduler: scheduler,
        onEvent: { [unowned self] in self.events.append($0) }
    )

    func deliverSession() {
        sessionDone?(GraineSessionConfig(agentId: "agent-1", webcallAgentId: "web-1"))
        sessionDone = nil
    }

    var endings: [CallEngine.Ending] {
        events.compactMap { if case .ended(let e) = $0 { return e }; return nil }
    }
}

@Suite struct CallConnectDeadlineTests {
    static let failure = CallEngine.Ending.couldNotOpen("The call could not connect within 20 seconds.")

    @Test func aSessionThatNeverArrivesFailsTheCallAt20Seconds() {
        let rig = SlowRig()
        rig.engine.start()
        rig.scheduler.advance(19.9)
        #expect(rig.endings.isEmpty)
        rig.scheduler.advance(0.2)
        #expect(rig.endings == [Self.failure])
        #expect(rig.network.posts == 0)
        #expect(rig.audio.stopped)
        // A session that turns up afterwards opens nothing.
        rig.deliverSession()
        #expect(rig.network.posts == 0)
        #expect(rig.network.sockets.isEmpty)
    }

    @Test func aTicketThatNeverAnswersFailsTheCallAt20Seconds() {
        let rig = SlowRig()
        rig.engine.start()
        rig.deliverSession()
        #expect(rig.network.posts == 1)
        rig.scheduler.advance(20.1)
        #expect(rig.endings == [Self.failure])
        rig.network.answerTicket()
        #expect(rig.network.sockets.isEmpty, "a ticket that answers after the deadline opens nothing")
    }

    @Test func theDeadlineCoversTheWholeOpeningNotEachStep() throws {
        // The session takes 12 s; the socket would have had its own 15 s, to 27 s. The call fails at 20 s.
        let rig = SlowRig()
        rig.engine.start()
        rig.scheduler.advance(12)
        rig.deliverSession()
        rig.network.answerTicket()
        let socket = try #require(rig.network.sockets.first)
        rig.scheduler.advance(7.9)
        #expect(rig.endings.isEmpty)
        rig.scheduler.advance(0.2)
        #expect(rig.endings == [Self.failure])
        #expect(socket.closed)
    }

    @Test func aSocketThatOpensInTimeIsNeverFailedLater() throws {
        let rig = SlowRig()
        rig.engine.start()
        rig.scheduler.advance(10)
        rig.deliverSession()
        rig.network.answerTicket()
        let socket = try #require(rig.network.sockets.first)
        rig.scheduler.advance(9)
        socket.open()
        rig.scheduler.advance(60)
        #expect(rig.endings.isEmpty)
        #expect(socket.sentTypes.first == "init")
    }
}

@Suite struct CallContextTokenTests {
    @Test func theGatewayUrlCarriesNoVariablesAndKeepsItsOwnQuery() throws {
        let rig = EngineRig()
        rig.network.ticketReply = (200, Data(#"{"ticket":"tkt-1","wsUrl":"wss://ws.graine.ai/embed/v1/web-1?region=in"}"#.utf8))
        rig.engine.start()
        let socket = try #require(rig.network.socket)
        #expect(socket.url.absoluteString == "wss://ws.graine.ai/embed/v1/web-1?region=in")
        #expect(!socket.url.absoluteString.contains("context_token"))
        // The variables ride the ticket instead.
        let post = try #require(rig.network.posts.first)
        let body = try #require(JSON.object(from: post.body))
        #expect(body["metadata"] as? [String: String] == ["who_called": "agent", "call_reason": "payment_due"])
    }

    @Test func theDirectUrlCarriesTheVariables() throws {
        let rig = EngineRig()
        rig.network.ticketReply = (503, nil)
        rig.engine.start()
        let socket = try #require(rig.network.socket)
        let token = try #require(CallWire.contextToken([("who_called", "agent"), ("call_reason", "payment_due")]))
        #expect(socket.url.absoluteString == "wss://ws.graine.ai/chat/v1/web-1?webcall=1&context_token=" + GraineProtocol.encode(token))
    }
}

@Suite struct CallStartAudioTests {
    struct NoMicrophone: Error {}

    @Test func aStartWithAnAnswerSaysTheAudioRuns() {
        let rig = EngineRig()
        rig.engine.start()
        rig.network.socket?.open()
        var answers: [Bool] = []
        rig.engine.startAudio { answers.append($0) }
        rig.engine.startAudio { answers.append($0) }
        #expect(answers == [true, true], "running already is running")
        #expect(rig.audio.starts == 1)
    }

    @Test func aStartWithAnAnswerThatFailsLeavesTheCallToTheCaller() {
        let rig = EngineRig()
        rig.audio.startError = NoMicrophone()
        rig.engine.start()
        rig.network.socket?.open()
        var answers: [Bool] = []
        rig.engine.startAudio { answers.append($0) }
        #expect(answers == [false])
        #expect(rig.endings.isEmpty, "the audio watch ends it, with its own words")
    }

    @Test func aStartWithoutAnAnswerThatFailsStillEndsTheCall() {
        let rig = EngineRig()
        rig.audio.startError = NoMicrophone()
        rig.engine.start()
        rig.network.socket?.open()
        rig.engine.startAudio()
        #expect(rig.endings.count == 1)
        if case .dropped = rig.endings.first {} else { Issue.record("expected dropped, got \(rig.endings)") }
    }

    @Test func aStartAfterTheEndSaysNo() {
        let rig = EngineRig()
        rig.engine.start()
        rig.engine.hangUp()
        var answers: [Bool] = []
        rig.engine.startAudio { answers.append($0) }
        #expect(answers == [false])
        #expect(rig.audio.starts == 0)
    }
}

/// The watch on a clock the test moves.
private final class WatchRig {
    private(set) var steps: [CallAudioWatch.Step] = []
    private var timers: [(due: Double, fire: () -> Void, live: Bool)] = []
    private(set) var now = 0.0
    var onStep: ((CallAudioWatch.Step) -> Void)?
    private(set) lazy var watch = CallAudioWatch(schedule: { [unowned self] seconds, fire in
        let index = self.timers.count
        self.timers.append((self.now + seconds, fire, true))
        return { [weak self] in self?.timers[index].live = false }
    }, act: { [unowned self] step in
        self.steps.append(step)
        self.onStep?(step)
    })

    func advance(_ seconds: Double) {
        let target = now + seconds
        while let i = timers.indices.filter({ timers[$0].live && timers[$0].due <= target + 1e-9 }).min(by: { timers[$0].due < timers[$1].due }) {
            timers[i].live = false
            now = timers[i].due
            timers[i].fire()
        }
        now = target
    }
}

@Suite struct CallAudioWatchTests {
    @Test func audioAlreadyRunningConnectsAtOnce() {
        let rig = WatchRig()
        rig.watch.opened(audioRunning: true)
        #expect(rig.steps == [.connect])
        #expect(!rig.watch.isWaiting)
        rig.advance(10)
        #expect(rig.steps == [.connect])
    }

    @Test func callKitActivatingWithinTheGraceConnectsWithoutARetry() {
        let rig = WatchRig()
        rig.watch.opened(audioRunning: false)
        rig.advance(2.9)
        #expect(rig.steps.isEmpty)
        rig.watch.audioStarted()
        #expect(rig.steps == [.connect])
        rig.advance(10)
        #expect(rig.steps == [.connect])
    }

    @Test func noAudioAfterThreeSecondsStartsItDirectlyOnceAndThatConnects() {
        let rig = WatchRig()
        rig.watch.opened(audioRunning: false)
        rig.advance(3.1)
        #expect(rig.steps == [.retry])
        rig.watch.audioStarted()
        #expect(rig.steps == [.retry, .connect])
        rig.advance(10)
        #expect(rig.steps == [.retry, .connect])
    }

    @Test func aDirectStartThatFailsFailsTheCallAtOnce() {
        let rig = WatchRig()
        rig.onStep = { [weak rig] step in if step == .retry { rig?.watch.retryFailed() } }
        rig.watch.opened(audioRunning: false)
        rig.advance(3.1)
        #expect(rig.steps == [.retry, .fail])
        rig.advance(10)
        #expect(rig.steps == [.retry, .fail])
        #expect(CallAudioWatch.failure == "The call's audio could not start.")
    }

    @Test func noAudioThreeSecondsAfterTheDirectStartFailsTheCall() {
        let rig = WatchRig()
        rig.watch.opened(audioRunning: false)
        rig.advance(3.1)
        #expect(rig.steps == [.retry])
        rig.advance(2.8)
        #expect(rig.steps == [.retry])
        rig.advance(0.2)
        #expect(rig.steps == [.retry, .fail])
        rig.watch.audioStarted()
        #expect(rig.steps == [.retry, .fail], "decided once")
    }

    @Test func aCallThatEndsWhileWaitingDecidesNothing() {
        let rig = WatchRig()
        rig.watch.opened(audioRunning: false)
        rig.advance(1)
        rig.watch.cancel()
        rig.advance(10)
        rig.watch.audioStarted()
        #expect(rig.steps.isEmpty)
    }
}

@Suite struct CallSessionLoaderTests {
    private final class Sources {
        var live: GraineSessionConfig?
        var kept: GraineSessionConfig?
        var refreshes = 0
        var loads = 0
        var loadAnswer: GraineSessionConfig?

        lazy var loader = CallEngine.sessionLoader(
            live: { [unowned self] in self.live },
            kept: { [unowned self] in self.live ?? self.kept },
            refresh: { [unowned self] in self.refreshes += 1 },
            load: { [unowned self] done in
                self.loads += 1
                done(self.loadAnswer)
            }
        )

        func session() -> GraineSessionConfig? {
            var got: GraineSessionConfig??
            loader { got = $0 }
            return got ?? nil
        }
    }

    @Test func theSessionInMemoryStartsTheCallWithoutTheNetwork() {
        let s = Sources()
        s.live = GraineSessionConfig(agentId: "a-live", webcallAgentId: "w-live")
        #expect(s.session()?.agentId == "a-live")
        #expect(s.loads == 0)
        #expect(s.refreshes == 0)
    }

    @Test func aKeptSessionStartsTheCallAtOnceAndIsRefreshedBehindIt() {
        let s = Sources()
        s.kept = GraineSessionConfig(agentId: "a-kept", webcallAgentId: "w-kept", wsHost: "wss://ws.graine.ai")
        #expect(s.session()?.agentId == "a-kept")
        #expect(s.loads == 0, "the call never waited for the network")
        #expect(s.refreshes == 1)
    }

    @Test func aKeptSessionThatDoesNotSayWhereTheSocketLivesWaitsForTheNetwork() {
        let s = Sources()
        s.kept = GraineSessionConfig(agentId: "a-kept", webcallAgentId: "w-kept")
        s.loadAnswer = GraineSessionConfig(agentId: "a-net", webcallAgentId: "w-net", wsHost: "wss://ws.graine.ai/net")
        #expect(s.session()?.agentId == "a-net")
        #expect(s.loads == 1)
        #expect(s.refreshes == 0)
    }

    @Test func noSessionAnywhereIsTheNetwork() {
        let s = Sources()
        s.loadAnswer = nil
        #expect(s.session() == nil)
        #expect(s.loads == 1)
    }
}
