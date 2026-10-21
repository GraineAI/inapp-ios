#if os(iOS)
import Combine
import SwiftUI

/**
 * THE COMPONENT THE AGENT PUT ON SCREEN — drawn by the SDK, not by the host.
 *
 * Kinds and their contents are built in the dashboard and arrive over the
 * call, so a catalogue of cars today and a list of policies tomorrow need no
 * release. This draws the common kinds the React Native renderer draws:
 *
 *   product_list / products   rows with a picture, badge, price and facts
 *   plan_comparison           the same rows, from `plans`
 *   info_card                 one row, from the card's title and summary
 *   choices / quick_actions   a set of buttons
 *   calendar_slots            a day, then its times
 *
 * and, for anything else, the agent's fallback sentence — guessing at an
 * unknown shape produces something worse than words. The dashboard's preset
 * (gallery, cards, list, spotlight, compact) picks the row shape; `select:
 * "many"` lets the customer tick several and answer once ("Compare: Creta and
 * Seltos"). While the agent says a component is coming, it
 * draws the loader with the dashboard's words for that moment. A design with
 * window chrome opens every card as a desktop window, its title moved into the
 * title bar; the loader and the answered row stay as they are.
 *
 * Mount it once, above your bar, and it appears when there is something to
 * show. It is presented inline — never as a full-screen cover, which on iOS
 * would take the engine's web view out of the window and deafen the call:
 *
 *     VStack { Spacer(); GraineWidgetView().padding(.horizontal, 12) }
 */
public struct GraineWidgetView: View {
    private let graine: GraineInApp?
    private let accent: Color?
    private let inBar: Bool

    /// - Parameters:
    ///   - graine: defaults to the instance `GraineInApp.configure` made.
    ///   - accent: overrides the component's and the dashboard's accent.
    public init(graine: GraineInApp? = nil, accent: Color? = nil) {
        self.graine = graine
        self.accent = accent
        self.inBar = false
    }

    /// The bar's own: it steps aside while the app mounts one of its own, so a component is never drawn twice.
    init(graine: GraineInApp, inBar: Bool) {
        self.graine = graine
        self.accent = nil
        self.inBar = inBar
    }

    public var body: some View {
        if let graine = graine ?? GraineInApp.current {
            if inBar {
                GraineBarWidgetSlot(graine: graine, hosts: graine.componentHosts)
            } else {
                GraineWidgetHost(graine: graine, accentOverride: accent)
                    .onAppear { graine.componentHosts.appViews += 1 }
                    .onDisappear { graine.componentHosts.appViews = max(0, graine.componentHosts.appViews - 1) }
            }
        }
    }
}

/// How many component views the app itself has on screen: while one is, the bar draws none.
final class GraineComponentHosts: ObservableObject {
    @Published var appViews = 0
}

/// The bar's component slot: empty while the app draws components itself.
private struct GraineBarWidgetSlot: View {
    let graine: GraineInApp
    @ObservedObject var hosts: GraineComponentHosts

    var body: some View {
        if hosts.appViews == 0 {
            GraineWidgetHost(graine: graine, accentOverride: nil)
        }
    }
}

/**
 * The component's lifecycle — shown, loading, answered, dismissed — the way the
 * React Native SDK's useGraineWidget runs it.
 */
final class GraineWidgetModel: ObservableObject, GraineListener {
    @Published private(set) var widget: GraineWidget?
    @Published private(set) var content: WidgetContent?
    /// A component is on its way: its kind, while its content loads.
    @Published private(set) var pendingKind: String?
    /// What the customer just chose, kept on screen as one line.
    @Published private(set) var answered: (title: String, detail: String)?
    /// The customer tapped and the agent has not spoken since.
    @Published private(set) var awaitingReply = false
    /// Ids ticked so far, when the component lets them choose several.
    @Published private(set) var ticked: [String] = []
    /// The component arrived in the chat, not on a call: nothing is listening, so nothing says so.
    @Published private(set) var typed = false
    @Published private(set) var appearance: [String: Any] = [:]
    /// The brand's design; nil draws from `appearance`, exactly as before designs.
    @Published private(set) var design: GraineDesign?
    /// The agent's origin, where the dashboard's logo is served.
    private(set) var baseUrl: String?
    /// `GraineConfig.fonts`: where the design's font families live in this app.
    private(set) var fontNames: [String: String] = [:]

    private weak var graine: GraineInApp?
    private var wasLive = false
    private var pendingShownAt: Date?
    private var pendingTimer: DispatchWorkItem?
    private var awaitingTimer: DispatchWorkItem?
    private var showTimer: DispatchWorkItem?

    init(graine: GraineInApp) {
        self.graine = graine
        if let session = graine.session {
            appearance = session.appearance
            design = session.design
        }
        baseUrl = graine.config.baseUrl
        fontNames = graine.config.fonts
        wasLive = graine.voice.connected
        // SEEDED FROM WHAT THE AGENT ALREADY DREW: a view mounted after the component
        // arrived must not open to nothing while the agent waits for an answer.
        if let frame = graine.componentFrame,
           let retained = GraineWidget(frame: frame, baseUrl: graine.config.baseUrl) {
            show(retained)
        }
        graine.addListener(self)
        // The chat closing is a conversation ending, as a call's end is.
        // Changes only (the publisher repeats the current status on subscribing, and that is no ending).
        chatWatch = graine.chat.$status.removeDuplicates().dropFirst().sink { [weak self, weak graine] status in
            guard let self = self, let graine = graine, status == .idle, !graine.chat.isOpen else { return }
            if self.widget != nil || self.answered != nil || self.pendingKind != nil { self.reset() }
        }
        // Answered or closed through the app's own UI (`answerComponent`, `dismissComponent`), or forgotten with its
        // conversation: what this view draws of it goes too. Changes only.
        componentWatch = graine.components.$current.dropFirst().sink { [weak self] current in
            guard let self = self, current == nil else { return }
            self.showTimer?.cancel()
            self.showTimer = nil
            guard self.widget != nil else { return }
            self.widget = nil
            self.content = nil
            self.ticked = []
        }
    }

    private var chatWatch: AnyCancellable?
    private var componentWatch: AnyCancellable?

    // MARK: GraineListener

    func onSessionReady(_ session: GraineSessionConfig) {
        appearance = session.appearance
        design = session.design
    }

    func onWidgetPending(_ hint: [String: Any]) {
        pendingShownAt = Date()
        pendingKind = JSON.string(hint["kind"])
        pendingTimer?.cancel()
        // The runtime gives the customer's API eight seconds; a loader that outlives that is a promise nothing keeps.
        let item = DispatchWorkItem { [weak self] in
            self?.pendingKind = nil
            self?.pendingShownAt = nil
        }
        pendingTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(WidgetRules.pendingWidgetMs), execute: item)
    }

    func onWidget(_ frame: [String: Any]) {
        guard let graine = graine, let next = GraineWidget(frame: frame, baseUrl: graine.config.baseUrl) else { return }
        stopAwaiting()
        pendingTimer?.cancel()
        pendingTimer = nil
        // Let the loader finish being seen: one that appears and vanishes in a frame reads as a glitch.
        let seen = pendingShownAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? WidgetRules.minLoaderMs
        if seen >= WidgetRules.minLoaderMs {
            show(next)
        } else {
            showTimer?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.show(next) }
            showTimer = item
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(WidgetRules.minLoaderMs - seen), execute: item)
        }
    }

    func onCaption(role: GraineRole, text: String, live: Bool) {
        // The agent started: stop saying we are waiting.
        if role == .agent { stopAwaiting() }
    }

    /// A call ended: nothing from it belongs on screen — not its component, not its answer.
    func onEnded() {
        reset()
    }

    /// A new call connected: the last call's component and answer go with it.
    func onCallState(connected: Bool, connecting: Bool) {
        if connected && !wasLive { reset() }
        wasLive = connected
    }

    private func reset() {
        pendingTimer?.cancel()
        pendingTimer = nil
        showTimer?.cancel()
        showTimer = nil
        pendingKind = nil
        pendingShownAt = nil
        widget = nil
        content = nil
        answered = nil
        ticked = []
        stopAwaiting()
    }

    // MARK: Actions

    /**
     * The customer answered. The app's own job first — a tap may name an in-app
     * action (onSelect), fired without being awaited so a slow handler never
     * delays the agent hearing the choice; a refusal is reported to the agent.
     * Then the answer, with the sentence the agent hears.
     */
    func submit(data: [String: Any], summary: String) {
        guard let graine = graine, let current = widget else { return }
        var sentence = summary
        var item = data
        item["summary"] = summary
        if let call = WidgetRules.selectCall(current.onSelect, item: item) {
            let actionName = call.name
            graine.executeAction(name: actionName, arguments: call.args) { [weak graine] result in
                guard result.status != .ok else { return }
                let why = result.message.isEmpty ? result.status.rawValue : result.message
                graine?.reportEvent(
                    "in_app_action_failed",
                    detail: "\"\(actionName)\" did not run: \(why). Do not describe a screen the customer cannot see.",
                    data: [:]
                )
            }
            if let say = current.onSelect.say { sentence = WidgetRules.fillTemplate(say, item: item) }
        }
        // To the conversation it belongs to: the chat's socket, or the call's page.
        graine.answerComponent(widgetId: current.id, data: data, summary: sentence)
        widget = nil
        content = nil
        ticked = []
        answered = WidgetRules.answeredLine(data)
        // A tap is a turn, and the agent takes a moment to answer it. Say so until it starts.
        awaitingReply = true
        awaitingTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in self?.awaitingReply = false }
        awaitingTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(WidgetRules.awaitingReplyMs), execute: timer)
    }

    /**
     * CLOSING IS NOT ANSWERING — but the agent is told, quietly, so it stops
     * talking about options nobody can see. It does not speak up because
     * someone closed a card.
     */
    func dismiss() {
        showTimer?.cancel()
        showTimer = nil
        if let current = widget, let graine = graine { graine.tellComponentDismissed(current) }
        // Kept, so `reopenComponent()` can put it back exactly as it was.
        graine?.componentDismissed()
        widget = nil
        content = nil
        answered = nil
        pendingKind = nil
        pendingShownAt = nil
        ticked = []
        stopAwaiting()
    }

    func toggle(_ id: String) {
        guard let current = content else { return }
        ticked = WidgetRules.toggle(ticked, id: id, max: current.maxSelect)
    }

    private func show(_ next: GraineWidget) {
        showTimer = nil
        pendingShownAt = nil
        pendingKind = nil
        // Decided as it arrives: the conversation it belongs to is the one live now.
        typed = graine?.chat.carriesConversation ?? false
        widget = next
        content = WidgetContent(next)
        ticked = []
        // A new question replaces the last answer.
        answered = nil
    }

    private func stopAwaiting() {
        awaitingTimer?.cancel()
        awaitingTimer = nil
        if awaitingReply { awaitingReply = false }
    }
}

/// Everything one component is drawn in: colours, corner, the phone's grammar, the loader — and the design, when there is one.
struct GraineWidgetTheme {
    /// The loader card and the answered row: `surfaceRaised` with a design, the palette's surface without.
    let surface: Color
    /**
     * The component card's body: the same as `surface` — except when the card
     * opens as a window (window chrome), where it is the design's
     * `colors.surface`, so the `surfaceRaised` title bar over it reads as one.
     */
    let cardFill: Color
    let border: Color
    let text: Color
    let muted: Color
    let accent: Color
    let onAccent: Color
    /// Fact chips: `accentSoft` with a design, a tint of the border without.
    let chip: Color
    /// A badge's backing: `accentSoft` with a design, a tint of the accent without.
    let badge: Color
    let radius: CGFloat
    let grammar: WidgetGrammar
    let loader: GraineLoaderLook
    let loaderColor: Color
    let logoUrl: String?
    /// Nil without a design; then every value below is today's.
    let tokens: GraineThemeTokens?
    let type: GraineType?
    let animation: Animation?
    let borderWidth: CGFloat
    let padding: CGFloat
    let gap: CGFloat
    /**
     * The chat's card tokens (DESIGN.md "Chat window v2" → Cards): corners,
     * shadow or hard offset, outline, the large image's shape and the main
     * button's treatment. Nil without a design; classic, they are exactly the
     * card as it was.
     */
    var cards: GraineChatTokens.Cards? = nil

    var designed: Bool { tokens != nil }

    /// The card's outline: always without a design; with one, where `cards.border` keeps it.
    var outlined: Bool { cards?.border ?? true }

    /// A title's CSS weight as a SwiftUI weight.
    var titleWeight: Font.Weight {
        switch grammar.titleWeight {
        case ..<550: return .medium
        case ..<650: return .semibold
        default: return .bold
        }
    }

    /// The design's font for a role, or exactly what this piece was drawn in before designs.
    func font(_ role: GraineTextRole, _ legacy: Font) -> Font {
        type.map { $0(role) } ?? legacy
    }

    /// A card's depth with a design: `elevation.card`, or the solid offset in `colors.text`. Nothing without one (see GraineCardDepth).
    @ViewBuilder
    func cardShadow<S: Shape>(_ shape: S) -> some View {
        if let t = tokens {
            let hard = cards?.hard ?? (t.elevation.hardOffset != nil)
            GraineShadowLayer(
                shape: shape, shadow: hard ? nil : (cards.map { $0.shadow } ?? t.elevation.card),
                hardOffset: hard ? t.elevation.hardOffset : nil, hardColor: .graineHex(t.colors.text)
            )
        }
    }

    /// How a main ("filled") button is drawn: the card tokens' treatment, or the accent as before.
    struct MainButton {
        let fill: Color?
        let text: Color
        let border: Color?
        let strong: Bool
    }

    /// The design's main-button treatment — unless the component chose its own accent, which still wins.
    func mainButton(ownAccent: Bool) -> MainButton {
        guard let c = cards, let t = tokens, !ownAccent else { return MainButton(fill: accent, text: onAccent, border: nil, strong: false) }
        func paint(_ hex: String) -> Color { hex == t.colors.accent ? accent : (hex == t.colors.onAccent ? onAccent : .graineHex(hex)) }
        return MainButton(
            fill: c.buttonFill.map(paint), text: paint(c.buttonText), border: c.buttonBorder.map(paint), strong: c.button == "text"
        )
    }
}

struct GraineWidgetHost: View {
    @StateObject private var model: GraineWidgetModel
    /// Observed so a card on screen is redrawn in the design's typeface when it lands.
    @ObservedObject private var fonts: GraineFontStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let accentOverride: Color?

    init(graine: GraineInApp, accentOverride: Color?) {
        _model = StateObject(wrappedValue: GraineWidgetModel(graine: graine))
        _fonts = ObservedObject(wrappedValue: graine.fonts)
        self.accentOverride = accentOverride
    }

    var body: some View {
        let theme = makeTheme()
        return VStack(spacing: 8) {
            if let line = model.answered {
                answeredRow(line, theme: theme)
                    .transition(.opacity)
            }
            if let widget = model.widget, let content = model.content {
                GraineWidgetCard(widget: widget, content: content, theme: theme, model: model)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if model.pendingKind != nil {
                loader(theme: theme)
                    .transition(.opacity)
            }
        }
        // The design's motion as a component arrives, loads and leaves; none without a design, or with Reduce Motion.
        .animation(theme.animation, value: model.widget?.id)
        .animation(theme.animation, value: model.pendingKind)
        .animation(theme.animation, value: model.answered?.title)
    }

    /**
     * Host code wins, then the component's own choice, then the dashboard's
     * Appearance (widget.tsx's order). An explicitly chosen platform also
     * brings that grammar's card radius; under "auto" the brand's radius stays.
     */
    private func makeTheme() -> GraineWidgetTheme {
        let look = model.widget?.look ?? WidgetRules.resolveLook(WidgetStyle(), kind: model.pendingKind)
        let dash = Appearance.resolve(model.appearance, accent: Appearance.defaultAccent, heading: "", origin: model.baseUrl)
        let loader = Loaders.resolve(model.appearance["loader"])
        let tokens = model.design?.tokens(deviceDark: colorScheme == .dark)
        let grammar = DesignRules.widgetGrammar(look, tokens: tokens)
        let cards = tokens?.chatOrClassic.cards
        // The component's own radius wins, then a platform it chose; otherwise the design's card corners.
        let radius = look.radius == nil && look.platform == .auto && cards != nil
            ? cards!.radius : DesignRules.widgetRadius(look, tokens: tokens, appearanceRadius: dash.radius)

        guard let t = tokens else {
            let accentHex = look.accent ?? dash.accent
            let palette = Appearance.palette(model.appearance, deviceDark: colorScheme == .dark, accent: accentHex)
            let accent = accentOverride ?? Color.graineHex(accentHex)
            let border = Color.graineHex(palette.border)
            return GraineWidgetTheme(
                surface: Color.graineHex(palette.surface),
                cardFill: Color.graineHex(palette.surface),
                border: border,
                text: Color.graineHex(palette.text),
                muted: Color.graineHex(palette.muted),
                accent: accent,
                onAccent: accentOverride == nil ? Color.graineHex(palette.onAccent, fallback: .white) : .white,
                chip: border.opacity(0.35),
                badge: accent.opacity(0.15),
                radius: CGFloat(radius),
                grammar: grammar,
                loader: loader,
                loaderColor: Color.graineHex(loader.color ?? dash.accent),
                logoUrl: dash.logoUrl,
                tokens: nil, type: nil, animation: nil,
                borderWidth: 1, padding: 14, gap: 10
            )
        }

        // DESIGN.md's components: the card on `surfaceRaised` (on `surface` when it opens as a window), outlined,
        // `radius.lg`, `cardPadding`, `gap`; chips on `accentSoft`; the loader in the accent. The component's own
        // accent and radius still win. (A host overrides only the accent here: no card surface to keep.)
        let c = t.colors
        let pair = DesignRules.widgetAccent(look, tokens: t, appearanceAccent: dash.accent, appearanceOnAccent: c.onAccent)
        return GraineWidgetTheme(
            surface: .graineHex(c.surfaceRaised),
            cardFill: .graineHex(WindowChrome.componentBodyFill(t)),
            border: .graineHex(c.border),
            text: .graineHex(c.text),
            muted: .graineHex(c.textMuted),
            accent: accentOverride ?? .graineHex(pair.accent),
            onAccent: accentOverride == nil ? .graineHex(pair.onAccent, fallback: .white) : .white,
            chip: .graineHex(c.accentSoft),
            badge: .graineHex(c.accentSoft),
            radius: CGFloat(radius),
            grammar: grammar,
            loader: loader,
            loaderColor: .graineHex(loader.color ?? c.accent),
            logoUrl: dash.logoUrl,
            tokens: t,
            type: GraineType(font: t.font, names: model.fontNames, faces: fonts.faces),
            animation: t.motion.animation(reduceMotion: reduceMotion),
            borderWidth: CGFloat(t.shape.borderWidth),
            padding: CGFloat(t.spacing.cardPadding),
            gap: CGFloat(t.spacing.gap),
            cards: cards
        )
    }

    /**
     * A LOADER IS A LOADER: the one the brand chose, centred on the space the
     * component will take, at a size you read from arm's length (bigger for a
     * screen or a sheet), with the dashboard's words for this moment.
     */
    private func loader(theme: GraineWidgetTheme) -> some View {
        let words = theme.loader.text.component ?? "Loading…"
        let size: CGFloat?
        switch WidgetRules.surface(kind: model.pendingKind) {
        case .screen: size = 34
        case .sheet: size = 26
        case .card: size = nil
        }
        return GraineLoaderLabel(
            look: theme.loader,
            color: theme.loaderColor,
            track: theme.border,
            textColor: theme.muted,
            label: words,
            size: size,
            stacked: true,
            logoUrl: theme.logoUrl
        )
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radius, style: .continuous).stroke(theme.border, lineWidth: theme.borderWidth)
        }
        .background(theme.cardShadow(RoundedRectangle(cornerRadius: theme.radius, style: .continuous)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(words)
    }

    /// WAITING, THEN DONE: a tick that appears before the agent has said anything reads as "handled", which it is not yet.
    private func answeredRow(_ line: (title: String, detail: String), theme: GraineWidgetTheme) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(theme.accent.opacity(0.18))
                if model.awaitingReply {
                    GraineLoaderMark(look: theme.loader, color: theme.loaderColor, track: theme.border, size: 12, logoUrl: theme.logoUrl)
                } else {
                    Text("✓")
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundColor(theme.accent)
                }
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(line.title.isEmpty ? line.detail : line.title)
                    .font(theme.font(.strong, .system(size: 13.5, weight: .bold)))
                    .foregroundColor(theme.text)
                    .lineLimit(1)
                if model.awaitingReply {
                    Text(Appearance.loaderText(model.appearance, moment: "thinking"))
                        .font(theme.font(.caption, .system(size: 11.5, weight: .semibold)))
                        .foregroundColor(theme.muted)
                        .lineLimit(1)
                } else if !line.title.isEmpty && !line.detail.isEmpty {
                    Text(line.detail)
                        .font(theme.font(.caption, .system(size: 11.5, weight: .semibold)))
                        .foregroundColor(theme.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if !model.awaitingReply {
                Button(action: { model.dismiss() }) {
                    Text("Clear")
                        .font(theme.font(.captionStrong, .system(size: 12, weight: .bold)))
                        .foregroundColor(theme.muted)
                        .frame(minHeight: 44)
                        .padding(.horizontal, 4)
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel("Clear what I chose")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radius, style: .continuous).stroke(theme.border, lineWidth: theme.borderWidth)
        }
    }
}

private struct GraineWidgetBodyHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// One component, on the card that carries it.
struct GraineWidgetCard: View {
    let widget: GraineWidget
    let content: WidgetContent
    let theme: GraineWidgetTheme
    @ObservedObject var model: GraineWidgetModel
    @State private var bodyHeight: CGFloat = 0

    init(widget: GraineWidget, content: WidgetContent, theme: GraineWidgetTheme, model: GraineWidgetModel) {
        self.widget = widget
        self.content = content
        self.theme = theme
        _model = ObservedObject(wrappedValue: model)
    }

    /// Pictures need room; a choice is a sheet's height; a fact interrupts as little as possible.
    private var maxBodyHeight: CGFloat {
        switch content.surface {
        case .screen: return 520
        case .sheet: return 420
        case .card: return 300
        }
    }

    /// A choice is a primary button: a capsule before designs; with one, `radius.md` (or the chosen platform's pill), drawn as the design's main button.
    @ViewBuilder
    private var choiceFill: some View {
        let main = theme.mainButton(ownAccent: content.look.accent != nil)
        if theme.designed && !theme.grammar.pillButtons {
            let shape = RoundedRectangle(cornerRadius: CGFloat(theme.grammar.buttonRadius), style: .continuous)
            shape.fill(main.fill ?? .clear)
                .overlay { if let border = main.border { shape.strokeBorder(border, lineWidth: max(1, theme.borderWidth)) } }
        } else {
            Capsule().fill(main.fill ?? .clear)
                .overlay { if let border = main.border { Capsule().strokeBorder(border, lineWidth: max(1, theme.borderWidth)) } }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.gap) {
            header
            ScrollView(.vertical, showsIndicators: false) {
                bodyView
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: GraineWidgetBodyHeightKey.self, value: proxy.size.height)
                    })
            }
            .frame(height: min(max(bodyHeight, 1), maxBodyHeight))
            .onPreferenceChange(GraineWidgetBodyHeightKey.self) { height in
                bodyHeight = height
            }
            footer
        }
        .padding(theme.padding)
        .modifier(GraineWindowed(bar: windowBar, spoken: true))
        .background(theme.cardFill, in: RoundedRectangle(cornerRadius: theme.radius, style: .continuous))
        .overlay {
            if theme.outlined {
                RoundedRectangle(cornerRadius: theme.radius, style: .continuous).stroke(theme.border, lineWidth: theme.borderWidth)
            }
        }
        .modifier(GraineCardDepth(theme: theme))
    }

    /// Window chrome (DESIGN.md): the card opens as a window titled with its own title, in its own corners. Nil without a design, or with a plain one.
    private var windowBar: WindowChrome.TitleBar? {
        guard let t = theme.tokens else { return nil }
        return WindowChrome.titleBar(t, for: .component(title: content.title, radius: Double(theme.radius)))
    }

    /// The card's own title — unless it opens as a window, whose bar carries it instead.
    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                if let title = WindowChrome.componentBodyTitle(theme.tokens, title: content.title) {
                    Text(title)
                        .font(theme.font(.title, .system(size: 15, weight: .heavy)))
                        .tracking(theme.type?.tracking(.title) ?? 0)
                        .lineSpacing(theme.type?.lineSpacing(.title) ?? 0)
                        .foregroundColor(theme.text)
                }
                if !content.prompt.isEmpty {
                    Text(content.prompt)
                        .font(theme.font(.caption, .system(size: 12.5)))
                        .foregroundColor(theme.muted)
                }
            }
            Spacer(minLength: 0)
            Button(action: { model.dismiss() }) {
                Text("×")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(theme.text)
                    .frame(width: 32, height: 32)
                    .background(theme.border.opacity(0.4), in: Circle())
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel(WidgetRules.closeLabel(typed: model.typed))
        }
    }

    @ViewBuilder
    private var bodyView: some View {
        switch content.body {
        case let .calendar(note, days):
            calendar(note: note, days: days)
        case .rows(let rows):
            rowsView(rows)
        case .chips(let chips):
            chipsView(chips)
        case .fallback(let text):
            Text(text)
                .font(theme.font(.body, .system(size: 14)))
                .lineSpacing(theme.type?.lineSpacing(.body) ?? 0)
                .foregroundColor(theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Rows

    private func variant(for preset: GraineWidgetPreset) -> GraineWidgetRowVariant {
        switch preset {
        case .gallery, .spotlight: return .hero
        case .list: return .list
        case .compact: return .compact
        case .cards: return .row
        }
    }

    private func rowsView(_ rows: [WidgetRow]) -> some View {
        let look = content.look
        return VStack(alignment: .leading, spacing: look.density == .compact ? 6 : 10) {
            if look.preset == .spotlight {
                // One card in view, the next one's edge showing: that edge is what says "there are more".
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(rows, id: \.index) { row in
                            rowView(row, variant: .hero).frame(width: 260)
                        }
                    }
                }
            } else if look.columns == 2 {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(rows, id: \.index) { row in
                        rowView(row, variant: .hero)
                    }
                }
            } else {
                ForEach(rows, id: \.index) { row in
                    rowView(row, variant: variant(for: look.preset))
                }
            }
            if content.many {
                manyButton(rows)
            }
        }
    }

    private func rowView(_ row: WidgetRow, variant: GraineWidgetRowVariant) -> some View {
        GraineWidgetRowView(
            row: row,
            variant: variant,
            look: content.look,
            theme: theme,
            picked: content.many ? model.ticked.contains(row.id) : nil,
            onPick: { pick(row) }
        )
    }

    private func pick(_ row: WidgetRow) {
        if content.many {
            model.toggle(row.id)
            return
        }
        let answer = content.answer(row: row)
        model.submit(data: answer.data, summary: answer.summary)
    }

    /// ONE BUTTON, ONE TURN. Disabled below two: a comparison of one is the single-tap case in disguise.
    private func manyButton(_ rows: [WidgetRow]) -> some View {
        let chosen: [WidgetRow] = model.ticked.compactMap { id in rows.first(where: { candidate in candidate.id == id }) }
        let enabled = chosen.count >= 2
        let label = WidgetRules.manyButtonLabel(chosen: chosen.count, selectLabel: content.selectLabel)
        return Button(action: {
            let answer = content.answer(rows: chosen)
            model.submit(data: answer.data, summary: answer.summary)
        }) {
            Text(label)
                .font(theme.font(.strong, .system(size: 14.5, weight: .bold)))
                .foregroundColor(enabled ? theme.onAccent : theme.muted)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(
                    enabled ? theme.accent : theme.border.opacity(0.5),
                    in: RoundedRectangle(cornerRadius: min(24, CGFloat(theme.grammar.pillButtons ? 999 : theme.grammar.buttonRadius)), style: .continuous)
                )
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    // MARK: Chips and slots

    private func chipsView(_ chips: [WidgetChip]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(0..<chips.count, id: \.self) { i in
                Button(action: {
                    let answer = content.answer(chip: chips[i])
                    model.submit(data: answer.data, summary: answer.summary)
                }) {
                    Text(chips[i].label)
                        .font(theme.font(.strong, .system(size: 13.5, weight: .bold)))
                        .foregroundColor(theme.mainButton(ownAccent: content.look.accent != nil).text)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(choiceFill)
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel(chips[i].label)
            }
        }
    }

    private func calendar(note: String?, days: [WidgetDay]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let note = note {
                Text(note)
                    .font(theme.font(.caption, .system(size: 12.5)))
                    .foregroundColor(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(0..<days.count, id: \.self) { d in
                VStack(alignment: .leading, spacing: 7) {
                    Text(days[d].label)
                        .font(theme.font(.strong, .system(size: 13, weight: .bold)))
                        .foregroundColor(theme.text)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(0..<days[d].slots.count, id: \.self) { s in
                            slotButton(day: days[d].label, slot: days[d].slots[s])
                        }
                    }
                }
            }
        }
    }

    private func slotButton(day: String, slot: String) -> some View {
        Button(action: {
            let answer = content.answer(day: day, slot: slot)
            model.submit(data: answer.data, summary: answer.summary)
        }) {
            Text(slot)
                .font(theme.font(.strong, .system(size: 13.5, weight: .semibold)))
                .foregroundColor(theme.text)
                .frame(maxWidth: .infinity, minHeight: 44)
                .overlay {
                    RoundedRectangle(cornerRadius: theme.designed ? CGFloat(theme.grammar.buttonRadius) : 11, style: .continuous)
                        .stroke(theme.border, lineWidth: theme.borderWidth)
                }
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel("\(day) at \(slot)")
    }

    // MARK: The way out

    /// NOT ANSWERING IS AN ANSWER: without a way out that is not a choice, the only exits are a wrong pick or hanging up.
    @ViewBuilder
    private var footer: some View {
        switch content.surface {
        case .sheet:
            Button(action: { model.dismiss() }) {
                Text("None of these")
                    .font(theme.font(.strong, .system(size: 13.5, weight: .bold)))
                    .foregroundColor(theme.text)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .background(theme.border.opacity(0.4), in: Capsule())
            }
            .buttonStyle(PlainButtonStyle())
        case .screen:
            // The agent is still on the call. Saying so is the difference between a screen it opened and one that replaced it.
            // In the chat there is no call to be on: no footer (WidgetRules.screenFooter).
            if let words = WidgetRules.screenFooter(prompt: content.prompt, typed: model.typed) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(words.label)
                        .font(theme.font(.captionStrong, .system(size: 10.5, weight: .heavy)))
                        .foregroundColor(theme.muted)
                    Text(words.line)
                        .font(theme.font(.body, .system(size: 13.5)))
                        .foregroundColor(theme.text)
                        .lineLimit(1)
                }
            }
        case .card:
            HStack {
                Spacer(minLength: 0)
                Button(action: { model.dismiss() }) {
                    Text("Dismiss")
                        .font(theme.font(.captionStrong, .system(size: 12.5, weight: .semibold)))
                        .foregroundColor(theme.muted)
                        .frame(minHeight: 44)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }
}

enum GraineWidgetRowVariant {
    /// Picture on top, full-width button — Gallery and Spotlight.
    case hero
    /// Thumbnail left, pill button — Cards.
    case row
    /// Dense; the row is the button — List.
    case list
    /// No picture, outline button — Compact.
    case compact
}

/// ONE ROW, FOUR SHAPES. Whatever the shape, the same things are on it: badge, title and price, facts as chips, a 44pt target.
struct GraineWidgetRowView: View {
    let row: WidgetRow
    let variant: GraineWidgetRowVariant
    let look: WidgetLook
    let theme: GraineWidgetTheme
    /// nil when choosing one; true/false when choosing several.
    let picked: Bool?
    let onPick: () -> Void
    /// The large image's width, for a shape that follows it (`cards.image`).
    @State private var heroWidth: CGFloat = 0

    private var many: Bool { picked != nil }
    /// Choosing several: the ROW toggles, always — a per-row button beside a tick is two controls for one decision.
    private var rowIsButton: Bool { many || look.button == .row }
    private var tight: Bool { look.density == .compact }
    private var pad: CGFloat { (variant == .list ? (tight ? 6 : 9) : (tight ? 7 : 10)) + CGFloat(theme.grammar.padBoost) }
    private var gap: CGFloat { tight ? 6 : 10 }
    private var cornerRadius: CGFloat { max(10, theme.radius - 6) }

    var body: some View {
        if rowIsButton {
            Button(action: onPick) { shape }
                .buttonStyle(PlainButtonStyle())
                .disabled(row.unavailable)
                .accessibilityLabel("\(row.selectLabel): \(row.title)")
        } else {
            shape
        }
    }

    @ViewBuilder
    private var shape: some View {
        switch variant {
        case .hero: hero
        case .row: card
        case .list: list
        case .compact: compact
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !row.image.isEmpty {
                picture
                    .frame(maxWidth: .infinity)
                    .frame(height: imageHeight)
                    .clipShape(RoundedRectangle(cornerRadius: max(8, theme.radius - 8), style: .continuous))
                    .background(GeometryReader { g in
                        Color.clear.onAppear { heroWidth = g.size.width }.onChange(of: g.size.width) { heroWidth = $0 }
                    })
            }
            badge
            titleLine(big: true)
            facts
            if !many && !rowIsButton {
                actionButton(wide: true)
            }
        }
        .padding(pad)
        .overlay(alignment: .topTrailing) {
            if many { tick.padding(pad + 6) }
        }
        .overlay { outline }
        .opacity(row.unavailable ? 0.55 : 1)
    }

    private var card: some View {
        HStack(spacing: gap) {
            if !row.image.isEmpty { thumbnail(size: thumbSize) }
            VStack(alignment: .leading, spacing: 3) {
                badge
                titleLine(big: false)
                facts
            }
            if many {
                tick
            } else if !rowIsButton {
                actionButton(wide: false)
            }
        }
        .padding(pad)
        .overlay { outline }
        .opacity(row.unavailable ? 0.55 : 1)
    }

    private var list: some View {
        HStack(spacing: gap) {
            if !row.image.isEmpty { thumbnail(size: listThumbSize) }
            VStack(alignment: .leading, spacing: 2) {
                titleLine(big: false)
                facts
            }
            if many {
                tick
            } else if rowIsButton {
                Text("›")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(theme.muted)
            } else {
                actionButton(wide: false)
            }
        }
        .padding(.vertical, pad)
        .padding(.horizontal, 2)
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) {
            theme.border.frame(height: 1).padding(.leading, CGFloat(theme.grammar.separatorInset))
        }
        .opacity(row.unavailable ? 0.55 : 1)
    }

    private var compact: some View {
        HStack(spacing: gap) {
            VStack(alignment: .leading, spacing: 2) {
                badge
                titleLine(big: false)
                facts
            }
            if many {
                tick
            } else if !rowIsButton {
                actionButton(wide: false)
            }
        }
        .padding(.vertical, pad)
        .padding(.horizontal, pad + 2)
        .frame(minHeight: 44)
        .overlay { outline }
        .opacity(row.unavailable ? 0.55 : 1)
    }

    // MARK: Parts

    private var outline: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(picked == true ? theme.accent : theme.border, lineWidth: picked == true ? theme.borderWidth + 1 : theme.borderWidth)
    }

    private var heroHeight: CGFloat {
        switch look.imageSize {
        case .small: return 100
        case .medium: return 140
        case .large: return 180
        }
    }

    /// The large image: its own height (`auto`), or the design's shape for its width — always 100–260.
    private var imageHeight: CGFloat {
        guard let image = theme.cards?.image, image != "auto", heroWidth > 0 else { return heroHeight }
        return CGFloat(ChatWindowRules.imageHeight(image, width: Double(heroWidth), auto: Double(heroHeight)))
    }

    private var thumbSize: CGFloat {
        switch look.imageSize {
        case .small: return 56
        case .medium: return 72
        case .large: return 96
        }
    }

    private var listThumbSize: CGFloat {
        switch look.imageSize {
        case .small: return 36
        case .medium: return 44
        case .large: return 56
        }
    }

    private var picture: some View {
        AsyncImage(url: URL(string: row.image)) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                theme.border
            }
        }
        .accessibilityHidden(true)
    }

    private func thumbnail(size: CGFloat) -> some View {
        picture
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: max(8, theme.radius - 8), style: .continuous))
    }

    @ViewBuilder
    private var badge: some View {
        if !row.subtitle.isEmpty {
            Text(row.subtitle.uppercased())
                .font(theme.font(.captionStrong, .system(size: 10.5, weight: .heavy)))
                .foregroundColor(theme.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(theme.badge, in: Capsule())
        }
    }

    private func titleLine(big: Bool) -> some View {
        let size: CGFloat = big ? 16.5 : (variant == .list ? 13.5 : 14.5)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(row.title)
                .font(theme.font(big ? .title : .strong, .system(size: size, weight: theme.titleWeight)))
                .foregroundColor(theme.text)
                .lineLimit(2)
            Spacer(minLength: 0)
            if !row.price.isEmpty {
                Text(row.price)
                    .font(theme.font(big ? .title : .strong, .system(size: big ? 17 : size, weight: .heavy)))
                    .foregroundColor(theme.text)
            }
        }
    }

    /// Facts as chips: joined with dots they read as the sentence a component exists to replace.
    @ViewBuilder
    private var facts: some View {
        let shown = variant == .list ? Array(row.facts.prefix(2)) : row.facts
        if look.facts && !shown.isEmpty {
            HStack(spacing: 6) {
                ForEach(0..<shown.count, id: \.self) { i in
                    Text(shown[i])
                        .font(theme.font(.caption, .system(size: variant == .list ? 10.5 : 11.5, weight: .semibold)))
                        .foregroundColor(theme.muted)
                        .lineLimit(1)
                        .padding(.horizontal, variant == .list ? 6 : 8)
                        .padding(.vertical, variant == .list ? 2 : 4)
                        .background(
                            theme.grammar.chipOutlined ? Color.clear : theme.chip,
                            in: RoundedRectangle(cornerRadius: min(12, CGFloat(theme.grammar.chipRadius)), style: .continuous)
                        )
                        .overlay {
                            if theme.grammar.chipOutlined {
                                RoundedRectangle(cornerRadius: min(12, CGFloat(theme.grammar.chipRadius)), style: .continuous)
                                    .stroke(theme.border, lineWidth: theme.borderWidth)
                            }
                        }
                }
            }
        }
    }

    private var tick: some View {
        ZStack {
            Circle().fill(picked == true ? theme.accent : Color.clear)
            Circle().stroke(theme.border, lineWidth: picked == true ? 0 : 1.5)
            if picked == true {
                Text("✓")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundColor(theme.onAccent)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }

    private func actionButton(wide: Bool) -> some View {
        let outlined = look.button == .outline
        // A filled button (the component's own look) is drawn as the design's main button.
        let main = theme.mainButton(ownAccent: look.accent != nil)
        let hollow = row.unavailable || outlined || main.fill == nil
        let label = row.unavailable ? "Unavailable" : row.selectLabel
        let maxWidth: CGFloat? = wide ? CGFloat.infinity : nil
        let textColor: Color = row.unavailable ? theme.muted : (outlined ? theme.accent : main.text)
        let fill: Color = row.unavailable || outlined ? Color.clear : (main.fill ?? .clear)
        let stroke: Color = row.unavailable ? theme.border : (outlined ? theme.accent : (main.border ?? .clear))
        let grammar = theme.grammar
        let corner = min(22, CGFloat(wide ? grammar.buttonRadius : (grammar.pillButtons ? 999 : grammar.buttonRadius)))
        return Button(action: onPick) {
            Text(label)
                .font(theme.font(wide ? .strong : .captionStrong, .system(size: wide ? 14 : 12.5, weight: .bold)))
                .foregroundColor(textColor)
                .padding(.horizontal, wide ? 12 : 14)
                .frame(maxWidth: maxWidth, minHeight: 44)
                .background(fill, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .stroke(stroke, lineWidth: hollow ? (theme.designed ? max(1, theme.borderWidth) : 1.5) : 0)
                }
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(row.unavailable)
        .accessibilityLabel("\(row.selectLabel): \(row.title)")
    }
}

/// A card's depth: today's soft shadow without a design; with one, `elevation.card` or the hard offset.
struct GraineCardDepth: ViewModifier {
    let theme: GraineWidgetTheme

    func body(content: Content) -> some View {
        if theme.designed {
            content.background(theme.cardShadow(RoundedRectangle(cornerRadius: theme.radius, style: .continuous)))
        } else {
            content.shadow(color: Color.black.opacity(0.18), radius: 12, x: 0, y: 4)
        }
    }
}
#endif
