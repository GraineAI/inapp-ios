import Foundation

/**
 * WHERE A COMPONENT GOES ON SCREEN — one rule, shared with the web embed and
 * the React Native SDK (protocol.ts `widgetSurface`), so the same component is
 * not a sheet on one surface and a card on another.
 *
 *   screen  the component IS the screen — pictures, several items to compare
 *   sheet   a choice to finish, then back to the app
 *   card    a fact, or a kind this build cannot draw
 */
public enum GraineWidgetSurface: String {
    case screen
    case sheet
    case card
}

/// How a component looks — the preset chosen in the dashboard's Web components.
public enum GraineWidgetPreset: String {
    case gallery
    case cards
    case list
    case spotlight
    case compact
}

enum WidgetImageSize: String { case small, medium, large }
enum WidgetDensity: String { case comfortable, compact }
enum WidgetButtonStyle: String { case filled, outline, row }
enum WidgetSurfaceChoice: String { case auto, screen, sheet, card }
enum WidgetPlatform: String { case auto, ios, material, oneui }
enum WidgetSelect: String { case one, many }

/**
 * The look as the dashboard stored it, allowlisted: only known keys with known
 * values survive, so a phone on this build draws Cards for a preset it has
 * never heard of rather than nothing (protocol.ts `normaliseWidgetStyle`).
 */
struct WidgetStyle: Equatable {
    var preset: GraineWidgetPreset?
    var imageSize: WidgetImageSize?
    var density: WidgetDensity?
    var button: WidgetButtonStyle?
    var facts: Bool?
    var columns: Int?
    var surface: WidgetSurfaceChoice?
    var radius: Double?
    var accent: String?
    var platform: WidgetPlatform?
    var select: WidgetSelect?
    var maxSelect: Int?
}

/// The effective look: preset defaults, then the knobs on top (protocol.ts `resolveWidgetLook`).
struct WidgetLook: Equatable {
    var preset: GraineWidgetPreset
    var imageSize: WidgetImageSize
    var density: WidgetDensity
    var button: WidgetButtonStyle
    var facts: Bool
    var columns: Int
    var surface: GraineWidgetSurface
    var radius: Double?
    var accent: String?
    var platform: WidgetPlatform
    var select: WidgetSelect
    var maxSelect: Int
}

/**
 * WHAT A PLATFORM'S DESIGN GRAMMAR CHANGES — not a theme (the colours stay the
 * brand's) but the shapes: how round a card is, whether a chip is a pill or a
 * tag, whether a button is a full pill, how a sheet shows it can be dragged.
 * `radius` is used only for an explicit platform; under "auto" the Appearance
 * radius wins, because a brand chose it on purpose.
 */
struct WidgetGrammar: Equatable {
    let radius: Double
    let chipRadius: Double
    let buttonRadius: Double
    let pillButtons: Bool
    let separatorInset: Double
    let grabberWidth: Double
    let grabberHeight: Double
    /// CSS weight: 500, 600 or 700.
    let titleWeight: Int
    let padBoost: Double
    let chipOutlined: Bool
}

/**
 * What the APP does when the customer taps, beyond telling the agent: one
 * in-app action (or a path for the navigate handler) with arguments built from
 * the tapped item (protocol.ts `WidgetSelectAction`).
 */
struct WidgetSelectAction: Equatable {
    var path: String?
    var action: String?
    var args: [String: String] = [:]
    var say: String?
}

enum WidgetRules {
    /// The one handler an app registers so the dashboard can open any screen.
    static let navigateAction = "open_screen"
    static let selectArgMax = 10
    static let selectValueMax = 200
    static let maxSelectDefault = 3
    /// How long a "component coming" loader may stand with nothing arriving.
    static let pendingWidgetMs = 12_000
    /// How long the answered line waits for the agent before it stops saying so.
    static let awaitingReplyMs = 12_000
    /// Once the loader is on screen, it stays at least this long, so it reads as loading and not a glitch.
    static let minLoaderMs = 450

    // MARK: - Surface

    /// An unknown kind is a CARD: what gets drawn for it is one fallback sentence.
    static func surface(kind: String?) -> GraineWidgetSurface {
        switch (kind ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "product_list", "products":
            return .screen
        case "plan_comparison", "choices", "quick_actions", "calendar_slots":
            return .sheet
        default:
            return .card
        }
    }

    // MARK: - Whose design grammar

    /**
     * "auto" → the phone's own grammar: Apple's on iOS, Material on Android,
     * One UI on a Samsung. An explicit platform is a brand's choice and wins.
     * Unknown means iOS-like neutrality (protocol.ts `resolvePlatform`).
     */
    static func resolvePlatform(_ platform: String?, os: String?, manufacturer: String? = nil) -> String {
        if let p = platform, !p.isEmpty, p != "auto" { return p }
        if os == "android" {
            return (manufacturer ?? "").range(of: "samsung", options: .caseInsensitive) != nil ? "oneui" : "material"
        }
        return "ios"
    }

    /// PLATFORM_GRAMMAR from protocol.ts: the shapes people on that phone already know. Colours stay the brand's.
    static let grammar: [String: WidgetGrammar] = [
        "ios": WidgetGrammar(radius: 12, chipRadius: 8, buttonRadius: 12, pillButtons: false, separatorInset: 16,
                             grabberWidth: 36, grabberHeight: 5, titleWeight: 600, padBoost: 0, chipOutlined: false),
        "material": WidgetGrammar(radius: 16, chipRadius: 8, buttonRadius: 20, pillButtons: true, separatorInset: 0,
                                  grabberWidth: 32, grabberHeight: 4, titleWeight: 500, padBoost: 0, chipOutlined: true),
        "oneui": WidgetGrammar(radius: 26, chipRadius: 999, buttonRadius: 999, pillButtons: true, separatorInset: 0,
                               grabberWidth: 40, grabberHeight: 4, titleWeight: 700, padBoost: 2, chipOutlined: false),
    ]

    /// The grammar a component is drawn in on this phone (an iPhone, so "auto" is iOS).
    static func grammar(for look: WidgetLook) -> WidgetGrammar {
        grammar[resolvePlatform(look.platform.rawValue, os: "ios")] ?? grammar["ios"]!
    }

    // MARK: - Style

    static func normaliseStyle(_ raw: Any?) -> WidgetStyle {
        var out = WidgetStyle()
        guard let r = JSON.unwrap(raw) as? [String: Any] else { return out }
        out.preset = pick(r["preset"])
        out.imageSize = pick(r["imageSize"])
        out.density = pick(r["density"])
        out.button = pick(r["button"])
        if let v = JSON.unwrap(r["facts"]), let b = JSON.bool(v) { out.facts = b }
        if isExactly(r["columns"], 2) { out.columns = 2 } else if isExactly(r["columns"], 1) { out.columns = 1 }
        out.surface = pick(r["surface"])
        if let radius = finiteNumber(r["radius"]) { out.radius = min(24, max(0, JSON.jsRound(radius))) }
        if let accent = r["accent"] as? String {
            let t = accent.trimmingCharacters(in: .whitespacesAndNewlines)
            if isHex6(t) { out.accent = t.uppercased() }
        }
        out.platform = pick(r["platform"])
        out.select = pick(r["select"])
        if let m = finiteNumber(r["maxSelect"]) { out.maxSelect = Int(min(8, max(2, JSON.jsRound(m)))) }
        return out
    }

    static func resolveLook(_ style: WidgetStyle, kind: String?) -> WidgetLook {
        let preset = style.preset ?? .cards
        let defaults: (WidgetImageSize, WidgetButtonStyle)
        switch preset {
        case .gallery: defaults = (.large, .filled)
        case .cards: defaults = (.medium, .filled)
        case .list: defaults = (.small, .row)
        case .spotlight: defaults = (.large, .filled)
        case .compact: defaults = (.small, .outline)
        }
        let surface: GraineWidgetSurface
        switch style.surface {
        case .some(.screen): surface = .screen
        case .some(.sheet): surface = .sheet
        case .some(.card): surface = .card
        default: surface = WidgetRules.surface(kind: kind)
        }
        return WidgetLook(
            preset: preset,
            imageSize: style.imageSize ?? defaults.0,
            density: style.density ?? .comfortable,
            button: style.button ?? defaults.1,
            facts: style.facts ?? true,
            columns: (preset == .gallery || preset == .cards) && style.columns == 2 ? 2 : 1,
            surface: surface,
            radius: style.radius,
            accent: style.accent,
            platform: style.platform ?? .auto,
            select: style.select ?? .one,
            maxSelect: style.maxSelect ?? maxSelectDefault
        )
    }

    // MARK: - What a tap does in the app

    static func normaliseSelectAction(_ raw: Any?) -> WidgetSelectAction {
        guard let r = JSON.unwrap(raw) as? [String: Any] else { return WidgetSelectAction() }
        var out = WidgetSelectAction()
        let name = JSON.jsStringOrEmpty(r["action"]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if isActionName(name) { out.action = name }
        // A path is the author's own string — a route, a screen name, a deep link. Only its length is checked.
        if let path = r["path"] as? String {
            let t = String(path.trimmingCharacters(in: .whitespacesAndNewlines).prefix(selectValueMax))
            if !t.isEmpty { out.path = t }
        }
        if let args = r["args"] as? [String: Any] {
            var kept: [String: String] = [:]
            for key in args.keys.sorted() {
                let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
                if k.isEmpty || kept.count >= selectArgMax { continue }
                guard let value = JSON.text(args[key]) else { continue }   // null and objects are dropped
                kept[k] = String(value.prefix(selectValueMax))
            }
            out.args = kept
        }
        if let say = r["say"] as? String {
            let t = String(say.trimmingCharacters(in: .whitespacesAndNewlines).prefix(selectValueMax))
            if !t.isEmpty { out.say = t }
        }
        // Arguments alone are nothing at all: a half-configured component must not look configured.
        return out.action != nil || out.path != nil ? out : WidgetSelectAction()
    }

    private static let placeholder: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: "\\{([a-zA-Z_][a-zA-Z0-9_]*)\\}", options: [])
        } catch {
            preconditionFailure("WidgetRules: placeholder pattern failed to compile — \(error)")
        }
    }()

    /**
     * Fill {id}/{title}/… from the tapped item. An unknown placeholder becomes
     * empty rather than staying literal: an app receiving the text "{sku}" as a
     * product id is a harder bug to see than an empty one.
     */
    static func fillTemplate(_ template: String, item: [String: Any]) -> String {
        let ns = template as NSString
        var out = ""
        var cursor = 0
        for match in placeholder.matches(in: template, options: [], range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let key = ns.substring(with: match.range(at: 1))
            out += JSON.jsStringOrEmpty(item[key])
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    static func fillArgs(_ args: [String: String], item: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in args { out[k] = fillTemplate(v, item: item) }
        return out
    }

    /// The action to run for one tap: an explicit action wins; a path goes to the navigate handler and travels as an argument.
    static func selectCall(_ onSelect: WidgetSelectAction?, item: [String: Any]) -> (name: String, args: [String: String])? {
        guard let s = onSelect, s.action != nil || s.path != nil else { return nil }
        var args = fillArgs(s.args, item: item)
        if let path = s.path { args["path"] = fillTemplate(path, item: item) }
        return (s.action ?? navigateAction, args)
    }

    // MARK: - Sentences

    /**
     * The sentence the agent hears when several were chosen. One line, in the
     * customer's voice, naming them — "I picked 2 items" is not something a
     * person says.
     */
    static func manySummary(_ titles: [String], verb: String = "compare") -> String {
        let names = titles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard let last = names.last else { return "" }
        let list = names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " and " + last
        return "Let's \(verb) \(list)."
    }

    /// Several chosen, one answer: the oldest choice gives way when the limit is reached.
    static func toggle(_ current: [String], id: String, max limit: Int) -> [String] {
        if current.contains(id) { return current.filter { $0 != id } }
        if current.count >= limit { return Array(current.dropFirst()) + [id] }
        return current + [id]
    }

    /// The label on the one button that answers a multi-choice. Disabled below two.
    static func manyButtonLabel(chosen: Int, selectLabel: String) -> String {
        chosen < 2 ? "Pick \(2 - chosen) more to \(selectLabel.lowercased())" : "\(selectLabel) \(chosen)"
    }

    /// What stays on screen after a tap: the chosen thing's name, and its price or day. Nil when there is nothing to show.
    static func answeredLine(_ data: [String: Any]) -> (title: String, detail: String)? {
        var title = ""
        for key in ["name", "title", "label", "slot"] where JSON.truthy(data[key]) {
            title = (JSON.text(data[key]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        let detail = ["price", "day"]
            .compactMap { JSON.truthy(data[$0]) ? JSON.text(data[$0]) : nil }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        if title.isEmpty && detail.isEmpty { return nil }
        return (title, detail)
    }

    // MARK: - Images

    private static let imageKeys: Set<String> = [
        "image", "imageurl", "image_url", "icon", "iconurl", "icon_url", "logo", "logourl", "logo_url",
        "photo", "photourl", "photo_url", "thumbnail", "thumbnailurl", "thumbnail_url",
    ]

    /**
     * A picture path that means something on the web means nothing on a phone.
     * A root-relative image ("/samples/car.png") is resolved against the
     * agent's own origin; absolute URLs, data: URIs and protocol-relative ones
     * are left alone. Only keys that name an image, top level and one level
     * into a list — a blind walk would rewrite strings that are not images.
     */
    static func resolveImages(_ data: [String: Any], baseUrl: String?) -> [String: Any] {
        guard let base = baseUrl, !base.isEmpty else { return data }
        var out: [String: Any] = [:]
        for (key, value) in data {
            if imageKeys.contains(key.lowercased()) {
                out[key] = resolveOne(value, base)
            } else if let rows = value as? [Any] {
                out[key] = rows.map { row -> Any in
                    guard let obj = row as? [String: Any] else { return row }
                    var o: [String: Any] = [:]
                    for (rk, rv) in obj { o[rk] = imageKeys.contains(rk.lowercased()) ? resolveOne(rv, base) : rv }
                    return o
                }
            } else {
                out[key] = value
            }
        }
        return out
    }

    private static func resolveOne(_ value: Any, _ base: String) -> Any {
        guard let s = value as? String, s.hasPrefix("/"), !s.hasPrefix("//") else { return value }
        return GraineProtocol.trimTrailingSlashes(base) + s
    }

    // MARK: - Helpers

    private static func pick<T: RawRepresentable>(_ value: Any?) -> T? where T.RawValue == String {
        let s = JSON.jsStringOrEmpty(value).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return T(rawValue: s)
    }

    private static func finiteNumber(_ value: Any?) -> Double? {
        guard let v = JSON.unwrap(value), let n = JSON.number(v) else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    /// JavaScript's `=== n || === "n"`.
    private static func isExactly(_ value: Any?, _ n: Int) -> Bool {
        guard let v = JSON.unwrap(value) else { return false }
        if let s = v as? String { return s == String(n) }
        if let num = JSON.number(v) { return num.doubleValue == Double(n) }
        return false
    }

    private static func isHex6(_ s: String) -> Bool {
        guard s.count == 7, s.hasPrefix("#") else { return false }
        return s.dropFirst().allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    /// /^[a-z][a-z0-9_]{0,63}$/ — tool names.
    private static func isActionName(_ s: String) -> Bool {
        let scalars = Array(s.unicodeScalars)
        guard let first = scalars.first, scalars.count <= 64 else { return false }
        func lower(_ c: Unicode.Scalar) -> Bool { c.value >= 97 && c.value <= 122 }   // a–z
        func digit(_ c: Unicode.Scalar) -> Bool { c.value >= 48 && c.value <= 57 }    // 0–9
        guard lower(first) else { return false }
        return scalars.allSatisfy { lower($0) || digit($0) || $0.value == 95 }       // or _
    }
}

/**
 * A component the agent asked to be shown — the frame the page forwards as
 * `graine:widget` (`{widget_id | id, kind, data, fallback_text, style, on_select}`),
 * read the way the React Native SDK reads it. Root-relative images are resolved
 * against the agent's origin; style and the tap action are allowlisted.
 */
public struct GraineWidget {
    public let id: String
    /// "product_list", "plan_comparison", "choices", … — whatever the agent declares.
    public let kind: String
    public let data: [String: Any]
    /// What the agent would have said instead. Shown for a kind this build cannot draw.
    public let fallbackText: String
    /// The frame exactly as it arrived.
    public let raw: [String: Any]
    let style: WidgetStyle
    let onSelect: WidgetSelectAction

    public init?(frame: [String: Any], baseUrl: String? = nil) {
        guard let id = JSON.nonEmpty(frame["widget_id"]) ?? JSON.nonEmpty(frame["id"]) else { return nil }
        self.id = id
        self.kind = JSON.string(frame["kind"])
        self.data = WidgetRules.resolveImages(frame["data"] as? [String: Any] ?? [:], baseUrl: baseUrl)
        self.fallbackText = JSON.nonEmpty(frame["fallback_text"]) ?? JSON.string(frame["fallbackText"])
        self.raw = frame
        self.style = WidgetRules.normaliseStyle(frame["style"])
        self.onSelect = WidgetRules.normaliseSelectAction(frame["on_select"] ?? frame["onSelect"])
    }

    var look: WidgetLook { WidgetRules.resolveLook(style, kind: kind) }

    /// The preset the dashboard chose, or cards.
    public var preset: GraineWidgetPreset { look.preset }
}

/// One normalised row: the shape every list-like kind is reduced to.
struct WidgetRow: Equatable {
    let index: Int
    let id: String
    let title: String
    let subtitle: String
    let price: String
    let facts: [String]
    let image: String
    let unavailable: Bool
    let selectLabel: String
}

struct WidgetChip: Equatable {
    let id: String
    let label: String
}

struct WidgetDay: Equatable {
    let label: String
    let slots: [String]
}

enum WidgetBody: Equatable {
    case calendar(note: String?, days: [WidgetDay])
    case rows([WidgetRow])
    case chips([WidgetChip])
    case fallback(String)
}

/**
 * THREE DASHBOARD KINDS, ONE ROW SHAPE — and what a tap answers.
 *
 * A plan comparison and an info card are structurally a product list: a name,
 * a price or a value, a few facts, and a button. The payload per kind mirrors
 * what the web renderer sends, because the runtime reads those exact keys to
 * build the sentence the agent hears. A port of widget.tsx's normalisation.
 */
struct WidgetContent {
    enum Kind { case products, plans, info }

    let body: WidgetBody
    let title: String
    let prompt: String
    let selectLabel: String
    /// Where it draws: a kind that cannot be drawn takes over nothing, so it is a card.
    let surface: GraineWidgetSurface
    /// Several may be chosen, and one button answers with all of them.
    let many: Bool
    let maxSelect: Int
    let look: WidgetLook
    private let kind: Kind
    private let quickActions: Bool
    private let infoAction: String

    init(_ widget: GraineWidget) {
        let data = widget.data
        let look = widget.look
        self.look = look

        let options: [Any]
        if let o = data["options"] as? [Any] {
            options = o
        } else if widget.kind == "quick_actions", let a = data["actions"] as? [Any] {
            options = a
        } else {
            options = []
        }
        let isQuickActions = widget.kind == "quick_actions" && !options.isEmpty
        self.quickActions = isQuickActions

        var items: [[String: Any]] = []
        var kind = Kind.products
        var selectLabel = "Choose"
        var infoAction = "Tell me more"
        if widget.kind == "plan_comparison", let plans = data["plans"] as? [Any] {
            kind = .plans
            selectLabel = "Select"
            items = plans.map { entry -> [String: Any] in
                let pl = entry as? [String: Any] ?? [:]
                var it: [String: Any] = [:]
                it["id"] = pl["id"]
                it["title"] = pl["name"]
                it["subtitle"] = pl["badge"]
                if JSON.truthy(pl["price"]) {
                    it["price"] = (JSON.text(pl["price"]) ?? "") + (JSON.text(pl["priceSuffix"]) ?? "")
                }
                it["facts"] = WidgetContent.factTexts(pl["facts"])
                it["selectLabel"] = pl["selectLabel"]
                return it
            }
        } else if widget.kind == "info_card", JSON.truthy(data["title"]) || JSON.truthy(data["summary"]) {
            kind = .info
            let action = JSON.truthy(data["actionLabel"]) ? (JSON.text(data["actionLabel"]) ?? "Tell me more") : "Tell me more"
            selectLabel = action
            infoAction = action
            var facts: [String] = []
            if JSON.truthy(data["summary"]), let s = JSON.text(data["summary"]) { facts.append(s) }
            facts.append(contentsOf: WidgetContent.factTexts(data["facts"]))
            items = [["id": "card", "title": data["title"] as Any, "subtitle": data["category"] as Any,
                      "imageUrl": data["imageUrl"] as Any, "facts": facts]]
        } else {
            // The dashboard's product_list. `items` is also accepted bare: an agent that sends a list
            // without naming the kind still means this.
            items = (data["items"] as? [Any] ?? []).map { $0 as? [String: Any] ?? [:] }
            if JSON.truthy(data["selectLabel"]) { selectLabel = JSON.text(data["selectLabel"]) ?? selectLabel }
        }
        self.kind = kind
        self.infoAction = infoAction
        self.selectLabel = selectLabel

        let rows: [WidgetRow] = items.prefix(8).enumerated().map { pair -> WidgetRow in
            let (i, it) = pair
            let id = JSON.text(it["id"]) ?? JSON.text(it["title"]) ?? String(i)
            let title = JSON.text(it["title"]) ?? JSON.text(it["id"]) ?? String(i)
            let rowFacts = kind == .products ? WidgetContent.factTexts(it["facts"]) : (it["facts"] as? [String] ?? [])
            return WidgetRow(
                index: i,
                id: id,
                title: title,
                subtitle: JSON.truthy(it["subtitle"]) ? (JSON.text(it["subtitle"]) ?? "") : "",
                price: JSON.truthy(it["price"]) ? (JSON.text(it["price"]) ?? "") : "",
                facts: Array(rowFacts.prefix(3)),
                image: JSON.truthy(it["imageUrl"]) ? (JSON.text(it["imageUrl"]) ?? "") : "",
                unavailable: JSON.unwrap(it["unavailable"]).flatMap { JSON.bool($0) } == true,
                selectLabel: JSON.truthy(it["selectLabel"]) ? (JSON.text(it["selectLabel"]) ?? selectLabel) : selectLabel
            )
        }

        let productKinds: Set<String> = ["product_list", "products", "plan_comparison", "info_card"]
        let isProducts = !rows.isEmpty && (productKinds.contains(widget.kind) || options.isEmpty)
        let isChips = (widget.kind == "choices" || isQuickActions) && !options.isEmpty
        let days = widget.kind == "calendar_slots" ? (data["days"] as? [Any] ?? []) : []
        let isCalendar = !days.isEmpty

        if isCalendar {
            var parsed: [WidgetDay] = []
            for (di, entry) in days.prefix(4).enumerated() {
                let d = entry as? [String: Any] ?? [:]
                let label = JSON.text(d["label"]) ?? JSON.text(d["id"]) ?? "Day \(di + 1)"
                let slots = (d["slots"] as? [Any] ?? []).compactMap { JSON.text($0) }
                if slots.isEmpty { continue }
                parsed.append(WidgetDay(label: label, slots: Array(slots.prefix(8))))
            }
            let note = JSON.truthy(data["note"]) ? JSON.text(data["note"]) : nil
            body = .calendar(note: note, days: parsed)
        } else if isProducts {
            body = .rows(rows)
        } else if isChips {
            var chips: [WidgetChip] = []
            for option in options {
                if let o = option as? [String: Any] {
                    let label = JSON.text(o["label"]) ?? JSON.text(o["title"]) ?? ""
                    if label.isEmpty { continue }
                    chips.append(WidgetChip(id: JSON.text(o["id"]) ?? label, label: label))
                } else if let text = JSON.text(option), !text.isEmpty {
                    chips.append(WidgetChip(id: text, label: text))
                }
            }
            body = .chips(chips)
        } else {
            let fallback = widget.fallbackText.isEmpty ? "The assistant has something to show you." : widget.fallbackText
            body = .fallback(fallback)
        }

        let drawable = isProducts || isChips || isCalendar
        surface = drawable ? look.surface : .card
        many = look.select == .many && drawable
        maxSelect = look.maxSelect
        title = JSON.truthy(data["title"]) ? (JSON.text(data["title"]) ?? "") : ""
        prompt = JSON.truthy(data["prompt"]) ? (JSON.text(data["prompt"]) ?? "") : ""
    }

    /// Facts as short texts: strings as they are, `{label, value}` as "label value".
    static func factTexts(_ raw: Any?) -> [String] {
        guard let list = raw as? [Any] else { return [] }
        return list.compactMap { entry -> String? in
            if let f = entry as? [String: Any] {
                let value = JSON.text(f["value"]) ?? ""
                if JSON.truthy(f["label"]), let label = JSON.text(f["label"]) {
                    return value.isEmpty ? label : "\(label) \(value)"
                }
                return value.isEmpty ? nil : value
            }
            return JSON.text(entry)
        }.filter { !$0.isEmpty }
    }

    // MARK: - Answers: the structured payload, and the sentence the agent hears

    /// The payload for one row, per kind — the keys the runtime's resultToText reads.
    func payload(for row: WidgetRow) -> [String: Any] {
        switch kind {
        case .plans: return ["id": row.id, "name": row.title, "price": row.price]
        case .info: return ["action": infoAction]
        case .products: return ["id": row.id, "title": row.title, "price": row.price]
        }
    }

    func answer(row: WidgetRow) -> (data: [String: Any], summary: String) {
        let at = row.price.isEmpty ? "" : " at \(row.price)"
        switch kind {
        case .plans: return (payload(for: row), "I'll take \(row.title)\(at).")
        case .info: return (payload(for: row), infoAction == "Tell me more" ? "Tell me more about this." : infoAction)
        case .products: return (payload(for: row), "I'll take a look at \(row.title)\(at).")
        }
    }

    /// Several at once, as ONE answer: every item, flattened ids and titles, and one sentence naming them.
    func answer(rows: [WidgetRow]) -> (data: [String: Any], summary: String) {
        let titles = rows.map { $0.title }.filter { !$0.isEmpty }
        let data: [String: Any] = [
            "items": rows.map { payload(for: $0) },
            "ids": rows.map { $0.id }.joined(separator: ","),
            "titles": titles.joined(separator: ", "),
            "count": rows.count,
        ]
        return (data, WidgetRules.manySummary(titles, verb: selectLabel.lowercased()))
    }

    /// `label`/`id` for quick_actions, `chosen` for the agent's own choices — each kind's own contract.
    func answer(chip: WidgetChip) -> (data: [String: Any], summary: String) {
        let data: [String: Any] = quickActions ? ["id": chip.id, "label": chip.label] : ["chosen": chip.id, "label": chip.label]
        return (data, "I'll go with \(chip.label).")
    }

    func answer(day: String, slot: String) -> (data: [String: Any], summary: String) {
        (["day": day, "slot": slot], "\(day) at \(slot), please.")
    }
}
