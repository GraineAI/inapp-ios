#if os(iOS)
import SwiftUI
import UIKit

/**
 * A CALL SCREEN for while your app is in the foreground, drawn in the brand's
 * design (the session's `call` tokens; contract/DESIGN.md "Call screen") in
 * every moment of a call: a scheduled call ringing ("Scheduled call" — Graine
 * rang it at a time booked earlier), any other call ringing, a call the
 * customer placed or answered connecting, on the call, ended, and missed — a
 * ring nobody answered, kept with Close and Call back for thirty seconds
 * (`GraineCalls.missedCall`).
 *
 * Edge to edge, in the brand's look: its backdrop (a colour, a gradient, a
 * mesh of glows that drifts, or its avatar blurred under a scrim), its layout,
 * the avatar the brand chose in its shape and size with the ring it wears, the
 * name and status in the design's faces, the line being said, the agent's
 * voice as bars, a wave or an orb, and the buttons in the design's style,
 * shape, size and colours, in the SDK's own icons. Each moment can have a look
 * of its own; the screen fades from one to the next. Everything that moves
 * stops when the screen is not visible, under Reduce Motion, or when the
 * design has no motion; a connected call nobody touches lets its backdrop come
 * to rest after ten seconds. A push that woke a closed app draws from the last
 * session the device kept; before any session, Graine Classic's screen.
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

    /// Whether the status bar over the call screen wants light icons: the call's agent's screen is in light ink (DESIGN.md).
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

/// GraineCalls as the screen draws it: the moment and what the call says.
struct GraineCallScreen: View {
    @ObservedObject var calls: GraineCalls
    let graine: GraineInApp?
    /// Observed so the design's typeface redraws the screen when it lands.
    @ObservedObject var fonts: GraineFontStore
    @StateObject private var model: GraineCallDesignModel
    @State private var failedLogo: String? = nil
    @Environment(\.colorScheme) private var colorScheme
    private let deviceDark: Bool?

    init(calls: GraineCalls, graine: GraineInApp?, fonts: GraineFontStore, deviceDark: Bool? = nil) {
        _calls = ObservedObject(wrappedValue: calls)
        self.graine = graine
        _fonts = ObservedObject(wrappedValue: fonts)
        self.deviceDark = deviceDark
        _model = StateObject(wrappedValue: GraineCallDesignModel(graine: graine))
    }

    private var theme: GraineThemeTokens? { model.design?.tokens(deviceDark: deviceDark ?? (colorScheme == .dark)) }

    private var dash: GraineNativeAppearance {
        Appearance.resolve(model.appearance, accent: Appearance.defaultAccent, heading: "Assistant", origin: graine?.config.baseUrl)
    }

    private var state: CallScreenState {
        let missed = CallScreen.phase(calls.state, missedPending: calls.missedCall != nil) == .missed
        let hosted = missed ? (calls.missedCall?.hosted ?? calls.hosted) : calls.hosted
        var ending = CallEnding.normal
        if case .ended(let reason) = calls.state { ending = CallEnding(reason) }
        let name: String
        if missed, let m = calls.missedCall, !m.callerName.isEmpty { name = m.callerName } else { name = calls.callerName.isEmpty ? dash.heading : calls.callerName }
        return CallScreenState(
            moment: CallScreen.moment(calls.state, direction: calls.direction, hosted: hosted, missed: missed, reconnecting: calls.isReconnecting),
            name: name, muted: calls.muted, speakerOn: calls.speakerOn, agentSpeaking: calls.agentSpeaking,
            // Until the call reports a level, the voice moves with `agentSpeaking`.
            agentLevel: calls.agentLevelHeard ? calls.agentLevel : nil,
            caption: calls.caption, connectedAt: calls.connectedAt, ending: ending
        )
    }

    var body: some View {
        let logo = dash.logoUrl.flatMap { $0 == failedLogo ? nil : $0 }
        CallScreenCanvas(
            state: state,
            call: CallScreen.tokens(theme),
            theme: theme,
            type: theme.map { GraineType(font: $0.font, names: graine?.config.fonts ?? [:], faces: fonts.faces) },
            avatar: CallAvatarSource(logoUrl: logo, plate: dash.logoPlate, accent: theme?.colors.accent ?? dash.accent,
                                     border: theme?.colors.border ?? "#E5E4E0", borderWidth: theme?.shape.borderWidth ?? 1),
            actions: CallScreenActions(
                answer: { calls.answer() }, decline: { calls.end() }, end: { calls.end() },
                mute: { calls.setMuted(!calls.muted) }, speaker: { calls.setSpeaker(!calls.speakerOn) },
                close: { calls.dismissMissedCall() }, callBack: { _ = calls.callBack() }
            ),
            restylesStatusBar: deviceDark != nil,
            onLogoFailed: { failedLogo = $0 }
        )
    }
}

// MARK: - The screen, from values

/// What the call screen shows, as plain values — what GraineCalls says, or a preview's.
struct CallScreenState: Equatable {
    var moment: CallMoment
    var name: String
    var muted = false
    var speakerOn = false
    var agentSpeaking = false
    /// How loud the agent is as it is heard, 0–1 (GraineCalls.agentLevel); nil until the call reports one.
    var agentLevel: Double? = nil
    var caption: GraineCaption? = nil
    var connectedAt: Date? = nil
    var ending: CallEnding = .normal
    /// Whether the chat can be opened during this call. This SDK holds the chat down during a native call, so never.
    var transcript = false
}

/// What the screen's buttons do.
struct CallScreenActions {
    var answer: () -> Void = {}
    var decline: () -> Void = {}
    var end: () -> Void = {}
    var mute: () -> Void = {}
    var speaker: () -> Void = {}
    var close: () -> Void = {}
    var callBack: () -> Void = {}
}

/// The brand's logo and its plate.
struct CallAvatarSource {
    var logoUrl: String?
    var plate: GraineLogoPlate = .accent
    var accent: String = Appearance.defaultAccent
    var border: String = "#E5E4E0"
    var borderWidth: Double = 1
}

/**
 * The drawn level of the agent's voice, eased up over 60 ms and down over
 * 240: the call's own level (`voice`, already on the visualiser's scale)
 * once it reports one, else the speech-like movement while the agent speaks.
 */
final class CallLevelMeter: ObservableObject {
    private var value = 0.0
    private var last: Date?

    func level(at now: Date, speaking: Bool, voice: Double? = nil, since start: Date) -> Double {
        let target = voice ?? (speaking ? CallScreen.speakingLevel(now.timeIntervalSince(start) * 1000) : 0)
        let dt = last.map { now.timeIntervalSince($0) * 1000 } ?? 1_000
        last = now
        value = CallScreen.smoothLevel(value, toward: target, dtMs: min(1_000, max(0, dt)))
        if value < 0.002 && target == 0 { value = 0 }
        return value
    }
}

/**
 * The call screen drawn from values — the moment, the name, the call's
 * switches — in the tokens' look. `frozenMs` draws every animation as it is
 * that many milliseconds in, and moves nothing: a preview, or a picture.
 */
struct CallScreenCanvas: View {
    let state: CallScreenState
    let call: GraineCallTokens
    let theme: GraineThemeTokens?
    let type: GraineType?
    var avatar = CallAvatarSource()
    var actions = CallScreenActions()
    /// The SDK presented this screen itself: it keeps the status bar in the moment's ink.
    var restylesStatusBar = false
    var onLogoFailed: (String) -> Void = { _ in }
    /// Every animation drawn as it is this far in (ms), still; nil: live.
    var frozenMs: Double? = nil
    /// The clock the timer reads; nil: now.
    var now: Date? = nil
    /// The safe area to lay out in, for a picture drawn off screen; nil: the screen's own.
    var insets: EdgeInsets? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotionSetting
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = true
    @State private var began = Date()
    @State private var lastTouch = Date()
    @State private var rested = false
    @StateObject private var meter = CallLevelMeter()

    private var look: GraineCallLook { CallScreen.look(call, state.moment) }
    private var layout: CallScreen.LayoutSpec { CallScreen.layout(call.layout) }

    /// The design's motion after Reduce Motion: 0 is none.
    private var motionMs: Double {
        guard let motion = theme?.motion else { return GraineThemeTokens.Motion.reduced(reduceMotionSetting) ? 0 : 200 }
        return motion.effectiveDurationMs(reduceMotion: GraineThemeTokens.Motion.reduced(reduceMotionSetting))
    }

    /// Whether anything may move at all: the design and the phone allow it, the screen is visible, it is not a still.
    private var moves: Bool { motionMs > 0 && frozenMs == nil && visible && scenePhase == .active }

    private var fade: Animation? {
        motionMs > 0 ? (theme?.motion.animation(reduceMotion: reduceMotionSetting) ?? .easeInOut(duration: motionMs / 1000)) : nil
    }

    var body: some View {
        GeometryReader { geo in
            // A picture drawn off screen lays itself out in the insets it was given, the backdrop under them.
            let given = self.insets
            let insets = given ?? geo.safeAreaInsets
            let inner = given.map { CGSize(width: geo.size.width - $0.leading - $0.trailing, height: geo.size.height - $0.top - $0.bottom) } ?? geo.size
            let full = CGSize(width: inner.width + insets.leading + insets.trailing, height: inner.height + insets.top + insets.bottom)
            ZStack(alignment: .topLeading) {
                backdrop(full: full, insets: insets, content: inner)
                    .frame(width: full.width, height: full.height)
                    .offset(x: given == nil ? -insets.leading : 0, y: given == nil ? -insets.top : 0)
                    .id(state.moment)
                    .transition(.opacity)
                    .accessibilityHidden(true)
                content(size: inner)
                    .frame(width: inner.width, height: inner.height)
                    .offset(x: given?.leading ?? 0, y: given?.top ?? 0)
            }
            .animation(fade, value: state.moment)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { touched() })
        .background(CallStatusBarStyler(darkInterface: CallScreen.lightStatusBar(look), enabled: restylesStatusBar))
        .accessibilityElement(children: .contain)
        .onAppear { visible = true; touched() }
        .onDisappear { visible = false }
        .onChange(of: state.moment) { _ in touched() }
        .task(id: lastTouch) {
            // A connected call nobody touches lets its backdrop come to rest: the timeline then stops.
            rested = false
            guard state.moment == .connected else { return }
            try? await Task.sleep(nanoseconds: UInt64((CallScreen.Motion.idleMs + CallScreen.Motion.settleMs) * 1_000_000))
            if !Task.isCancelled { rested = true }
        }
    }

    private func touched() {
        lastTouch = Date()
        began = lastTouch
        rested = false
    }

    // MARK: The backdrop

    @ViewBuilder private func backdrop(full: CGSize, insets: EdgeInsets, content: CGSize) -> some View {
        let b = look.backdrop
        let moving = moves && b.motion != "none" && b.type != "solid" && !rested
        if let frozen = frozenMs {
            backdropFrame(b, full: full, insets: insets, content: content, t: frozen, rest: 0)
        } else if moving {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving)) { context in
                backdropFrame(b, full: full, insets: insets, content: content,
                              t: context.date.timeIntervalSince(began) * 1000, rest: restShare(at: context.date))
            }
        } else {
            backdropFrame(b, full: full, insets: insets, content: content, t: 0, rest: 0)
        }
    }

    /// How far a connected call nobody touched has come to rest: nothing for ten seconds, then all of it over 600 ms.
    private func restShare(at date: Date) -> Double {
        guard state.moment == .connected else { return 0 }
        let idle = date.timeIntervalSince(lastTouch) * 1000 - CallScreen.Motion.idleMs
        return idle <= 0 ? 0 : min(1, idle / CallScreen.Motion.settleMs)
    }

    private func backdropFrame(_ b: GraineCallLook.Backdrop, full: CGSize, insets: EdgeInsets, content: CGSize, t: Double, rest: Double) -> some View {
        let w = Double(full.width), h = Double(full.height)
        let atRest = CallScreen.backdropFrame(b, w: w, h: h, t: 0)
        let f = rest > 0 ? CallScreen.settle(CallScreen.backdropFrame(b, w: w, h: h, t: t), toward: atRest, by: rest)
            : CallScreen.backdropFrame(b, w: w, h: h, t: t)
        return CallBackdropView(backdrop: b, frame: f, size: full,
                                avatarCentre: avatarCentre(content: content, insets: insets),
                                avatarSize: CGFloat(call.avatarSize),
                                face: { size in avatarFace(size: size) })
    }

    /// Where the avatar's centre is on the whole screen, for the blurred avatar behind everything.
    private func avatarCentre(content: CGSize, insets: EdgeInsets) -> CGPoint {
        let a = CGFloat(call.avatarSize * max(layout.avatar, 0.5))
        let side = CGFloat(CallScreen.Screen.side)
        var x = insets.leading + content.width / 2
        var y = insets.top + CGFloat(layout.top) + a / 2
        if layout.leading { x = insets.leading + side + a / 2 }
        if layout.card { y += CGFloat(CallScreen.Screen.cardPadding) }
        if layout.nameFirst || layout.avatar == 0 { y = insets.top + content.height * 0.42 }
        return CGPoint(x: x, y: y)
    }

    // MARK: The content

    private func content(size: CGSize) -> some View {
        let side = CGFloat(CallScreen.Screen.side)
        let bottomCaption = captionShown && call.captionPosition == "bottom"
        return VStack(spacing: 0) {
            if layout.nameFirst {
                orbColumn(width: size.width - 2 * side)
            } else {
                Spacer().frame(height: CGFloat(layout.top))
                if layout.card {
                    identity(width: size.width - 2 * side - 2 * CGFloat(CallScreen.Screen.cardPadding))
                        .padding(CGFloat(CallScreen.Screen.cardPadding))
                        .background(RoundedRectangle(cornerRadius: CGFloat(CallScreen.Screen.cardRadius), style: .continuous)
                            .fill(Color.graineHex(look.captionFill).opacity(max(look.captionFillAlpha, CallScreen.Screen.cardMinAlpha))))
                } else {
                    identity(width: size.width - 2 * side)
                }
                Spacer(minLength: 0)
            }
            if bottomCaption {
                caption(width: size.width - 2 * side)
                    .padding(.bottom, CGFloat(CallScreen.Screen.captionAboveButtons))
            }
            buttons(width: size.width - 2 * side)
                .padding(.bottom, CGFloat(CallScreen.Screen.buttonsBottom))
        }
        .padding(.horizontal, side)
    }

    private var captionShown: Bool {
        guard state.moment == .connected, call.captions, let line = state.caption else { return false }
        return !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The avatar, name, status, voice and a middle caption — every layout but the orb.
    private func identity(width: CGFloat) -> some View {
        let lead = layout.leading
        let avatarSize = CGFloat((call.avatarSize * layout.avatar).rounded())
        return VStack(alignment: lead ? .leading : .center, spacing: 0) {
            if avatarSize > 0 {
                avatarBlock(size: avatarSize, orbLayout: false)
                Spacer().frame(height: CGFloat(layout.nameGap))
            }
            nameText.frame(width: width, alignment: lead ? .leading : .center)
            statusText
                .frame(width: width, alignment: lead ? .leading : .center)
                .padding(.top, CGFloat(CallScreen.Screen.statusGap))
            voiceStrip.frame(width: width, alignment: lead ? .leading : .center)
            if captionShown && call.captionPosition == "middle" {
                caption(width: width).padding(.top, CGFloat(CallScreen.Screen.captionGap))
            }
        }
    }

    /// The orb layout: the name and status first, the avatar in its orb centred in the space left above the buttons.
    private func orbColumn(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer().frame(height: CGFloat(layout.top))
            nameText.frame(width: width)
            statusText.frame(width: width).padding(.top, CGFloat(CallScreen.Screen.statusGap))
            voiceStrip.frame(width: width)
            Spacer(minLength: 12)
            avatarBlock(size: CGFloat((call.avatarSize * layout.avatar).rounded()), orbLayout: true)
            if captionShown && call.captionPosition == "middle" {
                caption(width: width).padding(.top, 24)
            }
            Spacer(minLength: 12)
        }
    }

    private var nameText: some View {
        let size = call.nameSize
        return Text(state.name)
            .font(type?.heading(size, call.nameWeight) ?? .system(size: CGFloat(size), weight: GraineTypeface.swiftUIWeight(call.nameWeight)))
            .tracking(type?.titleTracking(size) ?? 0)
            .foregroundColor(.graineHex(look.text))
            .lineLimit(layout.nameLines)
            .multilineTextAlignment(layout.leading ? .leading : .center)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var statusText: some View {
        let font = type?.body(call.statusSize, call.statusWeight)
            ?? .system(size: CGFloat(call.statusSize), weight: GraineTypeface.swiftUIWeight(call.statusWeight))
        Group {
            if state.moment == .connected, call.timer, let since = state.connectedAt {
                if let fixed = now {
                    Text(words(elapsedMs: fixed.timeIntervalSince(since) * 1000))
                } else {
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        Text(words(elapsedMs: context.date.timeIntervalSince(since) * 1000))
                    }
                }
            } else {
                Text(words(elapsedMs: nil))
            }
        }
        .font(font)
        .monospacedDigit()
        .foregroundColor(.graineHex(look.textMuted))
        .lineLimit(1)
        .multilineTextAlignment(layout.leading ? .leading : .center)
    }

    private func words(elapsedMs: Double?) -> String {
        CallScreen.statusWords(call, state.moment, elapsedMs: elapsedMs, muted: state.muted, speaking: state.agentSpeaking, ending: state.ending)
    }

    // MARK: The avatar

    private func avatarBlock(size: CGFloat, orbLayout: Bool) -> some View {
        let ring = CallScreen.ring(call, state.moment)
        let connected = state.moment == .connected
        let drawsOrb = orbLayout || (connected && call.visualizer == "orb")
        let span = orbLayout ? CGFloat(call.avatarSize * CallScreen.Screen.orbScale) : size
        return ZStack {
            if drawsOrb {
                animated(running: connected && moves) { t, level in
                    // Around the avatar as drawn; the orb layout's orb is the avatar's size token × 2.
                    CallOrbView(color: .graineHex(look.visualizerColor), avatar: orbLayout ? CGFloat(call.avatarSize) : size,
                                level: connected ? level : 0, orbLayout: orbLayout)
                }
            }
            if motionMs > 0 && ring != "none" {
                animated(running: moves) { t, level in
                    CallRingView(kind: ring, color: .graineHex(look.avatarRingColor), size: size, shape: call.avatarShape,
                                 t: t, level: level, connected: connected)
                }
            }
            avatarFace(size: size)
                .scaleEffect(connected && state.agentSpeaking && motionMs > 0 ? CGFloat(CallScreen.Screen.speakingScale) : 1)
                .animation(fade, value: state.agentSpeaking)
        }
        .frame(width: span, height: span)
        .accessibilityHidden(true)
    }

    /// The call's level on the visualiser's scale (theme.ts `callVoiceLevel()`, the design's sensitivity); nil until it reports one.
    private var voice: Double? {
        state.agentLevel.map { CallScreen.voiceLevel($0, sensitivity: call.visualizerSensitivity) }
    }

    /// `body(t, level)` live on a timeline while `running`, else still at the frozen time (or the start).
    @ViewBuilder private func animated<V: View>(running: Bool, @ViewBuilder _ body: @escaping (Double, Double) -> V) -> some View {
        if let frozen = frozenMs {
            body(frozen, voice ?? (state.agentSpeaking ? CallScreen.speakingLevel(frozen) : 0))
        } else if running {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !running)) { context in
                body(context.date.timeIntervalSince(began) * 1000,
                     meter.level(at: context.date, speaking: state.agentSpeaking, voice: voice, since: began))
            }
        } else {
            body(0, 0)
        }
    }

    /// The avatar's face at `size`: the logo on its plate, the glyph or the initial on `avatarFill`, in its shape.
    private func avatarFace(size: CGFloat) -> some View {
        CallAvatarFace(call: call, theme: theme, type: type, avatar: avatar, name: state.name, size: size, onLogoFailed: onLogoFailed)
    }

    // MARK: The voice

    @ViewBuilder private var voiceStrip: some View {
        if state.moment == .connected, call.visualizer == "bars" || call.visualizer == "wave" {
            animated(running: moves) { t, level in
                CallVoiceView(style: call.visualizer, color: .graineHex(look.visualizerColor), t: t, level: level)
            }
            .frame(height: CGFloat(CallScreen.Screen.visualizerHeight))
            .padding(.top, CGFloat(CallScreen.Screen.visualizerGap))
            .accessibilityHidden(true)
        }
    }

    // MARK: The caption

    @ViewBuilder private func caption(width: CGFloat) -> some View {
        if let line = state.caption {
            CallCaptionView(line: line, style: call.captionStyle, look: look, type: type,
                            strong: theme?.font.weights.strong ?? 600, leading: layout.leading, width: width)
                .transition(.opacity)
                .animation(fade, value: line.text)
        }
    }

    // MARK: The buttons

    private func buttons(width: CGFloat) -> some View {
        let sizes = CallScreen.buttonSizes(call.buttonSize)
        let ended = state.moment == .ended
        return Group {
            switch state.moment {
            case .incoming, .scheduled:
                HStack(spacing: 0) {
                    button("decline", icon: .end, label: "Decline", size: sizes.big, share: width / 2, action: actions.decline)
                    button("answer", icon: .call, label: "Answer", size: sizes.big, share: width / 2, action: actions.answer)
                }
            case .missed:
                HStack(spacing: 0) {
                    button("close", icon: .close, label: "Close", size: sizes.big, share: width / 2, action: actions.close)
                    button("callback", icon: .call, label: "Call back", size: sizes.big, share: width / 2, action: actions.callBack)
                }
            default:
                let shown = CallScreen.controls(call, transcript: state.transcript)
                let share = width / CGFloat(max(1, shown.count))
                HStack(spacing: 0) {
                    ForEach(shown, id: \.self) { name in control(name, size: sizes.button, share: share) }
                }
                .opacity(ended ? CallScreen.Screen.endedAlpha : 1)
                .disabled(ended)
            }
        }
        .animation(fade, value: state.moment)
    }

    @ViewBuilder private func control(_ name: String, size: Double, share: CGFloat) -> some View {
        switch name {
        case "mute":
            button("mute", icon: state.muted ? .micOff : .mic, label: state.muted ? "Unmute" : "Mute", size: size, share: share,
                   on: state.muted, action: actions.mute)
        case "speaker":
            button("speaker", icon: .speaker, label: "Speaker", size: size, share: share, on: state.speakerOn, action: actions.speaker)
        default:
            button("end", icon: .end, label: "End", size: size, share: share, end: true, action: actions.end)
        }
    }

    private func button(_ name: String, icon: GraineIconName, label: String, size: Double, share: CGFloat,
                        on: Bool? = nil, end: Bool = false, action: @escaping () -> Void) -> some View {
        let frame = CallScreen.buttonFrame(shape: call.buttonShape, size: size, share: Double(share), end: end,
                                           endShape: call.endShape, on: on == true)
        return CallButtonView(
            colours: look.actions[name], icon: icon, label: label, frame: frame,
            iconSize: CGFloat(CallScreen.buttonSizes(call.buttonSize).icon), showsLabel: call.buttonLabels == "below",
            labelColour: .graineHex(look.textMuted), labelFont: type?.body(CallScreen.Screen.labelSize, theme?.font.weights.body ?? 400) ?? .system(size: 13),
            iconStyle: theme?.icons.style ?? "outline", iconStroke: theme?.icons.stroke ?? 2, on: on, fade: fade,
            lightInk: look.ink == "light", frosted: frozenMs == nil, action: action
        )
        .frame(width: share)
    }
}

// MARK: - Pieces

/// The fill behind everything, in one moment's look and frame.
struct CallBackdropView<Face: View>: View {
    let backdrop: GraineCallLook.Backdrop
    let frame: CallScreen.Frame
    let size: CGSize
    let avatarCentre: CGPoint
    let avatarSize: CGFloat
    let face: (CGFloat) -> Face

    var body: some View {
        let w = max(1, size.width), h = max(1, size.height)
        let stops = backdrop.stops.map { Gradient.Stop(color: .graineHex($0.color), location: CGFloat($0.at)) }
        let line = frame.line
        let linear = LinearGradient(stops: stops, startPoint: UnitPoint(x: line.x0 / Double(w), y: line.y0 / Double(h)),
                                    endPoint: UnitPoint(x: line.x1 / Double(w), y: line.y1 / Double(h)))
        ZStack {
            switch backdrop.type {
            case "linear":
                linear
            case "radial":
                RadialGradient(stops: stops, center: UnitPoint(x: frame.radial.cx / Double(w), y: frame.radial.cy / Double(h)),
                               startRadius: 0, endRadius: CGFloat(frame.radial.r))
            case "mesh":
                if let image = CallMeshBitmap.image(frame.mesh) {
                    Image(uiImage: image).resizable().interpolation(.high)
                } else {
                    Color.graineHex(backdrop.stops.first?.color)
                }
            case "blurred-avatar":
                linear
                face(avatarSize * 4)
                    .scaleEffect(CGFloat(frame.avatar.scale))
                    .position(x: avatarCentre.x + CGFloat(frame.avatar.dx), y: avatarCentre.y + CGFloat(frame.avatar.dy))
                    .blur(radius: CGFloat(CallScreen.Motion.blur))
                linear.opacity(backdrop.scrim)
            default:
                Color.graineHex(backdrop.stops.first?.color)
            }
        }
        .frame(width: w, height: h)
        .clipped()
    }
}

/// A mesh's bitmap: the contract's weighted glows at each pixel's centre, to be scaled up smoothly.
enum CallMeshBitmap {
    /// Half again the contract's floor (32 × 64): a phone-sized stretch shows no bands.
    static let cols = CallScreen.Motion.meshCols * 3 / 2
    static let rows = CallScreen.Motion.meshRows * 3 / 2

    static func image(_ glows: [CallScreen.Glow], cols: Int = CallMeshBitmap.cols, rows: Int = CallMeshBitmap.rows) -> UIImage? {
        let g = glows.map { (u: $0.u, v: $0.v, rgb: CallScreen.channels($0.color)) }
        var bytes = [UInt8](repeating: 255, count: cols * rows * 4)
        for y in 0..<rows {
            for x in 0..<cols {
                let c = CallScreen.meshRGB(g, u: (Double(x) + 0.5) / Double(cols), v: (Double(y) + 0.5) / Double(rows))
                let i = (y * cols + x) * 4
                bytes[i] = UInt8(max(0, min(255, JSON.jsRound(c.0))))
                bytes[i + 1] = UInt8(max(0, min(255, JSON.jsRound(c.1))))
                bytes[i + 2] = UInt8(max(0, min(255, JSON.jsRound(c.2))))
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = CGImage(width: cols, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cols * 4, space: space,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                               decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// The avatar's outline: fully round, continuous corners at 30%, or corners at 25% of the size.
struct CallAvatarShape: Shape {
    let kind: String

    func path(in rect: CGRect) -> Path {
        switch kind {
        case "squircle": return RoundedRectangle(cornerRadius: rect.height * 0.30, style: .continuous).path(in: rect)
        case "rounded-square": return RoundedRectangle(cornerRadius: rect.height * 0.25, style: .circular).path(in: rect)
        default: return Circle().path(in: rect)
        }
    }
}

/// The avatar itself: the logo whole on its plate, the launcher glyph, or the call name's first letter, on `avatarFill`.
struct CallAvatarFace: View {
    let call: GraineCallTokens
    let theme: GraineThemeTokens?
    let type: GraineType?
    let avatar: CallAvatarSource
    let name: String
    let size: CGFloat
    var onLogoFailed: (String) -> Void = { _ in }

    var body: some View {
        let shape = CallAvatarShape(kind: call.avatarShape)
        let content = CallScreen.avatar(call, glyph: theme?.icons.launcher, logoUrl: avatar.logoUrl, name: name)
        let initial = Text(CallScreen.initials(name))
            .font(type?.heading(Double(size) * 0.4, theme?.font.weights.title ?? 600) ?? .system(size: size * 0.4, weight: .semibold))
            .foregroundColor(.graineHex(call.avatarText))
        let plate = DesignRules.logoPlateLook(avatar.plate, accent: avatar.accent, border: avatar.border, borderWidth: avatar.borderWidth)
        let isLogo: Bool = { if case .logo = content { return true }; return false }()
        return ZStack {
            shape.fill(Color.graineHex(isLogo ? plate.fill : call.avatarFill))
            switch content {
            case .glyph(let glyph):
                GraineGlyphView(glyph: glyph, stroke: theme?.icons.stroke ?? 2, color: .graineHex(call.avatarText), size: size * 0.46, fallback: initial)
            case .logo(let url):
                AsyncImage(url: URL(string: url)) { phase in
                    switch phase {
                    case .success(let image):
                        let box = CGFloat(DesignRules.logoBox(call.avatarShape == "rounded-square" ? .roundedSquare : .circle, size: Double(size)))
                        image.resizable().scaledToFit().frame(width: box, height: box)
                    case .failure: initial.onAppear { onLogoFailed(url) }
                    default: Color.clear
                    }
                }
            case .initials:
                initial
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(Group {
            if isLogo, let outline = plate.outline {
                shape.stroke(Color.graineHex(outline.color), lineWidth: CGFloat(outline.width))
            }
        })
    }
}

/// The ring the avatar wears, at `t` ms (contract/DESIGN.md "Call screen" → Avatar).
struct CallRingView: View {
    let kind: String
    let color: Color
    let size: CGFloat
    let shape: String
    let t: Double
    /// The agent's voice, 0–1: a connected call's ring follows it.
    let level: Double
    let connected: Bool

    var body: some View {
        let outline = CallAvatarShape(kind: shape)
        ZStack {
            switch kind {
            case "glow":
                let g = CallScreen.Rings.glow
                let q = connected ? level : 0.5 - 0.5 * cos(2 * .pi * t / (2 * g.periodMs))
                Circle()
                    .fill(RadialGradient(stops: [
                        .init(color: color.opacity(g.alphaHigh), location: 0),
                        .init(color: color.opacity(g.alphaHigh), location: 0.62),
                        .init(color: color.opacity(0), location: 1),
                    ], center: .center, startRadius: 0, endRadius: size * CGFloat(g.reach) / 2))
                    .frame(width: size * CGFloat(g.reach), height: size * CGFloat(g.reach))
                    .scaleEffect(1 + CGFloat((g.breathe - 1) * q))
                    .opacity(0.5 + 0.5 * q)
            case "pulse", "ripple":
                let spec = kind == "pulse" ? CallScreen.Rings.pulse : CallScreen.Rings.ripple
                // On a connected call a growing ring only runs while the agent's voice is heard.
                if !connected || level > 0.05 {
                    ForEach(0..<spec.count, id: \.self) { i in
                        let p = (t + Double(i) * spec.periodMs / Double(spec.count)).truncatingRemainder(dividingBy: spec.periodMs) / spec.periodMs
                        outline.stroke(color, lineWidth: CGFloat(spec.width))
                            .frame(width: size, height: size)
                            .scaleEffect(1 + CGFloat((spec.scale - 1) * p))
                            .opacity(spec.alpha * (1 - p))
                    }
                }
            default:
                EmptyView()
            }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }
}

/// The orb around the avatar: two soft discs that grow with the voice.
struct CallOrbView: View {
    let color: Color
    let avatar: CGFloat
    let level: Double
    let orbLayout: Bool

    var body: some View {
        let v = CallScreen.Voice.self
        let across = avatar * CGFloat(orbLayout ? v.orbLayoutRest + v.orbLayoutGain * level : v.orbRest + v.orbGain * level)
        let disc = RadialGradient(stops: [
            .init(color: color.opacity(v.orbInnerAlpha), location: 0),
            .init(color: color.opacity(v.orbOuterAlpha), location: 0.55),
            .init(color: color.opacity(0), location: 1),
        ], center: .center, startRadius: 0, endRadius: across / 2)
        ZStack {
            Circle().fill(disc).frame(width: across, height: across)
            Circle().fill(disc).frame(width: across * CGFloat(v.orbInner), height: across * CGFloat(v.orbInner))
        }
        .allowsHitTesting(false)
    }
}

/// The agent's voice as bars or a wave, at `t` ms and `level` 0–1.
struct CallVoiceView: View {
    let style: String
    let color: Color
    let t: Double
    let level: Double

    var body: some View {
        let v = CallScreen.Voice.self
        if style == "bars" {
            HStack(alignment: .center, spacing: CGFloat(v.barGap)) {
                ForEach(0..<v.barCount, id: \.self) { i in
                    // Each wobbles between 35% and 100% of its height over 600 ms, bar i starting i × 110 ms late.
                    let wobble = level > 0 ? 0.675 - 0.325 * cos(2 * .pi * (t - Double(i) * 110) / (2 * v.barWobbleMs)) : 1
                    let height = v.barRest + (v.barMax - v.barRest) * level * v.barWeights[i] * wobble
                    Capsule().fill(color).frame(width: CGFloat(v.barWidth), height: CGFloat(max(v.barRest, height)))
                }
            }
            .frame(height: CGFloat(v.barMax))
        } else {
            CallWaveShape(phase: t / v.wavePeriodMs, amplitude: v.waveAmplitude * level, cycles: v.waveCycles)
                .stroke(color.opacity(level > 0 ? 1 : v.waveRestAlpha), style: StrokeStyle(lineWidth: CGFloat(v.waveStroke), lineCap: .round, lineJoin: .round))
                .frame(width: CGFloat(v.waveWidth), height: CGFloat(CallScreen.Screen.visualizerHeight))
        }
    }
}

/// A sine across the width that tapers to its ends and moves left one cycle every period.
struct CallWaveShape: Shape {
    let phase: Double
    let amplitude: Double
    let cycles: Double

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = Double(rect.width), mid = Double(rect.midY)
        let steps = 64
        for i in 0...steps {
            let x = w * Double(i) / Double(steps)
            let y = mid - amplitude * sin(.pi * x / w) * sin(2 * .pi * (cycles * x / w + phase))
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        return p
    }
}

/// The line being said, in the caption's style.
struct CallCaptionView: View {
    let line: GraineCaption
    let style: String
    let look: GraineCallLook
    let type: GraineType?
    let strong: Int
    let leading: Bool
    let width: CGFloat

    var body: some View {
        let words = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let ink = Color.graineHex(line.role == .agent ? look.text : look.textMuted)
        let backing = Color.graineHex(look.captionFill).opacity(look.captionFillAlpha)
        let size: Double = style == "plain" ? 17 : style == "card" ? 16 : 15
        let text = Text(words)
            .font(type?.body(size, strong) ?? .system(size: CGFloat(size), weight: .semibold))
            .lineSpacing(type?.bodyLineSpacing(size: size, weight: strong, lineHeight: size * 1.3) ?? CGFloat(size * 0.3))
            .foregroundColor(ink)
            .opacity(line.live ? VoiceBar.liveOpacity : 1)
            .truncationMode(.head)
        switch style {
        case "card":
            text.lineLimit(4)
                .multilineTextAlignment(leading ? .leading : .center)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .frame(width: width, alignment: leading ? .leading : .center)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(backing))
        case "subtitle":
            text.lineLimit(3)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(backing))
                .frame(width: width)
        case "bubble":
            let agent = line.role == .agent
            text.lineLimit(4)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(CallBubbleShape(radius: 18, tail: 6, tailLeading: agent).fill(backing))
                .frame(maxWidth: width * 0.85, alignment: agent ? .leading : .trailing)
                .frame(width: width, alignment: agent ? .leading : .trailing)
        default:
            text.lineLimit(4)
                .multilineTextAlignment(leading ? .leading : .center)
                .frame(width: width, alignment: leading ? .leading : .center)
        }
    }
}

/// A chat bubble: corners of `radius`, the speaker's lower corner `tail` (iOS 15 has no uneven rounded rectangle).
struct CallBubbleShape: Shape {
    let radius: CGFloat
    let tail: CGFloat
    let tailLeading: Bool

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height / 2, rect.width / 2)
        let t = min(tail, r)
        let bl = tailLeading ? t : r
        let br = tailLeading ? r : t
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        p.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// A button in the moment's look: filled, glass or an outline, in its shape, with its label under it or none.
struct CallButtonView: View {
    let colours: GraineCallLook.Action
    let icon: GraineIconName
    let label: String
    let frame: CallScreen.ButtonFrame
    let iconSize: CGFloat
    let showsLabel: Bool
    let labelColour: Color
    let labelFont: Font
    let iconStyle: String
    let iconStroke: Double
    /// Mute and speaker: on or off. Nil for a button that is not a switch.
    let on: Bool?
    let fade: Animation?
    /// The moment's ink is light: glass frosts dark under it (and light under dark ink), so it only adds contrast.
    var lightInk = true
    /// Glass frosts the backdrop with a material; a still picture (which cannot draw one) shows the fill alone.
    var frosted = true
    let action: () -> Void

    var body: some View {
        let isOn = on == true
        let shape = RoundedRectangle(cornerRadius: CGFloat(frame.radius), style: frame.continuous ? .continuous : .circular)
        let ink = Color.graineHex(isOn ? colours.activeIcon : colours.icon)
        Button(action: action) {
            VStack(spacing: CGFloat(CallScreen.Screen.labelGap)) {
                ZStack {
                    face(shape, on: isOn)
                    GraineIconView(name: icon, style: iconStyle, stroke: iconStroke, color: ink, size: iconSize)
                }
                .frame(width: CGFloat(frame.width), height: CGFloat(frame.height))
                .animation(fade, value: isOn)
                if showsLabel {
                    Text(label)
                        .font(labelFont)
                        .foregroundColor(labelColour)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(on.map { $0 ? "On" : "Off" } ?? "")
    }

    @ViewBuilder private func face(_ shape: RoundedRectangle, on: Bool) -> some View {
        if on || colours.fillAlpha >= 1 {
            shape.fill(Color.graineHex(on ? colours.activeFill : colours.fill))
        } else if colours.fillAlpha <= 0 {
            shape.strokeBorder(Color.graineHex(colours.stroke ?? colours.icon), lineWidth: 1.5)
        } else if frosted {
            // Glass: the backdrop frosted behind the button (a material in the ink's opposite), tinted by the fill.
            shape.fill(Color.graineHex(colours.fill).opacity(colours.fillAlpha))
                .background(.ultraThinMaterial, in: shape)
                .environment(\.colorScheme, lightInk ? .dark : .light)
        } else {
            shape.fill(Color.graineHex(colours.fill).opacity(colours.fillAlpha))
        }
    }
}

/**
 * Keeps the presenting controller's status bar in the moment's ink: light
 * icons over light ink. Only for a screen the SDK presented itself, whose
 * design scheme is fixed by the presenter — an app's own presentation keeps
 * its own status bar.
 */
struct CallStatusBarStyler: UIViewRepresentable {
    let darkInterface: Bool
    let enabled: Bool

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard enabled else { return }
        DispatchQueue.main.async {
            var responder: UIResponder? = uiView
            while let r = responder, !(r is UIViewController) { responder = r.next }
            guard let controller = responder as? UIViewController else { return }
            let style: UIUserInterfaceStyle = darkInterface ? .dark : .light
            if controller.overrideUserInterfaceStyle != style {
                controller.overrideUserInterfaceStyle = style
                controller.setNeedsStatusBarAppearanceUpdate()
            }
        }
    }
}
#endif
