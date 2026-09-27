#if os(iOS)
import Combine
import SwiftUI
import UIKit

/**
 * THE DEFAULT AGENT BAR — a working UI, not a requirement.
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
 * It says the network's name out loud — "weak connection", "no connection",
 * "reconnecting…" — because a customer whose agent goes quiet on a train reads
 * "listening" and concludes the agent is broken.
 *
 * The customer can DRAG it up or down (a bar fixed at one height covers
 * somebody's primary button on some screen of some app); a tap still does what
 * a tap did. Persist the offset from `onPlacementChange` and hand it back as
 * `initialOffset`. It RISES ABOVE THE KEYBOARD, and so does anything you ride
 * in it with `.accessory { … }` — a text field there is never under the keys.
 *
 * It fills the area it is given and draws only the bar; touches elsewhere pass
 * through. Every piece is public state on GraineVoice (an ObservableObject); an
 * app with its own design system should draw its own from that and ignore this.
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
            GraineAgentBarContainer(graine: graine, voice: graine.voice, config: config, accessory: accessoryView)
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
     *   - name: the name beside the status. Defaults to the dashboard's heading when it is short, else "Assistant".
     *   - accent: overrides the dashboard's accent.
     *   - bottomInset: points above the bottom of the area — lift it clear of your tab bar.
     *   - draggable: let the customer move it up and down.
     *   - initialOffset: a position the app persisted, in points above the anchor.
     *   - onPlacementChange: the customer let go somewhere new. Persist it here.
     *   - autoAttach: mount the engine in the key window when the bar appears, if nothing has yet.
     */
    init(
        graine: GraineInApp? = nil,
        name: String? = nil,
        accent: Color? = nil,
        bottomInset: CGFloat = 16,
        draggable: Bool = true,
        initialOffset: CGFloat = 0,
        onPlacementChange: ((CGFloat) -> Void)? = nil,
        autoAttach: Bool = true
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
                autoAttach: autoAttach
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
}

/// What the bar hears that GraineVoice does not publish: the dashboard's appearance and design, and a refused microphone.
final class GraineAgentBarModel: ObservableObject, GraineListener {
    @Published var appearance: [String: Any] = [:]
    /// The brand's design; nil draws from `appearance`, exactly as before designs.
    @Published var design: GraineDesign?
    @Published var micDenied = false

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

    func onCallState(connected: Bool, connecting: Bool) {
        if connected || connecting { micDenied = false }
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
    let config: GraineAgentBarConfig
    let accessory: Accessory

    @StateObject private var model: GraineAgentBarModel
    @StateObject private var keyboard = GraineKeyboardObserver()
    @State private var offset: CGFloat
    @State private var dragStart: CGFloat? = nil
    @State private var unitHeight: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Space kept clear at the top — status bar, notch.
    private let topMargin: CGFloat = 48

    init(graine: GraineInApp, voice: GraineVoice, config: GraineAgentBarConfig, accessory: Accessory) {
        self.graine = graine
        _voice = ObservedObject(wrappedValue: voice)
        self.config = config
        self.accessory = accessory
        _model = StateObject(wrappedValue: GraineAgentBarModel(graine: graine))
        _offset = State(initialValue: config.initialOffset)
    }

    var body: some View {
        GeometryReader { geo in
            positioned(in: geo)
        }
        // The bar measures the keyboard itself; SwiftUI must not also move it.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onAppear {
            if config.autoAttach && !voice.isAttached { voice.attach() }
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

    /// The bar, its caption and any accessory: one unit, measured and moved together.
    private func unit(placement: PlacementMath.Bounds, resting: CGFloat) -> some View {
        VStack(spacing: 8) {
            accessory
            caption
            bar(placement: placement, resting: resting)
        }
        // The design's motion as the call comes and goes (the caption, the mute button); none without a design.
        .animation(look.animation, value: voice.connected)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: GraineBarHeightKey.self, value: proxy.size.height)
        })
        .onPreferenceChange(GraineBarHeightKey.self) { height in
            unitHeight = height
        }
    }

    // MARK: - Pieces

    /// The dashboard's appearance, translated: accent, heading, logo, radius. The dashboard decides; props override.
    private var dash: GraineNativeAppearance {
        Appearance.resolve(model.appearance, accent: Appearance.defaultAccent, heading: "Assistant", origin: graine.config.baseUrl)
    }

    /// The dashboard's light/dark/auto; auto follows the device.
    private var palette: GraineBarPalette {
        Appearance.prefersDark(model.appearance, deviceIsDark: colorScheme == .dark) ? .dark : .light
    }

    private var accentColor: Color {
        config.accent ?? Color.graineHex(dash.accent)
    }

    private var onAccentColor: Color {
        config.accent == nil ? Color.graineHex(Appearance.onAccent(dash.accent), fallback: .white) : .white
    }

    private var loader: GraineLoaderLook {
        Loaders.resolve(model.appearance["loader"])
    }

    /// The design's tokens for this view's light or dark (SwiftUI re-draws when it switches); nil without a design.
    private var tokens: GraineThemeTokens? {
        model.design?.tokens(deviceDark: colorScheme == .dark)
    }

    /**
     * Everything the bar is drawn in. With a design, DESIGN.md's voice bar:
     * `surface` (glass-aware), a `borderWidth` outline in `border`, `radius.xl`,
     * `elevation.floating`, the status in `textMuted`, the call button in the
     * accent and the end button in `danger`. Without one, today's bar, unchanged.
     */
    private var look: GraineBarLook {
        guard let t = tokens else {
            return GraineBarLook(
                tokens: nil, type: nil, animation: nil,
                surface: palette.surface, border: palette.border, text: palette.text, sub: palette.sub, chip: palette.chip,
                accent: accentColor, onAccent: onAccentColor, danger: palette.danger,
                barRadius: min(26, radius + 8), borderWidth: 1
            )
        }
        let c = t.colors
        return GraineBarLook(
            tokens: t,
            type: GraineType(font: t.font, names: graine.config.fonts),
            animation: t.motion.animation(reduceMotion: reduceMotion),
            surface: .graineHex(c.surface), border: .graineHex(c.border), text: .graineHex(c.text),
            sub: .graineHex(c.textMuted), chip: .graineHex(c.accentSoft),
            accent: config.accent ?? .graineHex(c.accent),
            onAccent: config.accent == nil ? .graineHex(c.onAccent, fallback: .white) : .white,
            danger: .graineHex(c.danger),
            barRadius: CGFloat(t.shape.radius.xl), borderWidth: CGFloat(t.shape.borderWidth)
        )
    }

    private var radius: CGFloat {
        CGFloat(dash.radius)
    }

    /// The name beside the status: the prop, else the dashboard's heading, else "Assistant".
    private var displayName: String {
        config.name ?? dash.heading
    }

    private var statusInput: BarStatus.Input {
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

    /// Only the line being said now, above the bar. The whole transcript would push the bar off the screen.
    @ViewBuilder
    private var caption: some View {
        if voice.connected, let last = voice.captions.last,
           !last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let t = look.tokens {
                designedCaption(last, tokens: t)
                    .transition(.opacity)
            } else {
                legacyCaption(last)
            }
        }
    }

    /**
     * THE LINE AS A CHAT BUBBLE, in the design's bubble style: filled in the
     * speaker's colours, outlined (the customer's in the accent, the agent's in
     * the border colour), or minimal. It floats over the app rather than
     * sitting on the chat page, so where the style has no fill the bar's own
     * surface stands in for the page — plain text straight on somebody's
     * screen would be unreadable. Corners `radius.lg`, the one nearest the
     * speaker `radius.sm`.
     */
    private func designedCaption(_ line: GraineCaption, tokens t: GraineThemeTokens) -> some View {
        let bubble = DesignRules.bubble(t, role: line.role)
        let lg = CGFloat(t.shape.radius.lg)
        let sm = CGFloat(t.shape.radius.sm)
        let agent = line.role == .agent
        let shape = GraineCornerShape(topLeading: lg, topTrailing: lg, bottomLeading: agent ? sm : lg, bottomTrailing: agent ? lg : sm)
        let type = GraineType(font: t.font, names: graine.config.fonts)
        let padding = CGFloat(t.spacing.cardPadding)
        let glass = bubble.fill == nil ? t.glass : nil
        return Text(line.text)
            .font(type(.body))
            .tracking(type.tracking(.body))
            .lineSpacing(type.lineSpacing(.body))
            .foregroundColor(.graineHex(bubble.text))
            .lineLimit(3)
            .opacity(line.live ? 0.85 : 1)
            .padding(.horizontal, padding)
            .padding(.vertical, padding * 0.75)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GraineSurfaceFill(shape: shape, color: .graineHex(bubble.fill ?? t.colors.surface), glass: glass))
            .overlay {
                if let outline = bubble.outline {
                    shape.stroke(Color.graineHex(outline), lineWidth: CGFloat(t.shape.borderWidth))
                }
            }
            .background(GraineShadowLayer(shape: shape, shadow: t.elevation.floating, outsideOnly: glass != nil))
    }

    private func legacyCaption(_ last: GraineCaption) -> some View {
        Text(last.text)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(palette.text)
            .lineLimit(3)
            .opacity(last.live ? 0.85 : 1)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(palette.border, lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.18), radius: 12, x: 0, y: 4)
    }

    private func bar(placement: PlacementMath.Bounds, resting: CGFloat) -> some View {
        HStack(spacing: 8) {
            label
                .contentShape(Rectangle())
                .onTapGesture {
                    if voice.connectivity == .failed { voice.retry() }
                }
                .gesture(drag(placement: placement, resting: resting), including: config.draggable ? .all : .subviews)
            if voice.connected {
                muteButton
            }
            callButton
        }
        .padding(8)
        .modifier(GraineBarSurface(look: look))
    }

    private var label: some View {
        let input = statusInput
        return HStack(spacing: 11) {
            avatar
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(look.type.map { GraineTypeface.font(
                        family: $0.font.heading, size: $0.font.scale.body, weight: $0.font.weights.title, names: $0.names
                    ) } ?? .system(size: 15, weight: .bold))
                    .foregroundColor(look.text)
                    .lineLimit(1)
                status(input)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(displayName), \(BarStatus.text(input))")
            Spacer(minLength: 0)
        }
    }

    /// A face: the dashboard's logo when there is one, else the mark on the accent.
    @ViewBuilder
    private var avatar: some View {
        if let url = dash.logoUrl.flatMap({ URL(string: $0) }) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    look.chip
                }
            }
            .frame(width: 38, height: 38)
            .clipShape(Circle())
            .accessibilityHidden(true)
        } else {
            ZStack {
                Circle().fill(look.accent)
                if let t = look.tokens {
                    // The design's mark: its launcher glyph, or the name's first letter when the brand chose its logo.
                    designedMark(t, size: 38)
                } else {
                    Text("✦")
                        .font(.system(size: 16))
                        .foregroundColor(onAccentColor)
                }
            }
            .frame(width: 38, height: 38)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func designedMark(_ t: GraineThemeTokens, size: CGFloat) -> some View {
        let letter = Text(String(displayName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased())
            .font(GraineTypeface.font(family: t.font.heading, size: Double(size) * 0.42, weight: t.font.weights.title, names: graine.config.fonts))
            .foregroundColor(look.onAccent)
        if let glyph = t.icons.launcher {
            GraineGlyphView(
                glyph: glyph, stroke: t.icons.stroke, color: look.onAccent,
                size: size * CGFloat(DesignRules.launcherGlyphShare), fallback: letter
            )
        } else {
            letter
        }
    }

    /// While it is coming up the status line IS the loader the brand chose, with its words for the moment.
    @ViewBuilder
    private func status(_ input: BarStatus.Input) -> some View {
        if let moment = BarStatus.waiting(input) {
            GraineLoaderLabel(
                look: loader,
                color: Color.graineHex(loader.color ?? look.tokens?.colors.accent ?? dash.accent),
                track: look.border,
                textColor: look.sub,
                label: loader.text.forMoment(moment),
                size: 15,
                logoUrl: dash.logoUrl
            )
        } else {
            Text(BarStatus.settled(input))
                .font(look.type.map { $0(.caption) } ?? .system(size: 12.5))
                .foregroundColor(look.sub)
                .lineLimit(1)
        }
    }

    /// Mute is on the bar because it is the control someone reaches for mid-sentence.
    private var muteButton: some View {
        Button(action: { voice.setMuted(!voice.muted) }) {
            Group {
                if let t = look.tokens {
                    Image(systemName: GraineIcon.name(voice.muted ? "mic.slash" : "mic", style: t.icons.style))
                        .font(.system(size: 15, weight: GraineIcon.weight(stroke: t.icons.stroke)))
                        .foregroundColor(voice.muted ? .white : look.text)
                } else {
                    Text(voice.muted ? "🔇" : "🎙")
                        .font(.system(size: 16))
                }
            }
            .frame(width: 38, height: 38)
            .background(voice.muted ? look.danger : look.chip, in: Circle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(voice.muted ? "Unmute" : "Mute")
    }

    private var callButton: some View {
        let failed = voice.connectivity == .failed
        let live = voice.connected || voice.connecting
        let glyph = failed ? "↻" : (live ? "✕" : "📞")
        let spoken = failed ? "Try again" : (live ? "End call" : "Start a call")
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
                if let t = look.tokens {
                    let symbol = failed ? "arrow.clockwise" : (live ? "xmark" : GraineIcon.name("phone", style: t.icons.style))
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: GraineIcon.weight(stroke: t.icons.stroke)))
                } else {
                    Text(glyph)
                        .font(.system(size: 16, weight: .bold))
                }
            }
            .foregroundColor(live ? .white : look.onAccent)
            .frame(width: 38, height: 38)
            .background(live ? look.danger : look.accent, in: Circle())
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

/// Everything the bar is drawn in, from the design or from today's palette.
struct GraineBarLook {
    /// Nil: no design — every value below is today's.
    let tokens: GraineThemeTokens?
    let type: GraineType?
    let animation: Animation?
    let surface: Color
    let border: Color
    let text: Color
    let sub: Color
    let chip: Color
    let accent: Color
    let onAccent: Color
    let danger: Color
    let barRadius: CGFloat
    let borderWidth: CGFloat
}

/// The bar's own surface: the design's (glass, outline, floating shadow), or today's.
struct GraineBarSurface: ViewModifier {
    let look: GraineBarLook

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: look.barRadius, style: .continuous)
        if let t = look.tokens {
            content
                .background(GraineSurfaceFill(shape: shape, color: look.surface, glass: t.glass))
                .overlay { shape.stroke(look.border, lineWidth: look.borderWidth) }
                .background(GraineShadowLayer(shape: shape, shadow: t.elevation.floating, outsideOnly: t.glass != nil))
        } else {
            content
                .background(look.surface, in: shape)
                .overlay { shape.stroke(look.border, lineWidth: 1) }
                .shadow(color: Color.black.opacity(0.3), radius: 16, x: 0, y: 6)
        }
    }
}
#endif
