#if os(iOS)
import Combine
import SwiftUI
import UIKit

/**
 * THE AGENT BAR — what the customer sees during a call, drawn by the SDK in
 * the brand's design. The app passes nothing about how it looks.
 *
 * A bar rather than a sheet: the agent can see the screen and tell the
 * customer what to tap, and a sheet would cover the very thing it is talking
 * about. MOUNT IT ONCE, AT YOUR ROOT, as an overlay — not inside a screen: the
 * agent's job is to move the customer between screens, and a bar inside one
 * disappears on the very action that proves the feature works.
 *
 *     ContentView()
 *         .overlay(GraineAgentBar(onPlacementChange: { UserDefaults.standard.set($0, forKey: "graineBar") }))
 *
 * With a design (every current session carries one) it is contract/DESIGN.md's
 * voice bar, element by element as the dashboard's Garage draws it: the
 * accent avatar with the launcher glyph, the name and a status line whose
 * meter moves at the design's pace, the microphone and the hang-up — in the
 * design's colours, corners, outline, shadow or hard offset, glass, icon style
 * and typeface, which the SDK loads itself. The line being said rides above it
 * as a caption card. Without a design (an older server) it is the bar it
 * always was.
 *
 * It says the network's name out loud — "Weak connection", "No connection",
 * "Reconnecting…" — because a customer whose agent goes quiet on a train reads
 * "Listening" and concludes the agent is broken.
 *
 * The customer can DRAG it up or down (a bar fixed at one height covers
 * somebody's primary button on some screen of some app); a tap still does what
 * a tap did. Persist the offset from `onPlacementChange` and hand it back as
 * `initialOffset`. It RISES ABOVE THE KEYBOARD, and so does anything you ride
 * in it with `.accessory { … }` — a text field there is never under the keys.
 *
 * It fills the area it is given and draws only the bar; touches elsewhere pass
 * through. Every piece is public state on GraineVoice (an ObservableObject,
 * `phase` included); an app with its own design system can draw its own from
 * that instead.
 */
public struct GraineAgentBar<Accessory: View>: View {
    let config: GraineAgentBarConfig
    let accessoryView: Accessory

    init(config: GraineAgentBarConfig, accessory: Accessory) {
        self.config = config
        self.accessoryView = accessory
    }

    public var body: some View {
        if let graine = config.graine ?? GraineInApp.current {
            GraineAgentBarContainer(graine: graine, voice: graine.voice, fonts: graine.fonts, config: config, accessory: accessoryView)
        }
    }

    /// Something that rides above the bar and moves with it — above the keyboard included. A text field, say.
    public func accessory<Content: View>(@ViewBuilder _ content: () -> Content) -> GraineAgentBar<Content> {
        GraineAgentBar<Content>(config: config, accessory: content())
    }
}

public extension GraineAgentBar where Accessory == EmptyView {
    /**
     * - Parameters:
     *   - graine: the instance; defaults to the one `GraineInApp.configure` made. Nothing draws before that.
     *   - name: the name beside the status, and what VoiceOver calls the agent. Defaults to the dashboard's heading.
     *   - accent: overrides the design's and the dashboard's accent.
     *   - bottomInset: points above the bottom of the area — lift it clear of your tab bar.
     *   - draggable: let the customer move it up and down.
     *   - initialOffset: a position the app persisted, in points above the anchor.
     *   - onPlacementChange: the customer let go somewhere new. Persist it here.
     *   - autoAttach: mount the engine in the key window when the bar appears, if nothing has yet.
     *   - surface: which conversation opens — the call or the chat — among those the dashboard offers
     *     (What visitors get). It can never add one the dashboard withheld. Nil: the dashboard's choice.
     *   - onClose: the customer hung up, or closed the bar with no call to end — after the goodbye has had a
     *     moment to leave the speaker. Take the bar away here if your app shows it on demand.
     */
    init(
        graine: GraineInApp? = nil,
        name: String? = nil,
        accent: Color? = nil,
        bottomInset: CGFloat = 16,
        draggable: Bool = true,
        initialOffset: CGFloat = 0,
        onPlacementChange: ((CGFloat) -> Void)? = nil,
        autoAttach: Bool = true,
        surface: GraineSurface? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.init(
            config: GraineAgentBarConfig(
                graine: graine,
                name: name,
                accent: accent,
                bottomInset: bottomInset,
                draggable: draggable,
                initialOffset: initialOffset,
                onPlacementChange: onPlacementChange,
                autoAttach: autoAttach,
                surface: surface,
                onClose: onClose
            ),
            accessory: EmptyView()
        )
    }
}

struct GraineAgentBarConfig {
    let graine: GraineInApp?
    let name: String?
    let accent: Color?
    let bottomInset: CGFloat
    let draggable: Bool
    let initialOffset: CGFloat
    let onPlacementChange: ((CGFloat) -> Void)?
    let autoAttach: Bool
    var surface: GraineSurface? = nil
    var onClose: (() -> Void)? = nil
}

/// What the bar hears that GraineVoice does not publish: the dashboard's appearance and design, a refused microphone, a misconfiguration.
final class GraineAgentBarModel: ObservableObject, GraineListener {
    @Published var appearance: [String: Any] = [:]
    /// The brand's design; nil draws from `appearance`, exactly as before designs.
    @Published var design: GraineDesign?
    @Published var micDenied = false
    /**
     * A misconfiguration the call reported (its transport `not_configured`):
     * it never recovers on its own, so the bar says "Unavailable" rather than
     * pretend. Cleared when a new attempt begins.
     */
    @Published var fault: String?
    private var active = false

    init(graine: GraineInApp) {
        if let session = graine.session {
            appearance = session.appearance
            design = session.design
        }
        graine.addListener(self)
    }

    func onSessionReady(_ session: GraineSessionConfig) {
        appearance = session.appearance
        design = session.design
    }

    func onMicDenied(reason: String) {
        micDenied = true
    }

    func onTransport(_ transport: GraineTransport, requested: GraineTransport, reason: String?, message: String?) {
        if reason == "not_configured", let message = message { fault = message }
    }

    func onCallState(connected: Bool, connecting: Bool) {
        if connected || connecting { micDenied = false }
        // A new attempt: the last one's fault is not news. Not on connect — the fault arrives during it.
        let now = connected || connecting
        if now && !active { fault = nil }
        active = now
    }
}

/**
 * The keyboard's frame, in the key window's coordinates, or nil while it is
 * hidden. Will-change, so the bar moves with the keyboard's own animation
 * rather than after it.
 */
final class GraineKeyboardObserver: ObservableObject {
    @Published var frame: CGRect? = nil
    private var tokens: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        tokens.append(center.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main
        ) { [weak self] note in self?.update(note) })
        tokens.append(center.addObserver(
            forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.frame = nil })
    }

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }

    private func update(_ note: Notification) {
        guard let value = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        let onScreen = value.cgRectValue
        guard let window = GraineVoice.keyWindow() else {
            frame = onScreen.height > 0 ? onScreen : nil
            return
        }
        let inWindow = window.convert(onScreen, from: window.screen.coordinateSpace)
        frame = inWindow.height > 0 && inWindow.minY < window.bounds.maxY ? inWindow : nil
    }
}

private struct GraineBarHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct GraineAgentBarContainer<Accessory: View>: View {
    let graine: GraineInApp
    @ObservedObject var voice: GraineVoice
    /// The typed conversation, when the customer is in the chat.
    @ObservedObject var chat: GraineChat
    /// Observed so a typeface that lands mid-call redraws the bar in place.
    @ObservedObject var fonts: GraineFontStore
    let config: GraineAgentBarConfig
    let accessory: Accessory

    @StateObject private var model: GraineAgentBarModel
    @StateObject private var keyboard = GraineKeyboardObserver()
    @State private var offset: CGFloat
    @State private var dragStart: CGFloat? = nil
    @State private var unitHeight: CGFloat = 0
    /// The surface the customer last switched to; nil until they do (the app's, else the dashboard's, opens).
    @State private var chosen: GraineSurface? = nil
    /// A logo that would not load: the avatar goes back to the letter on the accent until the logo changes.
    @State private var failedLogo: String? = nil
    /// This bar shows the chat now — counted once by the chat, however the bar came to show it or stopped.
    @State private var chatOnScreen = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Space kept clear at the top — status bar, notch.
    private let topMargin: CGFloat = 48

    /**
     * Whether this package can carry the agent's chat. It can: the chat has its
     * own connection (GraineChat), so the bar offers whatever the dashboard
     * offers — the call, the chat, or both with the switch between them.
     */
    static var carriesChat: Bool { true }

    init(graine: GraineInApp, voice: GraineVoice, fonts: GraineFontStore, config: GraineAgentBarConfig, accessory: Accessory) {
        self.graine = graine
        _voice = ObservedObject(wrappedValue: voice)
        _chat = ObservedObject(wrappedValue: graine.chat)
        _fonts = ObservedObject(wrappedValue: fonts)
        self.config = config
        self.accessory = accessory
        _model = StateObject(wrappedValue: GraineAgentBarModel(graine: graine))
        _offset = State(initialValue: config.initialOffset)
    }

    var body: some View {
        ZStack {
            GeometryReader { geo in
                positioned(in: geo)
            }
            // The bar measures the keyboard itself; SwiftUI must not also move it.
            .ignoresSafeArea(.keyboard, edges: .bottom)
            // A bigger chat window — a sheet, an iPad's panel, the screen — over the app (GraineChatSizes.swift).
            if let t = tokens, let shown = presentation, shown != .window {
                GraineBigChat(presentation: shown, tokens: t, keyboard: keyboardOverWindow, onClose: closeChat) {
                    bigChatWindow(t, shown)
                }
                .transition(shown == .panel ? .graineRise : .move(edge: .bottom))
            }
        }
        .animation(tokens?.motion.animation(reduceMotion: reduceMotion), value: presentation)
        .onAppear {
            if config.autoAttach && !voice.isAttached { voice.attach() }
            // While a bar is on screen, a page still loading is the customer's wait (GraineVoice.slowConnect).
            voice.viewerAppeared()
            graine.tapCapture.attach(to: GraineVoice.keyWindow())
            if showsChat { showChat(true) }
        }
        .onDisappear {
            voice.viewerDisappeared()
            // The bar is gone, and with it an open's own size. The conversation is kept for the next window, until idle.
            if chatOnScreen {
                showChat(false)
                chat.forgetOpenedSize()
            }
        }
        // The chat's connection follows the surface: up while the customer is in it. Moving to the call ends it at once
        // (one conversation at a time), and moving back keeps the size an open asked for.
        .onChange(of: showsChat) { inChat in
            showChat(inChat)
            if !inChat { chat.closeConnection() }
        }
        // The app opened the chat (`chat.open(size:)`): the bar moves to it, where the agent offers one.
        .onReceive(chat.$appOpens.dropFirst()) { _ in
            if policy.allowed.contains(.chat) { chosen = .chat }
        }
    }

    // MARK: - How big the chat is (DESIGN.md "Chat window" → Size)

    /// The key window's size: a phone's or a tablet's, whatever area the app gave the bar.
    private var screenSize: CGSize {
        GraineVoice.keyWindow()?.bounds.size ?? UIScreen.main.bounds.size
    }

    /// Where the chat goes while the customer is in it: above the bar, a sheet, a panel or the screen; nil on the call.
    private var presentation: ChatWindowLayout.Presentation? {
        guard tokens != nil else { return nil }
        let size = screenSize
        return ChatWindowLayout.barPresentation(
            inChat: showsChat, open: chat.openedSize, config: graine.config.chatSize, token: tokens?.chat?.size,
            width: Double(size.width), height: Double(size.height)
        )
    }

    /// A bigger window is showing the chat: it carries the agent's components itself.
    private var bigChatShown: Bool {
        if let shown = presentation { return shown != .window }
        return false
    }

    /// The keyboard's height over the window's bottom edge.
    private var keyboardOverWindow: CGFloat {
        guard let kb = keyboard.frame else { return 0 }
        return max(0, screenSize.height - kb.minY)
    }

    /**
     * The chat window's call button and microphone (DESIGN.md "Chat window
     * v2" → Header, Composer): only where the agent takes calls as well as
     * chats, and a call can be placed. A tap is exactly the bar's own call —
     * the switch to the call, then the microphone's start.
     */
    private var chatCall: (() -> Void)? {
        guard canSwitch, model.fault == nil else { return nil }
        return {
            chosen = .voice
            if !voice.isAttached { voice.attach() }
            voice.start()
        }
    }

    /// The height the composer takes at the window's bottom: its strip, or a floating capsule and its margins.
    static func composerRoom(_ composer: GraineChatTokens.Composer) -> Double {
        switch composer.style {
        case "pill": return 60
        case "floating": return composer.height + 20
        default: return VoiceBar.Chat.composer
        }
    }

    /// Tell the chat whether this bar shows it: on screen it connects; off every screen it is kept until idle.
    private func showChat(_ on: Bool) {
        guard on != chatOnScreen else { return }
        chatOnScreen = on
        chat.shown(on)
    }

    /// What the chevron does, and closing a sheet, a panel or a screen: back to the call, or the bar closes.
    private func closeChat() {
        switch ChatWindowLayout.close(canSwitch: canSwitch) {
        case .backToCall: chosen = .voice
        case .closeBar: endOrClose()
        }
    }

    /// The chat in a bigger window: filling it (an iPad's panel keeps its frame), the chevron leading a full screen,
    /// the agent's components above its composer.
    private func bigChatWindow(_ t: GraineThemeTokens, _ shown: ChatWindowLayout.Presentation) -> some View {
        GraineChatWindow(
            tokens: t, type: type(t), accent: accent(t), onAccent: onAccent(t),
            heading: displayName, logoUrl: dash.logoUrl, logoPlate: dash.logoPlate,
            turns: chat.turns, status: chat.status, typing: chat.typing, lifted: keyboard.frame != nil,
            fills: true, keepsFrame: shown == .panel, leadingChevron: shown == .screen,
            collapseLabel: canSwitch ? "Collapse" : "Close",
            upcoming: chat.upcomingCalls, cancelling: chat.cancelling, cancelFailed: chat.cancelFailed,
            callName: graine.sessionOrCached?.calls?.callName,
            bookable: graine.bookingAvailable,
            quickReplies: chat.quickReplies, ended: chat.ended, rating: chat.rating, pin: chat.pinned,
            wasOnline: chat.wasOnline, disconnected: chat.disconnected, marks: chat.marks, loader: loader,
            onSend: { chat.send($0) },
            onRetry: { chat.retry() },
            onCancelCall: { chat.cancelUpcomingCall(id: $0) },
            onBook: { Task { @MainActor in _ = await graine.presentBooking() } },
            // A sheet, a panel and a screen offer New conversation like the compact window.
            onNewConversation: { Task { try? await chat.newConversation() } },
            onRate: { chat.rate(style: $0, value: $1) },
            onAttach: chat.onAttach,
            onCall: chatCall,
            onCollapse: closeChat
        )
        .overlay(alignment: .bottom) {
            GraineWidgetView(graine: graine, inBar: true)
                .padding(.horizontal, 12)
                .padding(.bottom, CGFloat(Self.composerRoom(t.chatOrClassic.composer)) + 8)
        }
    }

    // MARK: - Where it sits

    private func bounds(height: CGFloat) -> PlacementMath.Bounds {
        PlacementMath.Bounds(
            windowHeight: Double(height),
            baseBottom: Double(config.bottomInset),
            barHeight: Double(unitHeight),
            topMargin: Double(topMargin)
        )
    }

    private func positioned(in geo: GeometryProxy) -> some View {
        let area = geo.frame(in: .global)
        let placement = bounds(height: geo.size.height)
        let resting = PlacementMath.clampOffset(Double(offset), placement)
        let lift = keyboardLift(area: area)
        let bottom = PlacementMath.bottomDistance(baseBottom: Double(config.bottomInset), offset: resting, keyboardLift: lift)
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            unit(placement: placement, resting: CGFloat(resting))
        }
        .padding(.horizontal, 12)
        .padding(.bottom, CGFloat(bottom))
        .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
        .animation(.easeOut(duration: 0.22), value: lift)
    }

    /// How much of this area the keyboard covers. 0 when SwiftUI has already moved the area up.
    private func keyboardLift(area: CGRect) -> Double {
        guard let kb = keyboard.frame else { return 0 }
        let overlap = KeyboardMath.overlap(
            areaMinX: Double(area.minX), areaMaxX: Double(area.maxX), areaMaxY: Double(area.maxY),
            keyboardMinX: Double(kb.minX), keyboardMinY: Double(kb.minY), keyboardMaxX: Double(kb.maxX),
            keyboardHeight: Double(kb.height)
        )
        return KeyboardMath.liftFor(keyboardHeight: overlap, windowShrink: 0)
    }

    /// The bar and what rides above it: one unit, measured and moved together.
    @ViewBuilder
    private func unit(placement: PlacementMath.Bounds, resting: CGFloat) -> some View {
        Group {
            if let t = tokens {
                VStack(spacing: CGFloat(VoiceBar.stackGap)) {
                    // A component the agent drew sits above everything: it is a thing to act on.
                    // A bigger chat window carries it itself.
                    if !bigChatShown {
                        GraineWidgetView(graine: graine, inBar: true)
                    }
                    accessory
                    above(t)
                    designedBar(t, placement: placement, resting: resting)
                }
                // Arrivals rise in the design's motion; nothing moves with none, or under Reduce Motion.
                .animation(t.motion.animation(reduceMotion: reduceMotion), value: captionLine != nil)
                .animation(t.motion.animation(reduceMotion: reduceMotion), value: showsChat)
            } else {
                VStack(spacing: 8) {
                    GraineWidgetView(graine: graine, inBar: true)
                    accessory
                    legacyCaption
                    legacyBar(placement: placement, resting: resting)
                }
            }
        }
        .background(GeometryReader { proxy in
            Color.clear.preference(key: GraineBarHeightKey.self, value: proxy.size.height)
        })
        .onPreferenceChange(GraineBarHeightKey.self) { height in
            unitHeight = height
        }
    }

    // MARK: - What the bar is drawn from

    /// The dashboard's appearance, translated: accent, heading, logo and its plate, radius. The dashboard decides; props override.
    private var dash: GraineNativeAppearance {
        Appearance.resolve(model.appearance, accent: Appearance.defaultAccent, heading: "Assistant", origin: graine.config.baseUrl)
    }

    /// The design's tokens for this view's light or dark (SwiftUI re-draws when it switches); nil without a design.
    private var tokens: GraineThemeTokens? {
        model.design?.tokens(deviceDark: colorScheme == .dark)
    }

    private var loader: GraineLoaderLook {
        Loaders.resolve(model.appearance["loader"])
    }

    /// The name beside the status: the prop, else the dashboard's heading, else "Assistant".
    private var displayName: String {
        config.name ?? dash.heading
    }

    private var initial: String {
        let first = String(displayName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased()
        return first.isEmpty ? "A" : first
    }

    /// The line being said now, on a call, while the captions are on.
    private var captionLine: GraineCaption? {
        VoiceBar.Caption.line(connected: voice.connected, captionsOn: voice.captionsOn, captions: voice.captions)
    }

    /// What the dashboard offers and which opens — the customer's last switch, else the app's, else the dashboard's.
    private var policy: SurfacePolicy {
        SurfacePolicy.resolve(appearance: model.appearance, prefer: chosen ?? config.surface)
    }

    private var canSwitch: Bool {
        Self.carriesChat && policy.canSwitch
    }

    /// In the chat — only with a design to draw it in (an older server's bar is the call, as it always was).
    private var showsChat: Bool { Self.carriesChat && tokens != nil && policy.start == .chat }

    // MARK: - The designed bar (DESIGN.md "Voice bar")

    private func type(_ t: GraineThemeTokens) -> GraineType {
        GraineType(font: t.font, names: graine.config.fonts, faces: fonts.faces)
    }

    private func accent(_ t: GraineThemeTokens) -> Color {
        config.accent ?? .graineHex(t.colors.accent)
    }

    private func onAccent(_ t: GraineThemeTokens) -> Color {
        config.accent == nil ? .graineHex(t.colors.onAccent, fallback: .white) : .white
    }

    private var statusInput: VoiceBarStatus.Input {
        VoiceBarStatus.Input(
            error: model.fault != nil,
            inChat: showsChat,
            chatOnline: chat.online,
            chatDisconnected: chat.disconnected,
            online: voice.online,
            reconnecting: voice.reconnecting,
            connectivity: voice.connectivity,
            micDenied: model.micDenied,
            ready: voice.ready,
            connecting: voice.connecting,
            muted: voice.muted,
            connected: voice.connected,
            phase: voice.phase,
            quality: voice.quality,
            callFailed: voice.callFailed,
            connectStage: voice.connectStage,
            slowConnect: voice.slowConnect,
            connectingWords: loader.text.connecting ?? "Connecting…"
        )
    }

    /// Above the bar: the chat window while the customer is in the chat, else the caption on a call.
    @ViewBuilder
    private func above(_ t: GraineThemeTokens) -> some View {
        if showsChat {
            // The compact window; a bigger one is drawn over the app instead (`bigChatWindow`).
            if presentation == .window {
            GraineChatWindow(
                tokens: t, type: type(t), accent: accent(t), onAccent: onAccent(t),
                heading: displayName, logoUrl: dash.logoUrl, logoPlate: dash.logoPlate,
                turns: chat.turns, status: chat.status, typing: chat.typing, lifted: keyboard.frame != nil,
                collapseLabel: canSwitch ? "Collapse" : "Close",
                upcoming: chat.upcomingCalls, cancelling: chat.cancelling, cancelFailed: chat.cancelFailed,
                callName: graine.sessionOrCached?.calls?.callName,
                bookable: graine.bookingAvailable,
                quickReplies: chat.quickReplies, ended: chat.ended, rating: chat.rating, pin: chat.pinned,
                wasOnline: chat.wasOnline, disconnected: chat.disconnected, marks: chat.marks, loader: loader,
                onSend: { chat.send($0) },
                onRetry: { chat.retry() },
                onCancelCall: { chat.cancelUpcomingCall(id: $0) },
                onBook: { Task { @MainActor in _ = await graine.presentBooking() } },
                onNewConversation: { Task { try? await chat.newConversation() } },
                onRate: { chat.rate(style: $0, value: $1) },
                onAttach: chat.onAttach,
                onCall: chatCall,
                // Back to the call where there is one; a chat-only agent's chevron closes the bar.
                onCollapse: closeChat
            )
            .transition(.graineRise)
            }
        } else if let line = captionLine {
            GraineCaptionCard(tokens: t, type: type(t), accent: accent(t), line: line)
                .transition(.graineRise)
        }
    }

    /**
     * 60 high, 9 in from each side, items 10 apart: the avatar, the name and
     * status taking the rest, the switch (only where the chat is offered and
     * carried), the microphone (calls only), the hang-up. On `surface`,
     * outlined, `radius.xl`, with the floating shadow or the hard offset.
     */
    private func designedBar(_ t: GraineThemeTokens, placement: PlacementMath.Bounds, resting: CGFloat) -> some View {
        let status = VoiceBarStatus.line(statusInput)
        let spoken = status.spoken(loader: loader)
        return HStack(spacing: CGFloat(VoiceBar.spacing)) {
            HStack(spacing: CGFloat(VoiceBar.spacing)) {
                designedAvatar(t)
                VStack(alignment: .leading, spacing: 1) {
                    Text(displayName)
                        .font(type(t).body(VoiceBar.nameSize, t.font.weights.strong))
                        .tracking(type(t).bodyTracking(VoiceBar.nameSize))
                        .foregroundColor(.graineHex(t.colors.text))
                        .lineLimit(1)
                    designedStatus(t, status)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                // "tap to retry": a page that never loaded reloads; a call nothing could carry is placed again.
                if voice.connectivity == .failed {
                    voice.retry()
                } else if voice.callFailed && !voice.connecting {
                    if !voice.isAttached { voice.attach() }
                    voice.start()
                }
            }
            .gesture(drag(placement: placement, resting: resting), including: config.draggable ? .all : .subviews)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(displayName), \(spoken)")
            if canSwitch {
                switchButton(t)
            }
            if !showsChat {
                micButton(t)
            }
            endButton(t)
        }
        .padding(.horizontal, CGFloat(VoiceBar.sidePadding))
        .frame(height: CGFloat(VoiceBar.height))
        .modifier(GraineDesignSurface(tokens: t, fill: t.colors.surface, frosted: true, radius: t.shape.radius.xl, shadow: t.elevation.floating))
    }

    /**
     * 38 round: the launcher glyph in `onAccent` at 18 on `accent`; with none,
     * the brand's logo — WHOLE, fitted into the largest square the circle holds,
     * never cropped, on its plate (DESIGN.md "The brand's logo"); else the
     * first letter on `accent`. The logo was drawn filling the circle, and a
     * wordmark lost both ends, a square logo its corners.
     */
    private func designedAvatar(_ t: GraineThemeTokens) -> some View {
        let ink = onAccent(t)
        let letter = Text(initial)
            .font(.system(size: CGFloat(VoiceBar.initial), weight: .bold))
            .foregroundColor(ink)
        // The logo stands in only where there is no glyph, and only while it has not refused to load.
        let raw = t.icons.launcher == nil && dash.logoUrl != failedLogo ? dash.logoUrl : nil
        let logo = raw.flatMap { URL(string: $0) }
        let plate = DesignRules.logoPlateLook(
            logo != nil ? dash.logoPlate : .accent, accent: t.colors.accent, border: t.colors.border, borderWidth: t.shape.borderWidth
        )
        let box = CGFloat(DesignRules.logoBox(.circle, size: VoiceBar.button))
        return ZStack {
            Circle().fill(plate.outline == nil ? accent(t) : Color.graineHex(plate.fill))
            if let glyph = t.icons.launcher {
                GraineGlyphView(glyph: glyph, stroke: t.icons.stroke, color: ink, size: CGFloat(VoiceBar.icon), fallback: letter)
            } else if let url = logo {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFit().frame(width: box, height: box)
                    case .failure: letter.onAppear { failedLogo = raw }
                    default: Color.clear
                    }
                }
            } else {
                letter
            }
        }
        .frame(width: CGFloat(VoiceBar.button), height: CGFloat(VoiceBar.button))
        .clipShape(Circle())
        .overlay {
            // A white plate on a white bar needs its hairline to be seen at all.
            if let outline = plate.outline {
                Circle().strokeBorder(Color.graineHex(outline.color), lineWidth: CGFloat(outline.width))
            }
        }
        .accessibilityHidden(true)
    }

    /// The status: caption size, the body family at `weights.body`, `textMuted` — after the meter while it listens or speaks; the loader while it waits.
    @ViewBuilder
    private func designedStatus(_ t: GraineThemeTokens, _ status: VoiceBarStatus.Line) -> some View {
        if status.waiting != nil {
            GraineLoaderLabel(
                look: loader,
                color: Color.graineHex(loader.color ?? t.colors.accent),
                track: .graineHex(t.colors.border),
                textColor: .graineHex(t.colors.textMuted),
                // The brand's words for the moment — a retry is "reconnecting" in their words — or "Still connecting…"
                // while the brand's connecting words are the default (VoiceBarStatus.connecting).
                label: status.spoken(loader: loader),
                size: 14,
                logoUrl: dash.logoUrl
            )
        } else {
            HStack(spacing: CGFloat(VoiceBar.meterGap)) {
                if status.meter {
                    GraineVoiceMeter(
                        color: accent(t),
                        durationMs: t.motion.effectiveDurationMs(reduceMotion: GraineThemeTokens.Motion.reduced(reduceMotion))
                    )
                }
                Text(status.text)
                    .font(type(t).body(t.font.scale.caption, t.font.weights.body))
                    .tracking(type(t).bodyTracking(t.font.scale.caption))
                    .foregroundColor(.graineHex(t.colors.textMuted))
                    .lineLimit(1)
            }
        }
    }

    private func roundButton<Icon: View>(fill: Color, _ icon: Icon) -> some View {
        icon
            .frame(width: CGFloat(VoiceBar.button), height: CGFloat(VoiceBar.button))
            .background(Circle().fill(fill))
            .contentShape(Circle())
    }

    /// To the other surface: `accentSoft`, the chat icon on a call and the call icon in the chat, in `text`.
    private func switchButton(_ t: GraineThemeTokens) -> some View {
        Button(action: { chosen = showsChat ? .voice : .chat }) {
            roundButton(fill: .graineHex(t.colors.accentSoft), GraineIconView(
                name: showsChat ? .call : .chat, style: t.icons.style, stroke: t.icons.stroke, color: .graineHex(t.colors.text)
            ))
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(showsChat ? "Switch to a call" : "Switch to chat")
    }

    /**
     * Off a call the microphone STARTS one; on a call it is the mute (then
     * `danger` with the struck-through microphone in white); after a failed
     * load it retries; after a call nothing could carry ("Couldn’t connect")
     * it places a new one. Faint and inert while it cannot act.
     */
    private func micButton(_ t: GraineThemeTokens) -> some View {
        let failed = voice.connectivity == .failed
        let blocked = model.fault != nil || model.micDenied || voice.connecting || (!voice.ready && !failed)
        let label = !voice.connected ? "Start talking to \(displayName)" : (voice.muted ? "Unmute" : "Mute")
        return Button(action: {
            if failed {
                voice.retry()
            } else if voice.connected {
                voice.setMuted(!voice.muted)
            } else {
                if !voice.isAttached { voice.attach() }
                voice.start()
            }
        }) {
            roundButton(fill: voice.muted ? .graineHex(t.colors.danger) : accent(t), GraineIconView(
                name: voice.muted ? .micOff : .mic, style: t.icons.style, stroke: t.icons.stroke,
                color: voice.muted ? .white : onAccent(t)
            ))
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(blocked)
        .opacity(blocked ? VoiceBar.blockedOpacity : 1)
        .accessibilityLabel(label)
    }

    /// Loud only while there is a call to end (`danger`, the hang-up in white); otherwise it closes (`accentSoft`, a cross in `textMuted`).
    private func endButton(_ t: GraineThemeTokens) -> some View {
        let onCall = voice.connected && !showsChat
        return Button(action: endOrClose) {
            roundButton(fill: onCall ? .graineHex(t.colors.danger) : .graineHex(t.colors.accentSoft), GraineIconView(
                name: onCall ? .end : .close, style: t.icons.style, stroke: t.icons.stroke,
                color: onCall ? .white : .graineHex(t.colors.textMuted)
            ))
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(onCall ? "End call" : "Close")
    }

    /// Hang up (or cancel a call still being placed) — or leave the chat — then let the app take the bar away once the goodbye has left the speaker.
    private func endOrClose() {
        if showsChat { chat.close() }
        voice.end()
        guard let close = config.onClose else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(400)) { close() }
    }

    // MARK: - The bar without a design — as it always was

    /// The dashboard's light/dark/auto; auto follows the device.
    private var palette: GraineBarPalette {
        Appearance.prefersDark(model.appearance, deviceIsDark: colorScheme == .dark) ? .dark : .light
    }

    private var legacyAccent: Color {
        config.accent ?? Color.graineHex(dash.accent)
    }

    private var legacyOnAccent: Color {
        config.accent == nil ? Color.graineHex(Appearance.onAccent(dash.accent), fallback: .white) : .white
    }

    private var legacyRadius: CGFloat {
        CGFloat(dash.radius)
    }

    private var legacyStatusInput: BarStatus.Input {
        BarStatus.Input(
            connectivity: voice.connectivity,
            online: voice.online,
            reconnecting: voice.reconnecting,
            connecting: voice.connecting,
            ready: voice.ready,
            muted: voice.muted,
            connected: voice.connected,
            quality: voice.quality,
            agentSpeaking: CaptionLog.agentSpeaking(voice.captions),
            micDenied: model.micDenied
        )
    }

    @ViewBuilder
    private var legacyCaption: some View {
        if let last = captionLine {
            Text(last.text)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(palette.text)
                .lineLimit(3)
                .opacity(last.live ? 0.85 : 1)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: legacyRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: legacyRadius, style: .continuous).stroke(palette.border, lineWidth: 1)
                }
                .shadow(color: Color.black.opacity(0.18), radius: 12, x: 0, y: 4)
        }
    }

    private func legacyBar(placement: PlacementMath.Bounds, resting: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: min(26, legacyRadius + 8), style: .continuous)
        return HStack(spacing: 8) {
            legacyLabel
                .contentShape(Rectangle())
                .onTapGesture {
                    if voice.connectivity == .failed { voice.retry() }
                }
                .gesture(drag(placement: placement, resting: resting), including: config.draggable ? .all : .subviews)
            if voice.connected {
                legacyMuteButton
            }
            legacyCallButton
        }
        .padding(8)
        .background(palette.surface, in: shape)
        .overlay { shape.stroke(palette.border, lineWidth: 1) }
        .shadow(color: Color.black.opacity(0.3), radius: 16, x: 0, y: 6)
    }

    private var legacyLabel: some View {
        let input = legacyStatusInput
        return HStack(spacing: 11) {
            legacyAvatar
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(palette.text)
                    .lineLimit(1)
                legacyStatus(input)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(displayName), \(BarStatus.text(input))")
            Spacer(minLength: 0)
        }
    }

    /// A face: the dashboard's logo when there is one, else Graine's waveform on the accent.
    @ViewBuilder
    private var legacyAvatar: some View {
        if let url = dash.logoUrl.flatMap({ URL(string: $0) }) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    palette.chip
                }
            }
            .frame(width: 38, height: 38)
            .clipShape(Circle())
            .accessibilityHidden(true)
        } else {
            ZStack {
                Circle().fill(legacyAccent)
                GraineGlyphView(
                    glyph: DesignTokens.Fallback.glyph, stroke: 2, color: legacyOnAccent, size: 18,
                    fallback: Circle().fill(legacyOnAccent).frame(width: 6, height: 6)
                )
            }
            .frame(width: 38, height: 38)
            .accessibilityHidden(true)
        }
    }

    /// While it is coming up the status line IS the loader the brand chose, with its words for the moment.
    @ViewBuilder
    private func legacyStatus(_ input: BarStatus.Input) -> some View {
        if let moment = BarStatus.waiting(input) {
            GraineLoaderLabel(
                look: loader,
                color: Color.graineHex(loader.color ?? dash.accent),
                track: palette.border,
                textColor: palette.sub,
                label: loader.text.forMoment(moment),
                size: 15,
                logoUrl: dash.logoUrl
            )
        } else {
            Text(BarStatus.settled(input))
                .font(.system(size: 12.5))
                .foregroundColor(palette.sub)
                .lineLimit(1)
        }
    }

    /// Mute is on the bar because it is the control someone reaches for mid-sentence.
    private var legacyMuteButton: some View {
        Button(action: { voice.setMuted(!voice.muted) }) {
            GraineIconView(name: voice.muted ? .micOff : .mic, style: "outline", stroke: 2, color: voice.muted ? .white : palette.text)
                .frame(width: 38, height: 38)
                .background(voice.muted ? palette.danger : palette.chip, in: Circle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(voice.muted ? "Unmute" : "Mute")
    }

    private var legacyCallButton: some View {
        let failed = voice.connectivity == .failed
        let live = voice.connected || voice.connecting
        let spoken = failed ? "Try again" : (live ? "End call" : "Start a call")
        let ink: Color = live ? .white : legacyOnAccent
        return Button(action: {
            if failed {
                voice.retry()
            } else if live {
                voice.end()
            } else {
                voice.start()
            }
        }) {
            Group {
                if failed {
                    Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .bold))
                } else {
                    GraineIconView(name: live ? .close : .call, style: "outline", stroke: 2, color: ink)
                }
            }
            .foregroundColor(ink)
            .frame(width: 38, height: 38)
            .background(live ? palette.danger : legacyAccent, in: Circle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(spoken)
    }

    // MARK: - Dragging

    /**
     * Claimed only once it is clearly a drag (8 points), so a tap on the bar
     * still does what a tap did. In the window's coordinates: the bar moves
     * under the finger, and its own coordinates would move with it.
     */
    private func drag(placement: PlacementMath.Bounds, resting: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: CGFloat(PlacementMath.dragSlop), coordinateSpace: .global)
            .onChanged { value in
                let start = dragStart ?? resting
                if dragStart == nil { dragStart = resting }
                let next = PlacementMath.offsetDuringDrag(start: Double(start), dy: Double(value.translation.height), placement)
                offset = CGFloat(next)
            }
            .onEnded { value in
                guard let start = dragStart else { return }
                let next = CGFloat(PlacementMath.offsetDuringDrag(start: Double(start), dy: Double(value.translation.height), placement))
                offset = next
                dragStart = nil
                if next != start { config.onPlacementChange?(next) }
            }
    }
}
#endif
