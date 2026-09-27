import Foundation
import Testing
@testable import GraineInApp

/**
 * THE DESIGN CONTRACT (contract/design.json): real session `design` objects,
 * produced by the React Native SDK's own resolver, with the expected picks and
 * glyph URLs. This SDK never resolves a philosophy; what it must prove is that
 * it reads every token exactly, picks light or dark the same way, and builds
 * the same glyph URL. Regenerate with:
 *
 *   cd sdk/inapp && npm run build && node ../contract/generate-design.mjs
 *
 * A missing file FAILS — it never skips.
 */
@Suite struct DesignContractTests {

    private func contract() throws -> [String: Any] {
        try ContractFile.load("design.json")
    }

    private func cases() throws -> [[String: Any]] {
        let cases = try #require(try contract()["cases"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        return cases
    }

    @Test func everyDesignInTheContractParsesTokenForToken() throws {
        for c in try cases() {
            let raw = try #require(c["design"] as? [String: Any])
            let design = try #require(GraineDesign.parse(raw), "config: \(String(describing: c["config"]))")
            try expectTokens(design.light, equal: try #require(raw["light"] as? [String: Any]))
            try expectTokens(design.dark, equal: try #require(raw["dark"] as? [String: Any]))
            let config = try #require(raw["config"] as? [String: Any])
            #expect(design.preset == config["preset"] as? String)
            #expect(design.scheme.rawValue == (config["scheme"] as? String ?? "auto"))
        }
    }

    @Test func picksLightOrDarkTheWayTheContractDoes() throws {
        for c in try cases() {
            let design = try #require(GraineDesign.parse(c["design"]))
            let picks = try #require(c["picks"] as? [String: String])
            #expect(design.tokens(deviceDark: false).scheme == picks["deviceLight"])
            #expect(design.tokens(deviceDark: true).scheme == picks["deviceDark"])
            #expect(design.tokens(deviceDark: nil).scheme == picks["deviceUnknown"])
        }
    }

    /// An embed that never chose a design still gets one: Graine Classic with its old Appearance settings.
    @Test func theLegacySessionDrawsItsOldAppearanceThroughTheDesign() throws {
        let legacy = try #require(try contract()["legacy"] as? [String: Any])
        let raw = try #require(legacy["design"] as? [String: Any])
        let design = try #require(GraineDesign.parse(raw))
        try expectTokens(design.dark, equal: try #require(raw["dark"] as? [String: Any]))
        #expect(design.scheme == .dark)
        #expect(design.tokens(deviceDark: false).scheme == "dark")
        let appearance = try #require(legacy["appearance"] as? [String: Any])
        #expect(design.light.colors.accent == appearance["accent"] as? String)
    }

    @Test func buildsTheSameGlyphUrls() throws {
        let glyphs = try #require(try contract()["glyphs"] as? [[String: Any]])
        #expect(!glyphs.isEmpty)
        for g in glyphs {
            let args = try #require(g["args"] as? [Any])
            let url = GraineGlyph.url(
                origin: try #require(args[0] as? String),
                id: try #require(args[1] as? String),
                color: try #require(args[2] as? String),
                sizePx: try #require((args[3] as? NSNumber)?.doubleValue),
                stroke: try #require((args[4] as? NSNumber)?.doubleValue)
            )
            #expect(url == g["url"] as? String)
        }
    }

    /**
     * Window chrome, case by case: the contract carries `chrome` in every
     * scheme of every case, and each is read exactly. Desktop Buddy opens in
     * windows; a design whose brand turned the knob on does too; the rest are
     * plain surfaces.
     */
    @Test func everyCaseReadsItsChromeExactly() throws {
        var windows = 0
        var plain = 0
        for c in try cases() {
            let raw = try #require(c["design"] as? [String: Any])
            let design = try #require(GraineDesign.parse(raw))
            for (scheme, tokens) in [("light", design.light), ("dark", design.dark)] {
                let json = try #require(raw[scheme] as? [String: Any])
                let want = try #require(json["chrome"] as? String, "\(scheme) of \(String(describing: c["config"])) has no chrome")
                #expect(tokens.chrome.rawValue == want, "\(scheme) of \(String(describing: c["config"]))")
                if tokens.chrome == .window { windows += 1 } else { plain += 1 }
            }
        }
        #expect(windows > 0, "the contract has designs that open in windows")
        #expect(plain > 0, "and designs that do not")

        let all = try cases()
        let buddy = try #require(all.first { ($0["config"] as? [String: Any])?["preset"] as? String == "desktop-buddy" })
        let buddyDesign = try #require(GraineDesign.parse(buddy["design"]))
        #expect(buddyDesign.light.chrome == .window)
        #expect(buddyDesign.dark.chrome == .window)
        let knob = try #require(all.first { ($0["config"] as? [String: Any])?["chrome"] as? String == "window" })
        let knobDesign = try #require(GraineDesign.parse(knob["design"]))
        #expect(knobDesign.light.chrome == .window)
        #expect(knobDesign.dark.chrome == .window)
    }

    @Test func everyLauncherGlyphInTheContractIsDrawable() throws {
        for c in try cases() {
            let design = try #require(GraineDesign.parse(c["design"]))
            for tokens in [design.light, design.dark] {
                guard let glyph = tokens.icons.launcher else { continue }
                let segments = try #require(GlyphPath.parse(glyph.path), "glyph \(glyph.id)")
                #expect(!segments.isEmpty)
            }
        }
    }

    // MARK: - Comparing against the JSON, key by key

    private func expectTokens(_ t: GraineThemeTokens, equal json: [String: Any]) throws {
        #expect(t.scheme == json["scheme"] as? String)
        #expect(t.preset == json["preset"] as? String)

        let colors = try #require(json["colors"] as? [String: String])
        let parsed = Dictionary(uniqueKeysWithValues: Mirror(reflecting: t.colors).children.compactMap { child in
            child.label.map { ($0, child.value as? String ?? "") }
        })
        #expect(parsed.count == DesignTokens.colorKeys.count)
        for (key, value) in colors { #expect(parsed[key] == value, "colors.\(key)") }

        let font = try #require(json["font"] as? [String: Any])
        #expect(t.font.body == font["body"] as? String)
        #expect(t.font.heading == font["heading"] as? String)
        let scale = try #require(font["scale"] as? [String: Double])
        #expect(t.font.scale.caption == scale["caption"])
        #expect(t.font.scale.body == scale["body"])
        #expect(t.font.scale.title == scale["title"])
        #expect(t.font.scale.display == scale["display"])
        let weights = try #require(font["weights"] as? [String: Int])
        #expect(t.font.weights.body == weights["body"])
        #expect(t.font.weights.strong == weights["strong"])
        #expect(t.font.weights.title == weights["title"])
        let spacing = try #require(font["letterSpacing"] as? [String: Double])
        #expect(t.font.letterSpacing.body == spacing["body"])
        #expect(t.font.letterSpacing.title == spacing["title"])
        let line = try #require(font["lineHeight"] as? [String: Double])
        #expect(t.font.lineHeight.body == line["body"])
        #expect(t.font.lineHeight.title == line["title"])

        let shape = try #require(json["shape"] as? [String: Any])
        let radius = try #require(shape["radius"] as? [String: Double])
        #expect(t.shape.radius.sm == radius["sm"])
        #expect(t.shape.radius.md == radius["md"])
        #expect(t.shape.radius.lg == radius["lg"])
        #expect(t.shape.radius.xl == radius["xl"])
        #expect(t.shape.borderWidth == (shape["borderWidth"] as? NSNumber)?.doubleValue)
        #expect(t.shape.launcher.rawValue == shape["launcher"] as? String)

        let space = try #require(json["spacing"] as? [String: Double])
        #expect(t.spacing.unit == space["unit"])
        #expect(t.spacing.cardPadding == space["cardPadding"])
        #expect(t.spacing.gap == space["gap"])

        let elevation = try #require(json["elevation"] as? [String: Any])
        expectShadow(t.elevation.card, elevation["card"])
        expectShadow(t.elevation.floating, elevation["floating"])
        if let hard = elevation["hardOffset"] as? [String: Double] {
            #expect(t.elevation.hardOffset == GraineThemeTokens.Offset(x: hard["x"]!, y: hard["y"]!))
        } else {
            #expect(t.elevation.hardOffset == nil)
        }

        let motion = try #require(json["motion"] as? [String: Any])
        #expect(t.motion.durationMs == (motion["durationMs"] as? NSNumber)?.doubleValue)
        #expect(t.motion.easing == motion["easing"] as? String)
        #expect(t.motion.bounce == (motion["bounce"] as? NSNumber)?.doubleValue)

        let icons = try #require(json["icons"] as? [String: Any])
        #expect(t.icons.style == icons["style"] as? String)
        #expect(t.icons.stroke == (icons["stroke"] as? NSNumber)?.doubleValue)
        if let glyph = icons["launcher"] as? [String: Any] {
            #expect(t.icons.launcher == GraineThemeTokens.Glyph(
                id: glyph["id"] as! String, path: glyph["path"] as! String, stroke: glyph["stroke"] as! Bool
            ))
        } else {
            #expect(t.icons.launcher == nil)
        }

        if let glass = json["glass"] as? [String: Double] {
            #expect(t.glass == GraineThemeTokens.Glass(blur: glass["blur"]!, surfaceOpacity: glass["surfaceOpacity"]!))
        } else {
            #expect(t.glass == nil)
        }
        #expect(t.bubbles.rawValue == json["bubbles"] as? String)
        // Absent from an older server's tokens: a plain surface.
        #expect(t.chrome.rawValue == (json["chrome"] as? String ?? "none"))
    }

    private func expectShadow(_ shadow: GraineThemeTokens.Shadow?, _ json: Any?) {
        guard let s = json as? [String: Any] else {
            #expect(shadow == nil)
            return
        }
        #expect(shadow == GraineThemeTokens.Shadow(
            y: (s["y"] as! NSNumber).doubleValue,
            blur: (s["blur"] as! NSNumber).doubleValue,
            spread: (s["spread"] as! NSNumber).doubleValue,
            opacity: (s["opacity"] as! NSNumber).doubleValue,
            color: s["color"] as! String
        ))
    }
}

@Suite struct DesignParsingTests {

    /// The first contract case, as a mutable tree — the base the cases below bend.
    private func classic() throws -> [String: Any] {
        let cases = try #require(try ContractFile.load("design.json")["cases"] as? [[String: Any]])
        return try #require(cases.first?["design"] as? [String: Any])
    }

    private func edit(_ design: [String: Any], scheme: String, _ change: (inout [String: Any]) -> Void) -> [String: Any] {
        var out = design
        var tokens = out[scheme] as? [String: Any] ?? [:]
        change(&tokens)
        out[scheme] = tokens
        return out
    }

    @Test func unknownKeysAnywhereAreIgnored() throws {
        let base = try classic()
        var noisy = base
        noisy["future"] = ["anything": [1, 2, 3]]
        var config = noisy["config"] as? [String: Any] ?? [:]
        config["newKnob"] = "on"
        noisy["config"] = config
        for scheme in ["light", "dark"] {
            noisy = edit(noisy, scheme: scheme) { t in
                t["v"] = 2
                t["sparkle"] = true
                var colors = t["colors"] as! [String: Any]
                colors["highlight"] = "#123456"
                colors["notAColour"] = 42
                t["colors"] = colors
                var font = t["font"] as! [String: Any]
                font["features"] = ["tnum"]
                t["font"] = font
                var icons = t["icons"] as! [String: Any]
                var glyph = icons["launcher"] as! [String: Any]
                glyph["label"] = "Waveform"
                icons["launcher"] = glyph
                t["icons"] = icons
            }
        }
        let parsed = try #require(GraineDesign.parse(noisy))
        #expect(parsed == GraineDesign.parse(base))
    }

    @Test func somethingThatIsNotADesignIsNilNeverACrash() throws {
        let base = try classic()
        let garbage: [Any?] = [
            nil, NSNull(), "design", 42, true, [1, 2], [String: Any](),
            ["light": [String: Any](), "dark": [String: Any]()],
            ["light": base["light"]!],                                         // no dark
            ["light": base["light"]!, "dark": "dark"],
            edit(base, scheme: "dark") { $0["colors"] = ["accent": "#318CE7"] },   // incomplete colours
            edit(base, scheme: "light") { t in
                var colors = t["colors"] as! [String: Any]
                colors["accent"] = "blue"
                t["colors"] = colors
            },
            edit(base, scheme: "light") { t in
                var colors = t["colors"] as! [String: Any]
                colors["text"] = NSNull()
                t["colors"] = colors
            },
            edit(base, scheme: "light") { $0["colors"] = [["accent": "#318CE7"]] },
        ]
        for g in garbage {
            #expect(GraineDesign.parse(g) == nil, "\(String(describing: g))")
        }
    }

    /// A malformed token is Graine Classic's value — the look as it was — never a failure.
    @Test func aMalformedTokenFallsBackToClassicAndTheRestSurvives() throws {
        let bent = edit(try classic(), scheme: "light") { t in
            var colors = t["colors"] as! [String: Any]
            colors["accent"] = "abc"                                   // #rgb, no "#": still a colour
            t["colors"] = colors
            t["font"] = ["body": "Inter", "scale": ["body": "15px", "title": -3], "weights": ["title": 1000]]
            t["shape"] = ["radius": ["lg": 30, "sm": "8"], "launcher": "hexagon", "borderWidth": true]
            t["spacing"] = "roomy"
            t["elevation"] = ["card": "soft", "hardOffset": ["x": 4]]
            t["motion"] = ["durationMs": -50, "easing": "Bouncy", "bounce": 7]
            t["icons"] = ["launcher": NSNull(), "stroke": 99]
            t["glass"] = [String: Any]()
            t["bubbles"] = "bubbly"
            t["chrome"] = "skeuomorphic"
        }
        let t = try #require(GraineDesign.parse(bent)).light
        let d = DesignTokens.Fallback.self
        #expect(t.colors.accent == "#AABBCC")
        #expect(t.font.body == "Inter")
        #expect(t.font.heading == "system")
        #expect(t.font.scale.body == d.font.scale.body)
        #expect(t.font.scale.title == d.font.scale.title)
        #expect(t.font.weights.title == 900)
        #expect(t.shape.radius.lg == 30)
        #expect(t.shape.radius.sm == d.radius.sm)
        #expect(t.shape.launcher == .circle)
        #expect(t.shape.borderWidth == d.borderWidth)
        #expect(t.spacing == d.spacing)
        #expect(t.elevation.card == nil)                               // present but unreadable: no shadow
        #expect(t.elevation.floating == d.floating)                    // absent from the group: Classic's
        #expect(t.elevation.hardOffset == nil)                         // half an offset is not an offset
        #expect(t.motion.durationMs == 0)
        #expect(t.motion.easing == "bouncy")
        #expect(t.motion.bounce == 1)
        #expect(t.icons.launcher == nil)                               // null: the brand's logo
        #expect(t.icons.stroke == 4)
        #expect(t.glass == d.glass)
        #expect(t.bubbles == .filled)
        #expect(t.chrome == .none)                                    // a frame this build does not know: plain
    }

    @Test func absentGroupsAreClassicsOwn() throws {
        let bare = edit(try classic(), scheme: "light") { t in
            for key in ["font", "shape", "spacing", "elevation", "motion", "icons", "glass", "bubbles", "chrome", "preset", "scheme"] {
                t.removeValue(forKey: key)
            }
        }
        let t = try #require(GraineDesign.parse(bare)).light
        let d = DesignTokens.Fallback.self
        #expect(t.scheme == "light")
        #expect(t.font == d.font)
        #expect(t.shape == GraineThemeTokens.Shape(radius: d.radius, borderWidth: d.borderWidth, launcher: .circle))
        #expect(t.elevation == GraineThemeTokens.Elevation(card: d.card, floating: d.floating, hardOffset: nil))
        #expect(t.motion == d.motion)
        #expect(t.icons.launcher == d.glyph)
        #expect(t.glass == nil)
        #expect(t.bubbles == .filled)
        #expect(t.chrome == .none)
    }

    /**
     * An older server sends no `chrome`: every surface stays plain. Read as
     * the other token words are — trimmed, any case — and anything that is
     * not a known word is a plain surface too, never an error.
     */
    @Test func tokensWithoutChromeReadAsNone() throws {
        var older = try classic()
        for scheme in ["light", "dark"] {
            older = edit(older, scheme: scheme) { $0.removeValue(forKey: "chrome") }
        }
        let parsed = try #require(GraineDesign.parse(older))
        #expect(parsed.light.chrome == .none)
        #expect(parsed.dark.chrome == .none)

        let words: [(Any, GraineDesignChrome)] = [
            ("window", .window), (" Window ", .window), ("WINDOW", .window), ("none", .none),
            ("skeuomorphic", .none), ("", .none), (NSNull(), .none), (42, .none), (true, .none), (["window"], .none),
        ]
        for (value, want) in words {
            let bent = edit(try classic(), scheme: "light") { $0["chrome"] = value }
            #expect(try #require(GraineDesign.parse(bent)).light.chrome == want, "\(value)")
        }
    }

    /// What a missing token falls back to is Graine Classic's own value, so a partial set degrades toward "as it was".
    @Test func theFallbackIsGraineClassic() throws {
        let classic = try #require(GraineDesign.parse(try classic())).light
        #expect(classic.preset == "graine-classic")
        let d = DesignTokens.Fallback.self
        #expect(classic.font == d.font)
        #expect(classic.shape.radius == d.radius)
        #expect(classic.shape.borderWidth == d.borderWidth)
        #expect(classic.spacing == d.spacing)
        #expect(classic.elevation.card == d.card)
        #expect(classic.elevation.floating == d.floating)
        #expect(classic.motion == d.motion)
        #expect(classic.icons.launcher == d.glyph)
        #expect(classic.chrome == .none)
    }

    @Test func anUnknownSchemeIsAuto() throws {
        var raw = try classic()
        raw["config"] = ["preset": "graine-classic", "scheme": "sepia"]
        let design = try #require(GraineDesign.parse(raw))
        #expect(design.scheme == .auto)
        raw["config"] = ["scheme": " DARK "]
        #expect(GraineDesign.parse(raw)?.scheme == .dark)
        raw.removeValue(forKey: "config")
        #expect(GraineDesign.parse(raw)?.scheme == .auto)
    }

    @Test func theSessionCarriesTheDesignOrNil() throws {
        let with = GraineSessionConfig.parse(["agentId": "a1", "appearance": ["accent": "#318CE7"], "design": try classic()])
        #expect(with.design != nil)
        #expect(with.design?.light.colors.background == "#F7F7F5")
        let without = GraineSessionConfig.parse(["agentId": "a1", "appearance": ["accent": "#318CE7"]])
        #expect(without.design == nil)
        let broken = GraineSessionConfig.parse(["agentId": "a1", "design": "classic"])
        #expect(broken.design == nil)
        #expect(broken.agentId == "a1")
    }

    @Test func theLauncherGlyphImageIsBuiltFromTheTokens() throws {
        let t = try #require(GraineDesign.parse(try classic())).light
        let url = t.launcherGlyphUrl(origin: "https://www.graine.ai/", points: 26, scale: 3)
        #expect(url == "https://www.graine.ai/api/embed/glyph?id=waveform&c=FFFFFF&s=78&w=2&v=2")
        let logo = edit(try classic(), scheme: "light") { t in
            var icons = t["icons"] as! [String: Any]
            icons["launcher"] = NSNull()
            t["icons"] = icons
        }
        #expect(try #require(GraineDesign.parse(logo)).light.launcherGlyphUrl(origin: nil, points: 26, scale: 3) == nil)
    }

    @Test func glyphUrlsClampLikeTheServer() {
        #expect(GraineGlyph.url(origin: "", id: " Mic ", color: "#fff", sizePx: 3, stroke: 0.6)
                == "https://www.graine.ai/api/embed/glyph?id=mic&c=FFFFFF&s=16&w=0.5&v=2")
        #expect(GraineGlyph.url(origin: nil, id: "mic", color: "nope", sizePx: .nan, stroke: .nan)
                == "https://www.graine.ai/api/embed/glyph?id=mic&c=FFFFFF&s=96&w=2&v=2")
        #expect(GraineGlyph.url(origin: "https://www.graine.ai", id: "a b", color: "0B6E4F", sizePx: 100.5, stroke: 1.4)
                == "https://www.graine.ai/api/embed/glyph?id=a%20b&c=0B6E4F&s=101&w=1.5&v=2")
    }
}

@Suite struct DesignRulesTests {

    private func tokens(_ scheme: String = "light", _ change: ((inout [String: Any]) -> Void)? = nil) throws -> GraineThemeTokens {
        let cases = try #require(try ContractFile.load("design.json")["cases"] as? [[String: Any]])
        var design = try #require(cases.first?["design"] as? [String: Any])
        if let change = change {
            var t = design[scheme] as! [String: Any]
            change(&t)
            design[scheme] = t
        }
        let parsed = try #require(GraineDesign.parse(design))
        return scheme == "dark" ? parsed.dark : parsed.light
    }

    @Test func reduceMotionAlwaysWins() throws {
        let t = try tokens()
        #expect(t.motion.effectiveDurationMs(reduceMotion: false) == 200)
        #expect(t.motion.effectiveDurationMs(reduceMotion: true) == 0)
        let still = GraineThemeTokens.Motion(durationMs: 0, easing: "standard", bounce: 0)
        #expect(still.effectiveDurationMs(reduceMotion: false) == 0)
        let none = GraineThemeTokens.Motion(durationMs: 300, easing: "none", bounce: 0)
        #expect(none.effectiveDurationMs(reduceMotion: false) == 0)
    }

    @Test func bubblesFollowTheirStyle() throws {
        let filled = try tokens()
        let c = filled.colors
        #expect(DesignRules.bubble(filled, role: .customer) == .init(fill: c.userBubble, text: c.userBubbleText, outline: nil))
        #expect(DesignRules.bubble(filled, role: .agent) == .init(fill: c.agentBubble, text: c.agentBubbleText, outline: nil))
        let outline = try tokens { $0["bubbles"] = "outline" }
        #expect(DesignRules.bubble(outline, role: .customer) == .init(fill: nil, text: c.text, outline: c.accent))
        #expect(DesignRules.bubble(outline, role: .agent) == .init(fill: nil, text: c.text, outline: c.border))
        let minimal = try tokens { $0["bubbles"] = "minimal" }
        #expect(DesignRules.bubble(minimal, role: .customer) == .init(fill: c.accentSoft, text: c.text, outline: nil))
        #expect(DesignRules.bubble(minimal, role: .agent) == .init(fill: nil, text: c.text, outline: nil))
    }

    @Test func launcherCornersPerShape() {
        let r = GraineThemeTokens.Radius(sm: 8, md: 12, lg: 18, xl: 24)
        #expect(DesignRules.launcherCornerRadius(.circle, size: 56, radius: r) == 28)
        #expect(DesignRules.launcherCornerRadius(.pill, size: 56, radius: r) == 28)
        #expect(abs(DesignRules.launcherCornerRadius(.squircle, size: 56, radius: r) - 16.8) < 1e-9)
        #expect(DesignRules.launcherCornerRadius(.roundedSquare, size: 56, radius: r) == 18)
        #expect(DesignRules.launcherCornerRadius(.square, size: 56, radius: r) == 8)
        let round = GraineThemeTokens.Radius(sm: 40, md: 48, lg: 48, xl: 48)
        #expect(DesignRules.launcherCornerRadius(.roundedSquare, size: 56, radius: round) == 28)
    }

    @Test func weightsAreTheNineSteps() {
        #expect(DesignRules.weightStep(100) == 0)
        #expect(DesignRules.weightStep(400) == 3)
        #expect(DesignRules.weightStep(449) == 3)
        #expect(DesignRules.weightStep(450) == 4)
        #expect(DesignRules.weightStep(600) == 5)
        #expect(DesignRules.weightStep(900) == 8)
        #expect(DesignRules.weightStep(0) == 0)
        #expect(DesignRules.weightStep(5000) == 8)
        #expect(DesignRules.isSystemFamily(" System "))
        #expect(DesignRules.isSystemFamily(""))
        #expect(!DesignRules.isSystemFamily("Inter"))
    }

    /// The component's own style wins; under "auto" the design fills in what the phone's grammar used to.
    @Test func componentsTakeTheDesignWhereTheyChoseNothing() throws {
        let t = try tokens()
        let auto = WidgetRules.resolveLook(WidgetStyle(), kind: "choices")
        let grammar = DesignRules.widgetGrammar(auto, tokens: t)
        #expect(grammar.radius == 18)
        #expect(grammar.buttonRadius == 12)
        #expect(grammar.chipRadius == 8)
        #expect(!grammar.pillButtons)
        #expect(grammar.titleWeight == 600)
        #expect(DesignRules.widgetGrammar(auto, tokens: nil) == WidgetRules.grammar(for: auto))

        var material = WidgetStyle()
        material.platform = .material
        let chosen = WidgetRules.resolveLook(material, kind: "choices")
        #expect(DesignRules.widgetGrammar(chosen, tokens: t) == WidgetRules.grammar(for: chosen))

        #expect(DesignRules.widgetRadius(auto, tokens: t, appearanceRadius: 9) == 18)
        #expect(DesignRules.widgetRadius(auto, tokens: nil, appearanceRadius: 9) == 9)
        #expect(DesignRules.widgetRadius(chosen, tokens: t, appearanceRadius: 9) == 16)
        var own = WidgetStyle()
        own.radius = 4
        #expect(DesignRules.widgetRadius(WidgetRules.resolveLook(own, kind: nil), tokens: t, appearanceRadius: 9) == 4)

        let pair = DesignRules.widgetAccent(auto, tokens: t, appearanceAccent: "#7C3AED", appearanceOnAccent: "#FFFFFF")
        #expect(pair.accent == "#318CE7")
        #expect(pair.onAccent == "#FFFFFF")   // Classic keeps white on its blue
        var yellow = WidgetStyle()
        yellow.accent = "#FFE600"
        let ownPair = DesignRules.widgetAccent(
            WidgetRules.resolveLook(yellow, kind: nil), tokens: t, appearanceAccent: "#7C3AED", appearanceOnAccent: "#FFFFFF"
        )
        #expect(ownPair.accent == "#FFE600")
        #expect(ownPair.onAccent == "#101318")
        let legacy = DesignRules.widgetAccent(auto, tokens: nil, appearanceAccent: "#7C3AED", appearanceOnAccent: "#FFFFFF")
        #expect(legacy.accent == "#7C3AED")
        #expect(legacy.onAccent == "#FFFFFF")
    }
}

@Suite struct GlyphPathTests {

    private func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { abs(a - b) < tolerance }

    private func end(_ s: GlyphSegment) -> (x: Double, y: Double)? {
        switch s {
        case let .move(x, y), let .line(x, y): return (x, y)
        case let .cubic(_, _, _, _, x, y): return (x, y)
        case .close: return nil
        }
    }

    /// Audio lines: nothing but vertical strokes, each its own subpath.
    @Test func strokesBetweenMovesAreLines() throws {
        let s = try #require(GlyphPath.parse("M2 10v3M6 6v11M10 3v18M14 8v7M18 5v13M22 10v3"))
        #expect(s.count == 12)
        #expect(s[0] == .move(x: 2, y: 10))
        #expect(s[1] == .line(x: 2, y: 13))
        #expect(s[10] == .move(x: 22, y: 10))
        #expect(s[11] == .line(x: 22, y: 13))
    }

    @Test func relativeCommandsAndCloseReturnToTheStart() throws {
        let s = try #require(GlyphPath.parse("m1 1h2v2h-2zl1 1"))
        #expect(s == [.move(x: 1, y: 1), .line(x: 3, y: 1), .line(x: 3, y: 3), .line(x: 1, y: 3), .close, .line(x: 2, y: 2)])
    }

    @Test func extraPairsAfterAMoveAreLines() throws {
        #expect(GlyphPath.parse("M0 0 10 0 10 10") == [.move(x: 0, y: 0), .line(x: 10, y: 0), .line(x: 10, y: 10)])
        #expect(GlyphPath.parse("m1 1 2 0 0 2") == [.move(x: 1, y: 1), .line(x: 3, y: 1), .line(x: 3, y: 3)])
        #expect(GlyphPath.parse("M0 0L1 1 2 2") == [.move(x: 0, y: 0), .line(x: 1, y: 1), .line(x: 2, y: 2)])
    }

    @Test func numbersWrittenTheWayMinifiersWriteThem() throws {
        #expect(GlyphPath.parse("M.5.5l0-.96") == [.move(x: 0.5, y: 0.5), .line(x: 0.5, y: 0.5 - 0.96)])
        #expect(GlyphPath.parse("M1e1,2E-1") == [.move(x: 10, y: 0.2)])
        #expect(GlyphPath.parse(" M 1 , 2 \n L 3 4 ") == [.move(x: 1, y: 2), .line(x: 3, y: 4)])
    }

    @Test func quadraticsAndSmoothCurvesBecomeExactCubics() throws {
        let q = try #require(GlyphPath.parse("M0 0Q3 3 6 0T12 0"))
        #expect(q[1] == .cubic(x1: 2, y1: 2, x2: 4, y2: 2, x: 6, y: 0))
        // T mirrors the last control point (3,3) through (6,0): (9,-3).
        #expect(q[2] == .cubic(x1: 8, y1: -2, x2: 10, y2: -2, x: 12, y: 0))
        let c = try #require(GlyphPath.parse("M0 0C1 2 3 2 4 0s3-2 4 0"))
        #expect(c[1] == .cubic(x1: 1, y1: 2, x2: 3, y2: 2, x: 4, y: 0))
        #expect(c[2] == .cubic(x1: 5, y1: -2, x2: 7, y2: -2, x: 8, y: 0))
        // S with nothing to mirror uses the current point.
        let s = try #require(GlyphPath.parse("M1 1S2 2 3 1"))
        #expect(s[1] == .cubic(x1: 1, y1: 1, x2: 2, y2: 2, x: 3, y: 1))
    }

    @Test func aHalfCircleArcIsTwoQuarterCubicsThatLandExactly() throws {
        for data in ["M0 0A1 1 0 0 1 2 0", "M0 0a1 1 0 012 0"] {
            let s = try #require(GlyphPath.parse(data), "\(data)")
            #expect(s.count == 3, "\(data)")
            let middle = try #require(end(s[1]))
            // Sweep 1 turns the positive way — on a y-down screen, over the top.
            #expect(near(middle.x, 1) && near(middle.y, -1), "\(data)")
            let last = try #require(end(s[2]))
            #expect(last.x == 2 && last.y == 0, "\(data)")
        }
        let under = try #require(GlyphPath.parse("M0 0A1 1 0 0 0 2 0"))
        let low = try #require(end(under[1]))
        #expect(near(low.x, 1) && near(low.y, 1))
    }

    @Test func arcsTooSmallAreScaledUpAndZeroRadiiAreLines() throws {
        // Radius 0.5 cannot span 2 units: scaled to 1, a half circle.
        let small = try #require(GlyphPath.parse("M0 0A.5 .5 0 0 1 2 0"))
        let middle = try #require(end(small[1]))
        #expect(near(middle.x, 1) && near(middle.y, -1))
        #expect(GlyphPath.parse("M0 0A0 1 0 0 1 2 0") == [.move(x: 0, y: 0), .line(x: 2, y: 0)])
        #expect(GlyphPath.parse("M1 1A3 3 0 0 1 1 1") == [.move(x: 1, y: 1)])
    }

    /**
     * Every launcher glyph a design can carry parses, and stays inside its
     * 24×24 box: those in contract/design.json always, and in the monorepo
     * every entry of theme.ts LAUNCHER_ICONS too — the standalone package
     * ships no TypeScript, and there the contract's glyphs are the check.
     */
    @Test func everyOfferedGlyphParsesInsideItsBox() throws {
        var glyphs: [String: (path: String, stroke: Bool)] = [:]
        let cases = try #require(try ContractFile.load("design.json")["cases"] as? [[String: Any]])
        for c in cases {
            let design = try #require(GraineDesign.parse(c["design"]))
            for t in [design.light, design.dark] {
                if let g = t.icons.launcher { glyphs[g.id] = (g.path, g.stroke) }
            }
        }
        #expect(!glyphs.isEmpty)
        if let offered = try GlyphPathTests.launcherIconsInTheme() {
            #expect(offered.count >= glyphs.count)
            for (id, glyph) in glyphs {
                // The contract and the source of truth agree on every glyph they share.
                #expect(offered[id]?.path == glyph.path, "\(id)")
            }
            glyphs.merge(offered) { _, fromTheme in fromTheme }
        }
        for (id, glyph) in glyphs {
            let segments = try #require(GlyphPath.parse(glyph.path), "\(id)")
            #expect(segments.count > 1, "\(id)")
            for s in segments {
                guard let p = end(s) else { continue }
                #expect(p.x >= -0.01 && p.x <= 24.01 && p.y >= -0.01 && p.y <= 24.01, "\(id): \(p)")
            }
        }
    }

    /// The microphone's capsule: a moveto, a flat top, then an arc that ends at the capsule's right side, (15, 5).
    @Test func arcsLandWhereTheGlyphSays() throws {
        let mic = try #require(GlyphPath.parse("M12 19v3M19 10v2a7 7 0 0 1 -14 0v-2M12 2h0a3 3 0 0 1 3 3v7a3 3 0 0 1 -3 3h0a3 3 0 0 1 -3 -3v-7a3 3 0 0 1 3 -3z"))
        let capsule = try #require(mic.firstIndex(of: .move(x: 12, y: 2)))
        #expect(mic[capsule + 1] == .line(x: 12, y: 2))
        let side = try #require(end(mic[capsule + 2]))
        #expect(near(side.x, 15) && near(side.y, 5))
        #expect(mic.last == .close)
    }

    /// A filled glyph with holes (the chat dots) is one path of several subpaths, "Z" then a relative "m" from the start.
    @Test func closeThenRelativeMoveStartsFromTheSubpathStart() throws {
        let s = try #require(GlyphPath.parse("M2 2h4v4h-4Zm1 1h2v2h-2z"))
        #expect(s[4] == .close)
        #expect(s[5] == .move(x: 3, y: 3))
    }

    /// theme.ts LAUNCHER_ICONS by id, when this checkout has it; nil in the standalone package.
    static func launcherIconsInTheme(from here: String = #filePath) throws -> [String: (path: String, stroke: Bool)]? {
        var dir = URL(fileURLWithPath: here).deletingLastPathComponent()
        var source: String?
        for _ in 0..<12 {
            let file = dir.appendingPathComponent("sdk/inapp/theme.ts")
            let sibling = dir.appendingPathComponent("inapp/theme.ts")
            if let text = try? String(contentsOf: file, encoding: .utf8) { source = text; break }
            if let text = try? String(contentsOf: sibling, encoding: .utf8) { source = text; break }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        guard let text = source else { return nil }
        let block = try #require(text.range(of: "export const LAUNCHER_ICONS").map { String(text[$0.lowerBound...]) })
        let list = String(block[..<(block.range(of: "\n];")?.lowerBound ?? block.endIndex)])
        let entry = try NSRegularExpression(pattern: #"id: "([^"]+)"[^}]*?stroke: (true|false)[^}]*?path: "([^"]+)""#)
        var out: [String: (path: String, stroke: Bool)] = [:]
        let ns = list as NSString
        for m in entry.matches(in: list, range: NSRange(location: 0, length: ns.length)) {
            out[ns.substring(with: m.range(at: 1))] = (ns.substring(with: m.range(at: 3)), ns.substring(with: m.range(at: 2)) == "true")
        }
        #expect(!out.isEmpty, "theme.ts has LAUNCHER_ICONS, but none were read")
        return out
    }

    @Test func anythingElseIsNil() {
        let bad = ["", "   ", "L1 1", "M1", "M1 1 X", "M1 1z3", "M1 1A1 1 0 2 1 2 2", "M1 1C1 2 3", "M- 1", "M1 1 .", "hello"]
        for data in bad {
            #expect(GlyphPath.parse(data) == nil, "\(data)")
        }
    }
}

/// The design kept on the instance: picked for the device, picked again when the device switches, reported only on a change.
@MainActor
@Suite struct ThemeTests {
    private final class Recorder: GraineListener {
        var themes: [GraineThemeTokens?] = []
        func onTheme(_ tokens: GraineThemeTokens?) { themes.append(tokens) }
    }

    /// The first contract design whose brand chose `scheme` (nil: chose nothing, so "auto").
    private func design(scheme: String?) throws -> GraineDesign {
        let cases = try #require(try ContractFile.load("design.json")["cases"] as? [[String: Any]])
        let hit = cases.first { ($0["config"] as? [String: Any])?["scheme"] as? String == scheme }
        let found = try #require(hit, "no design with scheme \(String(describing: scheme))")
        return try #require(GraineDesign.parse(found["design"]))
    }

    private func graine(with design: GraineDesign?, recorder: Recorder, deviceDark: Bool?) -> GraineInApp {
        // Never configure()d: no network, no lifecycle observers.
        let graine = GraineInApp(config: GraineConfig(baseUrl: "https://example.invalid", publishableKey: "pk_test"))
        graine.addListener(recorder)
        graine.deviceAppearanceChanged(dark: deviceDark)
        #expect(graine.theme == nil)   // nothing before the session
        graine.finishSession(.success(GraineSessionConfig(agentId: "a1", webcallAgentId: "a1", design: design)))
        return graine
    }

    @Test func autoFollowsTheDeviceAndSaysSoOnlyWhenItChanges() throws {
        let auto = try design(scheme: nil)
        let recorder = Recorder()
        let graine = graine(with: auto, recorder: recorder, deviceDark: true)
        #expect(graine.design == auto)
        #expect(graine.theme == auto.dark)
        #expect(recorder.themes == [auto.dark])
        graine.deviceAppearanceChanged(dark: true)
        #expect(recorder.themes.count == 1)
        graine.deviceAppearanceChanged(dark: false)
        #expect(graine.theme == auto.light)
        #expect(recorder.themes == [auto.dark, auto.light])
        graine.deviceAppearanceChanged(dark: nil)     // unknown is light: no change to report
        #expect(recorder.themes.count == 2)
    }

    @Test func aFixedSchemeIgnoresTheDevice() throws {
        let dark = try design(scheme: "dark")
        #expect(dark.scheme == .dark)
        let recorder = Recorder()
        let graine = graine(with: dark, recorder: recorder, deviceDark: false)
        #expect(graine.theme == dark.dark)
        graine.deviceAppearanceChanged(dark: true)
        graine.deviceAppearanceChanged(dark: false)
        #expect(recorder.themes == [dark.dark])
    }

    @Test func noDesignIsNoThemeAndNoCallback() {
        let recorder = Recorder()
        let graine = graine(with: nil, recorder: recorder, deviceDark: true)
        graine.deviceAppearanceChanged(dark: false)
        #expect(graine.theme == nil)
        #expect(graine.design == nil)
        #expect(recorder.themes.isEmpty)
    }
}
