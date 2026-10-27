import Foundation
import Testing
@testable import GraineInApp

/*
 * CHAT WINDOW v2 (contract/DESIGN.md "Chat window v2"), proven on a Mac:
 * every piece's tokens read exactly as design.json serves them, classic
 * derived from the v1 tokens when a server sends none, the seven sections of
 * sdk/contract/chat-window.json run against this SDK's own code (the quick
 * replies, the chat's fold, the rating, the rating card's layout, the groups,
 * the formatting, the reveal), and the window's decisions — which composer,
 * which corners, whose time, where the pin and the chips go.
 */

private let v2Groups = ["preset", "header", "bubbles", "timestamps", "wallpaper", "chips", "cards", "composer",
                        "typing", "density", "welcome", "rating", "escalation", "glass"]
private let v2Knobs: Set<String> = ["bubbles", "timestamps", "wallpaper", "chips", "cards", "composer", "typing",
                                    "density", "welcome", "rating", "escalation", "glass"]

/// JSON values compared as JSON compares them: numbers by value, null by absence of a value.
private func same(_ a: Any?, _ b: Any?) -> Bool {
    let x = a.flatMap { JSON.unwrap($0) }
    let y = b.flatMap { JSON.unwrap($0) }
    switch (x, y) {
    case (nil, nil): return true
    case (nil, let v?), (let v?, nil): return v is NSNull
    case let (l?, r?):
        if l is NSNull || r is NSNull { return l is NSNull && r is NSNull }
        if let lb = JSON.bool(l) { return JSON.bool(r) == lb }
        if let ln = JSON.number(l) { return JSON.number(r).map { abs($0.doubleValue - ln.doubleValue) < 1e-9 } ?? false }
        if let ls = l as? String { return (r as? String) == ls }
        if let la = l as? [Any] {
            guard let ra = r as? [Any], ra.count == la.count else { return false }
            return zip(la, ra).allSatisfy { same($0, $1) }
        }
        if let lo = l as? [String: Any] {
            guard let ro = r as? [String: Any], Set(lo.keys) == Set(ro.keys) else { return false }
            return lo.allSatisfy { same($0.value, ro[$0.key]) }
        }
        return false
    }
}

private func cases() throws -> [[String: Any]] {
    try #require(try ContractFile.load("design.json")["cases"] as? [[String: Any]])
}

private func hasV2Knobs(_ c: [String: Any]) -> Bool {
    let chat = (c["config"] as? [String: Any])?["chat"] as? [String: Any] ?? [:]
    if chat.keys.contains(where: { v2Knobs.contains($0) }) || chat["header"] is [String: Any] { return true }
    if let preset = chat["preset"] as? String, preset != "classic" { return true }
    return false
}

@Suite struct ChatStyleTokenTests {

    /// The comparison every test below leans on tells values apart.
    @Test func theComparisonTellsValuesApart() {
        #expect(same(["a": 1, "b": [true, "x"]], ["b": [true, "x"], "a": 1.0]))
        #expect(!same(["a": 1], ["a": 2]) && !same([1], [1, 2]) && !same(["a": 1], ["a": 1, "b": 2]))
        #expect(!same(true, 1) && !same("1", 1) && same(NSNull(), nil) && !same(NSNull(), "x"))
    }

    /// Every design, both schemes: each v2 group exactly as served — every field, every word, every colour.
    @Test func everyCaseReadsEveryPieceExactly() throws {
        var styles = Set<String>()
        for (i, c) in try cases().enumerated() {
            let raw = try #require(c["design"] as? [String: Any])
            let design = try #require(GraineDesign.parse(raw))
            for (scheme, tokens) in [("light", design.light), ("dark", design.dark)] {
                let served = try #require((raw[scheme] as? [String: Any])?["chat"] as? [String: Any])
                let chat = try #require(tokens.chat, "case \(i) \(scheme)")
                let mine = ChatStyles.json(chat.style, number: { $0 })
                for key in v2Groups {
                    #expect(same(mine[key], served[key]), "case \(i) \(scheme) chat.\(key): \(String(describing: mine[key])) vs \(String(describing: served[key]))")
                }
                styles.insert(chat.preset)
            }
        }
        #expect(styles.isSuperset(of: ["classic", "soft", "bold", "glass", "minimal", "crisp", "cozy", "calm", "compact", "lively"]),
                "the contract carries every style: \(styles.sorted())")
    }

    /**
     * An older server sends no v2 groups: the window is classic, derived from
     * the v1 tokens. Where the design has no v2 knobs, that is exactly what the
     * server would have sent; where it has, it is still a classic window.
     */
    @Test func withoutTheGroupsTheV1TokensGiveClassic() throws {
        var exact = 0
        for (i, c) in try cases().enumerated() {
            let raw = try #require(c["design"] as? [String: Any])
            var stripped = raw
            for scheme in ["light", "dark"] {
                var tokens = try #require(raw[scheme] as? [String: Any])
                var chat = try #require(tokens["chat"] as? [String: Any])
                for key in v2Groups { chat.removeValue(forKey: key) }
                tokens["chat"] = chat
                stripped[scheme] = tokens
            }
            let older = try #require(GraineDesign.parse(stripped))
            let served = try #require(GraineDesign.parse(raw))
            for (scheme, tokens, original) in [("light", older.light, served.light), ("dark", older.dark, served.dark)] {
                let chat = try #require(tokens.chat)
                #expect(chat.preset == "classic" && chat.composer.style == "bar" && chat.typing.style == "loader"
                        && chat.welcome.layout == "centered" && !chat.rating.show && chat.escalation.call == "none"
                        && chat.glass == nil && chat.bubbles.shape == "rounded" && !chat.bubbles.grouping, "case \(i) \(scheme)")
                // The v1 words are untouched by the groups' absence.
                #expect(chat.headerBackground == original.chat?.headerBackground && chat.background == original.chat?.background)
                if !hasV2Knobs(c) {
                    #expect(chat.style == original.chat?.style, "case \(i) \(scheme): stripping a classic design's groups gives them back")
                    exact += 1
                }
            }
        }
        #expect(exact >= 60, "most of the contract's designs are classic")
    }

    @Test func aFieldMissingOrOfTheWrongTypeIsClassicAndAnUnknownWordIsTheFirst() throws {
        let palette = try #require(DesignTokens.parse(["colors": testColors], scheme: "light")).colors
        let classic = try #require(SurfaceTokens.chat([:], colors: palette)).style
        let t = try #require(SurfaceTokens.chat([
            "preset": "future",
            "header": ["style": "sparkly", "align": 3, "status": "TEXT", "contextCard": "sidebar", "fill": ["color": "nope"], "dot": "#0f0"],
            "bubbles": ["shape": "blob", "radius": "big", "maxWidth": 2, "shadow": "soft", "user": ["color": NSNull(), "border": "#123456"]],
            "timestamps": ["show": "sometimes", "ticks": "yes"],
            "wallpaper": ["style": "video", "pattern": "stars", "intensity": -1, "colorTo": "#abc"],
            "chips": ["placement": "sky", "scroll": 1, "height": 0, "border": NSNull()],
            "cards": ["image": "panorama", "button": "ghost", "shadow": NSNull()],
            "composer": ["style": "orb", "send": "arrow", "mic": "true", "strip": NSNull()],
            "typing": ["style": "morse", "text": "  Writing\n now  "],
            "density": ["name": "tight", "gap": -4],
            "welcome": ["layout": "splash", "starters": "grid"],
            "rating": ["style": "hearts", "show": true],
            "escalation": ["call": "everywhere"],
            "glass": true,
        ], colors: palette))
        #expect(t.preset == "future", "the style's name is informational, kept as sent")
        #expect(t.header.style == "surface" && t.header.status == "text" && t.header.contextCard == "bar")
        #expect(t.header.align == classic.header.align && t.header.fill == classic.header.fill && t.header.dot == "#00FF00")
        #expect(t.bubbles.shape == "rounded" && t.bubbles.radius == classic.bubbles.radius)
        #expect(t.bubbles.maxWidth == 0.92, "a share past its range is held at the edge")
        #expect(t.bubbles.shadow == classic.bubbles.shadow, "a shadow that is not one is classic's")
        #expect(t.bubbles.user.color == nil && t.bubbles.user.border == "#123456", "null is no fill; a colour is that colour")
        #expect(t.bubbles.user.text == classic.bubbles.user.text, "what the side leaves out is classic's")
        #expect(t.timestamps.show == "never" && t.timestamps.ticks == classic.timestamps.ticks)
        #expect(t.wallpaper.style == "solid" && t.wallpaper.pattern == "dots" && t.wallpaper.intensity == 0 && t.wallpaper.colorTo == "#AABBCC")
        #expect(t.chips.placement == "both" && t.chips.scroll == classic.chips.scroll && t.chips.height == 34 && t.chips.border == nil)
        #expect(t.cards.image == "auto" && t.cards.button == "filled" && t.cards.shadow == nil)
        #expect(t.composer.style == "bar" && t.composer.send == "circle" && !t.composer.mic && t.composer.strip == nil)
        #expect(t.typing.style == "loader" && t.typing.text == "Writing now", "the brand's words, one line")
        #expect(t.density.name == "comfortable" && t.density.gap == classic.density.gap)
        #expect(t.welcome.layout == "centered" && t.welcome.starters == "chips")
        #expect(t.rating.style == "thumbs" && t.rating.show)
        #expect(t.escalation.call == "none")
        #expect(t.glass == classic.glass, "not an object and not null: classic's")
        let frosted = try #require(SurfaceTokens.chat(["glass": ["blur": 12]], colors: palette))
        #expect(frosted.glass == GraineChatTokens.Glass(blur: 12, opacity: 0.72))
        #expect(try #require(SurfaceTokens.chat(["glass": NSNull()], colors: palette)).glass == nil)
    }

    @Test func classicIsTheV1TableAndTheResolversContrastRules() throws {
        let palette = try #require(DesignTokens.parse(["colors": testColors], scheme: "light")).colors
        let surface = try #require(SurfaceTokens.chat([:], colors: palette))
        #expect(surface.header.style == "surface" && surface.header.dot == palette.success && surface.header.divider)
        #expect(surface.bubbles.user.color == palette.userBubble && surface.bubbles.agent.color == palette.agentBubble)
        #expect(surface.wallpaper.style == "solid" && surface.composer.strip == surface.background)
        #expect(surface.density.edge == 12 && surface.density.gap == 10 && surface.density.groupGap == 3)
        let accent = try #require(SurfaceTokens.chat(["headerBackground": palette.accent, "headerText": "#FFFFFF", "pattern": "dots"], colors: palette))
        #expect(accent.header.style == "accent" && accent.header.dot == "#FFFFFF", "on an accent header the dot is the title's colour")
        #expect(accent.wallpaper.style == "pattern" && accent.wallpaper.pattern == "dots")
        let timed = try #require(SurfaceTokens.chat(["showTimestamps": true], colors: palette))
        #expect(timed.timestamps.show == "always")
        // The colour helpers are the resolver's, number for number.
        #expect(ChatInk.mix("#FFFFFF", "#000000", 0.5) == "#808080")
        #expect(abs(ChatInk.contrast("#FFFFFF", "#000000") - 21) < 1e-9)
        #expect(ChatInk.ensureContrast("#FFE600", on: "#FFFFFF", min: 3) != "#FFE600", "a yellow accent on white is moved until it reads")
    }

    @Test func theThemeCrossesTheBridgeWithItsPieces() throws {
        for c in try cases() {
            let design = try #require(GraineDesign.parse(c["design"]))
            for tokens in [design.light, design.dark] {
                let json = try #require(ObjCBridge.object(ObjCBridge.text(ObjCBridge.theme(tokens))))
                let chat = try #require(json["chat"] as? [String: Any])
                for key in v2Groups { #expect(chat[key] != nil, "chat.\(key) crosses the bridge") }
                #expect(DesignTokens.parse(json, scheme: tokens.scheme)?.chat == tokens.chat)
            }
        }
    }
}

let testColors: [String: Any] = [
    "background": "#FFFFFF", "surface": "#F7F7F5", "surfaceRaised": "#FFFFFF", "text": "#101318", "textMuted": "#5F6672",
    "border": "#E5E4E0", "accent": "#318CE7", "onAccent": "#FFFFFF", "accentSoft": "#E3EEFB", "success": "#1FAD5B",
    "warning": "#F5A524", "danger": "#E5484D", "userBubble": "#318CE7", "userBubbleText": "#FFFFFF",
    "agentBubble": "#F1F1EF", "agentBubbleText": "#101318", "scrim": "#000000",
]

// MARK: - chat-window.json

@Suite struct ChatWindowVectorTests {
    private func contract() throws -> [String: Any] { try ContractFile.load("chat-window.json") }

    private func section(_ name: String) throws -> [[String: Any]] {
        let list = try #require(try contract()[name] as? [[String: Any]], "chat-window.json has no \(name)")
        #expect(!list.isEmpty)
        return list
    }

    @Test func theConstantsAreTheContracts() throws {
        let c = try contract()
        let limits = try #require(c["limits"] as? [String: Any])
        #expect(limits["quickReplies"] as? Int == QuickReplies.max)
        #expect(limits["quickReplyLabel"] as? Int == QuickReplies.labelMax)
        #expect(limits["quickReplyText"] as? Int == QuickReplies.textMax)
        #expect((limits["groupGapMs"] as? NSNumber)?.doubleValue == ChatGroups.gapMs)
        #expect((limits["revealMinCps"] as? NSNumber)?.doubleValue == ChatReveal.minCharsPerSecond)
        #expect((limits["revealCatchUpMs"] as? NSNumber)?.doubleValue == ChatReveal.catchUpMs)
        #expect((limits["ratingMaxWidth"] as? NSNumber)?.doubleValue == ChatWindowRules.ratingMaxWidth)
        #expect((limits["ratingShare"] as? NSNumber)?.doubleValue == ChatWindowRules.ratingShare)
        #expect((limits["ratingGap"] as? NSNumber)?.doubleValue == ChatWindowRules.ratingGap)
        let choices = try #require(c["ratingChoices"] as? [String: Any])
        #expect(Set(choices.keys) == Set(GraineChatRating.Style.allCases.map(\.rawValue)))
        for style in GraineChatRating.Style.allCases {
            let full = ChatWindowRules.ratingChoices(style)
            #expect(same(["count": full.count, "size": full.size, "glyph": full.glyph] as [String: Any], choices[style.rawValue]), "\(style) at full size")
        }
        #expect(c["ratingEvent"] as? String == ChatRatings.event)
        #expect(c["ratingEmoji"] as? [String] == ChatRatings.emoji)
        #expect(c["ratingThanks"] as? String == ChatRatings.thanks)
        let labels = try #require(c["ratingLabels"] as? [String: [String]])
        for style in GraineChatRating.Style.allCases {
            #expect(labels[style.rawValue] == ChatRatings.labels[style], "\(style)")
        }
    }

    @Test func quickRepliesAreReadAsTheReferenceReadsThem() throws {
        for v in try section("quickReplies") {
            let name = v["name"] as? String ?? "?"
            let got = QuickReplies.read(v["frame"])
            if let want = v["replies"] as? [[String: String]] {
                #expect(got?.map { ["label": $0.label, "text": $0.text] } == want, "\(name)")
            } else {
                #expect(got == nil, "\(name): ignored")
            }
        }
    }

    @Test func aRatingIsNormalisedAndSentAsAQuietAppEvent() throws {
        for v in try section("rating") {
            let input = try #require(v["input"] as? [String: Any])
            let r = ChatRatings.make(style: input["style"], value: input["value"])
            let want = try #require(v["rating"] as? [String: Any])
            #expect(same(["value": r.value, "scale": r.scale, "style": r.style.rawValue], want), "\(input)")
            #expect(same(JSON.object(from: ChatRatings.frame(r)), v["frame"]), "\(input): the frame")
        }
    }

    /// The rating card's width and its choices' target, glyph and gap for a thread and a card padding: the reference's, within 1e-6.
    @Test func theRatingCardFitsItsThreadAsTheReferenceLaysItOut() throws {
        let list = try section("ratingLayout")
        #expect(list.count >= 12)
        for v in list {
            let n = { (k: String) in (v[k] as? NSNumber)?.doubleValue ?? .nan }
            let style = try #require(v["style"] as? String)
            let got = ChatWindowRules.ratingLayout(style: style, thread: n("thread"), padding: n("padding"))
            let mine = ["width": got.width, "count": Double(got.count), "size": got.size, "glyph": got.glyph, "gap": got.gap]
            for (k, value) in mine {
                #expect(abs(value - n(k)) < 1e-6, "\(style) in \(n("thread")) with \(n("padding")): \(k) \(value) vs \(n(k))")
            }
        }
        // A wide thread draws v1's card: min(300, 84%), the choices at full size.
        #expect(ChatWindowRules.ratingLayout(style: "emoji", thread: 500, padding: 14) == .init(width: 300, count: 5, size: 44, glyph: 24, gap: 8))
        // A style this build does not know is thumbs, in any thread.
        for (thread, padding) in [(327.0, 14.0), (100, 14), (600, 16), (0, 0)] {
            let thumbs = ChatWindowRules.ratingLayout(style: "thumbs", thread: thread, padding: padding)
            #expect(thumbs.count == 2)
            #expect(ChatWindowRules.ratingLayout(style: "hearts", thread: thread, padding: padding) == thumbs, "hearts in \(thread)")
            #expect(ChatWindowRules.ratingLayout(style: "", thread: thread, padding: padding) == thumbs, "no style in \(thread)")
        }
        // A width or padding that is not a number is 0.
        #expect(ChatWindowRules.ratingLayout(style: "emoji", thread: .nan, padding: 14) == .init(width: 0, count: 5, size: 0, glyph: 0, gap: 8))
        #expect(ChatWindowRules.ratingLayout(style: "stars", thread: 240, padding: .infinity) == ChatWindowRules.ratingLayout(style: "stars", thread: 240, padding: 0))
    }

    @Test func groupsAndWhoseTimeIsDrawn() throws {
        for v in try section("groups") {
            let name = v["name"] as? String ?? "?"
            let items = (v["items"] as? [[String: Any]] ?? []).map { o -> ChatGroups.Item in
                let role: GraineRole? = (o["role"] as? String) == "agent" ? .agent : (o["role"] as? String) == "customer" ? .customer : nil
                return ChatGroups.Item(role: role, at: (o["at"] as? NSNumber)?.doubleValue, breaks: o["breaks"] as? Bool ?? false)
            }
            let positions = ChatGroups.positions(items)
            #expect(positions.map(\.rawValue) == v["positions"] as? [String], "\(name)")
            let times = try #require(v["times"] as? [String: [Bool]])
            for (show, want) in times {
                #expect(positions.map { ChatGroups.showsTime(show, $0) } == want, "\(name): \(show)")
            }
        }
    }

    @Test func theAgentsWordsAreFormattedAsTheReferenceFormatsThem() throws {
        for v in try section("markdown") {
            let text = v["text"] as? String ?? ""
            let live = v["live"] as? Bool ?? false
            let blocks = ChatMarkdown.blocks(text, live: live)
            let mine: [[String: Any]] = blocks.map { b in
                var o: [String: Any] = ["spans": b.spans.map { s -> [String: Any] in
                    var span: [String: Any] = ["text": s.text]
                    if s.bold { span["bold"] = true }
                    if s.italic { span["italic"] = true }
                    if s.code { span["code"] = true }
                    if let link = s.link { span["link"] = link }
                    return span
                }]
                switch b.kind {
                case .paragraph: o["kind"] = "paragraph"
                case .bullet: o["kind"] = "bullet"
                case .number(let n):
                    o["kind"] = "number"
                    o["n"] = n
                }
                return o
            }
            #expect(same(mine, v["blocks"]), "\(text.debugDescription) live=\(live): \(mine)")
            #expect(ChatMarkdown.plainText(blocks) == v["plain"] as? String, "\(text.debugDescription): plain words")
        }
    }

    @Test func aReplyStillArrivingIsRevealedAtThePace() throws {
        for v in try section("reveal") {
            let n = { (k: String) in (v[k] as? NSNumber)?.doubleValue ?? 0 }
            #expect(ChatReveal.length(shown: n("shown"), target: n("target"), elapsedMs: n("elapsedMs")) == v["length"] as? Int, "\(v)")
        }
        #expect(ChatReveal.slice("Hi 👋 there", 4) == "Hi 👋", "never half an emoji")
        #expect(ChatReveal.slice("abc", 9) == "abc" && ChatReveal.slice("abc", -1) == "")
    }

    /// The chat's fold — chat.json's steps plus rate and clear — run on this SDK's connection, on a clock the test moves.
    @Test func theChatFoldsTheNewFramesAsTheReferenceDoes() throws {
        for v in try section("fold") {
            let name = v["name"] as? String ?? "?"
            let rig = FoldRig()
            let socket = rig.online()
            for step in v["steps"] as? [[String: Any]] ?? [] {
                if let frame = step["frame"] as? [String: Any] {
                    socket.frame(frame)
                } else if let text = step["send"] as? String {
                    rig.chat.send(text)
                } else if step["drop"] != nil {
                    socket.fail("closed (1006)")
                } else if let rate = step["rate"] as? [String: Any] {
                    let r = ChatRatings.make(style: rate["style"], value: rate["value"])
                    rig.chat.rate(style: r.style, value: (rate["value"] as? NSNumber)?.intValue ?? 0)
                } else if step["clear"] != nil {
                    rig.chat.clearScreen()
                }
            }
            let turns = rig.chat.transcript.turns
            let want = v["turns"] as? [[String: Any]] ?? []
            #expect(turns.count == want.count, "\(name): \(turns.map(\.text))")
            for (turn, w) in zip(turns, want) {
                #expect(turn.role == ((w["role"] as? String) == "agent" ? .agent : .customer), "\(name)")
                #expect(turn.text == w["text"] as? String, "\(name)")
                #expect(turn.live == (w["live"] as? Bool ?? false), "\(name): live")
                #expect(turn.proactive == (w["proactive"] as? Bool ?? false), "\(name): proactive")
                #expect(turn.restored == (w["restored"] as? Bool ?? false), "\(name): restored")
            }
            #expect(rig.chat.typing == v["typing"] as? Bool, "\(name): typing")
            let replies = rig.chat.quickReplies.map { ["label": $0.label, "text": $0.text] }
            #expect(replies == v["quickReplies"] as? [[String: String]], "\(name): quick replies")
            #expect(rig.chat.ended == v["ended"] as? Bool, "\(name): ended")
            let rating: Any = rig.chat.rating.map { ["value": $0.value, "scale": $0.scale, "style": $0.style.rawValue] as Any } ?? NSNull()
            #expect(same(rating, v["rating"]), "\(name): rating")
            let sent = socket.sentFrames.filter { $0["type"] as? String == "text" }.map { $0["data"] as? String ?? "" }
            #expect(sent == v["sent"] as? [String], "\(name): sent")
            let events = socket.sentFrames.filter { $0["type"] as? String == "app_event" }
            #expect(same(events, v["events"]), "\(name): events")
        }
    }
}

/// One chat connection on fakes, for the fold vectors.
private final class FoldRig {
    let scheduler = ManualScheduler()
    let network = RoutedNetwork()
    private(set) var rated: [GraineChatRating] = []
    lazy var chat: ChatConnection = ChatConnection(
        setup: ChatConnection.Setup(
            publishableKey: "pk_test_fold",
            baseUrl: "https://www.graine.ai",
            variables: { [] },
            identity: { nil },
            contextFrame: { nil },
            session: { done in done(GraineSessionConfig(agentId: "agent-1", webcallAgentId: "web-1")) },
            runAction: { _, _, answer in answer(.ok("done")) },
            now: { Date(timeIntervalSince1970: 2_000) }
        ),
        network: network,
        scheduler: scheduler,
        onEvent: { [unowned self] event in if case .rated(let r) = event { self.rated.append(r) } }
    )

    func online() -> FakeSocket {
        chat.open()
        let socket = network.socket!
        socket.open()
        socket.clearSent()
        return socket
    }
}

// MARK: - The window's decisions

@Suite struct ChatWindowRuleTests {
    private func tokens(_ chat: [String: Any] = [:]) throws -> GraineChatTokens {
        let palette = try #require(DesignTokens.parse(["colors": testColors], scheme: "light")).colors
        return try #require(SurfaceTokens.chat(chat, colors: palette))
    }

    private func turn(_ role: GraineRole, delivery: GraineChatTurn.Delivery = .sent, live: Bool = false) -> GraineChatTurn {
        GraineChatTurn(id: "t1", role: role, text: "Hello", live: live, delivery: delivery, at: Date(), proactive: false)
    }

    @Test func eachShapeHasItsCornersInAGroup() throws {
        typealias C = ChatWindowRules.Corners
        func bubbles(_ shape: String, grouping: Bool = true) throws -> GraineChatTokens.Bubbles {
            try tokens(["bubbles": ["shape": shape, "radius": 20, "tightRadius": 6, "grouping": grouping]]).bubbles
        }
        // rounded (v1): the bottom speaker-side corner always tight; the top one in a group's middle and end.
        let rounded = try bubbles("rounded")
        #expect(ChatWindowRules.corners(rounded, role: .customer, position: .single)
                == C(topLeading: 20, topTrailing: 20, bottomLeading: 20, bottomTrailing: 6, continuous: false, tail: false))
        #expect(ChatWindowRules.corners(rounded, role: .agent, position: .middle)
                == C(topLeading: 6, topTrailing: 20, bottomLeading: 6, bottomTrailing: 20, continuous: false, tail: false))
        // squircle: continuous; inner corners tight inside a group.
        let squircle = try bubbles("squircle")
        #expect(ChatWindowRules.corners(squircle, role: .customer, position: .first)
                == C(topLeading: 20, topTrailing: 20, bottomLeading: 20, bottomTrailing: 6, continuous: true, tail: false))
        #expect(ChatWindowRules.corners(squircle, role: .customer, position: .last)
                == C(topLeading: 20, topTrailing: 6, bottomLeading: 20, bottomTrailing: 20, continuous: true, tail: false))
        #expect(ChatWindowRules.corners(squircle, role: .agent, position: .single)
                == C(topLeading: 20, topTrailing: 20, bottomLeading: 20, bottomTrailing: 20, continuous: true, tail: false))
        // tail: the last (or only) bubble's bottom speaker-side corner is square and carries the tail.
        let tail = try bubbles("tail")
        #expect(ChatWindowRules.corners(tail, role: .agent, position: .last)
                == C(topLeading: 6, topTrailing: 20, bottomLeading: 0, bottomTrailing: 20, continuous: true, tail: true))
        #expect(ChatWindowRules.corners(tail, role: .customer, position: .middle).tail == false)
        // flat: every corner the radius.
        let flat = try bubbles("flat")
        #expect(ChatWindowRules.corners(flat, role: .customer, position: .middle)
                == C(topLeading: 20, topTrailing: 20, bottomLeading: 20, bottomTrailing: 20, continuous: false, tail: false))
        // Without grouping every bubble is single.
        let loose = try bubbles("squircle", grouping: false)
        #expect(ChatWindowRules.corners(loose, role: .customer, position: .middle) == ChatWindowRules.corners(loose, role: .customer, position: .single))
    }

    @Test func timesFollowTheGroupAndTheirPlace() throws {
        let t = try tokens(["timestamps": ["show": "group", "style": "inside", "ticks": true]])
        let side = t.bubbles.user
        #expect(ChatWindowRules.timePlace(t.timestamps, side: side, position: .last, turn: turn(.customer)) == .inside)
        #expect(ChatWindowRules.timePlace(t.timestamps, side: side, position: .first, turn: turn(.customer)) == nil, "only the last of a group")
        #expect(ChatWindowRules.timePlace(t.timestamps, side: side, position: .single, turn: turn(.agent, live: true)) == nil, "a reply still arriving has none")
        #expect(ChatWindowRules.tick(t.timestamps, turn: turn(.customer, delivery: .sending)) == .clock)
        #expect(ChatWindowRules.tick(t.timestamps, turn: turn(.customer)) == .check)
        #expect(ChatWindowRules.tick(t.timestamps, turn: turn(.customer, delivery: .failed)) == .alert)
        #expect(ChatWindowRules.tick(t.timestamps, turn: turn(.agent)) == nil, "ticks are the customer's")
        let bare = try tokens(["timestamps": ["show": "always", "style": "inside"], "bubbles": ["agent": ["color": NSNull(), "bare": true]]])
        #expect(ChatWindowRules.timePlace(bare.timestamps, side: bare.bubbles.agent, position: .single, turn: turn(.agent)) == .below, "a bare bubble's time sits below it")
        let classic = try tokens(["showTimestamps": true])
        #expect(ChatWindowRules.timePlace(classic.timestamps, side: classic.bubbles.user, position: .single, turn: turn(.customer, delivery: .sending)) == nil,
                "without ticks a waiting message says so instead of a time")
    }

    @Test func theHeaderSaysWhereTheChatIs() throws {
        let online = try tokens().header
        #expect(ChatWindowRules.headerStatus(online, status: .connected, typing: false, subtitle: "", typingText: "") == .words("Online", dot: true))
        #expect(ChatWindowRules.headerStatus(online, status: .connecting, typing: false, subtitle: "", typingText: "") == .waiting("Connecting…"))
        #expect(ChatWindowRules.headerStatus(online, status: .reconnecting(attempt: 2), typing: false, subtitle: "", typingText: "") == .waiting("Reconnecting…"))
        #expect(ChatWindowRules.headerStatus(online, status: .offline, typing: false, subtitle: "Here for you", typingText: "") == .words("Not connected", dot: false))
        #expect(ChatWindowRules.headerStatus(online, status: .connected, typing: true, subtitle: "", typingText: "") == .words("Online", dot: true),
                "typing shows only where the status says so")
        let typing = try tokens(["header": ["typingStatus": true, "status": "none"]]).header
        #expect(ChatWindowRules.headerStatus(typing, status: .connected, typing: true, subtitle: "", typingText: "Writing…") == .words("Writing…", dot: false))
        #expect(ChatWindowRules.headerStatus(typing, status: .connected, typing: false, subtitle: "", typingText: "") == .none)
        let words = try tokens(["header": ["status": "text"]]).header
        #expect(ChatWindowRules.headerStatus(words, status: .connected, typing: false, subtitle: "We reply fast", typingText: "") == .words("We reply fast", dot: false))
        let loader = GraineLoaderText(connecting: "Un momento…")
        #expect(ChatWindowRules.headerStatus(online, status: .connecting, typing: false, subtitle: "", typingText: "", loader: loader) == .waiting("Un momento…"),
                "the brand's own connecting words")
        // Graine ended the conversation itself (4408, 4410): said before typing, and even where the design has no line.
        #expect(ChatWindowRules.headerStatus(online, status: .offline, typing: false, subtitle: "", typingText: "", disconnected: true)
                == .words("Disconnected", dot: false))
        #expect(ChatWindowRules.headerStatus(typing, status: .offline, typing: true, subtitle: "", typingText: "Writing…", disconnected: true)
                == .words("Disconnected", dot: false), "before typing and before status none")
        #expect(ChatWindowRules.headerStatus(online, status: .connecting, typing: false, subtitle: "", typingText: "", disconnected: true)
                == .waiting("Connecting…"), "connecting again comes first")
    }

    @Test func thePinTheCallButtonAndTheComposersPieces() throws {
        let pin = GraineChatPin(title: "  Your\nplan  ", subtitle: "", imageUrl: nil, badge: String(repeating: "b", count: 40))
        #expect(pin.title == "Your plan" && pin.subtitle == nil && pin.badge?.count == 24)
        #expect(pin.spoken == "Pinned: Your plan, " + String(repeating: "b", count: 24))
        let bar = try tokens().header
        #expect(ChatWindowRules.pinPlace(bar, pin: nil) == nil, "nothing until the app pins one")
        #expect(ChatWindowRules.pinPlace(bar, pin: pin) == .bar)
        #expect(ChatWindowRules.pinPlace(try tokens(["header": ["contextCard": "card"]]).header, pin: pin) == .card)
        #expect(ChatWindowRules.pinPlace(try tokens(["header": ["contextCard": "none"]]).header, pin: pin) == nil)
        #expect(ChatWindowRules.pinPlace(bar, pin: GraineChatPin(title: "   ")) == nil)

        let header = try tokens(["escalation": ["call": "header"]])
        #expect(ChatWindowRules.headerCall(header.escalation, takesCalls: true))
        #expect(!ChatWindowRules.headerCall(header.escalation, takesCalls: false), "only where the agent takes calls this SDK can start")

        let all = try tokens(["composer": ["mic": true, "attach": true], "escalation": ["call": "composer"]])
        #expect(ChatWindowRules.composerPieces(all.composer, escalation: all.escalation, attachHandler: true, takesCalls: true)
                == .init(attach: true, call: false, mic: true), "the microphone already calls")
        #expect(ChatWindowRules.composerPieces(all.composer, escalation: all.escalation, attachHandler: false, takesCalls: false)
                == .init(attach: false, call: false, mic: false), "no handler, no paperclip; no calls, no microphone")
        let call = try tokens(["composer": ["mic": false], "escalation": ["call": "composer"]])
        #expect(ChatWindowRules.composerPieces(call.composer, escalation: call.escalation, attachHandler: false, takesCalls: true)
                == .init(attach: false, call: true, mic: false))
        let classic = try tokens()
        #expect(ChatWindowRules.composerPieces(classic.composer, escalation: classic.escalation, attachHandler: true, takesCalls: true)
                == .init(attach: false, call: false, mic: false), "classic draws none of them")
    }

    @Test func whereTheChipsAndTheWelcomeGo() throws {
        let both = try tokens()
        #expect(ChatWindowRules.starterPlace(both.chips, welcome: both.welcome) == .docked)
        #expect(!ChatWindowRules.repliesDocked(both.chips))
        let inline = try tokens(["chips": ["placement": "inline"]])
        #expect(ChatWindowRules.starterPlace(inline.chips, welcome: inline.welcome) == .thread)
        let docked = try tokens(["chips": ["placement": "above-composer"], "welcome": ["starters": "list"]])
        #expect(ChatWindowRules.repliesDocked(docked.chips))
        #expect(ChatWindowRules.starterPlace(docked.chips, welcome: docked.welcome) == .thread, "a list is always in the thread")

        let greeting = GraineChatTurn(id: "t1", role: .agent, text: "Hi", live: false, delivery: .sent, at: Date(), proactive: true)
        let asked = GraineChatTurn(id: "t2", role: .customer, text: "Hello", live: false, delivery: .sent, at: Date(), proactive: false)
        #expect(ChatWindowRules.welcome(both.welcome, turns: []) == .centered)
        #expect(ChatWindowRules.welcome(both.welcome, turns: [greeting]) == nil, "v1's empty chat is before any message")
        let hero = try tokens(["welcome": ["layout": "hero"]]).welcome
        #expect(ChatWindowRules.welcome(hero, turns: [greeting]) == .hero)
        #expect(ChatWindowRules.welcome(hero, turns: [greeting, asked]) == .hero, "it stays at the top as the conversation grows")
        let earlier = GraineChatTurn(id: "t0", role: .agent, text: "Yesterday", live: false, delivery: .sent, at: Date(), proactive: false, restored: true)
        #expect(ChatWindowRules.welcome(hero, turns: [earlier, greeting]) == nil, "a restored conversation has no welcome")
        let card = try tokens(["welcome": ["layout": "card"]]).welcome
        #expect(ChatWindowRules.welcome(card, turns: [greeting, asked]) == .card)
        #expect(ChatWindowRules.welcome(try tokens(["welcome": ["layout": "minimal"]]).welcome, turns: []) == nil)
    }

    @Test func theBannerThePillAndTheCards() {
        let waiting = GraineChatTurn(id: "t1", role: .customer, text: "Hi", live: false, delivery: .sending, at: Date(), proactive: false)
        #expect(ChatWindowRules.banner(status: .reconnecting(attempt: 1), wasOnline: true, turns: []) == .reconnecting)
        #expect(ChatWindowRules.banner(status: .reconnecting(attempt: 1), wasOnline: false, turns: []) == nil, "a first connect is the header's to say")
        #expect(ChatWindowRules.banner(status: .offline, wasOnline: true, turns: [waiting]) == .offline)
        #expect(ChatWindowRules.banner(status: .offline, wasOnline: true, turns: []) == nil)
        #expect(ChatWindowRules.banner(status: .connected, wasOnline: true, turns: []) == nil)
        #expect(ChatWindowRules.newCount(0) == nil && ChatWindowRules.newCount(3) == "3 new" && ChatWindowRules.newCount(12) == "9+ new")
        #expect(ChatWindowRules.imageHeight("auto", width: 300, auto: 140) == 140)
        #expect(ChatWindowRules.imageHeight("square", width: 300, auto: 140) == 260, "never past 260")
        #expect(ChatWindowRules.imageHeight("landscape", width: 240, auto: 140) == 180)
        #expect(ChatWindowRules.imageHeight("wide", width: 160, auto: 140) == 100, "never under 100")
        #expect(ChatRatings.choices(.thumbs) == [1, 0] && ChatRatings.label(.thumbs, value: 1) == "Thumbs up")
        #expect(ChatRatings.label(.emoji, value: 5) == "Very happy" && ChatRatings.label(.stars, value: 1) == "1 star")
        #expect(GraineChatRating(style: .stars, value: 9) == GraineChatRating(value: 5, scale: 5, style: .stars))
    }

    /// The ten styles as they come on Graine Classic (found in design.json by what each case says), as the window decides to draw each.
    @Test func eachStyleDrawsItsOwnPieces() throws {
        let all = try cases()
        let styleCases = all.indices.filter { i in
            guard let config = all[i]["config"] as? [String: Any], config["preset"] as? String == "graine-classic", config["accent"] == nil,
                  let chat = config["chat"] as? [String: Any], chat.count == 1, chat["preset"] is String else { return false }
            return true
        }
        #expect(styleCases.count == 10)
        struct Want { let composer: String; let headerCall: Bool; let mic: Bool; let attach: Bool; let welcome: ChatWindowRules.WelcomeKind?; let typing: String; let rating: String? }
        let want: [String: Want] = [
            "classic": Want(composer: "bar", headerCall: false, mic: false, attach: false, welcome: nil, typing: "loader", rating: nil),
            "soft": Want(composer: "floating", headerCall: false, mic: true, attach: false, welcome: .card, typing: "dots", rating: "emoji"),
            "bold": Want(composer: "pill", headerCall: true, mic: true, attach: false, welcome: .hero, typing: "wave", rating: "stars"),
            "glass": Want(composer: "floating", headerCall: false, mic: true, attach: false, welcome: nil, typing: "dots", rating: "thumbs"),
            "minimal": Want(composer: "pill", headerCall: false, mic: false, attach: false, welcome: nil, typing: "text", rating: nil),
            "crisp": Want(composer: "bar", headerCall: true, mic: false, attach: true, welcome: .card, typing: "dots", rating: "thumbs"),
            "cozy": Want(composer: "pill", headerCall: false, mic: true, attach: true, welcome: nil, typing: "dots", rating: nil),
            "calm": Want(composer: "floating", headerCall: false, mic: true, attach: false, welcome: .hero, typing: "text", rating: "stars"),
            "compact": Want(composer: "bar", headerCall: false, mic: false, attach: false, welcome: nil, typing: "text", rating: nil),
            "lively": Want(composer: "floating", headerCall: false, mic: true, attach: false, welcome: .hero, typing: "wave", rating: "emoji"),
        ]
        let greeting = GraineChatTurn(id: "t1", role: .agent, text: "Hi", live: false, delivery: .sent, at: Date(), proactive: true)
        var seen = Set<String>()
        for i in styleCases {
            let design = try #require(GraineDesign.parse(all[i]["design"]))
            for tokens in [design.light, design.dark] {
                let chat = try #require(tokens.chat)
                let w = try #require(want[chat.preset], "case \(i): \(chat.preset)")
                seen.insert(chat.preset)
                #expect(chat.composer.style == w.composer, "\(chat.preset): composer")
                #expect(ChatWindowRules.headerCall(chat.escalation, takesCalls: true) == w.headerCall, "\(chat.preset): header call")
                let pieces = ChatWindowRules.composerPieces(chat.composer, escalation: chat.escalation, attachHandler: true, takesCalls: true)
                #expect(pieces.mic == w.mic && pieces.attach == w.attach, "\(chat.preset): microphone and paperclip")
                #expect(!ChatWindowRules.composerPieces(chat.composer, escalation: chat.escalation, attachHandler: false, takesCalls: false).attach,
                        "\(chat.preset): no paperclip without the app's handler")
                #expect(ChatWindowRules.welcome(chat.welcome, turns: [greeting]) == w.welcome, "\(chat.preset): welcome")
                #expect(chat.typing.style == w.typing, "\(chat.preset): typing")
                #expect((chat.rating.show ? chat.rating.style : nil) == w.rating, "\(chat.preset): rating")
            }
        }
        #expect(seen.count == 10)
    }

    @Test func aBubbleIsOneSpokenElement() {
        let mine = GraineChatTurn(id: "t1", role: .customer, text: "Hi", live: false, delivery: .failed, at: Date(), proactive: false)
        #expect(ChatWindowRules.spoken(mine, plain: "Hi", name: "Aria", time: nil) == "You: Hi, not sent. Double-tap to retry.")
        let theirs = GraineChatTurn(id: "t2", role: .agent, text: "**Hello**", live: false, delivery: .sent, at: Date(), proactive: false)
        #expect(ChatWindowRules.spoken(theirs, plain: "Hello", name: "Aria", time: "9:41 AM") == "Aria: Hello, 9:41 AM")
    }
}

// MARK: - The chat's API

@Suite @MainActor struct ChatWindowApiTests {
    private func settle() async throws { try await Task.sleep(nanoseconds: 30_000_000) }

    @Test func quickRepliesTheEndAndTheRatingReachTheApp() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session()
        var heard: [GraineChatRating] = []
        rig.graine.chat.onRated = { heard.append($0) }
        rig.graine.chat.open()
        let socket = try #require(rig.network.socket)
        socket.open()
        socket.frame(["type": "text", "data": "<beginning_of_stream>Shall I go ahead?<end_of_stream>"])
        socket.frame(["type": "quick_replies", "replies": ["Yes", ["label": "Not now", "text": "Not right now, thanks"]]])
        #expect(rig.graine.chat.quickReplies == [GraineQuickReply(label: "Yes", text: "Yes"), GraineQuickReply(label: "Not now", text: "Not right now, thanks")])
        socket.clearSent()
        rig.graine.chat.sendQuickReply(rig.graine.chat.quickReplies[1])
        #expect(socket.sent == [ChatWire.textFrame("Not right now, thanks")], "a tap is the customer's own message")
        #expect(rig.graine.chat.quickReplies.isEmpty)
        #expect(rig.graine.chat.turns.last?.text == "Not right now, thanks")

        rig.graine.chat.rate(style: .thumbs, value: 1)
        #expect(rig.graine.chat.rating == nil && heard.isEmpty, "only a conversation the agent ended is rated")
        socket.frame(["type": "conversation_end"])
        #expect(rig.graine.chat.ended && !rig.graine.chat.typing)
        socket.clearSent()
        rig.graine.chat.rate(style: .stars, value: 4)
        rig.graine.chat.rate(style: .stars, value: 1)
        #expect(rig.graine.chat.rating == GraineChatRating(value: 4, scale: 5, style: .stars), "one answer per conversation")
        #expect(heard == [GraineChatRating(value: 4, scale: 5, style: .stars)])
        #expect(socket.sentTypes == ["app_event"])
        let event = try #require(socket.sentFrames.first?["event"] as? [String: Any])
        #expect(event["name"] as? String == "chat_rating" && event["quiet"] as? Bool == true)
        rig.graine.chat.send("One more thing")
        #expect(!rig.graine.chat.ended && rig.graine.chat.rating == nil, "a message after the end starts over")
    }

    @Test func thePinAndTheAttachHandlerAreTheApps() async throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        let chat = rig.graine.chat
        var changes = 0
        let watching = chat.objectWillChange.sink { changes += 1 }
        chat.pin(GraineChatPin(title: "Your plan", subtitle: "Renews on 14 Nov", imageUrl: URL(string: "https://cdn.example.com/p.png"), badge: "Active"))
        #expect(chat.pinned?.title == "Your plan" && chat.pinned?.badge == "Active")
        chat.pin(GraineChatPin(title: " "))
        #expect(chat.pinned == nil, "an empty title is nothing pinned")
        chat.pin(GraineChatPin(title: "Again"))
        chat.pin(nil)
        #expect(chat.pinned == nil)
        let before = changes
        var attached = 0
        chat.onAttach = { attached += 1 }
        #expect(changes > before, "the window redraws: the paperclip may show now")
        chat.onAttach?()
        #expect(attached == 1)
        watching.cancel()
    }
}

// MARK: - The live reply's reveal

@Suite struct ChatRevealModelTests {
    private func turn(_ text: String, live: Bool, id: String = "t2", role: GraineRole = .agent) -> GraineChatTurn {
        GraineChatTurn(id: id, role: role, text: text, live: live, delivery: .sent, at: Date(), proactive: false)
    }

    @Test func aReplyStillArrivingIsRevealedAtThePaceThenDrawnWhole() {
        let reveal = GraineChatReveal()
        let words = String(repeating: "a", count: 300)
        reveal.feed(turn(words, live: true), enabled: true)
        #expect(reveal.visible(turn(words, live: true)) == 0, "a new live reply starts from nothing")
        let t0 = Date(timeIntervalSince1970: 1_000)
        reveal.tick(t0)
        let first = reveal.shown
        reveal.tick(t0.addingTimeInterval(0.1))
        #expect(reveal.shown > first, "it moves on with the clock")
        #expect(reveal.shown < 300, "never all at once")
        // The turn ends: the rest is revealed at the same pace, then drawn whole.
        reveal.feed(turn(words, live: false), enabled: true)
        #expect(reveal.active)
        var now = t0.addingTimeInterval(0.1)
        for _ in 0..<200 where reveal.active {
            now = now.addingTimeInterval(0.016)
            reveal.tick(now)
        }
        #expect(!reveal.active && reveal.visible(turn(words, live: false)) == nil)
        #expect(now.timeIntervalSince(t0) < 3.5, "caught up in a few seconds at 60 frames a second")
    }

    @Test func noRevealUnderReducedMotionOrForAnotherTurn() {
        let reveal = GraineChatReveal()
        reveal.feed(turn("Hello", live: true), enabled: false)
        #expect(!reveal.active, "drawn as it arrives")
        reveal.feed(turn("Hello", live: true), enabled: true)
        #expect(reveal.visible(turn("Hello", live: true, id: "t1")) == nil, "only the live turn animates")
        reveal.feed(turn("Hi", live: false, id: "t3", role: .customer), enabled: true)
        #expect(!reveal.active, "the customer speaking ends it")
        reveal.feed(turn("Settled already", live: false, id: "t4"), enabled: true)
        #expect(!reveal.active, "a turn that arrived whole is drawn whole")
    }

    @Test func settledWordsAreParsedOnce() {
        let cache = GraineChatFormatCache()
        let a = cache.blocks("**Hi** there")
        #expect(a == ChatMarkdown.blocks("**Hi** there"))
        #expect(cache.blocks("**Hi** there") == a)
    }
}
