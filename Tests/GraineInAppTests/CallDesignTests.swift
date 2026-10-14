import Foundation
import Testing
@testable import GraineInApp

/*
 * The chat window's and the call screen's tokens (contract §7): read
 * leniently, every field falling back on its own, absent meaning "as before";
 * and the call screen's rules — status words (scheduled and missed included),
 * the avatar's fallbacks, the controls.
 */

private let colors: [String: Any] = [
    "background": "#FFFFFF", "surface": "#F7F7F5", "surfaceRaised": "#FFFFFF", "text": "#101318", "textMuted": "#5F6672",
    "border": "#E5E4E0", "accent": "#318CE7", "onAccent": "#FFFFFF", "accentSoft": "#E3EEFB", "success": "#1FAD5B",
    "warning": "#F5A524", "danger": "#E5484D", "userBubble": "#318CE7", "userBubbleText": "#FFFFFF",
    "agentBubble": "#F1F1EF", "agentBubbleText": "#101318", "scrim": "#000000",
]

private let fullCall: [String: Any] = [
    "background": "#0B1F3A", "backgroundTo": "#1D4E89", "text": "#FFFFFF", "textMuted": "#B8C4D6",
    "avatar": "glyph", "avatarShape": "squircle", "avatarFill": "#318CE7", "avatarText": "#FFFFFF",
    "buttonFill": "#22344F", "buttonIcon": "#FFFFFF", "buttonActiveFill": "#FFFFFF", "buttonActiveIcon": "#0B1F3A",
    "endFill": "#E5484D", "endIcon": "#FFFFFF", "endShape": "pill", "acceptFill": "#1FAD5B", "acceptIcon": "#FFFFFF",
    "declineFill": "#E5484D", "declineIcon": "#FFFFFF", "captions": false, "timer": true,
    "controls": ["speaker", "mute", "chat", "end"], "ringtone": "soft",
    "statusText": ["ringing": "Acme is calling", "connecting": "Joining…", "ended": "Thanks for calling",
                   "scheduled": "Your booked call", "missed": "You missed Acme"],
]

@Suite struct CallTokenTests {
    @Test func aFullSetIsReadAsItIs() throws {
        let t = try #require(SurfaceTokens.call(fullCall))
        #expect(t.background == "#0B1F3A" && t.backgroundTo == "#1D4E89")
        #expect(t.avatar == "glyph" && t.avatarShape == "squircle")
        #expect(t.endShape == "pill")
        #expect(!t.captions && t.timer)
        #expect(t.controls == ["speaker", "mute", "chat", "end"])
        #expect(t.ringtone == "soft")
        #expect(t.statusText.scheduled == "Your booked call")
        #expect(t.statusText.missed == "You missed Acme")
    }

    @Test func eachMissingOrMalformedFieldFallsBackOnItsOwn() throws {
        let t = try #require(SurfaceTokens.call([
            "background": "navy", "text": "#fff", "avatar": "hologram", "endShape": "square",
            "controls": ["mute", "teleport", "mute"], "statusText": ["ringing": "  "],
        ]))
        let d = SurfaceTokens.legacyCall
        #expect(t.background == d.background, "not a colour: the legacy screen's")
        #expect(t.text == "#FFFFFF", "#fff is a colour")
        #expect(t.avatar == "logo" && t.endShape == "round", "an unknown word is the first one listed")
        #expect(t.controls == ["mute", "end"], "unknown dropped, repeats dropped, and always a way to hang up")
        #expect(t.statusText.ringing == "Incoming call")
        #expect(t.statusText.scheduled == "Scheduled call" && t.statusText.missed == "Missed call", "the new words are optional")
        #expect(t.backgroundTo == nil)
        #expect(SurfaceTokens.call(["controls": []])?.controls == SurfaceTokens.defaultControls)
        #expect(t.callbackFill == d.callbackFill && t.callbackIcon == d.callbackIcon)
        #expect(SurfaceTokens.call(["callbackFill": "#123456"])?.callbackFill == "#123456")
        #expect(SurfaceTokens.call("nope") == nil)
    }

    @Test func theDesignCarriesBothSchemesSetsOrNone() throws {
        let design = try #require(GraineDesign.parse([
            "config": ["scheme": "auto"],
            "light": ["colors": colors, "call": fullCall, "chat": ["title": "Acme help", "suggestions": ["Track my order"]]],
            "dark": ["colors": colors],
        ]))
        #expect(design.light.call?.statusText.missed == "You missed Acme")
        #expect(design.light.chat?.title == "Acme help")
        #expect(design.dark.call == nil, "an older server's scheme: the screen as it was")
        #expect(design.dark.chat == nil)
    }
}

@Suite struct ChatTokenTests {
    @Test func theChatSetIsReadAndFallsBackToTheSchemesColours() throws {
        let palette = try #require(DesignTokens.parse(["colors": colors], scheme: "light")).colors
        let t = try #require(SurfaceTokens.chat([
            "title": " Acme ", "avatar": "none", "showTimestamps": true, "headerBackground": "#000",
            "suggestions": ["One", "  ", "Two", "Three", "Four", "Five", String(repeating: "x", count: 60)],
        ], colors: palette))
        #expect(t.title == "Acme" && t.subtitle.isEmpty)
        #expect(t.avatar == "none")
        #expect(t.placeholder == "Message…")
        #expect(t.showTimestamps)
        #expect(t.suggestions == ["One", "Two", "Three", "Four"], "four at most, blanks dropped")
        #expect(t.headerBackground == "#000000")
        #expect(t.headerText == palette.text && t.composerBorder == palette.border && t.background == palette.background)
        let long = try #require(SurfaceTokens.chat(["suggestions": [String(repeating: "y", count: 60)]], colors: palette))
        #expect(long.suggestions.first?.count == 40)
    }

    @Test func aSurfaceWithNoDesignStillHasOne() {
        let light = DesignTokens.classic(dark: false, accent: "#E91E63")
        let dark = DesignTokens.classic(dark: true, accent: "nonsense")
        #expect(light.colors.accent == "#E91E63")
        #expect(light.scheme == "light" && dark.scheme == "dark")
        #expect(dark.colors.accent == "#318CE7", "an unreadable accent is Graine's")
        #expect(DesignTokens.mix("#FFFFFF", over: "#000000", share: 0.5) == "#808080")
    }
}

@Suite struct CallScreenRuleTests {
    private let t = SurfaceTokens.legacyCall
    private let glyph = GraineThemeTokens.Glyph(id: "waveform", path: "M2 13h20", stroke: true)

    @Test func eachStateSaysWhereTheCallIs() {
        #expect(CallScreen.status(.ringing, direction: .incoming, call: t, elapsed: nil, speaking: false) == "Incoming call")
        #expect(CallScreen.status(.ringing, direction: .incoming, call: t, elapsed: nil, speaking: false, hosted: true) == "Scheduled call")
        #expect(CallScreen.status(.connecting, direction: .incoming, call: t, elapsed: nil, speaking: false) == "Connecting…")
        #expect(CallScreen.status(.connecting, direction: .outgoing, call: t, elapsed: nil, speaking: false) == "Connecting…", "either direction")
        #expect(CallScreen.status(.active, direction: .incoming, call: t, elapsed: "0:42", speaking: true) == "0:42")
        #expect(CallScreen.status(.active, direction: .incoming, call: t, elapsed: "0:42", speaking: false, muted: true) == "0:42 · Muted")
        #expect(CallScreen.status(.ended(.remote), direction: nil, call: t, elapsed: nil, speaking: false) == "Call ended")
        #expect(CallScreen.status(.ended(.missed), direction: nil, call: t, elapsed: nil, speaking: false) == "Missed call")
        #expect(CallScreen.status(.ended(.failed), direction: nil, call: t, elapsed: nil, speaking: false) == "Call failed")
        #expect(CallScreen.status(.ended(.declined), direction: nil, call: t, elapsed: nil, speaking: false) == "Declined")
    }

    @Test func theBrandsWordsWin() throws {
        let brand = try #require(SurfaceTokens.call(fullCall))
        #expect(CallScreen.status(.ringing, direction: .incoming, call: brand, elapsed: nil, speaking: false, hosted: true) == "Your booked call")
        #expect(CallScreen.status(.ringing, direction: .incoming, call: brand, elapsed: nil, speaking: false) == "Acme is calling")
        #expect(CallScreen.status(.connecting, direction: .outgoing, call: brand, elapsed: nil, speaking: false) == "Joining…")
        #expect(CallScreen.status(.ended(.missed), direction: nil, call: brand, elapsed: nil, speaking: false) == "You missed Acme")
        let noTimer = try #require(SurfaceTokens.call(["timer": false]))
        #expect(CallScreen.status(.active, direction: nil, call: noTimer, elapsed: "1:00", speaking: false) == "Listening")
        #expect(CallScreen.status(.active, direction: nil, call: noTimer, elapsed: "1:00", speaking: true) == "Speaking")
        #expect(CallScreen.status(.active, direction: nil, call: noTimer, elapsed: "1:00", speaking: true, muted: true) == "Muted")
    }

    @Test func aMissedRingStaysOnScreenUntilTheCustomerChooses() {
        #expect(CallScreen.phase(.ended(.missed), missedPending: true) == .missed)
        #expect(CallScreen.phase(.idle, missedPending: true) == .missed)
        #expect(CallScreen.phase(.idle, missedPending: false) == .call(.idle))
        #expect(CallScreen.phase(.connecting, missedPending: true) == .call(.connecting), "a call back is a call")
    }

    @Test func theAvatarFallsBackLogoGlyphInitials() throws {
        let logo = try #require(SurfaceTokens.call(["avatar": "logo"]))
        let glyphFirst = try #require(SurfaceTokens.call(["avatar": "glyph"]))
        #expect(CallScreen.avatar(logo, glyph: glyph, logoUrl: "https://cdn.example.com/l.png", name: "Acme") == .logo("https://cdn.example.com/l.png"))
        #expect(CallScreen.avatar(logo, glyph: glyph, logoUrl: nil, name: "Acme") == .glyph(glyph))
        #expect(CallScreen.avatar(glyphFirst, glyph: nil, logoUrl: "https://cdn.example.com/l.png", name: "Acme") == .logo("https://cdn.example.com/l.png"))
        #expect(CallScreen.avatar(glyphFirst, glyph: nil, logoUrl: nil, name: "Acme care") == .initials("A"))
        #expect(CallScreen.avatar(t, glyph: glyph, logoUrl: "https://cdn.example.com/l.png", name: "Acme") == .logo("https://cdn.example.com/l.png"),
                "Classic's avatar is the logo")
        let initialsOnly = try #require(SurfaceTokens.call(["avatar": "initials"]))
        #expect(CallScreen.avatar(initialsOnly, glyph: glyph, logoUrl: "https://cdn.example.com/l.png", name: "ébène") == .initials("É"))
        #expect(CallScreen.initials("") == "A")
        #expect(CallScreen.initials("  राहुल") == "रा", "a grapheme, not a code point")
    }

    @Test func theTranscriptControlOnlyWhereThereIsATranscript() throws {
        let brand = try #require(SurfaceTokens.call(fullCall))
        #expect(CallScreen.controls(brand, transcript: true) == ["speaker", "mute", "chat", "end"])
        #expect(CallScreen.controls(brand, transcript: false) == ["speaker", "mute", "end"])
    }

    @Test func theTokensToDrawAreTheSchemesElseTheLegacyScreen() {
        #expect(CallScreen.tokens(nil) == SurfaceTokens.legacyCall)
        #expect(CallScreen.elapsed(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 3_725)) == "1:02:05")
    }

    @Test func aMissedCallIsCalledBackWithItsReason() {
        let missed = GraineMissedCall(callId: "c1", callerName: "Acme", reason: nil, hosted: true, at: Date(timeIntervalSince1970: 1_000))
        #expect(missed.callBackReason == "returning_missed_call")
        #expect(GraineMissedCall(callId: "c2", callerName: "Acme", reason: "payment_due").callBackReason == "payment_due")
        #expect(missed.isRecent(now: Date(timeIntervalSince1970: 1_000 + 599)))
        #expect(!missed.isRecent(now: Date(timeIntervalSince1970: 1_000 + 601)))
    }

    @Test func theHostKeepsAMissedRingOnScreenUntilTheCustomerChooses() {
        #expect(CallsHostCallScreenRule.step(callScreen: .sdk, state: .idle, active: true, shown: true, missedPending: true) == .stay)
        #expect(CallsHostCallScreenRule.step(callScreen: .sdk, state: .idle, active: true, shown: true, missedPending: false) == .dismiss)
        #expect(CallsHostCallScreenRule.step(callScreen: .sdk, state: .idle, active: true, shown: false, missedPending: true) == .stay,
                "a ring missed in the background is not brought up later")
    }
}

@Suite @MainActor struct ScreenContextTests {
    @Test func aFieldIsMergedAddedAndRemovedByName() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        let graine = rig.graine
        graine.updateField(GraineField(name: "pan", value: "ABCDE1234F"))
        #expect(graine.currentContextFrame() == nil, "no screen: nothing to attach it to")
        graine.setScreen(GraineScreen(screen: "kyc", fields: [GraineField(name: "pan", status: .empty)]))
        graine.updateField(GraineField(name: "pan", value: "ABCDE1234F", status: .invalid, error: "Not recognised"))
        graine.updateField(GraineField(name: "dob", status: .empty))
        var fields = try #require((graine.currentContextFrame()?["context"] as? [String: Any])?["fields"] as? [[String: Any]])
        #expect(fields.map { $0["name"] as? String } == ["pan", "dob"])
        #expect(fields[0]["status"] as? String == "invalid")
        #expect(fields[0]["value"] as? String == "[PAN]", "masked on the way out")
        graine.removeField("pan")
        graine.removeField("never-there")
        fields = try #require((graine.currentContextFrame()?["context"] as? [String: Any])?["fields"] as? [[String: Any]])
        #expect(fields.map { $0["name"] as? String } == ["dob"])
    }

    @Test func clearingAScreenOnlyClearsTheOneStillDescribed() {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        let graine = rig.graine
        graine.setScreen(GraineScreen(screen: "next"))
        graine.clearScreen("previous")
        #expect(graine.hasScreen, "a late teardown of the last screen does not blank the new one")
        graine.clearScreen("next")
        #expect(!graine.hasScreen)
        graine.setScreen(GraineScreen(screen: "x"))
        graine.clearScreen(nil)
        #expect(!graine.hasScreen)
    }

    @Test func aTapIsContextNotNews() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        let graine = rig.graine
        var frames: [[String: Any]] = []
        let stop = graine.onContext { frames.append($0) }
        graine.setScreen(GraineScreen(screen: "pay"))
        #expect(frames.count == 1)
        try await Task.sleep(nanoseconds: 450_000_000)
        graine.tap("  Pay   now ")
        #expect(frames.count == 1, "never a frame at once")
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(frames.count == 2, "one at the end of the window")
        let events = try #require((frames.last?["context"] as? [String: Any])?["recent_events"] as? [[String: Any]])
        #expect(events.last?["name"] as? String == "tap:Pay now")
        #expect(graine.namedTapSince(0))
        stop()
    }
}

@Suite struct TapRuleTests {
    @Test func aNameIsTidiedAndKeptShort() {
        #expect(TapRules.clean("  Submit\n order ") == "Submit order")
        #expect(TapRules.clean("   ") == nil)
        #expect(TapRules.clean(nil) == nil)
        #expect(TapRules.clean(String(repeating: "a", count: 80))?.count == 60)
    }

    @Test func atMostTwoTapsASecond() {
        var recent: [Double] = []
        var allowed: [Bool] = []
        for ms in [0.0, 100, 200, 300, 1_050, 1_150, 1_200] {
            let r = TapRules.admit(nowMs: ms, recent: recent)
            recent = r.recent
            allowed.append(r.allowed)
        }
        #expect(allowed == [true, true, false, false, true, true, false])
    }
}

@Suite struct VariableOrderTests {
    @Test func theTicketKeepsThePersonFirstAndNeverTheIdentifier() {
        let store = VariableStore(buildTime: ["b2": "x", "b1": "y"])
        store.setDashboardDefaults(["d1": "z", "name": "Guest"])
        store.setRuntime(["r1": "w"])
        store.setIdentity(["name": "Asha", "user_id": "P-1"])
        #expect(store.orderedForTicket().map { $0.0 } == ["name", "r1", "b1", "b2", "d1"])
        #expect(store.orderedForTicket().first?.1 == "Asha", "the person beats the default")
        store.setIdentityField("name")
        #expect(store.merged()["name"] == "Guest", "the identifying trait never reaches the variables")
        #expect(store.merged()["user_id"] == "P-1")
    }
}

/// The thirty designs the dashboard offers (contract/design.json), as the session serves them.
@Suite struct DesignCatalogueTests {
    private func cases() throws -> [[String: Any]] {
        try #require(try ContractFile.load("design.json")["cases"] as? [[String: Any]])
    }

    @Test func everyDesignCarriesACallScreenAndAChatWindowInBothSchemes() throws {
        let all = try cases()
        #expect(all.count >= 30)
        for c in all {
            let raw = try #require(c["design"] as? [String: Any])
            let design = try #require(GraineDesign.parse(raw), "case \(String(describing: (c["config"] as? [String: Any])?["preset"]))")
            for (scheme, tokens) in [("light", design.light), ("dark", design.dark)] {
                let rawCall = try #require((raw[scheme] as? [String: Any])?["call"] as? [String: Any])
                let call = try #require(tokens.call, "\(scheme) call")
                // Every colour as served, every word as served: nothing was replaced by a fallback.
                for key in ["background", "text", "textMuted", "avatarFill", "avatarText", "buttonFill", "buttonIcon", "buttonActiveFill",
                            "buttonActiveIcon", "endFill", "endIcon", "acceptFill", "acceptIcon", "declineFill", "declineIcon",
                            "callbackFill", "callbackIcon"] {
                    let served = try #require(DesignTokens.hex(rawCall[key]), "\(scheme).call.\(key)")
                    let mirror = Mirror(reflecting: call).children.first { $0.label == key }?.value as? String
                    #expect(mirror == served, "\(scheme).call.\(key)")
                }
                #expect(call.backgroundTo == DesignTokens.hex(rawCall["backgroundTo"]))
                #expect(call.avatar == rawCall["avatar"] as? String && call.avatarShape == rawCall["avatarShape"] as? String)
                #expect(call.endShape == rawCall["endShape"] as? String && call.ringtone == rawCall["ringtone"] as? String)
                #expect(call.controls == rawCall["controls"] as? [String])
                let words = try #require(rawCall["statusText"] as? [String: String])
                #expect(call.statusText.scheduled == words["scheduled"] && call.statusText.missed == words["missed"])
                #expect(call.statusText.ringing == words["ringing"] && call.statusText.ended == words["ended"])

                let rawChat = try #require((raw[scheme] as? [String: Any])?["chat"] as? [String: Any])
                let chat = try #require(tokens.chat, "\(scheme) chat")
                #expect(chat.pattern == rawChat["pattern"] as? String)
                #expect(chat.patternColor == DesignTokens.hex(rawChat["patternColor"]))
                #expect(chat.headerBackground == DesignTokens.hex(rawChat["headerBackground"]))
                #expect(chat.background == DesignTokens.hex(rawChat["background"]))
                #expect(chat.suggestions == (rawChat["suggestions"] as? [String] ?? []))
                #expect(chat.title == (rawChat["title"] as? String ?? ""))
            }
        }
    }

    @Test func beforeAnySessionTheScreenIsGraineClassics() throws {
        let first = try #require(try cases().first)
        let raw = try #require((first["design"] as? [String: Any])?["light"] as? [String: Any])
        let classic = try #require(SurfaceTokens.call(raw["call"]))
        #expect(SurfaceTokens.legacyCall == classic)
    }

    @Test func theRingtonesAreTheContractsPatterns() throws {
        let rings = try #require(try ContractFile.load("design.json")["ringtones"] as? [String: [String: Any]])
        #expect(Set(rings.keys) == Set(Ringtones.patterns.keys))
        for (name, raw) in rings {
            let mine = try #require(Ringtones.patterns[name])
            #expect(mine.wave == raw["wave"] as? String, "\(name).wave")
            #expect(mine.gain == (raw["gain"] as? NSNumber)?.doubleValue, "\(name).gain")
            #expect(mine.pauseMs == (raw["pauseMs"] as? NSNumber)?.doubleValue, "\(name).pauseMs")
            let notes = try #require(raw["notes"] as? [[String: Any]])
            #expect(mine.notes == notes.map { Ringtones.Note(hz: ($0["hz"] as! NSNumber).doubleValue, ms: ($0["ms"] as! NSNumber).doubleValue) }, "\(name).notes")
        }
    }
}

@Suite struct RingtoneTests {
    @Test func aCycleIsItsNotesThenItsPauseShapedAsTheContractSays() throws {
        let p = try #require(Ringtones.patterns["graine"])
        let rate = 22_050
        let s = Ringtones.samples(p, rate: rate)
        let noteSamples = p.notes.map { Int(($0.ms / 1_000 * Double(rate)).rounded()) }
        #expect(s.count == noteSamples.reduce(0, +) + Int(p.pauseMs / 1_000 * Double(rate)))
        // The first note starts from silence (the 10 ms rise) and never passes its gain.
        #expect(s[0] == 0)
        let peak = s.map { abs(Int($0)) }.max() ?? 0
        #expect(peak <= Int(p.gain * 32_767) + 1)
        #expect(peak > Int(p.gain * 32_767 * 0.9))
        // The rest (the third note) is silent; so is the pause.
        let restStart = noteSamples[0] + noteSamples[1]
        #expect(s[restStart..<(restStart + noteSamples[2])].allSatisfy { $0 == 0 })
        #expect(s.suffix(Int(p.pauseMs / 1_000 * Double(rate))).allSatisfy { $0 == 0 })
        // Each note ends falling to silence over its last 40 ms.
        #expect(abs(Int(s[noteSamples[0] - 1])) < 50)
    }

    @Test func aTriangleIsATriangle() throws {
        let p = try #require(Ringtones.patterns["soft"])
        let s = Ringtones.samples(p)
        #expect(s.count > 0)
        let peak = s.map { abs(Int($0)) }.max() ?? 0
        #expect(peak <= Int(p.gain * 32_767) + 1)
    }

    @Test func theFileIsAPlainWavWrittenOnce() throws {
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        let name = try #require(Ringtones.soundFile("soft", directory: sandbox.folder))
        #expect(name == "graine-ringtone-soft-v1.wav")
        let data = try Data(contentsOf: sandbox.folder.appendingPathComponent(name))
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
        let samples = Ringtones.samples(try #require(Ringtones.patterns["soft"]))
        #expect(data.count == 44 + samples.count * 2)
        #expect(Ringtones.soundFile("soft", directory: sandbox.folder) == name, "already there: not written again")
        #expect(Ringtones.soundFile("system", directory: sandbox.folder) == nil)
        #expect(Ringtones.soundFile("disco", directory: sandbox.folder) == nil)
    }
}

@Suite struct UpcomingCallsTests {
    private let zone = TimeZone(identifier: "Asia/Kolkata")!
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }

    @Test func aTimeReadsTodayTomorrowOrItsDayInTheCustomersZone() {
        let now = Date(timeIntervalSince1970: 1_791_979_200) // 14 Oct 2026, 17:30 in Kolkata
        let locale = Locale(identifier: "en_US")
        // The system's own spacing before AM/PM (a narrow no-break space on newer systems) is the system's business.
        func label(_ at: Date) -> String {
            UpcomingCalls.label(at, now: now, calendar: calendar, locale: locale).replacingOccurrences(of: "\u{202F}", with: " ")
        }
        #expect(label(now.addingTimeInterval(3_600)) == "Today, 6:30 PM")
        #expect(label(now.addingTimeInterval(16 * 3_600)) == "Tomorrow, 9:30 AM")
        let later = label(now.addingTimeInterval(3 * 86_400))
        #expect(later.hasPrefix("Sat, Oct 17") && later.hasSuffix("5:30 PM"), "\(later)")
    }

    @Test func theCardListsWhatIsStillToRingSoonestFirstAtMostThree() {
        let t0 = Date(timeIntervalSince1970: 2_000_000_000)
        let calls = [
            GraineScheduledCall(id: "c", at: t0.addingTimeInterval(300), status: .scheduled),
            GraineScheduledCall(id: "a", at: t0.addingTimeInterval(100), status: .scheduled),
            GraineScheduledCall(id: "ringing", at: t0, status: .ringing),
            GraineScheduledCall(id: "done", at: t0, status: .completed),
            GraineScheduledCall(id: "timeless", at: nil, status: .scheduled),
            GraineScheduledCall(id: "b", at: t0.addingTimeInterval(200), status: .scheduled),
            GraineScheduledCall(id: "d", at: t0.addingTimeInterval(400), status: .scheduled),
        ]
        #expect(UpcomingCalls.shown(calls).map { $0.id } == ["ringing", "a", "b"], "still to come — ringing too — soonest first, three")
        #expect(UpcomingCalls.shown(calls).map { $0.canCancel } == [false, true, true], "a call ringing now cannot be called off")
        #expect(UpcomingCalls.title(count: 1) == "Upcoming call" && UpcomingCalls.title(count: 2) == "Upcoming calls")
    }
}

@Suite struct ChatPatternTokenTests {
    @Test func thePatternIsReadAndAnUnknownOneIsNone() throws {
        let palette = try #require(DesignTokens.parse(["colors": colors], scheme: "light")).colors
        let dots = try #require(SurfaceTokens.chat(["pattern": "dots", "patternColor": "#E0E0DF"], colors: palette))
        #expect(dots.pattern == "dots" && dots.patternColor == "#E0E0DF")
        let odd = try #require(SurfaceTokens.chat(["pattern": "stars"], colors: palette))
        #expect(odd.pattern == "none")
    }
}
