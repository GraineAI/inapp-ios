import Foundation
import Testing
@testable import GraineInApp

/*
 * WINDOW CHROME (contract/DESIGN.md "Window chrome"), proven on a Mac against
 * every design in contract/design.json: a design that opens in windows gives
 * each surface — the chat window, the caption card, a component card — the
 * title bar its tokens say, number for number, and moves a component's title
 * out of its body into the bar, over a body on `surface`; every other design
 * gives none, and keeps its cards on `surfaceRaised`.
 */
@Suite struct WindowChromeTests {

    private static let lights = ["#FF5F57", "#FEBC2E", "#28C840"]

    /// Every scheme of every design in the contract, with where it came from.
    private func schemes() throws -> [(label: String, tokens: GraineThemeTokens)] {
        let cases = try #require(try ContractFile.load("design.json")["cases"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        var out: [(label: String, tokens: GraineThemeTokens)] = []
        for c in cases {
            let config = String(describing: c["config"])
            let design = try #require(GraineDesign.parse(c["design"]), "config: \(config)")
            out.append(("light of \(config)", design.light))
            out.append(("dark of \(config)", design.dark))
        }
        return out
    }

    /// The first contract design, as a mutable tree.
    private func classic(_ change: (inout [String: Any]) -> Void) throws -> GraineThemeTokens {
        let cases = try #require(try ContractFile.load("design.json")["cases"] as? [[String: Any]])
        var design = try #require(cases.first?["design"] as? [String: Any])
        var light = try #require(design["light"] as? [String: Any])
        change(&light)
        design["light"] = light
        return try #require(GraineDesign.parse(design)).light
    }

    private let surfaces: [WindowChrome.Surface] = [
        .chat(heading: "Aria", online: true),
        .chat(heading: "Aria", online: false),
        .caption,
        .component(title: "Compare plans", radius: 12),
    ]

    @Test func everyWindowDesignDrawsTheTitleBarItsTokensSay() throws {
        var windows = 0
        for (label, t) in try schemes() where t.chrome == .window {
            let c = t.colors
            let r = t.shape.radius
            let chat = try #require(WindowChrome.titleBar(t, for: .chat(heading: "Talk to Aria", online: true)), "\(label)")
            #expect(chat == WindowChrome.TitleBar(
                height: 32, fill: c.surfaceRaised, outline: c.border, outlineWidth: t.shape.borderWidth,
                cornerRadius: r.xl, lightsInset: 12, dot: 10, dotGap: 6, lights: Self.lights,
                title: "talk to aria", titleSize: t.font.scale.caption, titleColor: c.textMuted,
                titleInset: 62, onlineDot: c.success
            ), "\(label)")

            let caption = try #require(WindowChrome.titleBar(t, for: .caption), "\(label)")
            #expect(caption == WindowChrome.TitleBar(
                height: 24, fill: c.surfaceRaised, outline: c.border, outlineWidth: t.shape.borderWidth,
                cornerRadius: r.lg, lightsInset: 12, dot: 8, dotGap: 6, lights: Self.lights,
                title: "captions", titleSize: t.font.scale.caption, titleColor: c.textMuted,
                titleInset: 56, onlineDot: nil
            ), "\(label)")

            let component = try #require(WindowChrome.titleBar(t, for: .component(title: "Compare Plans", radius: 7)), "\(label)")
            #expect(component == WindowChrome.TitleBar(
                height: 32, fill: c.surfaceRaised, outline: c.border, outlineWidth: t.shape.borderWidth,
                cornerRadius: 7, lightsInset: 12, dot: 10, dotGap: 6, lights: Self.lights,
                title: "compare plans", titleSize: t.font.scale.caption, titleColor: c.textMuted,
                titleInset: 62, onlineDot: nil
            ), "\(label)")
            windows += 1
        }
        #expect(windows >= 4, "Desktop Buddy and the all-knobs design, light and dark")
    }

    @Test func everyOtherDesignDrawsNoTitleBar() throws {
        var plain = 0
        for (label, t) in try schemes() where t.chrome == .none {
            for surface in surfaces {
                #expect(WindowChrome.titleBar(t, for: surface) == nil, "\(label): \(surface)")
            }
            plain += 1
        }
        #expect(plain > 0)
    }

    /// The token decides, not the philosophy: any design can switch it on, and an older server's tokens draw none.
    @Test func theTokenAloneDecides() throws {
        let knob = try classic { $0["chrome"] = "window" }
        #expect(knob.preset == "graine-classic")
        let bar = try #require(WindowChrome.titleBar(knob, for: .caption))
        #expect(bar.fill == knob.colors.surfaceRaised)
        #expect(bar.titleColor == knob.colors.textMuted)

        let older = try classic { $0.removeValue(forKey: "chrome") }
        #expect(older.chrome == .none)
        for surface in surfaces {
            #expect(WindowChrome.titleBar(older, for: surface) == nil, "\(surface)")
        }
    }

    @Test func theChatShowsTheOnlineDotOnlyWhileOnline() throws {
        let t = try classic { $0["chrome"] = "window" }
        #expect(WindowChrome.titleBar(t, for: .chat(heading: "Aria", online: true))?.onlineDot == t.colors.success)
        #expect(try #require(WindowChrome.titleBar(t, for: .chat(heading: "Aria", online: false))).onlineDot == nil)
        #expect(try #require(WindowChrome.titleBar(t, for: .caption)).onlineDot == nil)
        #expect(try #require(WindowChrome.titleBar(t, for: .component(title: "Aria", radius: 12))).onlineDot == nil)
        // A 6-point dot, and 6 between it and the heading — the same on every SDK.
        #expect(WindowChrome.onlineDotSize == 6)
        #expect(WindowChrome.onlineGap == 6)
    }

    /**
     * A component card's own title MOVES into the bar: drawn there, and not
     * again in the body. A plain design, and no design at all, keep it in the
     * body as before. A card with no title draws none anywhere but the lights.
     */
    @Test func aComponentsTitleMovesIntoTheBar() throws {
        var windows = 0
        var plain = 0
        for (label, t) in try schemes() {
            let bar = WindowChrome.titleBar(t, for: .component(title: "Compare Plans", radius: 12))
            if t.chrome == .window {
                #expect(bar?.title == "compare plans", "\(label)")
                #expect(WindowChrome.componentBodyTitle(t, title: "Compare Plans") == nil, "\(label): drawn once, in the bar")
                windows += 1
            } else {
                #expect(bar == nil, "\(label)")
                #expect(WindowChrome.componentBodyTitle(t, title: "Compare Plans") == "Compare Plans", "\(label)")
                plain += 1
            }
            #expect(WindowChrome.componentBodyTitle(t, title: "") == nil, "\(label)")
        }
        #expect(windows > 0 && plain > 0)
        #expect(WindowChrome.componentBodyTitle(nil, title: "Compare Plans") == "Compare Plans", "no design: as it always was")
        #expect(WindowChrome.componentBodyTitle(nil, title: "") == nil)
    }

    /**
     * A window's body is `surface`, so its `surfaceRaised` title bar reads as
     * a title bar; a plain card's body stays `surfaceRaised`. Checked on every
     * design in the contract.
     */
    @Test func aWindowsBodyIsSurfaceAndAPlainCardsIsSurfaceRaised() throws {
        var windows = 0
        var plain = 0
        for (label, t) in try schemes() {
            if t.chrome == .window {
                #expect(WindowChrome.componentBodyFill(t) == t.colors.surface, "\(label)")
                // The bar over it stays surfaceRaised.
                #expect(WindowChrome.titleBar(t, for: .component(title: "Plans", radius: 12))?.fill == t.colors.surfaceRaised, "\(label)")
                windows += 1
            } else {
                #expect(WindowChrome.componentBodyFill(t) == t.colors.surfaceRaised, "\(label)")
                plain += 1
            }
        }
        #expect(windows > 0 && plain > 0)
    }

    /// Desktop Buddy, in its own colours: a white window under a grey bar — and in the dark, the same step.
    @Test func desktopBuddyIsAWhiteWindowUnderAGreyBar() throws {
        let cases = try #require(try ContractFile.load("design.json")["cases"] as? [[String: Any]])
        let buddy = try #require(cases.first { ($0["config"] as? [String: Any])?["preset"] as? String == "desktop-buddy" })
        let design = try #require(GraineDesign.parse(buddy["design"]))
        let lightBar = try #require(WindowChrome.titleBar(design.light, for: .component(title: "Plans", radius: 16)))
        #expect(WindowChrome.componentBodyFill(design.light) == "#FFFFFF")
        #expect(lightBar.fill == "#F5F5F5")
        let darkBar = try #require(WindowChrome.titleBar(design.dark, for: .component(title: "Plans", radius: 16)))
        #expect(WindowChrome.componentBodyFill(design.dark) == "#161618")
        #expect(darkBar.fill == "#1F1F22")
    }

    /// Lower case, on one line: the bar has room for nothing else.
    @Test func theTitleIsLowerCaseOnOneLine() throws {
        #expect(WindowChrome.oneLine("Talk to Aria") == "talk to aria")
        #expect(WindowChrome.oneLine("  Compare\n\tPLANS  ") == "compare plans")
        #expect(WindowChrome.oneLine("Ärzte-Hilfe") == "ärzte-hilfe")
        #expect(WindowChrome.oneLine("") == "")
        let t = try classic { $0["chrome"] = "window" }
        // A component with no title still opens as a window: the lights alone.
        #expect(try #require(WindowChrome.titleBar(t, for: .component(title: "  ", radius: 12))).title == "")
    }

    /// Centred in the whole bar, and never under the lights: the same room kept on both sides.
    @Test func theTitleStaysCentredClearOfTheLights() {
        #expect(WindowChrome.lightsWidth(dot: 10) == 42)
        #expect(WindowChrome.lightsWidth(dot: 8) == 36)
        #expect(WindowChrome.inset + WindowChrome.lightsWidth(dot: WindowChrome.dot) + WindowChrome.titleGap == 62)
        #expect(WindowChrome.inset + WindowChrome.lightsWidth(dot: WindowChrome.captionDot) + WindowChrome.titleGap == 56)
    }

    /// The window's controls, not the brand's colours: the same three on a yellow accent, a dark scheme, anything.
    @Test func theLightsAreAlwaysTheWindowsOwn() throws {
        #expect(WindowChrome.lights == Self.lights)
        for (label, t) in try schemes() where t.chrome == .window {
            for surface in surfaces {
                #expect(WindowChrome.titleBar(t, for: surface)?.lights == Self.lights, "\(label): \(surface)")
            }
        }
    }

    /// Each surface's own top corners: the chat window `radius.xl`, the caption `radius.lg`, a component its card's.
    @Test func theBarTakesItsSurfacesCorners() throws {
        let t = try classic { t in
            t["chrome"] = "window"
            t["shape"] = ["radius": ["sm": 2, "md": 6, "lg": 14, "xl": 30], "borderWidth": 2]
        }
        #expect(WindowChrome.titleBar(t, for: .chat(heading: "Aria", online: false))?.cornerRadius == 30)
        #expect(WindowChrome.titleBar(t, for: .caption)?.cornerRadius == 14)
        #expect(WindowChrome.titleBar(t, for: .component(title: "Plans", radius: 4))?.cornerRadius == 4)
        #expect(WindowChrome.titleBar(t, for: .component(title: "Plans", radius: -3))?.cornerRadius == 0)
        #expect(WindowChrome.titleBar(t, for: .caption)?.outlineWidth == 2)
    }
}
