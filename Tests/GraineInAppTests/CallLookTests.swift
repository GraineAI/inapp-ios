import Foundation
import Testing
@testable import GraineInApp

/*
 * THE CALL SCREEN'S LOOK (contract/DESIGN.md "Call screen" → "The look"):
 * every design in contract/design.json read as served — and, with the look's
 * keys taken away, derived exactly as the server derives it for a design that
 * set none — and every rule the renderer shares with the other SDKs agreeing
 * with design.json → callVectors and callScreen.
 */

private func contract() throws -> [String: Any] { try ContractFile.load("design.json") }
private func vectors() throws -> [String: Any] { try #require(try contract()["callVectors"] as? [String: Any]) }
private func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? .nan }

/// The look's keys on `call`: what a server that predates the look does not send.
private let lookKeys = [
    "preset", "layout", "backdrop", "ink", "avatarSize", "rings", "avatarRingColor", "buttonStyle", "buttonShape", "buttonSize",
    "buttonLabels", "actions", "visualizer", "visualizerColor", "visualizerSensitivity", "captionStyle", "captionPosition",
    "captionFill", "captionFillAlpha", "nameSize", "nameWeight", "statusSize", "statusWeight", "states",
]
private let actionNames = ["answer", "decline", "end", "callback", "mute", "speaker", "chat", "close"]

private func backdrop(_ raw: [String: Any]) -> GraineCallLook.Backdrop {
    let stops = (raw["stops"] as? [[String: Any]] ?? []).map { GraineCallLook.Stop(color: $0["color"] as! String, at: num($0["at"])) }
    return .init(type: raw["type"] as! String, stops: stops, angle: num(raw["angle"]), motion: raw["motion"] as! String,
                 intensity: num(raw["intensity"]), scrim: raw["scrim"].map { num($0) } ?? 1)
}

private func close(_ a: Double, _ b: Double, _ within: Double, _ what: String) {
    #expect(abs(a - b) <= within, "\(what): \(a) vs \(b)")
}

private func sameColor(_ a: String, _ b: String, _ what: String) {
    let x = CallScreen.channels(a), y = CallScreen.channels(b)
    #expect(abs(x.0 - y.0) <= 1.01 && abs(x.1 - y.1) <= 1.01 && abs(x.2 - y.2) <= 1.01, "\(what): \(a) vs \(b)")
}

/// A look as served, against how it was read.
private func expectLook(_ look: GraineCallLook, _ raw: [String: Any], _ where_: String) {
    let bd = backdrop(raw["backdrop"] as! [String: Any])
    #expect(look.backdrop == bd, "\(where_).backdrop")
    #expect(look.ink == raw["ink"] as? String, "\(where_).ink")
    #expect(look.text == raw["text"] as? String && look.textMuted == raw["textMuted"] as? String, "\(where_).text")
    #expect(look.avatarRingColor == raw["avatarRingColor"] as? String, "\(where_).avatarRingColor")
    #expect(look.visualizerColor == raw["visualizerColor"] as? String, "\(where_).visualizerColor")
    #expect(look.captionFill == raw["captionFill"] as? String && look.captionFillAlpha == num(raw["captionFillAlpha"]), "\(where_).caption")
    let actions = raw["actions"] as! [String: [String: Any]]
    for name in actionNames {
        let a = look.actions[name], r = actions[name]!
        #expect(a.fill == r["fill"] as? String && a.fillAlpha == num(r["fillAlpha"]) && a.icon == r["icon"] as? String, "\(where_).\(name)")
        #expect(a.stroke == r["stroke"] as? String, "\(where_).\(name).stroke")
        #expect(a.activeFill == r["activeFill"] as? String && a.activeIcon == r["activeIcon"] as? String, "\(where_).\(name).active")
    }
}

@Suite struct CallLookContractTests {
    @Test func everyDesignsLookIsReadAsServedInBothSchemes() throws {
        let cases = try #require(try contract()["cases"] as? [[String: Any]])
        var looks = 0
        for (i, c) in cases.enumerated() {
            let raw = try #require(c["design"] as? [String: Any])
            let design = try #require(GraineDesign.parse(raw))
            for (scheme, tokens) in [("light", design.light), ("dark", design.dark)] {
                let rc = try #require((raw[scheme] as? [String: Any])?["call"] as? [String: Any])
                let call = try #require(tokens.call)
                let w = "case \(i) \(scheme)"
                #expect(call.preset == rc["preset"] as? String && call.layout == rc["layout"] as? String, "\(w) preset/layout")
                #expect(call.avatarSize == num(rc["avatarSize"]) && call.buttonSize == num(rc["buttonSize"]), "\(w) sizes")
                #expect(call.buttonStyle == rc["buttonStyle"] as? String && call.buttonShape == rc["buttonShape"] as? String, "\(w) buttons")
                #expect(call.buttonLabels == rc["buttonLabels"] as? String && call.visualizer == rc["visualizer"] as? String, "\(w)")
                #expect(call.visualizerSensitivity == num(rc["visualizerSensitivity"]), "\(w) sensitivity")
                #expect(call.captionStyle == rc["captionStyle"] as? String && call.captionPosition == rc["captionPosition"] as? String, "\(w)")
                #expect(call.nameSize == num(rc["nameSize"]) && call.statusSize == num(rc["statusSize"]), "\(w) type sizes")
                #expect(Double(call.nameWeight) == num(rc["nameWeight"]) && Double(call.statusWeight) == num(rc["statusWeight"]), "\(w) weights")
                #expect(call.rings == rc["rings"] as? [String: String], "\(w) rings")
                let words = try #require(rc["statusText"] as? [String: String])
                #expect(call.statusText.outgoing == words["outgoing"] && call.statusText.reconnecting == words["reconnecting"], "\(w) words")
                expectLook(call.look, rc, w)
                let states = rc["states"] as? [String: [String: Any]] ?? [:]
                #expect(Set(call.states.keys) == Set(states.keys), "\(w) moments")
                for (m, rs) in states { expectLook(try #require(call.states[m]), rs, "\(w) \(m)"); looks += 1 }
                looks += 1
            }
        }
        #expect(looks > 100)
    }

    @Test func aServerThatPredatesTheLookDrawsTodaysScreen() throws {
        let cases = try #require(try contract()["cases"] as? [[String: Any]])
        var checked = 0
        for (i, c) in cases.enumerated() {
            // Only designs that set no knob of the look: for them the server derived it, as an SDK must.
            let config = c["config"] as? [String: Any] ?? [:]
            let knobs = (config["call"] as? [String: Any] ?? [:]).keys.filter { lookKeys.contains($0) && $0 != "preset" }
            let preset = (config["call"] as? [String: Any])?["preset"] as? String
            guard knobs.isEmpty, preset == nil || preset == "classic" else { continue }
            let raw = try #require(c["design"] as? [String: Any])
            for scheme in ["light", "dark"] {
                let tokens = try #require(raw[scheme] as? [String: Any])
                var old = try #require(tokens["call"] as? [String: Any])
                for k in lookKeys { old.removeValue(forKey: k) }
                var words = try #require(old["statusText"] as? [String: Any])
                words.removeValue(forKey: "outgoing")
                words.removeValue(forKey: "reconnecting")
                old["statusText"] = words
                var olderTokens = tokens
                olderTokens["call"] = old
                let served = try #require(DesignTokens.parse(tokens, scheme: scheme)?.call)
                let derived = try #require(DesignTokens.parse(olderTokens, scheme: scheme)?.call)
                #expect(derived == served, "case \(i) \(scheme): derived as the server derives it")
                checked += 1
            }
        }
        #expect(checked >= 60, "\(checked) designs derived")
    }

    @Test func eachKeyOfTheLookFallsBackOnItsOwn() throws {
        let t = try #require(SurfaceTokens.call([
            "background": "#101010", "text": "#FFFFFF", "textMuted": "#BBBBBB",
            "layout": "sideways", "buttonStyle": 7, "avatarSize": 999, "rings": ["incoming": "spin", "connected": "glow"],
            "backdrop": ["type": "hologram", "stops": [["color": "nope"], ["color": "#ff0000", "at": 3]], "motion": "wobble"],
            "actions": ["mute": ["fill": "#123456", "fillAlpha": 0.3, "stroke": NSNull()], "end": "x"],
            "states": ["ended": ["ink": "dark"], "lunch": ["ink": "dark"]],
        ]))
        #expect(t.layout == "classic", "an unknown word is the first one listed")
        #expect(t.buttonStyle == "solid")
        #expect(t.avatarSize == 160, "clamped")
        #expect(t.rings["incoming"] == "none" && t.rings["connected"] == "glow" && t.rings["scheduled"] == "pulse", "absent: derived")
        #expect(t.look.backdrop.type == "solid" && t.look.backdrop.motion == "none")
        #expect(t.look.backdrop.stops == [.init(color: "#FF0000", at: 1)], "only the stops that are colours")
        #expect(t.look.actions.mute.fill == "#123456" && t.look.actions.mute.fillAlpha == 0.3 && t.look.actions.mute.stroke == nil)
        #expect(t.look.actions.end.fill == SurfaceTokens.legacyFields["endFill"] as? String, "a broken button keeps the derived one")
        #expect(t.look.ink == "light", "derived from the text")
        #expect(Set(t.states.keys) == ["ended"], "a moment nobody knows is ignored")
        #expect(t.states["ended"]?.ink == "dark" && t.states["ended"]?.text == "#FFFFFF", "a moment's missing keys are the screen's")
        #expect(t.statusText.outgoing == "Connecting…" && t.statusText.reconnecting == "Reconnecting…")
        let brand = try #require(SurfaceTokens.call(["statusText": ["connecting": "Putting you through…"]]))
        #expect(brand.statusText.outgoing == "Putting you through…", "a placed call says the brand's connecting words")
    }

    @Test func theScreensNumbersAreTheContracts() throws {
        let screen = try #require(try contract()["callScreen"] as? [String: Any])
        let layouts = try #require(screen["layouts"] as? [String: [String: Any]])
        #expect(Set(layouts.keys) == Set(CallScreen.layouts.keys))
        for (name, l) in layouts {
            let mine = CallScreen.layout(name)
            #expect(mine.leading == ((l["align"] as? String) == "start"), "\(name).align")
            #expect(mine.top == num(l["top"]) && mine.avatar == num(l["avatar"]) && mine.nameGap == num(l["nameGap"]), "\(name)")
            #expect(mine.nameFirst == (l["nameFirst"] as? Bool) && mine.card == (l["card"] as? Bool), "\(name)")
            #expect(mine.nameSize == num(l["nameSize"]) && Double(mine.nameLines) == num(l["nameLines"]), "\(name)")
        }
        let s = try #require(screen["screen"] as? [String: Any])
        typealias S = CallScreen.Screen
        let pairs: [(String, Double)] = [
            ("side", S.side), ("statusGap", S.statusGap), ("visualizerGap", S.visualizerGap), ("visualizerHeight", S.visualizerHeight),
            ("captionGap", S.captionGap), ("captionAboveButtons", S.captionAboveButtons), ("buttonsBottom", S.buttonsBottom),
            ("labelGap", S.labelGap), ("labelSize", S.labelSize), ("cardPadding", S.cardPadding), ("cardRadius", S.cardRadius),
            ("cardMinAlpha", S.cardMinAlpha), ("orbScale", S.orbScale), ("speakingScale", S.speakingScale), ("endedAlpha", S.endedAlpha),
            ("bigButton", S.bigButton), ("icon", S.icon),
        ]
        for (k, v) in pairs { close(num(s[k]), v, 1e-9, "screen.\(k)") }
        let rings = try #require(screen["rings"] as? [String: [String: Any]])
        close(num(rings["pulse"]?["periodMs"]), CallScreen.Rings.pulse.periodMs, 0, "pulse")
        close(num(rings["pulse"]?["scale"]), CallScreen.Rings.pulse.scale, 1e-9, "pulse scale")
        close(num(rings["ripple"]?["periodMs"]), CallScreen.Rings.ripple.periodMs, 0, "ripple")
        close(num(rings["ripple"]?["scale"]), CallScreen.Rings.ripple.scale, 1e-9, "ripple scale")
        close(num(rings["ripple"]?["count"]), Double(CallScreen.Rings.ripple.count), 0, "ripple count")
        close(num(rings["glow"]?["reach"]), CallScreen.Rings.glow.reach, 1e-9, "glow reach")
        close(num(rings["glow"]?["periodMs"]), CallScreen.Rings.glow.periodMs, 0, "glow")
        let voice = try #require(screen["visualizer"] as? [String: Any])
        let bars = try #require(voice["bars"] as? [String: Any])
        #expect((bars["weights"] as? [NSNumber])?.map { $0.doubleValue } == CallScreen.Voice.barWeights)
        close(num(bars["max"]), CallScreen.Voice.barMax, 0, "bars.max")
        close(num((voice["wave"] as? [String: Any])?["width"]), CallScreen.Voice.waveWidth, 0, "wave.width")
        close(num((voice["orb"] as? [String: Any])?["rest"]), CallScreen.Voice.orbRest, 1e-9, "orb.rest")
        close(num(voice["attackMs"]), CallScreen.Voice.attackMs, 0, "attack")
        close(num(voice["releaseMs"]), CallScreen.Voice.releaseMs, 0, "release")
        let motion = try #require(screen["motion"] as? [String: Any])
        close(num(motion["breatheMs"]), CallScreen.Motion.breatheMs, 0, "breathe")
        close(num(motion["idleMs"]), CallScreen.Motion.idleMs, 0, "idle")
        close(num(motion["blur"]), CallScreen.Motion.blur, 0, "blur")
        #expect((screen["moments"] as? [String]) == CallMoment.allCases.map { $0.rawValue })
        #expect((screen["moments"] as? [String]) == SurfaceTokens.moments)
    }
}

@Suite struct CallLookVectorTests {
    @Test func gradientLines() throws {
        for v in try #require(try vectors()["lines"] as? [[String: Any]]) {
            let l = CallScreen.gradientLine(angle: num(v["angle"]), w: num(v["w"]), h: num(v["h"]))
            let e = try #require(v["line"] as? [String: Any])
            for (k, x) in [("x0", l.x0), ("y0", l.y0), ("x1", l.x1), ("y1", l.y1)] { close(x, num(e[k]), 0.011, "line \(v["angle"]!) \(k)") }
        }
    }

    @Test func backdropFramesOverTime() throws {
        for v in try #require(try vectors()["frames"] as? [[String: Any]]) {
            let b = backdrop(try #require(v["backdrop"] as? [String: Any]))
            let f = CallScreen.backdropFrame(b, w: num(v["w"]), h: num(v["h"]), t: num(v["t"]))
            let e = try #require(v["frame"] as? [String: Any])
            let what = "\(b.type) \(b.motion) t=\(num(v["t"]))"
            let line = try #require(e["line"] as? [String: Any])
            for (k, x) in [("x0", f.line.x0), ("y0", f.line.y0), ("x1", f.line.x1), ("y1", f.line.y1)] { close(x, num(line[k]), 0.011, "\(what) line.\(k)") }
            let radial = try #require(e["radial"] as? [String: Any])
            close(f.radial.cx, num(radial["cx"]), 0.011, "\(what) cx")
            close(f.radial.cy, num(radial["cy"]), 0.011, "\(what) cy")
            close(f.radial.r, num(radial["r"]), 0.011, "\(what) r")
            let mesh = try #require(e["mesh"] as? [[String: Any]])
            #expect(f.mesh.count == mesh.count, "\(what) glows")
            for (g, m) in zip(f.mesh, mesh) {
                close(g.u, num(m["u"]), 0.0011, "\(what) u")
                close(g.v, num(m["v"]), 0.0011, "\(what) v")
                #expect(g.color == m["color"] as? String, "\(what) glow colour")
            }
            let avatar = try #require(e["avatar"] as? [String: Any])
            close(f.avatar.dx, num(avatar["dx"]), 0.011, "\(what) dx")
            close(f.avatar.dy, num(avatar["dy"]), 0.011, "\(what) dy")
            close(f.avatar.scale, num(avatar["scale"]), 0.0011, "\(what) scale")
        }
    }

    @Test func meshColours() throws {
        for v in try #require(try vectors()["mesh"] as? [[String: Any]]) {
            let glows = try #require(v["glows"] as? [[String: Any]]).map { CallScreen.Glow(u: num($0["u"]), v: num($0["v"]), color: $0["color"] as! String) }
            sameColor(CallScreen.meshColor(glows, u: num(v["u"]), v: num(v["v"])), try #require(v["color"] as? String), "mesh at \(num(v["u"])),\(num(v["v"]))")
        }
    }

    @Test func buttonBoxesAndSizes() throws {
        for v in try #require(try vectors()["buttons"] as? [[String: Any]]) {
            let a = try #require(v["args"] as? [String: Any])
            let f = CallScreen.buttonFrame(shape: a["shape"] as! String, size: num(a["size"]), share: num(a["share"]),
                                           end: a["end"] as? Bool ?? false, endShape: a["endShape"] as? String, on: a["on"] as? Bool ?? false)
            let e = try #require(v["frame"] as? [String: Any])
            #expect(f.width == num(e["width"]) && f.height == num(e["height"]) && f.radius == num(e["radius"]) && f.continuous == (e["continuous"] as? Bool), "\(a)")
        }
        for v in try #require(try vectors()["buttonSizes"] as? [[String: Any]]) {
            let s = CallScreen.buttonSizes(num(v["buttonSize"]))
            let e = try #require(v["sizes"] as? [String: Any])
            #expect(s.button == num(e["button"]) && s.big == num(e["big"]) && s.icon == num(e["icon"]), "size \(num(v["buttonSize"]))")
        }
    }

    @Test func theVoice() throws {
        for v in try #require(try vectors()["levels"] as? [[String: Any]]) {
            close(CallScreen.voiceLevel(num(v["raw"]), sensitivity: num(v["sensitivity"])), num(v["level"]), 0.0011, "level \(num(v["raw"])) @ \(num(v["sensitivity"]))")
        }
        for v in try #require(try vectors()["speaking"] as? [[String: Any]]) {
            close(CallScreen.speakingLevel(num(v["t"])), num(v["level"]), 0.0011, "speaking at \(num(v["t"]))")
        }
        #expect(CallScreen.smoothLevel(0, toward: 1, dtMs: 60) > CallScreen.smoothLevel(1, toward: 0, dtMs: 60) - 0.5, "up faster than down")
        #expect(CallScreen.smoothLevel(0.4, toward: 0.4, dtMs: 16) == 0.4)
    }

    @Test func momentsAndTheirWords() throws {
        for v in try #require(try vectors()["moments"] as? [[String: Any]]) {
            let i = try #require(v["input"] as? [String: Any])
            let m = CallScreen.moment(word: i["state"] as! String, direction: i["direction"] as? String, hosted: i["hosted"] as? Bool ?? false,
                                      missed: i["missed"] as? Bool ?? false, reconnecting: i["reconnecting"] as? Bool ?? false)
            #expect(m.rawValue == v["moment"] as? String, "\(i)")
        }
        // The SDK's own states map onto the same moments.
        #expect(CallScreen.moment(.ringing, direction: .incoming, hosted: true, missed: false) == .scheduled)
        #expect(CallScreen.moment(.connecting, direction: .outgoing, hosted: false, missed: false) == .outgoing)
        #expect(CallScreen.moment(.connecting, direction: .incoming, hosted: false, missed: false) == .connecting)
        #expect(CallScreen.moment(.active, direction: .incoming, hosted: false, missed: false) == .connected)
        #expect(CallScreen.moment(.ended(.missed), direction: .incoming, hosted: false, missed: false) == .missed)
        #expect(CallScreen.moment(.idle, direction: nil, hosted: false, missed: true) == .missed)

        let cases = try #require(try contract()["cases"] as? [[String: Any]])
        let turnedCase = try #require(cases.first { (($0["config"] as? [String: Any])?["call"] as? [String: Any])?["layout"] as? String == "full-bleed" })
        let turned = try #require(GraineDesign.parse(turnedCase["design"])?.light.call)
        var plainRaw = try #require(((cases[0]["design"] as? [String: Any])?["light"] as? [String: Any])?["call"] as? [String: Any])
        plainRaw["timer"] = false
        let noTimer = try #require(SurfaceTokens.call(plainRaw))
        for v in try #require(try vectors()["status"] as? [[String: Any]]) {
            let call = (v["call"] as? String) == "turned" ? turned : noTimer
            let o = v["options"] as? [String: Any] ?? [:]
            let moment = try #require(CallMoment(rawValue: v["moment"] as! String))
            let words = CallScreen.statusWords(call, moment, elapsedMs: o["elapsedMs"].map { num($0) }, muted: o["muted"] as? Bool ?? false,
                                               speaking: o["speaking"] as? Bool ?? false, ending: CallEnding(rawValue: o["ending"] as? String ?? "normal") ?? .normal)
            #expect(words == v["words"] as? String, "\(v["call"]!) \(moment) \(o)")
        }
        for v in try #require(try vectors()["looks"] as? [[String: Any]]) {
            let moment = try #require(CallMoment(rawValue: v["moment"] as! String))
            #expect((turned.states[moment.rawValue] != nil) == (v["own"] as? Bool), "\(moment) own")
            #expect(CallScreen.look(turned, moment).backdrop == backdrop(try #require(v["backdrop"] as? [String: Any])), "\(moment) backdrop")
            #expect(CallScreen.ring(turned, moment) == v["ring"] as? String, "\(moment) ring")
        }
    }

    @Test func theStatusBarFollowsTheInk() throws {
        let light = try #require(SurfaceTokens.call(["text": "#FFFFFF", "ink": "light"]))
        let dark = try #require(SurfaceTokens.call(["text": "#101318", "background": "#FFFFFF"]))
        #expect(CallScreen.lightStatusBar(light) && !CallScreen.lightStatusBar(dark))
        #expect(CallScreen.lightStatusBar(light.look) && !CallScreen.lightStatusBar(dark.look))
    }
}
