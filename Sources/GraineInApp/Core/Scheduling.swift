import Foundation

/// Where a booked call is (WIRE.md "SDK types"). A status this build does not know is `unknown`, with its word.
public enum GraineCallStatus: Equatable, Hashable, Sendable, CustomStringConvertible {
    case scheduled
    case ringing
    case answered
    case completed
    case declined
    case missed
    case failed
    case cancelled
    case expired
    /// Graine had no device of this customer's to ring (wire: `no_device`).
    case noDevice
    case unknown(String)

    private static let words: [(GraineCallStatus, String)] = [
        (.scheduled, "scheduled"), (.ringing, "ringing"), (.answered, "answered"), (.completed, "completed"),
        (.declined, "declined"), (.missed, "missed"), (.failed, "failed"), (.cancelled, "cancelled"),
        (.expired, "expired"), (.noDevice, "no_device"),
    ]

    public init(wire: String) {
        let word = wire.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self = GraineCallStatus.words.first { $0.1 == word }?.0 ?? .unknown(wire)
    }

    /// The word on the wire: `scheduled`, …, `no_device`; an unknown status's own.
    public var wire: String {
        if case .unknown(let raw) = self { return raw }
        return GraineCallStatus.words.first { $0.0 == self }?.1 ?? ""
    }

    public var description: String { wire }
}

/// Who booked a call. The app's own bookings (`scheduleCall`) are `app` (wire: `sdk`).
public enum GraineCallSource: Equatable, Hashable, Sendable, CustomStringConvertible {
    case agent
    case app
    case dashboard
    case api
    case unknown(String)

    public init(wire: String) {
        switch wire.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "agent": self = .agent
        case "sdk", "app": self = .app
        case "dashboard": self = .dashboard
        case "api": self = .api
        default: self = .unknown(wire)
        }
    }

    public var wire: String {
        switch self {
        case .agent: return "agent"
        case .app: return "sdk"
        case .dashboard: return "dashboard"
        case .api: return "api"
        case .unknown(let raw): return raw
        }
    }

    public var description: String { wire }
}

/**
 * A CALL THE AGENT WILL MAKE TO THIS CUSTOMER, booked for later (contract §3.3,
 * §4.2): when it rings this device, Graine rings it, as a call through the
 * system's call screen. WIRE.md "SDK types".
 */
public struct GraineScheduledCall: Equatable, Sendable, Identifiable {
    public let id: String
    /// When it rings. Nil only when the server's time could not be read.
    public let at: Date?
    public let status: GraineCallStatus
    /// Who booked it; nil when the server does not say.
    public let source: GraineCallSource?
    /// Why, as it was booked. Nil when none was given (or the server keeps it to itself).
    public let reason: String?

    public init(id: String, at: Date?, status: GraineCallStatus = .scheduled, source: GraineCallSource? = nil, reason: String? = nil) {
        self.id = id
        self.at = at
        self.status = status
        self.source = source
        self.reason = reason
    }

    /// Still to come: scheduled, or ringing now.
    public var isUpcoming: Bool { status == .scheduled || status == .ringing }

    /// It can still be called off: it has not rung yet.
    public var canCancel: Bool { status == .scheduled }
}

/// A platform Graine rings.
public enum GraineRingPlatform: String, Sendable {
    case ios
    case android
}

/**
 * THE RULES FOR BOOKING, from the session (`calls.scheduling` and `calls.*`;
 * WIRE.md "SDK types") — `GraineInApp.schedulingRules`. With nothing in the
 * session, customers cannot book (`usersCanBook` false) and the defaults hold.
 * `scheduleCall` checks a time against `earliest(now:)` and `latest(now:)`
 * before it asks; a booking UI can offer only times between them.
 */
public struct GraineSchedulingRules: Equatable, Sendable {
    public let usersCanBook: Bool
    public let minLeadMinutes: Int
    public let maxDaysAhead: Int
    public let maxPendingPerUser: Int
    /// How long a ring Graine sends lasts before it is missed.
    public let ringTimeoutSeconds: Int
    /// The name the agent's calls ring with, when the dashboard set one.
    public let callName: String?
    /// Graine rings this app's devices (the workspace uploaded its push credentials).
    public let hostedRinging: Bool
    public let platforms: [GraineRingPlatform]

    public init(
        usersCanBook: Bool = false, minLeadMinutes: Int = 5, maxDaysAhead: Int = 14, maxPendingPerUser: Int = 3,
        ringTimeoutSeconds: Int = 45, callName: String? = nil, hostedRinging: Bool = false, platforms: [GraineRingPlatform] = []
    ) {
        self.usersCanBook = usersCanBook
        self.minLeadMinutes = minLeadMinutes
        self.maxDaysAhead = maxDaysAhead
        self.maxPendingPerUser = maxPendingPerUser
        self.ringTimeoutSeconds = ringTimeoutSeconds
        self.callName = callName
        self.hostedRinging = hostedRinging
        self.platforms = platforms
    }

    /// The earliest a call can be booked for: `now` plus `minLeadMinutes`.
    public func earliest(now: Date = Date()) -> Date {
        now.addingTimeInterval(TimeInterval(minLeadMinutes) * 60)
    }

    /// The latest: `now` plus `maxDaysAhead` days.
    public func latest(now: Date = Date()) -> Date {
        now.addingTimeInterval(TimeInterval(maxDaysAhead) * 86_400)
    }

    /// From the session's `calls`; the defaults (and no booking) when there are none.
    static func from(_ calls: GraineHostedCallsSettings?) -> GraineSchedulingRules {
        guard let c = calls else { return GraineSchedulingRules() }
        return GraineSchedulingRules(
            usersCanBook: c.usersCanBook,
            minLeadMinutes: c.minLeadMinutes ?? 5,
            maxDaysAhead: c.maxDaysAhead ?? 14,
            maxPendingPerUser: c.maxPendingPerUser ?? 3,
            ringTimeoutSeconds: c.ringTimeoutSeconds ?? 45,
            callName: c.callName,
            hostedRinging: c.hosted,
            platforms: c.platforms.compactMap { GraineRingPlatform(rawValue: $0) }
        )
    }
}

/**
 * The scheduling routes' bodies and answers (WIRE.md): a ScheduledCall is
 * `{id, at, status, source, reason}`, under `call` (schedule) or in `calls`
 * (list, upcoming first, kept in the server's order). Read leniently all the
 * same — the call at the top level, `callId` / `call_id`, `scheduledAt` /
 * `scheduled_at`, epoch milliseconds — so a server that names a field the other
 * way still books the call.
 */
enum Scheduling {
    /// What the session says about booking: `calls.scheduling`.
    struct Rules: Equatable {
        var usersCanBook: Bool
        var maxDaysAhead: Int?
        var minLeadMinutes: Int?
        var maxPendingPerUser: Int?

        static func parse(_ raw: Any?) -> Rules? {
            guard let o = JSON.unwrap(raw) as? [String: Any] else { return nil }
            return Rules(
                usersCanBook: JSON.unwrap(o["usersCanBook"]).flatMap { JSON.bool($0) } ?? false,
                maxDaysAhead: wholeNumber(o["maxDaysAhead"]),
                minLeadMinutes: wholeNumber(o["minLeadMinutes"]),
                maxPendingPerUser: wholeNumber(o["maxPendingPerUser"])
            )
        }
    }

    /// The time, as the server takes it: ISO-8601 with the device's own offset — `2026-10-14T18:00:00+05:30`.
    static func isoTime(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    /// A time the server wrote: ISO-8601 with or without fractions, or milliseconds since the epoch.
    static func date(_ raw: Any?) -> Date? {
        guard let v = JSON.unwrap(raw), !(v is NSNull) else { return nil }
        if let n = JSON.number(v) {
            let d = n.doubleValue
            guard d.isFinite, d > 0 else { return nil }
            // Seconds or milliseconds: anything past the year 5000 in seconds is milliseconds.
            return Date(timeIntervalSince1970: d > 1e11 ? d / 1000 : d)
        }
        guard let s = v as? String, !s.isEmpty else { return nil }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: s) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: s)
    }

    /// One call from the server's answer, or nil when it has no id. A null `at` is a call with no time, not no call.
    static func call(_ raw: Any?) -> GraineScheduledCall? {
        guard let o = JSON.unwrap(raw) as? [String: Any],
              let id = JSON.nonEmpty(o["id"]) ?? JSON.nonEmpty(o["callId"]) ?? JSON.nonEmpty(o["call_id"]) else { return nil }
        return GraineScheduledCall(
            id: id,
            at: date(o["at"]) ?? date(o["scheduledAt"]) ?? date(o["scheduled_at"]),
            status: JSON.nonEmpty(o["status"]).map { GraineCallStatus(wire: $0) } ?? .scheduled,
            source: JSON.nonEmpty(o["source"]).map { GraineCallSource(wire: $0) },
            reason: JSON.nonEmpty(o["reason"])
        )
    }

    /// The booked call in a `schedule` answer: under `call`, or the answer itself.
    static func booked(_ body: [String: Any]) -> GraineScheduledCall? {
        call(body["call"]) ?? call(body)
    }

    /// The calls in a `list` answer, in the server's order (upcoming first).
    static func listed(_ body: [String: Any]) -> [GraineScheduledCall] {
        let raw = (JSON.unwrap(body["calls"]) as? [Any]) ?? (JSON.unwrap(body["scheduled"]) as? [Any]) ?? []
        return raw.compactMap { call($0) }
    }

    /// A reason is the agent's only context for the call, and the server keeps 120 characters of it.
    static let reasonLimit = 120

    static func clippedReason(_ reason: String?) -> String? {
        guard let r = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty else { return nil }
        return CallWire.utf16Prefix(r, reasonLimit)
    }

    private static func wholeNumber(_ raw: Any?) -> Int? {
        guard let v = JSON.unwrap(raw), let n = JSON.number(v), n.doubleValue.isFinite else { return nil }
        return Int(n.doubleValue.rounded())
    }
}
