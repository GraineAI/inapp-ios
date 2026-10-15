import Foundation
import Testing
@testable import GraineInApp

/*
 * What a call needs from the phone and the app: the permissions' statuses,
 * the setup self-check's problems and fixes, what the build's profile says
 * about push, and that each problem is logged once.
 */

/// An app set up for calls the way the README says: nothing to report.
private func readyFacts() -> CallSetupFacts {
    var f = CallSetupFacts()
    f.info = ["NSMicrophoneUsageDescription": "Lets you talk to the assistant.", "UIBackgroundModes": ["audio", "voip"]]
    f.pushEntitlement = .present
    f.voipPushesEnabled = true
    f.hasVoipToken = true
    f.secondsSinceConfigure = 60
    f.secondsSinceVoipEnabled = 60
    f.microphone = .granted
    f.hostedRinging = true
    return f
}

private func codes(_ f: CallSetupFacts) -> [String] {
    CallSetup.problems(f).map(\.code)
}

@Suite struct CallPermissionsTests {
    @Test func theMicrophoneIsAskedOnceThenOnlySettingsChangesIt() {
        #expect(CallSetup.microphone(.granted) == .granted)
        #expect(CallSetup.microphone(.undetermined) == .denied, "never asked: requestCallPermissions can still ask")
        #expect(CallSetup.microphone(.denied) == .blocked, "iOS shows its dialog once")
    }

    @Test func callKitNeedsNoNotificationAndDrawsItsOwnFullScreen() {
        let p = CallSetup.permissions(microphone: .granted)
        #expect(p.notifications == .notNeeded && p.fullScreen == .notNeeded)
        #expect(p.allGranted)
        #expect(!CallSetup.permissions(microphone: .undetermined).allGranted)
        #expect(!CallSetup.permissions(microphone: .denied).allGranted)
    }

    @Test func eachItemIsReadByName() {
        let p = GraineCallPermissions(microphone: .blocked, notifications: .denied, fullScreen: .granted)
        #expect(p[.microphone] == .blocked && p[.notifications] == .denied && p[.fullScreen] == .granted)
        #expect(GraineCallPermissionStatus.notNeeded.isSatisfied && GraineCallPermissionStatus.granted.isSatisfied)
        #expect(!GraineCallPermissionStatus.denied.isSatisfied && !GraineCallPermissionStatus.blocked.isSatisfied)
    }

    @Test func aBridgeGetsTheSameWordsOnEveryPlatform() {
        let p = GraineCallPermissions(microphone: .granted, notifications: .notNeeded, fullScreen: .notNeeded)
        #expect(p.fields as? [String: String] == ["microphone": "granted", "notifications": "notNeeded", "fullScreen": "notNeeded"])
        #expect(GraineCallPermission.allCases.map(\.rawValue) == ["microphone", "notifications", "fullScreen"])
    }
}

@Suite struct CallSetupCheckTests {
    @Test func anAppSetUpAsTheReadmeSaysHasNothingToFix() {
        #expect(CallSetup.problems(readyFacts()).isEmpty)
    }

    @Test func theInfoPlistIsReadForTheUsageStringAndBothBackgroundModes() {
        var f = readyFacts()
        f.info = [:]
        #expect(codes(f) == ["microphone_usage_missing", "background_audio_missing", "background_voip_missing"])
        f.info = ["NSMicrophoneUsageDescription": "   ", "UIBackgroundModes": ["audio"]]
        #expect(codes(f) == ["microphone_usage_missing", "background_voip_missing"], "a blank sentence is no sentence")
        f.info = ["NSMicrophoneUsageDescription": "Talk to Asha", "UIBackgroundModes": ["voip", "fetch"]]
        #expect(codes(f) == ["background_audio_missing"])
    }

    @Test func everyProblemSaysTheExactFix() {
        var f = CallSetupFacts()
        f.secondsSinceConfigure = 60
        f.microphone = .blocked
        f.pushEntitlement = .missing
        f.hostedRinging = false
        let byCode = Dictionary(uniqueKeysWithValues: CallSetup.problems(f).map { ($0.code, $0.message) })
        #expect(byCode["microphone_usage_missing"]?.contains("NSMicrophoneUsageDescription") == true)
        #expect(byCode["background_audio_missing"]?.contains("Background Modes → Audio") == true)
        #expect(byCode["background_voip_missing"]?.contains("Voice over IP") == true)
        #expect(byCode["push_entitlement_missing"]?.contains("Push Notifications") == true)
        #expect(byCode["voip_pushes_not_enabled"]?.contains("enableVoIPPushes()") == true)
        #expect(byCode["microphone_blocked"]?.contains("openCallSettings(.microphone)") == true)
        #expect(byCode["hosted_ringing_off"]?.contains("In-app calling") == true)
        // Client words only: no internal service or vendor names in what a developer reads.
        for message in byCode.values {
            for word in ["Apollo", "Hermes", "gateway", "Jambonz", "mem0"] {
                #expect(!message.contains(word))
            }
        }
    }

    @Test func pushRegistrationHasItsSecondsBeforeItIsAProblem() {
        var f = readyFacts()
        f.voipPushesEnabled = false
        f.secondsSinceConfigure = 3
        #expect(codes(f).isEmpty, "the app may enable VoIP pushes a moment after configuring")
        f.secondsSinceConfigure = CallSetup.settleSeconds
        #expect(codes(f) == ["voip_pushes_not_enabled"])
        f.secondsSinceConfigure = nil
        #expect(codes(f).isEmpty, "nothing is late before configure")
    }

    @Test func aMissingTokenIsLateOnlyAfterItsSecondsAndNeverOnTheSimulator() {
        var f = readyFacts()
        f.hasVoipToken = false
        f.secondsSinceVoipEnabled = 2
        #expect(codes(f).isEmpty)
        f.secondsSinceVoipEnabled = 20
        #expect(codes(f) == ["no_voip_token"])
        f.simulator = true
        #expect(codes(f).isEmpty, "PushKit gives the simulator no token")
        f.simulator = false
        f.voipPushesEnabled = false
        #expect(codes(f) == ["voip_pushes_not_enabled"], "not enabled is the problem, not the token")
    }

    @Test func aMicrophoneNotAskedYetIsNoProblemButABlockedOneIs() {
        var f = readyFacts()
        f.microphone = .denied
        #expect(codes(f).isEmpty, "the SDK asks when a call starts")
        f.microphone = .blocked
        #expect(codes(f) == ["microphone_blocked"])
    }

    @Test func hostedRingingIsJudgedOnlyOnceASessionIsKnown() {
        var f = readyFacts()
        f.hostedRinging = nil
        #expect(codes(f).isEmpty)
        f.hostedRinging = false
        #expect(codes(f) == ["hosted_ringing_off"])
        let ios = GraineHostedCallsSettings.parse(["hosted": true, "platforms": ["ios"]])
        let android = GraineHostedCallsSettings.parse(["hosted": true, "platforms": ["android"]])
        #expect(CallSetup.hostedRinging([]) == nil)
        #expect(CallSetup.hostedRinging([android, nil]) == false, "a session without calls settings rings nobody")
        #expect(CallSetup.hostedRinging([android, ios]) == true, "any configured agent ringing this phone is enough")
    }

    @Test func eachProblemIsLoggedOnceALaunch() {
        var log = CallSetup.LogOnce()
        let a = GraineCallSetupProblem(code: "background_voip_missing", message: "…")
        let b = GraineCallSetupProblem(code: "no_voip_token", message: "…")
        #expect(log.fresh([a]).map(\.code) == ["background_voip_missing"])
        #expect(log.fresh([a, b]).map(\.code) == ["no_voip_token"])
        #expect(log.fresh([a, b]).isEmpty)
        #expect(GraineCallSetupProblem(code: "x", message: "y").fields as? [String: String] == ["code": "x", "message": "y"])
    }
}

@Suite struct PushEntitlementTests {
    private func profile(_ environment: String?) -> Data {
        let entitlements = environment.map { "<key>aps-environment</key><string>\($0)</string>" } ?? ""
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Name</key><string>Acme</string>
        <key>Entitlements</key><dict>\(entitlements)<key>application-identifier</key><string>T.ai.acme</string></dict></dict></plist>
        """
        return Data([0x30, 0x82, 0x2F, 0x01]) + Data(plist.utf8) + Data([0xA0, 0x82, 0x00])
    }

    @Test func aProfileWithoutPushCannotSignAnAppThatRings() {
        #expect(CallSetup.pushEntitlement(provisioningProfile: profile("development")) == .present)
        #expect(CallSetup.pushEntitlement(provisioningProfile: profile("production")) == .present)
        #expect(CallSetup.pushEntitlement(provisioningProfile: profile(nil)) == .missing)
    }

    @Test func aStoreBuildEmbedsNoProfileSoNothingIsClaimed() {
        #expect(CallSetup.pushEntitlement(provisioningProfile: nil) == .unknown)
        #expect(CallSetup.pushEntitlement(provisioningProfile: Data("garbage".utf8)) == .unknown)
    }
}
