import CryptoKit
import Foundation

/*
 * CALLS GRAINE RINGS — the hosted mode (contract §3). A workspace that uploads
 * its push credentials lets Graine ring its customers' phones itself: this
 * device registers its VoIP token with Graine, the agent (or the dashboard, or
 * the customer through `scheduleCall`) books a call, and Graine sends the push.
 * The push is the one this SDK always answered — `type: "agent_call"` — with
 * `hosted: "1"`, and every outcome of that ring goes back to Graine.
 * Pure: Foundation and CryptoKit.
 */

/// The session's `calls`: whether Graine rings this app, and the rules for booking.
public struct GraineHostedCallsSettings: Equatable, Sendable {
    /// Graine rings this app's devices (the workspace uploaded its push credentials).
    public let hosted: Bool
    /// Which platforms Graine rings: `ios`, `android`.
    public let platforms: [String]
    /// How long a ring Graine sent lasts before it is missed. Nil: the app's own `ringTimeout`.
    public let ringTimeoutSeconds: Int?
    /// The name the agent's calls ring with, when the dashboard set one.
    public let callName: String?
    /// Whether customers may book calls from the app (`scheduleCall`), and within what.
    public let usersCanBook: Bool
    public let maxDaysAhead: Int?
    public let minLeadMinutes: Int?
    public let maxPendingPerUser: Int?
    /**
     * The dashboard's say on the native calls' audio (`calls.audioTransport`):
     * `.websocket` turns WebRTC off for this agent whatever the app asked;
     * `.webrtc`, or nil (no opinion), leaves the app's `callTransport` to decide.
     */
    public let audioTransport: GraineCallTransport?

    /// Graine rings iOS devices for this agent.
    public var ringsThisPlatform: Bool {
        hosted && (platforms.isEmpty || platforms.contains("ios"))
    }

    static func parse(_ raw: Any?) -> GraineHostedCallsSettings? {
        guard let o = JSON.unwrap(raw) as? [String: Any] else { return nil }
        let rules = Scheduling.Rules.parse(o["scheduling"])
        var timeout: Int?
        // The dashboard's range (Calls & scheduling → Ring for): 20–60 seconds, as every SDK reads it.
        if let v = JSON.unwrap(o["ringTimeoutSeconds"]), let n = JSON.number(v), n.doubleValue.isFinite, n.doubleValue > 0 {
            timeout = Int(min(max(n.doubleValue, 20), 60).rounded())
        }
        let platforms = ((JSON.unwrap(o["platforms"]) as? [Any]) ?? []).compactMap { JSON.unwrap($0) as? String }.map { $0.lowercased() }
        let name = JSON.nonEmpty(o["callName"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        return GraineHostedCallsSettings(
            hosted: JSON.unwrap(o["hosted"]).flatMap { JSON.bool($0) } ?? false,
            platforms: platforms,
            ringTimeoutSeconds: timeout,
            callName: name?.isEmpty == false ? name : nil,
            usersCanBook: rules?.usersCanBook ?? false,
            maxDaysAhead: rules?.maxDaysAhead,
            minLeadMinutes: rules?.minLeadMinutes,
            maxPendingPerUser: rules?.maxPendingPerUser,
            audioTransport: (JSON.unwrap(o["audioTransport"]) as? String).flatMap(GraineCallTransport.from).flatMap { $0 == .auto ? nil : $0 }
        )
    }
}

/**
 * WHEN THIS DEVICE TELLS GRAINE ITS TOKEN: on every new token, whenever what
 * the registration says changes (another customer signed in, a new time zone,
 * a new app version), and otherwise at most once a day — Graine forgets a
 * device not seen for 90 days, and a phone that rings must not be forgotten.
 * What was sent is kept as hashes: never the token, never the customer.
 */
struct DeviceRegistration: Equatable {
    static let key = "ai.graine.inapp.device"
    static let refreshSeconds: TimeInterval = 24 * 60 * 60

    /// A one-way fingerprint of everything a registration says.
    let fingerprint: String
    let at: Date

    static func fingerprint(token: String, fields: [(String, String)]) -> String {
        var text = "graine:device:v1\n" + token
        for (k, v) in fields { text += "\n" + k + "=" + v }
        return SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func due(last: DeviceRegistration?, fingerprint: String, now: Date) -> Bool {
        guard let last = last else { return true }
        if last.fingerprint != fingerprint { return true }
        return now.timeIntervalSince(last.at) >= refreshSeconds || now < last.at
    }

    /// Where an agent's last registration is kept: the default agent under `key`, another under `key.<name>`.
    static func storageKey(agent: String) -> String {
        agent == GraineAgentRegistry.defaultName ? key : key + "." + agent
    }

    static func load(_ defaults: UserDefaults, agent: String = GraineAgentRegistry.defaultName) -> DeviceRegistration? {
        guard let o = defaults.dictionary(forKey: storageKey(agent: agent)), let f = o["f"] as? String,
              let at = (o["at"] as? NSNumber)?.doubleValue else {
            return nil
        }
        return DeviceRegistration(fingerprint: f, at: Date(timeIntervalSince1970: at))
    }

    func save(_ defaults: UserDefaults, agent: String = GraineAgentRegistry.defaultName) {
        defaults.set(["f": fingerprint, "at": at.timeIntervalSince1970], forKey: DeviceRegistration.storageKey(agent: agent))
    }
}

/**
 * WHICH APNs A TOKEN BELONGS TO, from the build itself: a build signed for
 * development carries `aps-environment: development` in its embedded
 * provisioning profile, and its tokens are sandbox tokens; an App Store or
 * TestFlight build carries no profile at all (or `production`). A token sent
 * to the wrong environment is `BadDeviceToken`, so this is not a guess Graine
 * can make for the app.
 */
enum ApnsEnvironment {
    static let sandbox = "sandbox"
    static let production = "production"

    /// The environment from `embedded.mobileprovision`'s bytes; production without one.
    static func from(provisioningProfile data: Data?) -> String {
        guard let data = data, let plist = plistInside(data),
              let parsed = try? PropertyListSerialization.propertyList(from: plist, options: [], format: nil) as? [String: Any],
              let entitlements = parsed["Entitlements"] as? [String: Any],
              let environment = entitlements["aps-environment"] as? String else { return production }
        return environment.lowercased() == "development" ? sandbox : production
    }

    /// The XML property list a CMS-signed profile wraps.
    static func plistInside(_ data: Data) -> Data? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        return data.subdata(in: start.lowerBound..<end.upperBound)
    }

    /// This build's, read once.
    static let current: String = {
        let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
        return from(provisioningProfile: url.flatMap { try? Data(contentsOf: $0) })
    }()
}

/**
 * WHAT BECAME OF A RING GRAINE SENT, in the outcome route's words (§3.6):
 * `ringing` once the system shows it, then `answered`, `declined`, `missed`,
 * `failed` (it never connected) or `ended` (with how long it lasted). The
 * server follows its own state machine and ignores a late or repeated report,
 * so this only has to say each thing once, in order.
 */
enum HostedOutcome {
    struct Report: Equatable {
        let callId: String
        let outcome: String
        let reason: String?
        let durationSeconds: Int?
    }

    /// The report for one of the calls' outcomes. `connectedAt` is when the conversation opened, for `ended`.
    static func report(_ outcome: GraineCallOutcome, callId: String, connectedAt: Date?, now: Date = Date()) -> Report {
        switch outcome {
        case .answered:
            return Report(callId: callId, outcome: "answered", reason: nil, durationSeconds: nil)
        case .declined:
            return Report(callId: callId, outcome: "declined", reason: nil, durationSeconds: nil)
        case .missed:
            return Report(callId: callId, outcome: "missed", reason: nil, durationSeconds: nil)
        case .ended(let why):
            let seconds = connectedAt.map { max(0, Int(now.timeIntervalSince($0).rounded())) }
            return Report(callId: callId, outcome: "ended", reason: why.rawValue, durationSeconds: seconds)
        case .failed(let error):
            return Report(callId: callId, outcome: "failed", reason: CallWire.utf16Prefix(error, 200), durationSeconds: nil)
        }
    }

    static func ringing(callId: String) -> Report {
        Report(callId: callId, outcome: "ringing", reason: nil, durationSeconds: nil)
    }

    /// A ring that found this device on another call.
    static func busy(callId: String) -> Report {
        Report(callId: callId, outcome: "missed", reason: "busy", durationSeconds: nil)
    }

    /// `installId, callId, outcome, reason?, durationSeconds?`.
    static func fields(_ report: Report, installId: String?) -> [(String, WireJSON)] {
        var out: [(String, WireJSON)] = []
        if let install = installId { out.append(("installId", .string(install))) }
        out.append(("callId", .string(report.callId)))
        out.append(("outcome", .string(report.outcome)))
        if let reason = report.reason, !reason.isEmpty { out.append(("reason", .string(reason))) }
        if let seconds = report.durationSeconds { out.append(("durationSeconds", .int(seconds))) }
        return out
    }
}
