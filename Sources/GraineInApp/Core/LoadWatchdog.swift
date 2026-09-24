import Foundation

/**
 * WAITING IS NOT THE SAME AS BEING STUCK.
 *
 * The engine page is downloaded over the customer's worst network. One flat
 * timer — "ready in 15 seconds or reload" — cancelled honest slow downloads,
 * threw away everything that had arrived, and started again, six times; on a
 * slow enough link it could never finish. So the question is "is it still
 * moving?", with three limits for three different failures:
 *
 *   stall   nothing has arrived for a while — a dead socket, a captive portal
 *   boot    everything arrived and the page still has not said ready — broken
 *   cap     an overall ceiling, so a link that dribbles forever still ends
 *
 * Pure: times are passed in (milliseconds on any monotonic clock), so every
 * rule is proven by a unit test rather than by hoping a device behaves.
 */
final class LoadWatchdog {
    enum Verdict: String {
        case wait
        case stalled
        case bootTimeout = "boot_timeout"
        case loadCap = "load_cap"
    }

    let stallMs: Int64
    let bootMs: Int64
    let hardCapMs: Int64

    private var startedAt: Int64 = 0
    private var movedAt: Int64 = 0
    private var lastProgress = 0
    private var downloaded = false

    init(stallMs: Int64 = 15_000, bootMs: Int64 = 15_000, hardCapMs: Int64 = 120_000) {
        self.stallMs = stallMs
        self.bootMs = bootMs
        self.hardCapMs = hardCapMs
    }

    func start(now: Int64) {
        startedAt = now
        movedAt = now
        lastProgress = 0
        downloaded = false
    }

    /// Progress 0–100 from the web view. Monotonic: a lower report is not the page going backwards.
    func progress(_ percent: Int, now: Int64) {
        if percent <= lastProgress { return }
        lastProgress = percent
        movedAt = now
        if percent >= 100 { downloaded = true }
    }

    /// The page is downloaded; from here it is booting, not fetching.
    func loaded(now: Int64) {
        downloaded = true
        movedAt = now
    }

    func check(now: Int64) -> Verdict {
        let limit = downloaded ? bootMs : stallMs
        if now - movedAt >= limit { return downloaded ? .bootTimeout : .stalled }
        if now - startedAt >= hardCapMs { return .loadCap }
        return .wait
    }

    /**
     * When to look again: the earlier of the two limits. Never busier than
     * every 250ms, and never slower than a quarter of the window — a fixed
     * floor swamps a short window the host asked for.
     */
    func nextCheckInMs(now: Int64) -> Int64 {
        let limit = downloaded ? bootMs : stallMs
        let untilLimit = limit - (now - movedAt)
        let untilCap = hardCapMs - (now - startedAt)
        let floor = min(Int64(250), limit / 4)
        return max(floor, min(untilLimit, untilCap))
    }
}

/**
 * How often to reload a page that failed, and when to stop.
 *
 * Jittered ±25%: a thousand phones coming back from the same outage must not
 * reload the same page in the same second. Bounded: a phone with no network
 * stops and says so, rather than burning the battery in the background.
 */
final class RetryLadder {
    private let delaysMs: [Int64]
    private let random: () -> Double
    private(set) var attempt = 0

    init(delaysMs: [Int64] = [1_000, 2_000, 4_000, 8_000, 15_000, 15_000],
         random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.delaysMs = delaysMs
        self.random = random
    }

    var exhausted: Bool { attempt >= delaysMs.count }

    /// The delay before the next attempt, or nil when every attempt is spent.
    func next() -> Int64? {
        if exhausted { return nil }
        let base = delaysMs[attempt]
        attempt += 1
        return Int64((Double(base) * (0.75 + random() * 0.5)).rounded())
    }

    func reset() { attempt = 0 }
}
