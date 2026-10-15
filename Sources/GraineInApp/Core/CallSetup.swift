import Foundation

/*
 * WHAT A CALL NEEDS FROM THE PHONE AND THE APP — the call permissions and the
 * setup self-check, without the phone: every rule in Foundation, so a Mac
 * proves it. GraineCalls reads the facts on an iPhone (the microphone, the
 * Info.plist, the signing, the push registration, the sessions) and asks
 * these rules what they mean.
 *
 * A problem is never an exception: calls still work wherever they can. The
 * check says what is missing, in plain words with the exact fix, once in the
 * log and whenever the app reads `callSetupProblems`.
 */

/// A permission a WhatsApp-style call needs.
public enum GraineCallPermission: String, CaseIterable, Sendable {
    /// The customer's voice. Asked by the SDK when a call starts without it, or by `requestCallPermissions()`.
    case microphone
    /// A call that rings while the app is closed (Android). iOS rings through CallKit, which needs none.
    case notifications
    /// A ring that fills a locked screen (Android 14+). iOS: CallKit's own screen, nothing to allow.
    case fullScreen
}

/// Where a call permission stands.
public enum GraineCallPermissionStatus: String, Sendable {
    /// Allowed.
    case granted
    /// Not allowed yet: `requestCallPermissions()` can ask for it.
    case denied
    /// Refused for good: only the Settings app can change it (`openCallSettings(_:)`).
    case blocked
    /// This phone needs no such permission.
    case notNeeded

    /// Granted, or nothing to grant.
    public var isSatisfied: Bool { self == .granted || self == .notNeeded }
}

/// Every call permission's status, as the phone holds it when read.
public struct GraineCallPermissions: Equatable, Sendable {
    public let microphone: GraineCallPermissionStatus
    public let notifications: GraineCallPermissionStatus
    public let fullScreen: GraineCallPermissionStatus

    public init(microphone: GraineCallPermissionStatus, notifications: GraineCallPermissionStatus, fullScreen: GraineCallPermissionStatus) {
        self.microphone = microphone
        self.notifications = notifications
        self.fullScreen = fullScreen
    }

    /// One permission's status.
    public subscript(_ item: GraineCallPermission) -> GraineCallPermissionStatus {
        switch item {
        case .microphone: return microphone
        case .notifications: return notifications
        case .fullScreen: return fullScreen
        }
    }

    /// Every permission is granted or not needed: calls can ring and connect.
    public var allGranted: Bool {
        GraineCallPermission.allCases.allSatisfy { self[$0].isSatisfied }
    }

    /// `{microphone, notifications, fullScreen}`, each a status word — for a bridge.
    var fields: [String: Any] {
        ["microphone": microphone.rawValue, "notifications": notifications.rawValue, "fullScreen": fullScreen.rawValue]
    }
}

/**
 * Something the app's setup still lacks for calls: a stable `code` to act on
 * and a `message` in plain words with the exact fix. Calls still work where
 * they can.
 */
public struct GraineCallSetupProblem: Equatable, Sendable {
    /// Stable: `microphone_usage_missing`, `background_audio_missing`, `background_voip_missing`,
    /// `push_entitlement_missing`, `voip_pushes_not_enabled`, `no_voip_token`, `microphone_blocked`, `hosted_ringing_off`.
    public let code: String
    /// What is missing and how to fix it, for the developer.
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    /// `{code, message}`, for a bridge.
    var fields: [String: Any] { ["code": code, "message": message] }
}

/// What the self-check reads from the phone and the app.
struct CallSetupFacts {
    /// The app's Info.plist.
    var info: [String: Any] = [:]
    /// The push entitlement, as far as the build lets it be read.
    var pushEntitlement: CallSetup.PushEntitlement = .unknown
    /// `enableVoIPPushes()` ran, or the app hands over the token of a push registry of its own.
    var voipPushesEnabled = false
    /// PushKit (or the app's own registry) has given a VoIP token.
    var hasVoipToken = false
    /// Seconds since `configure`; nil before it.
    var secondsSinceConfigure: TimeInterval?
    /// Seconds since VoIP pushes were enabled; nil before.
    var secondsSinceVoipEnabled: TimeInterval?
    /// The simulator: PushKit gives it no token, so a missing one is not news there.
    var simulator = false
    var microphone: GraineCallPermissionStatus = .denied
    /// Whether Graine rings this phone for any configured agent; nil while no session is known.
    var hostedRinging: Bool?
}

enum CallSetup {
    /// How long after `configure` (and after enabling VoIP pushes) a missing push registration or token is a problem.
    static let settleSeconds: TimeInterval = 15

    /// The push entitlement, from the profile the build embeds.
    enum PushEntitlement: Equatable {
        case present
        case missing
        /// No profile to read: an App Store or TestFlight build, or the simulator.
        case unknown
    }

    /**
     * Whether `embedded.mobileprovision` grants push. Only a development or
     * ad hoc build embeds one; a profile without `aps-environment` cannot sign
     * an app that has it.
     */
    static func pushEntitlement(provisioningProfile data: Data?) -> PushEntitlement {
        guard let data = data, let plist = ApnsEnvironment.plistInside(data),
              let parsed = try? PropertyListSerialization.propertyList(from: plist, options: [], format: nil) as? [String: Any]
        else { return .unknown }
        let entitlements = parsed["Entitlements"] as? [String: Any] ?? [:]
        return (entitlements["aps-environment"] as? String)?.isEmpty == false ? .present : .missing
    }

    /// The microphone as a call permission: iOS shows its dialog once, then only Settings can change it.
    static func microphone(_ permission: MicPermission) -> GraineCallPermissionStatus {
        switch permission {
        case .granted: return .granted
        case .denied: return .blocked
        case .undetermined: return .denied
        }
    }

    /// The permissions on an iPhone: the microphone; CallKit needs no notification and draws its own full screen.
    static func permissions(microphone permission: MicPermission) -> GraineCallPermissions {
        GraineCallPermissions(microphone: microphone(permission), notifications: .notNeeded, fullScreen: .notNeeded)
    }

    /// Every problem the facts show, the build's first, then what this launch has or has not done.
    static func problems(_ f: CallSetupFacts) -> [GraineCallSetupProblem] {
        var out: [GraineCallSetupProblem] = []
        let usage = (f.info["NSMicrophoneUsageDescription"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if usage.isEmpty {
            out.append(GraineCallSetupProblem(
                code: "microphone_usage_missing",
                message: "Info.plist has no NSMicrophoneUsageDescription, so iOS closes the app the moment a call asks for the microphone. "
                    + "Add NSMicrophoneUsageDescription with a sentence such as \"Lets you talk to the assistant on calls.\""
            ))
        }
        let modes = Set((f.info["UIBackgroundModes"] as? [Any] ?? []).compactMap { ($0 as? String)?.lowercased() })
        if !modes.contains("audio") {
            out.append(GraineCallSetupProblem(
                code: "background_audio_missing",
                message: "UIBackgroundModes in Info.plist lacks \"audio\", so a call goes silent when the screen locks or the app leaves the screen. "
                    + "In Xcode: Signing & Capabilities → Background Modes → Audio, AirPlay, and Picture in Picture."
            ))
        }
        if !modes.contains("voip") {
            out.append(GraineCallSetupProblem(
                code: "background_voip_missing",
                message: "UIBackgroundModes in Info.plist lacks \"voip\", so iOS does not wake the app for a call that rings. "
                    + "In Xcode: Signing & Capabilities → Background Modes → Voice over IP."
            ))
        }
        if f.pushEntitlement == .missing {
            out.append(GraineCallSetupProblem(
                code: "push_entitlement_missing",
                message: "The app is signed without the Push Notifications capability (no aps-environment entitlement), so no call can ring this phone. "
                    + "In Xcode: Signing & Capabilities → + Capability → Push Notifications."
            ))
        }
        let settled = (f.secondsSinceConfigure ?? 0) >= settleSeconds
        if settled && !f.voipPushesEnabled {
            out.append(GraineCallSetupProblem(
                code: "voip_pushes_not_enabled",
                message: "enableVoIPPushes() has not been called, so calls can't ring this phone (calls the customer places still work). "
                    + "Call it at launch, every launch, after configuring the calls."
            ))
        }
        if f.voipPushesEnabled && !f.hasVoipToken && !f.simulator && (f.secondsSinceVoipEnabled ?? 0) >= settleSeconds {
            out.append(GraineCallSetupProblem(
                code: "no_voip_token",
                message: "No VoIP push token \(Int(settleSeconds)) seconds after enableVoIPPushes(), so calls can't ring this phone yet. "
                    + "Check the Push Notifications capability and the Voice over IP background mode, and that the phone is online."
            ))
        }
        if f.microphone == .blocked {
            out.append(GraineCallSetupProblem(
                code: "microphone_blocked",
                message: "The microphone is turned off for this app in Settings, so calls can't connect. "
                    + "Ask the customer to turn it on: openCallSettings(.microphone) opens the page."
            ))
        }
        if f.hostedRinging == false {
            out.append(GraineCallSetupProblem(
                code: "hosted_ringing_off",
                message: "Graine can't ring this phone: no push credentials for iOS are uploaded for this agent. "
                    + "Upload them in the dashboard (Workspace settings → In-app calling), unless your own server sends the call pushes."
            ))
        }
        return out
    }

    /// Whether Graine rings this phone, from the calls settings of every session known; nil when none is.
    static func hostedRinging(_ sessions: [GraineHostedCallsSettings?]) -> Bool? {
        guard !sessions.isEmpty else { return nil }
        return sessions.contains { $0?.ringsThisPlatform == true }
    }

    /// The log says each problem once a launch: the codes it has said, and the problems it has not.
    struct LogOnce {
        private(set) var said: Set<String> = []

        mutating func fresh(_ problems: [GraineCallSetupProblem]) -> [GraineCallSetupProblem] {
            let new = problems.filter { !said.contains($0.code) }
            said.formUnion(new.map(\.code))
            return new
        }
    }
}
