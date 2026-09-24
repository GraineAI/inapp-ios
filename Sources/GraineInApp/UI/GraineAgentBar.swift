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

/// What the bar hears that GraineVoice does not publish: the dashboard's appearance, and a refused microphone.
final class GraineAgentBarModel: ObservableObject, GraineListener {
    @Published var appearance: [String: Any] = [:]
    @Published var micDenied = false

    init(graine: GraineInApp) {
        if let session = graine.session { appearance = session.appearance }
        graine.addListener(self)
    }

    func onSessionReady(_ session: GraineSessionConfig) {
        appearance = session.appearance
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
        .background(palette.surface, in: RoundedRectangle(cornerRadius: min(26, radius + 8), style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: min(26, radius + 8), style: .continuous).stroke(palette.border, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.3), radius: 16, x: 0, y: 6)
    }

    private var label: some View {
        let input = statusInput
        return HStack(spacing: 11) {
            avatar
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(palette.text)
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
                    palette.chip
                }
            }
            .frame(width: 38, height: 38)
            .clipShape(Circle())
            .accessibilityHidden(true)
        } else {
            ZStack {
                Circle().fill(accentColor)
                Text("✦")
                    .font(.system(size: 16))
                    .foregroundColor(onAccentColor)
            }
            .frame(width: 38, height: 38)
            .accessibilityHidden(true)
        }
    }

    /// While it is coming up the status line IS the loader the brand chose, with its words for the moment.
    @ViewBuilder
    private func status(_ input: BarStatus.Input) -> some View {
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
    private var muteButton: some View {
        Button(action: { voice.setMuted(!voice.muted) }) {
            Text(voice.muted ? "🔇" : "🎙")
                .font(.system(size: 16))
                .frame(width: 38, height: 38)
                .background(voice.muted ? palette.danger : palette.chip, in: Circle())
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
            Text(glyph)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(live ? .white : onAccentColor)
                .frame(width: 38, height: 38)
                .background(live ? palette.danger : accentColor, in: Circle())
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
