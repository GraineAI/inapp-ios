import Foundation
import Testing
@testable import GraineInApp

/*
 * A CONNECT THAT SAYS WHERE IT IS, AND THE BRAND'S LOGO WHOLE ON ITS PLATE
 * (contract/DESIGN.md "Voice bar" → "Connecting", "The brand's logo"), proven
 * on a Mac. The cases are the React Native SDK's own (its connect-progress,
 * voice-bar and theme tests), with the same inputs and the same answers.
 */

@Suite struct ConnectProgressTests {
    private func parse(_ raw: String) -> PageMessage? { GraineProtocol.parse(raw) }

    private func progress(_ stage: String) -> GraineConnectProgress? {
        guard case let .progress(p)? = parse(#"{"type":"graine:progress","stage":"\#(stage)"}"#) else { return nil }
        return p
    }

    @Test func theEngineNamesEveryStageAndAFailure() {
        #expect(GraineProtocol.In.progress == "graine:progress")
        #expect(progress("registering") == .stage(.registering))
        #expect(progress("dialling") == .stage(.dialling))
        #expect(progress("retrying") == .stage(.retrying))
        #expect(progress("switching") == .stage(.switching))
        #expect(progress("failed") == .failed)
    }

    @Test func aStageThisBuildDoesNotKnowIsIgnoredNotStored() {
        for stage in ["nonsense", "", "FAILED", "Dialling", "connected"] {
            #expect(progress(stage) == nil, "\(stage)")
        }
        #expect(parse(#"{"type":"graine:progress"}"#) == nil)
        #expect(parse(#"{"type":"graine:progress","stage":3}"#) == nil)
    }

    /// The launcher's half: stages reach the bar, an answered call clears them.
    @Test func theStagesReachTheBarAndAnAnsweredCallClearsThem() throws {
        var a = ConnectAttempt()
        #expect(a.stage == nil)
        a = a.after(.progress(.stage(.dialling)))
        #expect(a.stage == .dialling)
        a = a.after(.progress(.stage(.retrying)))
        #expect(a.stage == .retrying)
        // "nonsense" never becomes an event at all (above), so the stage holds.
        #expect(progress("nonsense").map { a.after(.progress($0)) } == nil)
        #expect(a.stage == .retrying)
        a = a.after(.connected)
        #expect(a == ConnectAttempt(), "a connected call still claimed to be retrying")
    }

    @Test func whenNothingCouldCarryTheCallTheConnectEndsAndOffersAnotherTry() {
        var a = ConnectAttempt().after(.progress(.stage(.switching)))
        a = a.after(.progress(.failed))
        #expect(a.failed)
        #expect(a.stage == nil)
        #expect(ConnectAttempt.stopsConnecting(.failed))
        #expect(!ConnectAttempt.stopsConnecting(.stage(.retrying)))
        // A new attempt does not show the last one's failure; nor does a closed bar or an answered call.
        #expect(a.after(.started) == ConnectAttempt())
        #expect(a.after(.ended) == ConnectAttempt())
        #expect(a.after(.connected) == ConnectAttempt())
        // A stage reported after a failure is the engine's word; the failure stands until something clears it.
        #expect(a.after(.progress(.stage(.dialling))) == ConnectAttempt(stage: .dialling, failed: true))
    }

    @Test func theCustomerIsWaitingOnlyWhileTheyAreWatchingAConnectThatHasNotLanded() {
        func waiting(watched: Bool = true, connected: Bool = false, callFailed: Bool = false, connecting: Bool = false, ready: Bool = true) -> Bool {
            ConnectWait.waiting(watched: watched, connected: connected, callFailed: callFailed, connecting: connecting, ready: ready)
        }
        #expect(waiting(connecting: true))
        #expect(waiting(ready: false), "the bar is open and the page is not there yet")
        #expect(!waiting(), "ready and idle: nothing to wait for")
        #expect(!waiting(watched: false, ready: false), "an idle page loading behind a closed bar is nobody's slow connect")
        #expect(!waiting(connected: true, connecting: true))
        #expect(!waiting(callFailed: true, connecting: true), "a failed connect is not still connecting")
        #expect(ConnectWait.slowConnectMs == 4_000)
        #expect(GraineConfig.Timing().slowConnectMs == ConnectWait.slowConnectMs)
        #expect(GraineConfig.Timing(slowConnectMs: 120).slowConnectMs == 120)
    }

    /// A clock on the customer's wait, driven by hand: nothing here sleeps.
    private final class ManualClock {
        var pending: [(ms: Int, fire: () -> Void, cancelled: Bool)] = []
        var changes: [Bool] = []

        func schedule(_ ms: Int, _ fire: @escaping () -> Void) -> () -> Void {
            pending.append((ms, fire, false))
            let index = pending.count - 1
            return { [weak self] in self?.pending[index].cancelled = true }
        }

        func fireAll() {
            let due = pending
            for (i, p) in due.enumerated() where !p.cancelled {
                pending[i].cancelled = true
                p.fire()
            }
        }

        var live: Int { pending.filter { !$0.cancelled }.count }
    }

    private func clock(_ manual: ManualClock, delayMs: Int = 120) -> SlowConnectClock {
        SlowConnectClock(delayMs: delayMs, schedule: manual.schedule, onChange: { manual.changes.append($0) })
    }

    @Test func aConnectTheCustomerIsWaitingOnAdmitsItIsSlowAndOneThatLandsNeverDoes() {
        let manual = ManualClock()
        let slow = clock(manual)
        slow.update(waiting: true)
        #expect(!slow.slow)
        #expect(manual.pending.first?.ms == 120)
        // Asked again while armed: still one clock, not a second.
        slow.update(waiting: true)
        #expect(manual.live == 1)
        manual.fireAll()
        #expect(slow.slow, "past the slow mark, the bar still said Connecting…")
        slow.update(waiting: true)
        #expect(manual.live == 0, "a slow connect is not re-armed while it is still slow")
        slow.update(waiting: false)
        #expect(!slow.slow)
        #expect(manual.changes == [true, false])
    }

    @Test func aConnectThatLandsInTimeIsNeverCalledSlow() {
        let manual = ManualClock()
        let slow = clock(manual)
        slow.update(waiting: true)
        slow.update(waiting: false)
        #expect(manual.live == 0, "the clock outlived the wait")
        manual.fireAll()
        #expect(!slow.slow)
        #expect(manual.changes.isEmpty)
        // The next wait starts its own clock from zero.
        slow.update(waiting: true)
        #expect(manual.live == 1)
    }

    @Test func aWaitThatNeverStartsArmsNothing() {
        let manual = ManualClock()
        let slow = clock(manual)
        slow.update(waiting: false)
        #expect(manual.pending.isEmpty)
        #expect(manual.changes.isEmpty)
    }
}

@Suite struct ConnectingWordsTests {
    private typealias Input = VoiceBarStatus.Input
    private typealias Line = VoiceBarStatus.Line

    private func line(_ change: (inout Input) -> Void) -> Line {
        var s = Input()
        change(&s)
        return VoiceBarStatus.line(s)
    }

    private let placing: (inout Input) -> Void = { $0.connecting = true; $0.phase = .connecting }

    /// voice-bar.test.mjs "a slow connect says what is happening instead of spinning on one word".
    @Test func aSlowConnectSaysWhatIsHappeningInsteadOfSpinningOnOneWord() {
        let cases: [(String, (inout Input) -> Void, Line)] = [
            ("placing", { _ in }, Line(text: "Connecting…", waiting: "connecting", meter: false)),
            ("slow", { $0.slowConnect = true }, Line(text: "Still connecting…", waiting: "connecting", meter: false, label: "Still connecting…")),
            ("retrying", { $0.connectStage = .retrying }, Line(text: "Reconnecting…", waiting: "reconnecting", meter: false)),
            ("retrying, slow", { $0.connectStage = .retrying; $0.slowConnect = true }, Line(text: "Reconnecting…", waiting: "reconnecting", meter: false)),
            ("switching", { $0.connectStage = .switching }, Line(text: "Reconnecting…", waiting: "reconnecting", meter: false)),
            ("dialling, slow", { $0.connectStage = .dialling; $0.slowConnect = true }, Line(text: "Still connecting…", waiting: "connecting", meter: false, label: "Still connecting…")),
            ("registering", { $0.connectStage = .registering }, Line(text: "Connecting…", waiting: "connecting", meter: false)),
        ]
        for (name, change, want) in cases {
            #expect(line { placing(&$0); change(&$0) } == want, "\(name)")
        }
        // The page not there yet is the same wait.
        #expect(line { $0.ready = false; $0.slowConnect = true }.label == "Still connecting…")
        #expect(line { $0.ready = false; $0.connectStage = .switching }.waiting == "reconnecting")
    }

    @Test func whenNothingCouldCarryTheCallTheBarOffersAnotherTry() {
        let failed = line { $0.callFailed = true }
        #expect(failed == Line(text: "Couldn’t connect · tap to retry", waiting: nil, meter: false))
        #expect(failed.text.contains("\u{2019}"), "the contract's apostrophe is the curly one")
        #expect(failed.text == "Couldn\u{2019}t connect \u{00B7} tap to retry")
    }

    /// voice-bar.test.mjs "a brand that chose its own connecting words keeps them, however slow the connect".
    @Test func aBrandThatChoseItsOwnConnectingWordsKeepsThemHoweverSlowTheConnect() throws {
        let loader = Loaders.resolve(["text": ["connecting": "जुड़ रहा है…", "reconnecting": "फिर से जुड़ रहे हैं…"]])
        let words = try #require(loader.text.connecting)
        let slow = line { placing(&$0); $0.slowConnect = true; $0.connectingWords = words }
        #expect(slow == Line(text: "जुड़ रहा है…", waiting: "connecting", meter: false))
        #expect(slow.label == nil)
        #expect(slow.spoken(loader: loader) == "जुड़ रहा है…", "the brand's wording was replaced")
        // A retry is the reconnecting moment — in the brand's words for it, not ours.
        let retry = line { placing(&$0); $0.connectStage = .retrying; $0.connectingWords = words }
        #expect(retry.spoken(loader: loader) == "फिर से जुड़ रहे हैं…")
        // With the default words, "Still connecting…" is what the loader says.
        let plain = Loaders.resolve(nil)
        #expect(line { placing(&$0); $0.slowConnect = true }.spoken(loader: plain) == "Still connecting…")
        #expect(line { placing(&$0) }.spoken(loader: plain) == "Connecting…")
        #expect(line { placing(&$0); $0.connectStage = .retrying }.spoken(loader: plain) == "Reconnecting…")
        // A brand that typed the default itself has the default.
        #expect(line { placing(&$0); $0.slowConnect = true; $0.connectingWords = "Connecting…" }.label == "Still connecting…")
    }

    @Test func wordsThatAreNotALoaderSpeakForThemselves() {
        let plain = Loaders.resolve(["text": ["thinking": "Hmm…"]])
        #expect(line { $0.connected = true; $0.phase = .listening }.spoken(loader: plain) == "Listening")
        #expect(line { $0.connected = true; $0.phase = .thinking }.spoken(loader: plain) == "Hmm…")
        #expect(line { $0.callFailed = true }.spoken(loader: plain) == "Couldn’t connect · tap to retry")
    }
}

@Suite struct BrandLogoTests {
    private typealias Outline = DesignRules.LogoPlateLook.Outline

    @Test func onlyWhiteIsWhite() {
        #expect(GraineLogoPlate.from("white") == .white)
        let notWhite: [Any?] = [nil, NSNull(), "", "accent", "WHITE", " white", "black", "chartreuse", 1, 3, true, ["white"]]
        for value in notWhite {
            #expect(GraineLogoPlate.from(value) == .accent, "\(String(describing: value)) is not a plate")
        }
        #expect(GraineLogoPlate.allCases.map(\.rawValue) == ["accent", "white"])
    }

    /// theme.test.mjs: fitted whole into the largest square its shape holds, rounded down.
    @Test func theLogoIsFittedWholeIntoTheLargestSquareItsShapeHolds() {
        #expect(DesignRules.logoBox(.circle, size: 38) == 26)
        #expect(DesignRules.logoBox(.squircle, size: 56) == 39)
        #expect(DesignRules.logoBox(.roundedSquare, size: 56) == 44)
        #expect(DesignRules.logoBox(.square, size: 56) == 44)
        // A pill's logo sits in its height, as a circle's does.
        #expect(DesignRules.logoBox(.pill, size: 56) == 39)
        #expect(DesignRules.logoBox(.circle, size: 56) == 39)
        #expect(DesignRules.logoBox(.circle, size: 30) == 21)
        #expect(DesignRules.logoBox(.square, size: 30) == 24)
        #expect(DesignRules.logoBox(.circle, size: 0) == 1, "never nothing")
        // The largest square inside a circle is 70.7% of it: a fitted logo never touches the edge.
        for size in [30.0, 38, 52, 56, 64] {
            #expect(DesignRules.logoBox(.circle, size: size) <= size / Double(2).squareRoot())
            #expect(DesignRules.logoBox(.circle, size: size) == DesignRules.logoBox(.circle, size: size).rounded(.down))
        }
    }

    @Test func eachPlateIsTheContracts() {
        let accent = DesignRules.logoPlateLook(.accent, accent: "#318CE7", border: "#E5E5E5")
        #expect(accent == DesignRules.LogoPlateLook(fill: "#318CE7", outline: nil))
        let hairline = DesignRules.logoPlateLook(.white, accent: "#318CE7", border: "#E5E5E5", borderWidth: 0)
        #expect(hairline == DesignRules.LogoPlateLook(fill: "#FFFFFF", outline: Outline(width: 1, color: "#E5E5E5")))
        #expect(DesignRules.logoPlateLook(.white, accent: "#318CE7", border: "#E5E5E5", borderWidth: 3).outline == Outline(width: 3, color: "#E5E5E5"))
        #expect(DesignRules.logoPlateLook(.white, accent: "#318CE7", border: "#E5E5E5", borderWidth: 0.5).outline?.width == 1)
        // A pill's label on the white plate is the one that reads on white.
        #expect(DesignRules.logoPlateLabel == "#101318")
        #expect(DesignRules.logoPlateLabel == Appearance.onAccent(DesignRules.logoPlateWhite))
    }

    /// Every design in the contract: its plate in its own border colour, at least a hairline, and a logo box inside its launcher.
    @Test func everyDesignInTheContractDrawsTheLogoWholeOnItsPlate() throws {
        let json = try ContractFile.load("design.json")
        let cases = try #require(json["cases"] as? [[String: Any]])
        #expect(cases.count >= 24, "design.json lost designs")
        for c in cases {
            let design = try #require(GraineDesign.parse(c["design"]), "config: \(String(describing: c["config"]))")
            for t in [design.light, design.dark] {
                let white = DesignRules.logoPlateLook(.white, accent: t.colors.accent, border: t.colors.border, borderWidth: t.shape.borderWidth)
                #expect(white.fill == "#FFFFFF")
                #expect(white.outline == Outline(width: max(1, t.shape.borderWidth), color: t.colors.border))
                #expect(DesignRules.logoPlateLook(.accent, accent: t.colors.accent, border: t.colors.border).fill == t.colors.accent)
                let launcher = DesignRules.logoBox(t.shape.launcher, size: DesignRules.launcherSize)
                #expect(launcher > 0 && launcher <= DesignRules.launcherSize * 0.8)
            }
        }
    }

    @Test func theAppearanceCarriesThePlateAndAbsentIsTheAccent() {
        let host = (accent: "#FF3D00", heading: "Ring")
        #expect(Appearance.resolve(["logo": "embed-logos/a.png", "logoPlate": "white"], accent: host.accent, heading: host.heading).logoPlate == .white)
        #expect(Appearance.resolve(["logo": "embed-logos/a.png", "logoPlate": "chartreuse"], accent: host.accent, heading: host.heading).logoPlate == .accent)
        #expect(Appearance.resolve([:], accent: host.accent, heading: host.heading).logoPlate == .accent)
        #expect(Appearance.resolve(nil, accent: host.accent, heading: host.heading).logoPlate == .accent)
    }
}
