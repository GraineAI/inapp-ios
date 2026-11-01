import Foundation
import Testing
@testable import GraineInApp

/*
 * A COMPONENT BUILT FROM BLOCKS (0.14.8) — "Start blank" in the dashboard,
 * kind `blank`, its content `data.blocks`: `{id, type: heading | text | image |
 * divider | button, content?, imageUrl?}`. `GraineWidget.blocks` keeps what the
 * dashboard's own preview draws, `GraineWidgetView` draws it (WidgetContent's
 * `.blocks`), and a button answers `{"action": its words}` with its words as
 * the sentence. These say the rules in words; RnParityTests holds them to the
 * contract's own answers.
 */

private func widget(kind: String = "blank", data: [String: Any]?, style: [String: Any]? = nil, baseUrl: String? = nil) -> GraineWidget? {
    var frame: [String: Any] = ["widget_id": "show_card:1", "kind": kind, "fallback_text": "Here is your plan."]
    if let data = data { frame["data"] = data }
    if let style = style { frame["style"] = style }
    return GraineWidget(frame: frame, baseUrl: baseUrl)
}

private func blocks(_ rows: Any?, kind: String = "blank") -> [GraineWidgetBlock] {
    var data: [String: Any] = [:]
    if let rows = rows { data["blocks"] = rows }
    return widget(kind: kind, data: data)?.blocks ?? []
}

private let canvas: [[String: Any]] = [
    ["id": "b1", "type": "heading", "content": "Your plan"],
    ["id": "b2", "type": "text", "content": "  Three things to check.\nThen tap below.  "],
    ["id": "b3", "type": "image", "imageUrl": "https://cdn.example.com/a.png"],
    ["id": "b4", "type": "divider"],
    ["id": "b5", "type": "button", "content": "Talk to sales"],
]

@Suite struct WidgetBlocksTests {

    // MARK: - What is kept

    @Test func aBlankComponentsBlocksComeInOrder() throws {
        let got = blocks(canvas)
        #expect(got == [
            GraineWidgetBlock(id: "b1", type: .heading, content: "Your plan", imageUrl: nil),
            GraineWidgetBlock(id: "b2", type: .text, content: "Three things to check.\nThen tap below.", imageUrl: nil),
            GraineWidgetBlock(id: "b3", type: .image, content: nil, imageUrl: "https://cdn.example.com/a.png"),
            GraineWidgetBlock(id: "b4", type: .divider, content: nil, imageUrl: nil),
            GraineWidgetBlock(id: "b5", type: .button, content: "Talk to sales", imageUrl: nil),
        ])
        #expect([GraineWidgetBlockType.heading, .text, .image, .divider, .button].map(\.rawValue)
            == ["heading", "text", "image", "divider", "button"], "the dashboard's words")
    }

    @Test func onlyWhatCanBeDrawnIsKeptAndEachBlockKeepsOnlyItsOwnField() throws {
        let rows: [Any] = [
            ["id": "a", "type": " Heading ", "content": "Kept, in any case"],
            ["id": "b", "type": "video", "content": "a type this version does not know"],
            ["id": "c", "type": "heading"],
            ["id": "d", "type": "text", "content": "   "],
            ["id": "e", "type": "button", "content": 42],
            ["id": "f", "type": "image"],
            ["id": "g", "type": "image", "imageUrl": " /samples/a.png ", "content": "not its field"],
            ["id": "h", "type": "divider", "content": "not its field", "imageUrl": "/x.png"],
            "not a block", NSNull(), ["heading"], ["type": 3, "content": "x"],
            ["id": "i", "type": "text", "content": "x", "imageUrl": "/y.png"],
            ["id": "j", "type": "image", "imageUrl": 7],
            ["id": "k", "type": "button", "content": ["Talk"]],
        ]
        let got = blocks(rows)
        #expect(got.map(\.id) == ["a", "g", "h", "i"])
        #expect(got[0] == GraineWidgetBlock(id: "a", type: .heading, content: "Kept, in any case", imageUrl: nil))
        #expect(got[1] == GraineWidgetBlock(id: "g", type: .image, content: nil, imageUrl: "/samples/a.png"), "trimmed; its words dropped")
        #expect(got[2] == GraineWidgetBlock(id: "h", type: .divider, content: nil, imageUrl: nil))
        #expect(got[3] == GraineWidgetBlock(id: "i", type: .text, content: "x", imageUrl: nil))
    }

    @Test func everyBlockHasAKeyOfItsOwn() {
        let rows: [Any] = [
            ["type": "divider"],
            ["id": "  ", "type": "divider"],
            ["id": "x", "type": "divider"],
            ["id": "x", "type": "divider"],
            ["id": "block-5", "type": "divider"],
            ["id": 7, "type": "divider"],
            ["id": "y", "type": "nothing"],
            ["id": "y", "type": "divider"],
        ]
        // `block-<n>` is the block's place in the list as sent — dropped rows count — and is made unique.
        #expect(blocks(rows).map(\.id) == ["block-0", "block-1", "x", "block-3", "block-5", "block-5-5", "y"])
        #expect(Set(blocks(rows).map(\.id)).count == 7, "unique: a key for a list")
    }

    @Test func onlyAComponentBuiltFromBlocksHasBlocks() {
        #expect(blocks(canvas, kind: "product_list").isEmpty)
        #expect(blocks(canvas, kind: "").isEmpty, "no kind")
        #expect(blocks(canvas, kind: " Blank ").count == 5, "the kind as the surface rule reads it")
        let junk: [Any?] = [nil, "blocks", ["0": canvas[0]], [Any](), 42]
        for raw in junk {
            #expect(blocks(raw).isEmpty, "\(String(describing: raw))")
        }
        #expect(widget(data: nil)?.blocks.isEmpty == true, "no data at all")
        // The rule itself is kind-blind, as the contract's is: the component asks the kind.
        #expect(WidgetRules.normaliseBlankBlocks(["blocks": canvas]).count == 5)
        #expect(WidgetRules.normaliseBlankBlocks(canvas).isEmpty, "the list is data's blocks, not data")
    }

    @Test func aBlockFromSwiftHidingAnOptionalIsReadAsItsValue() {
        let maybe: String? = "Book a visit"
        let none: String? = nil
        let rows: [[String: Any?]] = [
            ["id": "b1", "type": "button", "content": maybe],
            ["id": "b2", "type": "text", "content": none],
        ]
        #expect(WidgetRules.normaliseBlankBlocks(["blocks": rows]) == [GraineWidgetBlock(id: "b1", type: .button, content: "Book a visit", imageUrl: nil)])
    }

    // MARK: - Pictures

    @Test func aBlocksPictureIsOnTheAgentsOriginAsTheOtherComponentPicturesAre() throws {
        let data: [String: Any] = [
            "logo": "/logo.png", "path": "/checkout",
            "blocks": [
                ["id": "b1", "type": "image", "imageUrl": "/samples/car-blue.png"],
                ["id": "b2", "type": "image", "imageUrl": "https://cdn.example.com/a.png"],
                ["id": "b3", "type": "image", "imageUrl": "//cdn.example.com/b.png"],
                ["id": "b4", "type": "image", "imageUrl": "data:image/png;base64,AA=="],
                ["id": "b5", "type": "image", "imageUrl": "samples/relative.png"],
            ],
        ]
        let shown = try #require(widget(data: data, baseUrl: "https://www.graine.ai/"))
        #expect(shown.blocks.map(\.imageUrl) == [
            "https://www.graine.ai/samples/car-blue.png", "https://cdn.example.com/a.png", "//cdn.example.com/b.png",
            "data:image/png;base64,AA==", "samples/relative.png",
        ])
        #expect(JSON.string(shown.data["logo"]) == "https://www.graine.ai/logo.png" && JSON.string(shown.data["path"]) == "/checkout")
        let unresolved = try #require(widget(data: data))
        #expect(unresolved.blocks.first?.imageUrl == "/samples/car-blue.png", "no origin: left as it is")
    }

    @Test func aPictureAsWideAsTheComponentIsAsTallAsTheLookSays() {
        #expect(WidgetRules.pictureHeight(.small) == 100)
        #expect(WidgetRules.pictureHeight(.medium) == 140)
        #expect(WidgetRules.pictureHeight(.large) == 180)
        // The design's shape for the large image, for its width — never under 100 or over 260.
        #expect(WidgetRules.pictureHeight(.medium, shape: "wide", width: 320) == 180)
        #expect(WidgetRules.pictureHeight(.medium, shape: "landscape", width: 200) == 150)
        #expect(WidgetRules.pictureHeight(.small, shape: "square", width: 300) == 260)
        #expect(WidgetRules.pictureHeight(.large, shape: "wide", width: 120) == 100)
        #expect(WidgetRules.pictureHeight(.large, shape: "auto", width: 320) == 180, "its own height")
        #expect(WidgetRules.pictureHeight(.small, shape: "square", width: 0) == 100, "not measured yet")
        #expect(WidgetRules.pictureHeight(.small, shape: nil, width: 300) == 100, "no design")
    }

    // MARK: - What the component view draws

    @Test func theViewDrawsTheBlocksAsACardThatAnswersAtOnce() throws {
        let shown = try #require(widget(data: ["blocks": canvas], style: ["select": "many", "preset": "list"]))
        let content = WidgetContent(shown)
        #expect(content.body == .blocks(shown.blocks))
        #expect(content.surface == .card, "a fact: its kind is no sheet or screen")
        #expect(!content.many, "a block's button answers at once: no row to tick")
        #expect(content.look.button == .row, "the look's button style reaches the button block")
        #expect(content.title.isEmpty && content.prompt.isEmpty)
    }

    @Test func theLookTheDashboardChoseStillPlacesIt() throws {
        let sheet = try #require(widget(data: ["blocks": canvas, "title": "Your plan"], style: ["surface": "sheet", "imageSize": "large", "density": "compact", "button": "outline"]))
        let content = WidgetContent(sheet)
        #expect(content.surface == .sheet)
        #expect(content.look.imageSize == .large && content.look.density == .compact && content.look.button == .outline)
        #expect(content.title == "Your plan", "a title travels as for any kind")
    }

    @Test func nothingToDrawIsTheAgentsSentence() throws {
        let empty: [[String: Any]] = [[:], ["blocks": [Any]()], ["blocks": [["type": "heading"], ["type": "video", "content": "x"]]]]
        for data in empty {
            let content = WidgetContent(try #require(widget(data: data)))
            #expect(content.body == .fallback("Here is your plan."), "\(data)")
            #expect(content.surface == .card)
        }
    }

    @Test func aButtonAnswersWithItsWordsAndNothingElseAnswers() throws {
        let content = WidgetContent(try #require(widget(data: ["blocks": canvas])))
        let button = try #require(content.answer(block: GraineWidgetBlock(id: "b5", type: .button, content: "Talk to sales", imageUrl: nil)))
        #expect(Canon(button.data) == Canon(["action": "Talk to sales"]))
        #expect(button.summary == "Talk to sales", "its words are the customer's sentence")
        for block in blocks(canvas) where block.type != .button {
            #expect(content.answer(block: block) == nil, "\(block.type)")
        }
        // The line kept after a tap reads the chosen thing's name: a button's action is no name, as an info card's is not.
        #expect(WidgetRules.answeredLine(button.data) == nil)
    }
}

/// The blocks through the SDK itself: a component the chat drew, read as public state and answered on the chat.
@Suite @MainActor struct WidgetBlocksPublicStateTests {
    private let frame: [String: Any] = [
        "type": "widget",
        "widget": [
            "widget_id": "show_card:2", "kind": "blank", "fallback_text": "Talk to sales?",
            "data": ["blocks": [
                ["id": "h", "type": "heading", "content": "Need a hand?"],
                ["id": "p", "type": "image", "imageUrl": "/samples/team.png"],
                ["id": "go", "type": "button", "content": "Talk to sales"],
            ]],
        ] as [String: Any],
    ]

    @Test func aBlankComponentIsPublicWithItsBlocksAndItsButtonAnswersOnTheChat() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.session()
        rig.graine.chat.open()
        let socket = try #require(rig.network.socket)
        socket.open()
        socket.clearSent()
        socket.frame(frame)
        let current = try #require(rig.graine.components.current)
        #expect(current.kind == "blank" && current.blocks.map(\.id) == ["h", "p", "go"])
        #expect(current.blocks[1].imageUrl == "https://www.graine.ai/samples/team.png", "on the agent's origin")
        // The tap the component view makes on the button block.
        let content = WidgetContent(current)
        let answer = try #require(content.answer(block: current.blocks[2]))
        rig.graine.answerComponent(widgetId: current.id, data: answer.data, summary: answer.summary)
        #expect(socket.sentTypes == ["widget_result", "text"])
        let result = try #require(socket.sentFrames.first)
        #expect(result["widget_id"] as? String == "show_card:2")
        #expect(Canon(result["data"]) == Canon(["action": "Talk to sales"]), "as the dashboard's preview answers it")
        #expect(JSON.string(socket.sentFrames.last?["data"]) == "Talk to sales", "the button's words are the customer's message")
        #expect(rig.graine.components.current == nil, "answered")
    }

    @Test func theObjectiveCBridgeHandsOnTheBlocksUntouched() throws {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        let facade = GraineObjC(graine: rig.graine)
        rig.graine.componentArrived(try #require(frame["widget"] as? [String: Any]))
        // Kotlin Multiplatform reads blocks from the component's data itself: nothing in between may drop them.
        let text = try #require(facade.componentJSON)
        let component = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let rows = try #require((component["data"] as? [String: Any])?["blocks"] as? [[String: Any]])
        #expect(rows.count == 3 && rows[2]["content"] as? String == "Talk to sales")
        #expect(rows[1]["imageUrl"] as? String == "https://www.graine.ai/samples/team.png")
    }
}
