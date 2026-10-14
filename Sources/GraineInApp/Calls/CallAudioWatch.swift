import Foundation

/**
 * A CALL'S AUDIO IS CALLKIT'S TO GIVE, AND IT CAN FAIL TO.
 *
 * The microphone and the speaker start only once CallKit activates the call's
 * audio session (`provider(_:didActivate:)`). If it never does — the app's own
 * audio session was already active, say — the conversation opens, the agent
 * speaks, and nobody hears anything, with nothing in the log to say why. So,
 * once the conversation is open without its audio:
 *
 *   3 s later, still none   start the audio directly, once
 *   3 s after that, none    the call fails: "The call's audio could not start."
 *
 * A direct start that reports failure fails the call at once. The call is not
 * `active` until its audio runs: a call nobody can hear never connected.
 * Foundation only, with the clock handed in, so a Mac proves it; GraineCalls
 * drives it on the main thread.
 */
final class CallAudioWatch {
    enum Step: Equatable {
        /// The audio runs: the call is connected.
        case connect
        /// Still no audio: start it directly — once.
        case retry
        /// It could not start: end the call with `failure`.
        case fail
    }

    /// How long the open conversation waits for its audio, before the direct start and again after it.
    static let graceSeconds: TimeInterval = 3
    /// Why a call whose audio never started failed — what the app's listener hears.
    static let failure = "The call's audio could not start."

    /// Run `fire` after `seconds`; the returned closure cancels it.
    typealias Schedule = (_ seconds: TimeInterval, _ fire: @escaping () -> Void) -> () -> Void

    private let schedule: Schedule
    private let act: (Step) -> Void
    private var cancelTimer: (() -> Void)?
    private var waiting = false
    private var retried = false

    init(schedule: @escaping Schedule, act: @escaping (Step) -> Void) {
        self.schedule = schedule
        self.act = act
    }

    /// Whether an open conversation is waiting for its audio.
    var isWaiting: Bool { waiting }

    /// The conversation opened. With the audio already running it is connected now; otherwise the wait begins.
    func opened(audioRunning: Bool) {
        stop()
        if audioRunning {
            act(.connect)
            return
        }
        waiting = true
        arm()
    }

    /// The audio runs — CallKit activated it, or the direct start worked.
    func audioStarted() {
        guard waiting else { return }
        stop()
        act(.connect)
    }

    /// The direct start reported that the audio could not start.
    func retryFailed() {
        guard waiting else { return }
        stop()
        act(.fail)
    }

    /// The call is over: nothing waiting is decided.
    func cancel() {
        stop()
    }

    private func arm() {
        cancelTimer = schedule(Self.graceSeconds) { [weak self] in
            guard let self = self, self.waiting else { return }
            self.cancelTimer = nil
            if self.retried {
                self.stop()
                self.act(.fail)
                return
            }
            self.retried = true
            self.act(.retry)
            // The direct start may already have answered (and connected or failed the call).
            if self.waiting { self.arm() }
        }
    }

    private func stop() {
        waiting = false
        retried = false
        cancelTimer?()
        cancelTimer = nil
    }
}
