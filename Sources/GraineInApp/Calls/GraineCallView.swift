#if os(iOS)
import SwiftUI

/**
 * A CALL SCREEN for while your app is in the foreground, drawn in the brand's
 * design (the session's `call` tokens; contract/DESIGN.md "Call screen") in
 * every moment of a call: a scheduled call ringing ("Scheduled call" — Graine
 * rang it at a time booked earlier), any other call ringing, connecting, on
 * the call, ended, and missed — a ring nobody answered, kept with Close and
 * Call back for thirty seconds (`GraineCalls.missedCall`).
 *
 * Edge to edge: the background (or its gradient), the avatar the brand chose
 * — its logo on its plate, its launcher glyph or the call name's initial — in
 * the chosen shape, the name in the design's heading face, the status in the
 * brand's words, the timer, the line being said, and the controls in the
 * design's order and colours, in the SDK's own icons. A ring pulses out from
 * the avatar while it rings, and the avatar breathes while the agent speaks —
 * at the design's pace, and not at all under Reduce Motion. A push that woke a
 * closed app draws from the last session the device kept; before any session,
 * Graine Classic's screen.
 *
 * The system's own call screen covers the lock screen and the background;
 * present this over your UI when you want the call inside the app too:
 *
 *     .fullScreenCover(isPresented: .constant(calls.showsCallScreen)) { GraineCallView() }
 */
public struct GraineCallView: View {
    private let calls: GraineCalls
    private let graine: GraineInApp?
    private let deviceDark: Bool?

    /// The calls to draw; `GraineInApp.shared.calls` when nil. Drawn in the design of the agent the call is with.
    public init(calls: GraineCalls? = nil) {
        let drawn = calls ?? GraineInApp.shared.calls
        self.calls = drawn
        self.graine = drawn.callAgent ?? GraineInApp.current
        self.deviceDark = nil
    }

    /// The device's light or dark, fixed by a presenter that styles the status bar over the screen itself.
    init(calls: GraineCalls, deviceDark: Bool?) {
        self.calls = calls
        self.graine = calls.callAgent ?? GraineInApp.current
        self.deviceDark = deviceDark
    }

    public var body: some View {
        if let graine = graine {
            GraineCallScreen(calls: calls, graine: graine, fonts: graine.fonts, deviceDark: deviceDark)
        } else {
            GraineCallScreen(calls: calls, graine: nil, fonts: GraineFontStore(), deviceDark: deviceDark)
        }
    }

    /// Whether the status bar over the call screen wants light icons: the call's agent's call text is light (DESIGN.md).
    static func drawsDark(deviceDark: Bool?, graine: GraineInApp?) -> Bool {
        let theme = graine?.sessionOrCached?.design?.tokens(deviceDark: deviceDark)
        return CallScreen.lightStatusBar(CallScreen.tokens(theme))
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        CallScreen.elapsed(from: start, to: now)
    }

    static func endedText(_ reason: GraineCallEndReason) -> String {
        CallScreen.status(.ended(reason), direction: nil, call: SurfaceTokens.legacyCall, elapsed: nil, speaking: false)
    }
}

/// The design the call screen draws from: the session's, else the last one the device kept.
final class GraineCallDesignModel: ObservableObject, GraineListener {
    @Published var design: GraineDesign?
    @Published var appearance: [String: Any] = [:]

    init(graine: GraineInApp?) {
        if let session = graine?.sessionOrCached {
            design = session.design
            appearance = session.appearance
        }
        graine?.addListener(self)
    }

    func onSessionReady(_ session: GraineSessionConfig) {
        design = session.design
        appearance = session.appearance
    }
}

/// The avatar's outline: fully round, continuous corners at 30%, or corners at 25% of the size.
private struct CallAvatarShape: Shape {
    let kind: String

    func path(in rect: CGRect) -> Path {
        switch kind {
        case "squircle": return RoundedRectangle(cornerRadius: rect.height * 0.30, style: .continuous).path(in: rect)
        case "rounded-square": return RoundedRectangle(cornerRadius: rect.height * 0.25, style: .circular).path(in: rect)
        default: return Circle().path(in: rect)
        }
    }
}

struct GraineCallScreen: View {
    @ObservedObject var calls: GraineCalls
    let graine: GraineInApp?
    /// Observed so the design's typeface redraws the screen when it lands.
    @ObservedObject var fonts: GraineFontStore
    @StateObject private var model: GraineCallDesignModel
    @State private var failedLogo: String? = nil
    @State private var ringBegan = Date()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let deviceDark: Bool?

    static let avatarSize: CGFloat = 112

    init(calls: GraineCalls, graine: GraineInApp?, fonts: GraineFontStore, deviceDark: Bool? = nil) {
        _calls = ObservedObject(wrappedValue: calls)
        self.graine = graine
        _fonts = ObservedObject(wrappedValue: fonts)
        self.deviceDark = deviceDark
        _model = StateObject(wrappedValue: GraineCallDesignModel(graine: graine))
    }

    private var theme: GraineThemeTokens? { model.design?.tokens(deviceDark: deviceDark ?? (colorScheme == .dark)) }
    private var t: GraineCallTokens { CallScreen.tokens(theme) }

    private var type: GraineType? {
        theme.map { GraineType(font: $0.font, names: graine?.config.fonts ?? [:], faces: fonts.faces) }
    }

    private var dash: GraineNativeAppearance {
        Appearance.resolve(model.appearance, accent: Appearance.defaultAccent, heading: "Assistant", origin: graine?.config.baseUrl)
    }

    private var logoUrl: String? {
        guard let url = dash.logoUrl, url != failedLogo else { return nil }
        return url
    }

    /// The design's motion after Reduce Motion: 0 is none.
    private var motionMs: Double {
        guard let motion = theme?.motion else { return reduceMotion ? 0 : 200 }
        return motion.effectiveDurationMs(reduceMotion: GraineThemeTokens.Motion.reduced(reduceMotion))
    }

    private var fade: Animation? {
        motionMs > 0 ? (theme?.motion.animation(reduceMotion: reduceMotion) ?? .easeInOut(duration: motionMs / 1000)) : nil
    }

    /// A call in some state, or a ring nobody answered (kept on screen to call back).
    private var phase: CallScreen.Phase {
        CallScreen.phase(calls.state, missedPending: calls.missedCall != nil)
    }

    private var ringing: Bool { phase == .call(.ringing) }

    /// The call name: the one the call carries — the agent's call name — else the Appearance heading.
    private var name: String {
        if phase == .missed, let missed = calls.missedCall, !missed.callerName.isEmpty { return missed.callerName }
        return calls.callerName.isEmpty ? dash.heading : calls.callerName
    }

    var body: some View {
        ZStack {
            background.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer().frame(height: 72)
                avatar
                Text(name)
                    .font(type?.heading(28, theme?.font.weights.title ?? 600) ?? .system(size: 28, weight: .semibold))
                    .tracking(type?.titleTracking(28) ?? 0)
                    .foregroundColor(.graineHex(t.text))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.top, 20)
                status
                    .font(type?.body(16, theme?.font.weights.body ?? 400) ?? .system(size: 16))
                    .monospacedDigit()
                    .foregroundColor(.graineHex(t.textMuted))
                    .lineLimit(1)
                    .padding(.top, 6)
                caption
                    .padding(.top, 36)
                Spacer(minLength: 0)
                controls
                    .padding(.bottom, 56)
                    .animation(fade, value: ringing)
                    .animation(fade, value: phase == .missed)
            }
            .padding(.horizontal, 24)
        }
        .accessibilityElement(children: .contain)
        .onChange(of: ringing) { if $0 { ringBegan = Date() } }
    }

    // MARK: Background

    @ViewBuilder private var background: some View {
        if let to = t.backgroundTo {
            LinearGradient(colors: [.graineHex(t.background), .graineHex(to)], startPoint: .top, endPoint: .bottom)
        } else {
            Color.graineHex(t.background)
        }
    }

    // MARK: Avatar

    private var avatar: some View {
        let size = GraineCallScreen.avatarSize
        let shape = CallAvatarShape(kind: t.avatarShape)
        let content = CallScreen.avatar(t, glyph: theme?.icons.launcher, logoUrl: logoUrl, name: name)
        let initial = Text(CallScreen.initials(name))
            .font(type?.heading(Double(size) * 0.4, theme?.font.weights.title ?? 600) ?? .system(size: size * 0.4, weight: .semibold))
            .foregroundColor(.graineHex(t.avatarText))
        let accent = theme?.colors.accent ?? dash.accent
        let plate = DesignRules.logoPlateLook(dash.logoPlate, accent: accent, border: theme?.colors.border ?? "#E5E4E0",
                                              borderWidth: theme?.shape.borderWidth ?? 1)
        let isLogo: Bool = { if case .logo = content { return true }; return false }()
        return ZStack {
            shape.fill(Color.graineHex(isLogo ? plate.fill : t.avatarFill))
            switch content {
            case .glyph(let glyph):
                GraineGlyphView(glyph: glyph, stroke: theme?.icons.stroke ?? 2, color: .graineHex(t.avatarText), size: size * 0.46, fallback: initial)
            case .logo(let url):
                AsyncImage(url: URL(string: url)) { phase in
                    switch phase {
                    case .success(let image):
                        let box = CGFloat(DesignRules.logoBox(t.avatarShape == "rounded-square" ? .roundedSquare : .circle, size: Double(size)))
                        image.resizable().scaledToFit().frame(width: box, height: box)
                    case .failure: initial.onAppear { failedLogo = url }
                    default: Color.clear
                    }
                }
            case .initials:
                initial
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay {
            if isLogo, let outline = plate.outline {
                shape.stroke(Color.graineHex(outline.color), lineWidth: CGFloat(outline.width))
            }
        }
        .background(halo(shape))
        .scaleEffect(calls.state == .active && calls.agentSpeaking && motionMs > 0 ? 1.06 : 1)
        .animation(motionMs > 0 ? (theme?.motion.animation(reduceMotion: reduceMotion) ?? .easeInOut(duration: 0.2)) : nil, value: calls.agentSpeaking)
        .accessibilityHidden(true)
    }

    /// Ringing: a ring 2 wide in `textMuted` grows from the avatar's edge to 1.35× while fading from 60% to nothing, every 1.6 s.
    @ViewBuilder private func halo(_ shape: CallAvatarShape) -> some View {
        if ringing && motionMs > 0 {
            TimelineView(.animation) { timeline in
                let progress = (timeline.date.timeIntervalSince(ringBegan) / 1.6).truncatingRemainder(dividingBy: 1)
                shape.stroke(Color.graineHex(t.textMuted), lineWidth: 2)
                    .scaleEffect(1 + 0.35 * progress)
                    .opacity(0.6 * (1 - progress))
            }
        }
    }

    // MARK: Status and caption

    @ViewBuilder private var status: some View {
        if phase == .missed {
            Text(t.statusText.missed)
        } else if calls.state == .active, t.timer, let since = calls.connectedAt {
            TimelineView(.periodic(from: since, by: 1)) { context in
                Text(CallScreen.status(.active, direction: calls.direction, call: t,
                                       elapsed: CallScreen.elapsed(from: since, to: context.date),
                                       speaking: calls.agentSpeaking, muted: calls.muted))
            }
        } else {
            Text(CallScreen.status(calls.state, direction: calls.direction, call: t, elapsed: nil,
                                   speaking: calls.agentSpeaking, hosted: calls.hosted, muted: calls.muted))
        }
    }

    /// On the call, with captions: the latest line, the agent's in `text` and the customer's in `textMuted`.
    @ViewBuilder private var caption: some View {
        if calls.state == .active, t.captions, let line = calls.caption,
           !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let weight = theme?.font.weights.strong ?? 600
            Text(line.text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(type?.body(17, weight) ?? .system(size: 17, weight: .semibold))
                .lineSpacing(type?.bodyLineSpacing(size: 17, weight: weight, lineHeight: 17 * 1.3) ?? 5)
                .foregroundColor(.graineHex(line.role == .agent ? t.text : t.textMuted))
                .opacity(line.live ? VoiceBar.liveOpacity : 1)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .truncationMode(.head)
                .transition(.opacity)
                .animation(fade, value: line.text)
        }
    }

    // MARK: Buttons

    @ViewBuilder private var controls: some View {
        if phase == .missed {
            HStack(spacing: 0) {
                button(label: "Close", icon: .close, fill: t.buttonFill, ink: t.buttonIcon, size: 72) { calls.dismissMissedCall() }
                    .frame(maxWidth: .infinity)
                button(label: "Call back", icon: .call, fill: t.callbackFill, ink: t.callbackIcon, size: 72) { calls.callBack() }
                    .frame(maxWidth: .infinity)
            }
        } else if ringing {
            HStack(spacing: 0) {
                button(label: "Decline", icon: .end, fill: t.declineFill, ink: t.declineIcon, size: 72) { calls.end() }
                    .frame(maxWidth: .infinity)
                button(label: "Answer", icon: .call, fill: t.acceptFill, ink: t.acceptIcon, size: 72) { calls.answer() }
                    .frame(maxWidth: .infinity)
            }
        } else {
            let ended: Bool = { if case .ended = calls.state { return true }; return false }()
            GeometryReader { geo in
                let shown = CallScreen.controls(t, transcript: false)
                let share = geo.size.width / CGFloat(max(1, shown.count))
                HStack(spacing: 0) {
                    ForEach(shown, id: \.self) { name in
                        control(name, share: share).frame(width: share)
                    }
                }
            }
            .frame(height: 64 + 8 + 18)
            .opacity(ended ? 0.4 : 1)
            .disabled(ended)
        }
    }

    /**
     * The call's own buttons. `chat` would open the agent's chat with the call
     * still on; this SDK holds the chat down during a native call (one
     * conversation at a time), so it is left out and the shares close up.
     */
    @ViewBuilder private func control(_ name: String, share: CGFloat) -> some View {
        switch name {
        case "mute":
            button(label: calls.muted ? "Unmute" : "Mute", icon: calls.muted ? .micOff : .mic,
                   fill: calls.muted ? t.buttonActiveFill : t.buttonFill, ink: calls.muted ? t.buttonActiveIcon : t.buttonIcon,
                   size: 64, on: calls.muted) { calls.setMuted(!calls.muted) }
        case "speaker":
            button(label: "Speaker", icon: .speaker,
                   fill: calls.speakerOn ? t.buttonActiveFill : t.buttonFill, ink: calls.speakerOn ? t.buttonActiveIcon : t.buttonIcon,
                   size: 64, on: calls.speakerOn) { calls.setSpeaker(!calls.speakerOn) }
        default:
            button(label: "End", icon: .end, fill: t.endFill, ink: t.endIcon, size: 64,
                   width: t.endShape == "pill" ? max(64, share - 8) : nil) { calls.end() }
        }
    }

    /// A disc (or a pill) with the SDK's icon at 30, and its label 8 under it.
    private func button(
        label: String, icon: GraineIconName, fill: String, ink: String, size: CGFloat,
        width: CGFloat? = nil, on: Bool? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Capsule().fill(Color.graineHex(fill)).frame(width: width ?? size, height: size)
                    GraineIconView(name: icon, style: theme?.icons.style ?? "outline", stroke: theme?.icons.stroke ?? 2,
                                   color: .graineHex(ink), size: 30)
                }
                Text(label)
                    .font(type?.body(13, theme?.font.weights.body ?? 400) ?? .system(size: 13))
                    .foregroundColor(.graineHex(t.textMuted))
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(on.map { $0 ? "On" : "Off" } ?? "")
    }
}
#endif
