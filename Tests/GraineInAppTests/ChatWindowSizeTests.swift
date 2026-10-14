import Foundation
import Testing
@testable import GraineInApp

/*
 * How big the chat window opens (contract/DESIGN.md "Chat window" → Size):
 * the design's `chat.size` as the session serves it — compact when it is
 * absent or a word this build does not know — the open's size over the app's
 * over the design's, and where each size goes on a phone and an iPad. The
 * same answers as the React Native SDK's chatSizeOf and chatPresentation.
 */

private let palette = GraineThemeTokens.Colors(
    background: "#FFFFFF", surface: "#F7F7F5", surfaceRaised: "#FFFFFF", text: "#101318", textMuted: "#5F6672",
    border: "#E5E4E0", accent: "#318CE7", onAccent: "#FFFFFF", accentSoft: "#E3EEFB", success: "#1FAD5B",
    warning: "#F5A524", danger: "#E5484D", userBubble: "#318CE7", userBubbleText: "#FFFFFF",
    agentBubble: "#F1F1EF", agentBubbleText: "#101318", scrim: "#000000"
)

@Suite struct ChatWindowSizeTests {
    @Test func everyDesignSaysItsSizeTheSameInLightAndDark() throws {
        let cases = try #require(try ContractFile.load("design.json")["cases"] as? [[String: Any]])
        var seen: Set<GraineChatSize> = []
        for c in cases {
            let raw = try #require(c["design"] as? [String: Any])
            let design = try #require(GraineDesign.parse(raw))
            for (scheme, tokens) in [("light", design.light), ("dark", design.dark)] {
                let served = try #require(((raw[scheme] as? [String: Any])?["chat"] as? [String: Any])?["size"] as? String)
                let chat = try #require(tokens.chat, "\(scheme) chat")
                #expect(chat.size.rawValue == served, "\(scheme): \(served)")
                seen.insert(chat.size)
            }
            #expect(design.light.chat?.size == design.dark.chat?.size, "not a colour: one size for both schemes")
        }
        #expect(seen == [.compact, .large, .full], "the contract has a design of each size")
    }

    @Test func absentOrUnknownIsCompact() throws {
        #expect(try #require(SurfaceTokens.chat([:], colors: palette)).size == .compact, "an older server says nothing")
        for word in ["cinema", "", "LARGEST"] {
            #expect(try #require(SurfaceTokens.chat(["size": word], colors: palette)).size == .compact, "\(word)")
        }
        for odd: Any in [3, true, ["full"], NSNull()] {
            #expect(try #require(SurfaceTokens.chat(["size": odd], colors: palette)).size == .compact)
        }
        #expect(try #require(SurfaceTokens.chat(["size": " Large "], colors: palette)).size == .large)
        #expect(try #require(SurfaceTokens.chat(["size": "full"], colors: palette)).size == .full)
        #expect(GraineChatSize(wire: "huge") == nil)
        #expect(GraineChatSize.allCases.map(\.rawValue) == ["compact", "large", "full"])
    }

    @Test func theOpensSizeThenTheAppsThenTheDesigns() {
        #expect(ChatWindowLayout.size(open: .full, config: .large, token: .compact) == .full)
        #expect(ChatWindowLayout.size(open: nil, config: .large, token: .full) == .large)
        #expect(ChatWindowLayout.size(open: nil, config: nil, token: .full) == .full)
        #expect(ChatWindowLayout.size(open: nil, config: nil, token: nil) == .compact)
        #expect(GraineConfig(baseUrl: "https://www.graine.ai", publishableKey: "pk").chatSize == nil, "nil follows the dashboard")
        #expect(GraineConfig(baseUrl: "https://www.graine.ai", publishableKey: "pk", chatSize: .large).chatSize == .large)
    }

    @Test func wherePhonesAndTabletsPutEachSize() {
        let phone = (390.0, 844.0), landscape = (844.0, 390.0), pad = (820.0, 1180.0)
        for (w, h) in [phone, landscape, pad] {
            #expect(ChatWindowLayout.presentation(.compact, width: w, height: h) == .window)
            #expect(ChatWindowLayout.presentation(.full, width: w, height: h) == .screen, "the whole screen, an iPad's too")
        }
        #expect(ChatWindowLayout.presentation(.large, width: phone.0, height: phone.1) == .sheet)
        #expect(ChatWindowLayout.presentation(.large, width: landscape.0, height: landscape.1) == .sheet, "a phone on its side")
        #expect(ChatWindowLayout.presentation(.large, width: pad.0, height: pad.1) == .panel)
        #expect(ChatWindowLayout.presentation(.large, width: 600, height: 1000) == .panel, "600 points across is a tablet")
        #expect(ChatWindowLayout.presentation(.large, width: 599, height: 1000) == .sheet)
        let tall = ChatWindowLayout.panelSize(height: 1180), short = ChatWindowLayout.panelSize(height: 700)
        #expect(tall.width == 420 && tall.height == 760, "90% of 1180, up to 760")
        #expect(short.width == 420 && short.height == 630)
        #expect(ChatWindowLayout.sheetTop == 0.08)
    }

    @Test func theBarDrawsTheChatWhereTheSizeSaysAndClosingDoesWhatTheChevronDoes() {
        #expect(ChatWindowLayout.barPresentation(inChat: false, open: .full, config: nil, token: nil, width: 390, height: 844) == nil,
                "on the call there is no chat window")
        #expect(ChatWindowLayout.barPresentation(inChat: true, open: nil, config: nil, token: nil, width: 390, height: 844) == .window)
        #expect(ChatWindowLayout.barPresentation(inChat: true, open: nil, config: nil, token: .large, width: 390, height: 844) == .sheet)
        #expect(ChatWindowLayout.barPresentation(inChat: true, open: nil, config: .full, token: .large, width: 390, height: 844) == .screen)
        #expect(ChatWindowLayout.barPresentation(inChat: true, open: .compact, config: .full, token: .large, width: 390, height: 844) == .window)
        #expect(ChatWindowLayout.barPresentation(inChat: true, open: nil, config: nil, token: .large, width: 1024, height: 1366) == .panel)
        #expect(ChatWindowLayout.close(canSwitch: true) == .backToCall)
        #expect(ChatWindowLayout.close(canSwitch: false) == .closeBar)
    }
}
