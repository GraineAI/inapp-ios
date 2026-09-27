import CoreGraphics
import Foundation
import Testing
@testable import GraineInApp

/*
 * THE VOICE BAR, ITS ICONS AND ITS TYPEFACES (contract/DESIGN.md "Voice bar",
 * "Icons", "Fonts"), proven on a Mac: the faces every design in
 * contract/design.json loads and where from, the icon set and how each style
 * paints it, the meter's timing, the status words and their order, and the
 * font loader end to end — against local bytes and a temporary folder, never
 * a network.
 */

@Suite struct FontContractTests {

    private func contract() throws -> [String: Any] {
        try ContractFile.load("design.json")
    }

    /// Sorted as the generator sorts `cases[].fontFaces`: by family, then weight.
    private func sorted(_ faces: [GraineFontFace]) -> [GraineFontFace] {
        faces.sorted { a, b in a.family == b.family ? a.weight < b.weight : a.family < b.family }
    }

    @Test func everyDesignLoadsExactlyTheFacesTheContractLists() throws {
        let json = try contract()
        let origin = try #require(json["fontOrigin"] as? String)
        let cases = try #require(json["cases"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        var withFaces = 0
        for c in cases {
            let config = String(describing: c["config"])
            let design = try #require(GraineDesign.parse(c["design"]), "config: \(config)")
            let expected = try #require(c["fontFaces"] as? [[String: Any]], "config: \(config)")
            let faces = sorted(GraineFonts.faces(for: design, origin: origin))
            #expect(faces.count == expected.count, "config: \(config)")
            for (face, want) in zip(faces, expected) {
                #expect(face.family == want["family"] as? String, "config: \(config)")
                #expect(face.weight == (want["weight"] as? NSNumber)?.intValue, "config: \(config)")
                #expect(face.name == want["name"] as? String, "config: \(config)")
                #expect(face.url == want["url"] as? String, "config: \(config)")
            }
            if !expected.isEmpty { withFaces += 1 }
        }
        #expect(withFaces > 0, "the contract has designs whose typeface must be loaded")
    }

    @Test func theWeightsTheVersionAndTheOriginAreTheContracts() throws {
        let json = try contract()
        let weights = try #require(json["fontWeights"] as? [String: [Int]])
        #expect(GraineFonts.weights == weights)
        #expect(GraineFonts.assetVersion == (json["fontAssetVersion"] as? NSNumber)?.intValue)
        let origin = try #require(json["fontOrigin"] as? String)
        #expect(GraineFonts.url(origin: nil, family: "Inter", weight: 400) == origin + "/api/embed/font?f=Inter&w=400&v=1")
        #expect(GraineFonts.url(origin: "  ", family: "Inter", weight: 400) == origin + "/api/embed/font?f=Inter&w=400&v=1")
    }

    @Test func theNearestWeightWinsAndATieGoesHeavier() {
        #expect(GraineFonts.nearestWeight([400, 600], to: 500) == 600)
        #expect(GraineFonts.nearestWeight([300, 500], to: 400) == 500)
        #expect(GraineFonts.nearestWeight([400, 500, 600], to: 500) == 500)
        #expect(GraineFonts.nearestWeight([400], to: 900) == 400)
        #expect(GraineFonts.nearestWeight([], to: 400) == nil)
        // Martel has no 500: 400 and 600 are equally near, and the heavier wins.
        #expect(GraineFonts.face(family: "Martel", weight: 500, origin: nil)?.weight == 600)
        #expect(GraineFonts.face(family: "Playfair Display", weight: 300, origin: nil)?.weight == 400)
        #expect(GraineFonts.face(family: "Tiro Devanagari Hindi", weight: 700, origin: nil)?.weight == 400)
    }

    @Test func theSystemFontAndFamiliesWithNoFilesLoadNothing() {
        for family in ["system", " System ", "", "Comic Sans", "Helvetica Neue"] {
            #expect(GraineFonts.face(family: family, weight: 400, origin: nil) == nil, "\(family)")
        }
        // Matched ignoring case and spaces around it; named, and served, as the curated list spells it.
        #expect(GraineFonts.face(family: " dm sans ", weight: 700, origin: "https://agents.example.test/") == GraineFontFace(
            family: "DM Sans", weight: 700, name: "Graine-DMSans-700",
            url: "https://agents.example.test/api/embed/font?f=DM%20Sans&w=700&v=1"
        ))
        #expect(GraineFonts.registryName(family: "Source Serif 4", weight: 400) == "Graine-SourceSerif4-400")
        // What a view looks a loaded face up by: the family as the list spells it, at its nearest weight.
        #expect(GraineFonts.loadedKey(family: "dm sans", weight: 650) == "DM Sans|700")
        #expect(GraineFonts.loadedKey(family: "Martel", weight: 500) == "Martel|600")
        #expect(GraineFonts.loadedKey(family: "system", weight: 400) == nil)
        #expect(GraineFonts.loadedKey(family: "Comic Sans", weight: 400) == nil)
    }

    @Test func aDesignWithOneFamilyLoadsEachWeightOnce() throws {
        let cases = try #require(try contract()["cases"] as? [[String: Any]])
        let brutal = try #require(cases.first { ($0["config"] as? [String: Any])?["preset"] as? String == "neo-brutalism" })
        let design = try #require(GraineDesign.parse(brutal["design"]))
        // Body 500 and 700, heading 700 and 700, in both schemes: two faces, not eight.
        #expect(GraineFonts.faces(for: design, origin: nil).map(\.weight) == [500, 700])
    }
}

@Suite struct SdkIconTests {

    @Test func theIconSetIsTheContracts() throws {
        let icons = try #require(try ContractFile.load("design.json")["icons"] as? [String: [String: String]])
        #expect(Set(icons.keys) == Set(GraineIconName.allCases.map(\.rawValue)))
        for name in GraineIconName.allCases {
            let want = try #require(icons[name.rawValue], "\(name)")
            #expect(GraineIcons.paths(name) == GraineIconPaths(body: want["body"], lines: want["lines"]), "\(name)")
        }
    }

    @Test func everyIconIsDrawableAndInsideItsBox() throws {
        for name in GraineIconName.allCases {
            let icon = GraineIcons.paths(name)
            #expect(icon.body != nil || icon.lines != nil, "\(name)")
            for data in [icon.body, icon.lines].compactMap({ $0 }) {
                let segments = try #require(GlyphPath.parse(data), "\(name)")
                for segment in segments {
                    let end: (x: Double, y: Double)?
                    switch segment {
                    case let .move(x, y), let .line(x, y): end = (x, y)
                    case let .cubic(_, _, _, _, x, y): end = (x, y)
                    case .close: end = nil
                    }
                    guard let p = end else { continue }
                    #expect(p.x >= -0.01 && p.x <= 24.01 && p.y >= -0.01 && p.y <= 24.01, "\(name): \(p)")
                }
            }
        }
    }

    @Test func eachStylePaintsAsTheContractSays() {
        typealias Paint = GraineIcons.Paint
        #expect(GraineIcons.paint(style: "outline", stroke: 2) == Paint(bodyFill: 0, bodyStroke: 2, linesStroke: 2, square: false))
        #expect(GraineIcons.paint(style: "sharp", stroke: 1.5) == Paint(bodyFill: 0, bodyStroke: 1.5, linesStroke: 1.5, square: true))
        #expect(GraineIcons.paint(style: "filled", stroke: 2) == Paint(bodyFill: 1, bodyStroke: 1.5, linesStroke: 2, square: false))
        // 0.75 × the stroke, but never under 1.
        #expect(GraineIcons.paint(style: "filled", stroke: 1.25) == Paint(bodyFill: 1, bodyStroke: 1, linesStroke: 1.25, square: false))
        #expect(GraineIcons.paint(style: "duotone", stroke: 1.5) == Paint(bodyFill: 0.28, bodyStroke: 1.5, linesStroke: 1.5, square: false))
        #expect(GraineIcons.paint(style: "sparkly", stroke: 2) == GraineIcons.paint(style: "outline", stroke: 2))
    }

    /// Every style a design in the contract uses is one drawn on purpose, not by the fallback.
    @Test func everyStyleInTheContractIsKnown() throws {
        let cases = try #require(try ContractFile.load("design.json")["cases"] as? [[String: Any]])
        for c in cases {
            let design = try #require(GraineDesign.parse(c["design"]))
            for t in [design.light, design.dark] {
                #expect(["outline", "sharp", "filled", "duotone"].contains(t.icons.style), "\(t.icons.style)")
            }
        }
    }
}

@Suite struct VoiceMeterTests {

    @Test func eachLegFollowsTheDesignsPace() {
        #expect(VoiceMeter.legMs(durationMs: 200) == 640)
        #expect(VoiceMeter.legMs(durationMs: 500) == 1_600)
        #expect(VoiceMeter.legMs(durationMs: 100) == 420)
        #expect(VoiceMeter.legMs(durationMs: 0) == 420)
    }

    @Test func itHoldsStillWithoutMotion() {
        #expect(VoiceMeter.moves(durationMs: 200, reduceMotion: false))
        #expect(!VoiceMeter.moves(durationMs: 0, reduceMotion: false))
        #expect(!VoiceMeter.moves(durationMs: 200, reduceMotion: true))
        // A design with no motion, and Reduce Motion, both reach the meter as 0.
        let none = GraineThemeTokens.Motion(durationMs: 300, easing: "none", bounce: 0)
        #expect(!VoiceMeter.moves(durationMs: none.effectiveDurationMs(reduceMotion: false), reduceMotion: false))
        let lively = GraineThemeTokens.Motion(durationMs: 300, easing: "spring", bounce: 0.3)
        #expect(!VoiceMeter.moves(durationMs: lively.effectiveDurationMs(reduceMotion: true), reduceMotion: false))
    }

    @Test func theBarsAreTheGaragesFour() {
        #expect(VoiceMeter.heights == [0.55, 1, 0.7, 0.4])
        #expect((0..<4).map(VoiceMeter.barHeight) == [6.6, 12, 8.4, 4.8])
        #expect(VoiceMeter.barWidth == 2.5)
        #expect(VoiceMeter.barGap == 2)
        #expect(VoiceMeter.height == 12)
    }

    @Test func eachBarRisesAndFallsNinetyMillisecondsBehindTheLast() {
        let leg = VoiceMeter.legMs(durationMs: 200)
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-6 }
        #expect(VoiceMeter.scale(bar: 0, elapsedMs: 0, legMs: leg) == 0.35)
        #expect(near(VoiceMeter.scale(bar: 0, elapsedMs: leg / 2, legMs: leg), 0.675))
        #expect(near(VoiceMeter.scale(bar: 0, elapsedMs: leg, legMs: leg), 1))
        #expect(near(VoiceMeter.scale(bar: 0, elapsedMs: leg * 1.5, legMs: leg), 0.675))
        #expect(near(VoiceMeter.scale(bar: 0, elapsedMs: leg * 2, legMs: leg), 0.35))
        #expect(near(VoiceMeter.scale(bar: 0, elapsedMs: leg * 7, legMs: leg), 1), "forever")
        for i in 1..<4 {
            let start = Double(i) * 90
            #expect(VoiceMeter.scale(bar: i, elapsedMs: start, legMs: leg) == 0.35, "bar \(i) waits its turn")
            #expect(VoiceMeter.scale(bar: i, elapsedMs: start + 20, legMs: leg) > 0.35, "bar \(i)")
            #expect(near(VoiceMeter.scale(bar: i, elapsedMs: start + leg, legMs: leg), 1), "bar \(i)")
        }
        // Up the first leg without a step back, and never outside 35%–100%.
        var last = 0.0
        for ms in stride(from: 0.0, through: leg * 3, by: 5) {
            let s = VoiceMeter.scale(bar: 0, elapsedMs: ms, legMs: leg)
            #expect(s >= 0.35 - 1e-12 && s <= 1 + 1e-12)
            if ms <= leg { #expect(s >= last - 1e-12); last = s }
        }
    }

    /// Each leg eases in and out exactly as the Garage's CSS `ease-in-out` does.
    @Test func eachLegIsCSSEaseInOut() {
        let ease = CubicBezier.easeInOut
        #expect(ease(0) == 0)
        #expect(ease(1) == 1)
        #expect(abs(ease(0.5) - 0.5) < 1e-6)
        #expect(abs(ease(0.25) - 0.129162) < 1e-5)
        #expect(abs(ease(0.1) - 0.019722) < 1e-5)
        for x in stride(from: 0.0, through: 1.0, by: 0.05) {
            #expect(abs(ease(x) + ease(1 - x) - 1) < 1e-6, "symmetric at \(x)")
        }
    }
}

@Suite struct VoiceBarStatusTests {
    private typealias Input = VoiceBarStatus.Input
    private typealias Line = VoiceBarStatus.Line

    private func line(_ change: (inout Input) -> Void) -> Line {
        var s = Input()
        change(&s)
        return VoiceBarStatus.line(s)
    }

    private func words(_ text: String) -> Line { Line(text: text, waiting: nil, meter: false) }

    @Test func theWordsAreTheContractsInSentenceCase() {
        #expect(line { _ in } == words("Tap to talk"))
        #expect(line { $0.connected = true; $0.phase = .listening } == Line(text: "Listening", waiting: nil, meter: true))
        #expect(line { $0.connected = true; $0.phase = .speaking } == Line(text: "Speaking", waiting: nil, meter: true))
        #expect(line { $0.connected = true; $0.phase = .thinking } == Line(text: "Thinking…", waiting: "thinking", meter: false))
        #expect(line { $0.connected = true; $0.phase = .listening; $0.quality = .poor } == words("Weak connection"))
        #expect(line { $0.connected = true; $0.muted = true } == words("Muted"))
        #expect(line { $0.connecting = true } == Line(text: "Connecting…", waiting: "connecting", meter: false))
        #expect(line { $0.ready = false } == Line(text: "Connecting…", waiting: "connecting", meter: false))
        #expect(line { $0.ready = false; $0.connectivity = .failed } == words("Couldn’t load · tap to retry"))
        #expect(line { $0.micDenied = true } == words("Needs microphone"))
        #expect(line { $0.reconnecting = true } == Line(text: "Reconnecting…", waiting: "reconnecting", meter: false))
        #expect(line { $0.connectivity = .retrying } == Line(text: "Reconnecting…", waiting: "reconnecting", meter: false))
        #expect(line { $0.online = false } == words("No connection"))
        #expect(line { $0.inChat = true; $0.chatOnline = true } == words("Online"))
        #expect(line { $0.inChat = true } == Line(text: "Connecting…", waiting: "connecting", meter: false))
        #expect(line { $0.error = true } == words("Unavailable"))
    }

    /**
     * First match wins: each rung, with every rung below it true at the same
     * time, still says its own words. Applied from the bottom up, so where two
     * rungs set the phase the higher one holds.
     */
    @Test func firstMatchWinsInTheContractsOrder() {
        let ladder: [(String, (inout Input) -> Void)] = [
            ("Unavailable", { $0.error = true }),
            ("Online", { $0.inChat = true; $0.chatOnline = true }),
            ("No connection", { $0.online = false }),
            ("Reconnecting…", { $0.reconnecting = true }),
            ("Needs microphone", { $0.micDenied = true }),
            ("Couldn’t load · tap to retry", { $0.connectivity = .failed }),
            ("Connecting…", { $0.connecting = true }),
            ("Muted", { $0.muted = true }),
            ("Thinking…", { $0.connected = true; $0.phase = .thinking }),
            ("Speaking", { $0.connected = true; $0.phase = .speaking }),
            ("Weak connection", { $0.connected = true; $0.phase = .listening; $0.quality = .poor }),
            ("Listening", { $0.connected = true; $0.phase = .listening }),
            ("Tap to talk", { _ in }),
        ]
        for i in ladder.indices {
            var s = Input()
            for j in stride(from: ladder.count - 1, through: i, by: -1) { ladder[j].1(&s) }
            #expect(VoiceBarStatus.line(s).text == ladder[i].0, "rung \(i)")
        }
    }
}

@Suite struct CallPhaseTests {

    private func phase(
        reconnecting: Bool = false, connectivity: GraineConnectivity = .ready, connecting: Bool = false,
        ready: Bool = true, connected: Bool = false, agentSpeaking: Bool = false, awaitingAgent: Bool = false
    ) -> GrainePhase {
        GrainePhase.of(
            reconnecting: reconnecting, connectivity: connectivity, connecting: connecting, ready: ready,
            connected: connected, agentSpeaking: agentSpeaking, awaitingAgent: awaitingAgent
        )
    }

    @Test func thePhaseIsTheReactNativeLaunchers() {
        #expect(phase() == .idle)
        #expect(phase(ready: false) == .connecting)
        #expect(phase(connecting: true) == .connecting)
        #expect(phase(connectivity: .retrying) == .reconnecting)
        #expect(phase(connectivity: .failed) == .reconnecting)
        #expect(phase(reconnecting: true, connected: true) == .reconnecting)
        #expect(phase(connected: true) == .listening)
        #expect(phase(connected: true, awaitingAgent: true) == .thinking)
        // Once the agent's words are arriving it is speaking, whatever the flag still says.
        #expect(phase(connected: true, agentSpeaking: true, awaitingAgent: true) == .speaking)
        #expect(phase(connected: false, awaitingAgent: true) == .idle)
    }

    @Test func thinkingIsTheGapBetweenTheCustomerFinishingAndTheAgentAnswering() {
        var awaiting = false
        awaiting = CaptionLog.awaitsAgent(awaiting, after: GraineCaption(role: .customer, text: "Book a", live: true))
        #expect(!awaiting, "still talking")
        awaiting = CaptionLog.awaitsAgent(awaiting, after: GraineCaption(role: .customer, text: "Book a test drive", live: false))
        #expect(awaiting, "finished: the agent owes an answer")
        awaiting = CaptionLog.awaitsAgent(awaiting, after: GraineCaption(role: .customer, text: "Book a test drive", live: true))
        #expect(awaiting, "a live customer line does not settle it")
        awaiting = CaptionLog.awaitsAgent(awaiting, after: GraineCaption(role: .agent, text: "Sure", live: true))
        #expect(!awaiting, "the agent started")
        awaiting = CaptionLog.awaitsAgent(awaiting, after: GraineCaption(role: .customer, text: "", live: false))
        #expect(awaiting, "a customer turn closed with no words still ends the customer's turn")
        awaiting = CaptionLog.awaitsAgent(awaiting, after: GraineCaption(role: .agent, text: "", live: false))
        #expect(!awaiting)
    }

    /// DESIGN.md: while the agent works out its answer the bar says "Thinking…" with the dashboard's loader — never the meter.
    @Test func thinkingIsTheLoaderWithTheDashboardsWords() throws {
        let now = phase(connected: true, awaitingAgent: true)
        let status = VoiceBarStatus.line(VoiceBarStatus.Input(connected: true, phase: now))
        #expect(status == VoiceBarStatus.Line(text: "Thinking…", waiting: "thinking", meter: false))
        let moment = try #require(status.waiting)
        #expect(Loaders.resolve(nil).text.forMoment(moment) == "Thinking…")
        #expect(Loaders.resolve(["text": ["thinking": "One moment…"]]).text.forMoment(moment) == "One moment…")
        // Muted outranks it; thinking outranks a weak line.
        #expect(VoiceBarStatus.line(VoiceBarStatus.Input(muted: true, connected: true, phase: now)).text == "Muted")
        #expect(VoiceBarStatus.line(VoiceBarStatus.Input(connected: true, phase: now, quality: .poor)).text == "Thinking…")
    }
}

@Suite struct ChatWindowRulesTests {

    private func classic(_ change: ((inout [String: Any]) -> Void)? = nil) throws -> GraineThemeTokens {
        let cases = try #require(try ContractFile.load("design.json")["cases"] as? [[String: Any]])
        var design = try #require(cases.first?["design"] as? [String: Any])
        if let change = change {
            var light = try #require(design["light"] as? [String: Any])
            change(&light)
            design["light"] = light
        }
        return try #require(GraineDesign.parse(design)).light
    }

    @Test func theSwitchShowsOnlyWhereBothAreOfferedAndTheChatCanBeCarried() {
        #expect(AgentSurfaces.canSwitch(appearance: [:], carriesChat: true))
        #expect(AgentSurfaces.canSwitch(appearance: ["mode": "both"], carriesChat: true))
        #expect(AgentSurfaces.canSwitch(appearance: ["mode": NSNull()], carriesChat: true))
        #expect(!AgentSurfaces.canSwitch(appearance: ["mode": "voice"], carriesChat: true))
        #expect(!AgentSurfaces.canSwitch(appearance: ["mode": " Chat "], carriesChat: true))
        #expect(!AgentSurfaces.canSwitch(appearance: ["mode": "both"], carriesChat: false))
        #expect(!AgentSurfaces.canSwitch(appearance: nil, carriesChat: false))
    }

    @Test func aMessageTakesItsCornersAndPaddingFromTheTokens() throws {
        let t = try classic()
        // radius.sm 8, radius.lg 18, cardPadding 14: padded 14 by round(10.5).
        #expect(ChatBubble.shape(t, role: .customer) == ChatBubble.Shape(
            paddingH: 14, paddingV: 11, topLeading: 18, topTrailing: 18, bottomLeading: 18, bottomTrailing: 8
        ))
        #expect(ChatBubble.shape(t, role: .agent) == ChatBubble.Shape(
            paddingH: 14, paddingV: 11, topLeading: 18, topTrailing: 18, bottomLeading: 8, bottomTrailing: 18
        ))
        let minimal = try classic { $0["bubbles"] = "minimal" }
        #expect(ChatBubble.shape(minimal, role: .agent) == ChatBubble.Shape(
            paddingH: 2, paddingV: 2, topLeading: 0, topTrailing: 0, bottomLeading: 0, bottomTrailing: 0
        ))
        #expect(ChatBubble.shape(minimal, role: .customer) == ChatBubble.shape(t, role: .customer))
    }
}

/// Serves one answer to every request, from a background thread as the network would, and counts them.
private final class FakeFontServer: @unchecked Sendable {
    private let lock = NSLock()
    private var asked = 0
    let answer: Data?

    init(answer: Data?) { self.answer = answer }

    var requests: Int {
        lock.lock()
        defer { lock.unlock() }
        return asked
    }

    func fetch(_ url: URL, _ done: @escaping (Data?) -> Void) {
        lock.lock()
        asked += 1
        lock.unlock()
        let answer = self.answer
        DispatchQueue.global().async { done(answer) }
    }
}

/**
 * The loader, end to end, with the network swapped for local bytes: a real
 * TrueType file from the Mac itself, served by a fake that counts requests.
 */
@MainActor
@Suite struct FontStoreTests {

    /// A TrueType file every Mac has. Registering it again is harmless: it is drawable by its name either way.
    private func macFont() throws -> (data: Data, postScriptName: String) {
        let candidates = [
            "/System/Library/Fonts/Supplemental/Georgia.ttf",
            "/System/Library/Fonts/Supplemental/Verdana.ttf",
            "/System/Library/Fonts/Monaco.ttf",
            "/System/Library/Fonts/Geneva.ttf",
        ]
        for path in candidates {
            guard let data = FileManager.default.contents(atPath: path),
                  let provider = CGDataProvider(data: data as CFData), let font = CGFont(provider),
                  let name = font.postScriptName as String? else { continue }
            return (data, name)
        }
        throw ContractFile.NotFound(name: "a TrueType system font", searchedFrom: "/System/Library/Fonts")
    }

    private func scratchFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("graine-fonts-\(UUID().uuidString)", isDirectory: true)
    }

    private func load(_ store: GraineFontStore, _ faces: [GraineFontFace]) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.load(faces) { continuation.resume() }
        }
    }

    private func dmSans700() throws -> GraineFontFace {
        try #require(GraineFonts.face(family: "DM Sans", weight: 700, origin: "https://www.graine.ai"))
    }

    @Test func aFaceIsFetchedOnceKeptOnDiskAndRegistered() async throws {
        let font = try macFont()
        let server = FakeFontServer(answer: font.data)
        let folder = scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = GraineFontStore(directory: folder, fetch: server.fetch)
        let face = try dmSans700()

        await load(store, [face, face])
        #expect(server.requests == 1, "asked for twice at once: fetched once")
        #expect(store.faces == ["DM Sans|700": font.postScriptName])
        // Looked up as a view asks: any spelling, any weight whose nearest is 700 (650 ties 600 and 700; heavier wins).
        #expect(store.postScriptName(family: "dm sans", weight: 650) == font.postScriptName)
        #expect(store.postScriptName(family: "DM Sans", weight: 400) == nil, "not loaded: the system font")
        #expect(store.postScriptName(family: "system", weight: 700) == nil)

        let file = try #require(store.cacheFile(for: face))
        #expect(file.lastPathComponent == "Graine-DMSans-700-" + GraineFontStore.fnv1a(face.url) + ".ttf")
        #expect(FileManager.default.contents(atPath: file.path) == font.data)

        await load(store, [face])
        #expect(server.requests == 1, "never fetched twice")
    }

    @Test func theNextLaunchDrawsFromTheKeptFileWithoutTheNetwork() async throws {
        let font = try macFont()
        let folder = scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let face = try dmSans700()
        await load(GraineFontStore(directory: folder, fetch: FakeFontServer(answer: font.data).fetch), [face])

        let offline = FakeFontServer(answer: nil)
        let relaunched = GraineFontStore(directory: folder, fetch: offline.fetch)
        await load(relaunched, [face])
        #expect(offline.requests == 0)
        #expect(relaunched.faces["DM Sans|700"] == font.postScriptName)
    }

    @Test func aFailedOrBrokenDownloadIsTheSystemFontSilently() async throws {
        let face = try dmSans700()
        for answer in [nil, Data("Font unavailable.".utf8), Data()] as [Data?] {
            let folder = scratchFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let server = FakeFontServer(answer: answer)
            let store = GraineFontStore(directory: folder, fetch: server.fetch)
            await load(store, [face])
            #expect(store.faces.isEmpty)
            #expect(store.postScriptName(family: "DM Sans", weight: 700) == nil)
            let file = try #require(store.cacheFile(for: face))
            #expect(!FileManager.default.fileExists(atPath: file.path), "nothing that is not a font is kept")
            await load(store, [face])
            #expect(server.requests == 1, "not retried until the next launch")
        }
    }

    @Test func aDamagedKeptFileIsReplacedFromTheNetwork() async throws {
        let font = try macFont()
        let folder = scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = FakeFontServer(answer: font.data)
        let store = GraineFontStore(directory: folder, fetch: server.fetch)
        let face = try dmSans700()
        let file = try #require(store.cacheFile(for: face))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("half a font".utf8).write(to: file)

        await load(store, [face])
        #expect(server.requests == 1)
        #expect(store.faces["DM Sans|700"] == font.postScriptName)
        #expect(FileManager.default.contents(atPath: file.path) == font.data)
    }

    @Test func eachUrlIsItsOwnFile() throws {
        #expect(GraineFontStore.fnv1a("") == "cbf29ce484222325")
        #expect(GraineFontStore.fnv1a("a") == "af63dc4c8601ec8c")
        let store = GraineFontStore(directory: scratchFolder(), fetch: { _, done in done(nil) })
        let graine = try #require(GraineFonts.face(family: "Inter", weight: 400, origin: "https://www.graine.ai"))
        let selfHosted = try #require(GraineFonts.face(family: "Inter", weight: 400, origin: "https://agents.example.test"))
        #expect(store.cacheFile(for: graine) != store.cacheFile(for: selfHosted))
        #expect(GraineFontStore(directory: nil, fetch: { _, done in done(nil) }).cacheFile(for: graine) == nil)
    }
}
