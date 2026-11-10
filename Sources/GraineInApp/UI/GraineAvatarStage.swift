#if os(iOS)
import SwiftUI
import UIKit

/**
 * THE FACE STAGE — the agent's face edge to edge, with the call drawn over
 * it: the name, the role, the LIVE mark and the clock at the top; the line
 * being said, the component the agent drew and the call's buttons at the
 * bottom (contract/DESIGN.md "Face stage"). Give it the screen, or any area:
 *
 *     GraineAvatarStage(role: "AI care assistant", onChat: { showChat = true })
 *         .ignoresSafeArea()
 *
 * It places the voice bar's call by default (`calls: .native` places native
 * calls), mounts the engine when it appears if nothing has, and follows a
 * native call that rings or is placed whatever `calls` says. Before the face's
 * first frame, and on a call without one, the brand's picture of the agent
 * stands in its place. It never ends a call by going away: the call carries
 * on, voice-only.
 *
 * Every piece is public state (`GraineInApp.stage`): draw your own over
 * `GraineAvatarFace` instead, and anything you draw is drawn over the face.
 */
public struct GraineAvatarStage: View {
    let graine: GraineInApp?
    let options: GraineAvatarStageOptions

    /**
     * - Parameters:
     *   - graine: the instance; defaults to the one `GraineInApp.configure` made.
     *   - name: the header's name. Nil: the dashboard chat header's title, else the bar's heading.
     *   - role: the line under the name ("AI care assistant"). Nil: the chat header's subtitle, else none.
     *   - calls: what the Call button places — the voice bar's call, or a native call.
     *   - showsHeader, showsCaption, showsComponent, showsControls: each piece over the face; all by default.
     *   - autoAttach: mount the voice bar's engine when the stage appears, if nothing has.
     *   - onChat: your chat. The chat button is drawn only with one; a tap calls it.
     *   - onClose: a close control leading the header, for a stage your app shows full screen. It never ends a call:
     *     take the stage away there (and `stage.end()` first if leaving should hang up).
     */
    public init(
        graine: GraineInApp? = nil,
        name: String? = nil,
        role: String? = nil,
        calls: GraineStageCalls = .voice,
        showsHeader: Bool = true,
        showsCaption: Bool = true,
        showsComponent: Bool = true,
        showsControls: Bool = true,
        autoAttach: Bool = true,
        onChat: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.graine = graine
        options = GraineAvatarStageOptions(
            name: name, role: role, calls: calls, showsHeader: showsHeader, showsCaption: showsCaption,
            showsComponent: showsComponent, showsControls: showsControls, autoAttach: autoAttach, onChat: onChat,
            onClose: onClose
        )
    }

    public var body: some View {
        if let graine = graine ?? GraineInApp.current {
            GraineAvatarStageScreen(graine: graine, stage: graine.stage, fonts: graine.fonts, options: options)
        }
    }
}

struct GraineAvatarStageOptions {
    var name: String?
    var role: String?
    var calls: GraineStageCalls = .voice
    var showsHeader = true
    var showsCaption = true
    var showsComponent = true
    var showsControls = true
    var autoAttach = true
    var onChat: (() -> Void)?
    var onClose: (() -> Void)?
}

/// The stage's fixed look: it sits on video, so it is one look on every design (DESIGN.md "Face stage").
enum StageLook {
    static let backdrop = Color(red: 17 / 255, green: 17 / 255, blue: 17 / 255)
    static let live = "#DC2626"
    static let end = "#DC2626"
    static let accept = "#16A34A"
    static let button: CGFloat = 58
    static let bigButton: CGFloat = 70
    static let icon: CGFloat = 26
    static let picture: CGFloat = 96
    static let maxWidth: CGFloat = 560
}

struct GraineAvatarStageScreen: View {
    let graine: GraineInApp
    @ObservedObject var stage: GraineStage
    /// Observed so the design's typeface redraws the stage when it lands.
    @ObservedObject var fonts: GraineFontStore
    let options: GraineAvatarStageOptions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var failedPicture: String?

    /// The design's tokens, dark: the stage sits on video. Nil without a design.
    private var tokens: GraineThemeTokens? { graine.design?.tokens(deviceDark: true) }

    /**
     * The design's LIGHT look, for the stage's fills — the LIVE mark, End and Call. The dark look lightens its
     * colours for text on dark surfaces, too pale for a filled pill or button with white on it.
     */
    private var fills: GraineThemeTokens? { graine.design?.tokens(deviceDark: false) }

    var body: some View {
        let s = stage.state
        let t = tokens
        ZStack {
            StageLook.backdrop.ignoresSafeArea()
            picture(s)
            GraineAvatarFace().ignoresSafeArea()
            scrims
            VStack(spacing: 0) {
                if options.showsHeader { header(s, t) }
                Spacer(minLength: 0)
                bottom(s, t)
            }
        }
        .animation(t?.motion.animation(reduceMotion: reduceMotion) ?? (reduceMotion ? nil : .easeOut(duration: 0.2)), value: s.caption?.text)
        .animation(t?.motion.animation(reduceMotion: reduceMotion) ?? (reduceMotion ? nil : .easeOut(duration: 0.2)), value: s.phase)
        .onAppear {
            apply()
            if options.autoAttach && !graine.voice.isAttached { graine.voice.attach() }
            // While the stage is on screen, a page still loading is the customer's wait (GraineVoice.slowConnect).
            graine.voice.viewerAppeared()
        }
        .onDisappear { graine.voice.viewerDisappeared() }
        .onChange(of: options.name) { _ in apply() }
        .onChange(of: options.role) { _ in apply() }
        .onChange(of: options.calls) { _ in apply() }
        .onChange(of: options.onChat == nil) { _ in apply() }
    }

    private func apply() {
        stage.name = options.name
        stage.role = options.role
        stage.calls = options.calls
        stage.onChat = options.onChat
    }

    // MARK: - Behind the face

    /// The brand's picture of the agent, seen until the face's first frame and on a call without one.
    @ViewBuilder
    private func picture(_ s: GraineStageState) -> some View {
        let look = Appearance.resolve(graine.sessionOrCached?.appearance ?? [:], accent: Appearance.defaultAccent, heading: s.name, origin: graine.config.baseUrl)
        let initial = String(s.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased()
        ZStack {
            Circle().fill(Color.white.opacity(0.12))
            if let logo = look.logoUrl, failedPicture != logo, let url = URL(string: logo) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit().padding(StageLook.picture * 0.15)
                    case .failure:
                        Text(initial).onAppear { failedPicture = logo }
                    default:
                        Color.clear
                    }
                }
                .clipShape(Circle())
            } else {
                Text(initial.isEmpty ? "A" : initial)
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
            }
        }
        .frame(width: StageLook.picture, height: StageLook.picture)
        .accessibilityHidden(true)
    }

    /// Black at 60% fading to clear at the top; clear to 82% black at the bottom, behind the words and buttons.
    private var scrims: some View {
        VStack(spacing: 0) {
            if options.showsHeader {
                LinearGradient(colors: [Color.black.opacity(0.6), Color.black.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 170)
            }
            Spacer(minLength: 0)
            LinearGradient(
                stops: [
                    .init(color: Color.black.opacity(0), location: 0),
                    .init(color: Color.black.opacity(0.82), location: 0.34),
                    .init(color: Color.black.opacity(0.82), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: bottomScrimHeight)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// From 120 above the caption's top to the bottom edge — as tall as what the bottom holds.
    private var bottomScrimHeight: CGFloat {
        let s = stage.state
        var h: CGFloat = 28 + 34
        if options.showsControls { h += StageLook.bigButton }
        if options.showsComponent && (s.component != nil || s.componentPending) { h += 22 + 120 }
        if options.showsCaption && s.caption != nil { h += 22 + 80 }
        return h + 120
    }

    // MARK: - The header

    private func header(_ s: GraineStageState, _ t: GraineThemeTokens?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if let close = options.onClose {
                Button(action: close) {
                    GraineIconView(name: .close, style: t?.icons.style ?? "outline", stroke: t?.icons.stroke ?? 2, color: .white, size: 22)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(PlainButtonStyle())
                // A 44 target around a 22 icon: the icon sits 22 in, 12 before the name (DESIGN.md "Face stage").
                .padding(.horizontal, -11)
                .padding(.top, -10)
                .accessibilityLabel("Close")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name)
                    .font(nameFont(t))
                    .foregroundColor(.white)
                    .lineLimit(1)
                if let role = s.role {
                    Text(role)
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.86))
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            trailing(s, t)
                .padding(.top, 4)
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
    }

    private func nameFont(_ t: GraineThemeTokens?) -> Font {
        guard let t = t else { return .system(size: 21, weight: .bold) }
        return GraineType(font: t.font, names: graine.config.fonts, faces: fonts.faces).heading(21, max(t.font.weights.title, 600))
    }

    @ViewBuilder
    private func trailing(_ s: GraineStageState, _ t: GraineThemeTokens?) -> some View {
        if s.live {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(Color.white).frame(width: 6, height: 6)
                    Text("LIVE")
                        .font(.system(size: 13, weight: .bold))
                        .tracking(13 * 0.06)
                        .foregroundColor(.white)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 10)
                .background(Capsule().fill(Color.graineHex(fills?.colors.danger ?? StageLook.live, fallback: .red)))
                TimelineView(.periodic(from: Date(), by: 1)) { context in
                    Text(s.clock(now: context.date))
                        .font(.system(size: 13, weight: .bold).monospacedDigit())
                        .foregroundColor(.white)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Live")
        } else if !s.status.isEmpty {
            Text(s.status)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.86))
                .lineLimit(1)
        }
    }

    // MARK: - The bottom: the line being said, the component, the buttons

    private func bottom(_ s: GraineStageState, _ t: GraineThemeTokens?) -> some View {
        let hasComponent = s.component != nil || s.componentPending
        return VStack(spacing: 0) {
            if options.showsCaption, let line = s.caption {
                caption(line, t)
                    .padding(.bottom, options.showsComponent && hasComponent ? 14 : 22)
                    .transition(.graineRise)
            }
            if options.showsComponent {
                // Always mounted, so the voice bar (if the app shows one too) never draws the same component twice.
                GraineWidgetView(graine: graine)
                    .padding(.bottom, hasComponent ? 22 : 0)
            }
            if options.showsControls {
                controls(s, t)
            }
        }
        .frame(maxWidth: StageLook.maxWidth)
        .padding(.horizontal, 18)
        .padding(.bottom, 28)
    }

    private func caption(_ line: GraineStageCaption, _ t: GraineThemeTokens?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if line.who == .customer {
                Text("YOU")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(11 * 0.06)
                    .foregroundColor(.white.opacity(0.7))
            }
            Text("\u{201C}\(line.text.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}")
                .font(captionFont(t))
                .foregroundColor(.white)
                .lineSpacing(18 * 0.38)
                .lineLimit(3)
                .truncationMode(.head)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .opacity(line.final ? 1 : 0.75)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
    }

    private func captionFont(_ t: GraineThemeTokens?) -> Font {
        guard let t = t else { return .system(size: 18, weight: .medium) }
        return GraineType(font: t.font, names: graine.config.fonts, faces: fonts.faces).body(18, 500)
    }

    private func controls(_ s: GraineStageState, _ t: GraineThemeTokens?) -> some View {
        HStack(spacing: 0) {
            ForEach(s.controls, id: \.self) { control in
                Spacer(minLength: 0)
                button(control, s, t)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func button(_ control: GraineStageControl, _ s: GraineStageState, _ t: GraineThemeTokens?) -> some View {
        let usable = s.canUse(control)
        let big = control == .end || control == .call || control == .answer
        let size = big ? StageLook.bigButton : StageLook.button
        let on = (control == .mute && s.muted) || (control == .speaker && s.speaker)
        let fill: Color
        let f = fills
        switch control {
        case .end:
            let hex = s.phase == .ringing ? (f?.call?.declineFill ?? f?.colors.danger) : (f?.call?.endFill ?? f?.colors.danger)
            fill = .graineHex(hex ?? StageLook.end, fallback: .red)
        case .call, .answer:
            fill = .graineHex(f?.call?.acceptFill ?? f?.colors.success ?? StageLook.accept, fallback: .green)
        default:
            fill = on ? Color.white.opacity(0.92) : Color.white.opacity(0.18)
        }
        let iconColor: Color = (!big && on) ? StageLook.backdrop : .white
        return Button(action: { act(control, s) }) {
            ZStack {
                Circle().fill(fill)
                GraineIconView(
                    name: icon(control, s), style: t?.icons.style ?? "outline", stroke: t?.icons.stroke ?? 2,
                    color: iconColor, size: StageLook.icon
                )
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!usable)
        .opacity(usable ? 1 : 0.4)
        .accessibilityLabel(label(control, s))
        .accessibilityValue(control == .speaker ? (s.speaker ? "On" : "Off") : "")
    }

    private func icon(_ control: GraineStageControl, _ s: GraineStageState) -> GraineIconName {
        switch control {
        case .mute: return s.muted ? .micOff : .mic
        case .chat: return .chat
        case .speaker: return .speaker
        case .end: return .end
        case .call, .answer: return .call
        }
    }

    private func label(_ control: GraineStageControl, _ s: GraineStageState) -> String {
        switch control {
        case .mute: return s.muted ? "Unmute" : "Mute"
        case .chat: return "Chat"
        case .speaker: return "Speaker"
        case .end: return s.endLabel == "End" ? "End call" : s.endLabel
        case .call: return "Call"
        case .answer: return "Answer"
        }
    }

    private func act(_ control: GraineStageControl, _ s: GraineStageState) {
        switch control {
        case .call: stage.call()
        case .answer: stage.answer()
        case .end: stage.end()
        case .mute: stage.setMuted(!s.muted)
        case .speaker: stage.setSpeaker(!s.speaker)
        case .chat: stage.openChat()
        }
    }
}

/**
 * THE FACE STAGE IN UIKIT — `GraineAvatarStage` as a view controller. Add it
 * as a child and give its view the area (the whole screen reads best).
 */
public final class GraineAvatarStageViewController: UIHostingController<GraineAvatarStage> {
    /**
     * - Parameters: as `GraineAvatarStage`. `onChat`: your chat; the chat button is drawn only with one.
     */
    public init(
        graine: GraineInApp? = nil,
        name: String? = nil,
        role: String? = nil,
        calls: GraineStageCalls = .voice,
        onChat: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        super.init(rootView: GraineAvatarStage(graine: graine, name: name, role: role, calls: calls, onChat: onChat, onClose: onClose))
        view.backgroundColor = .black
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("GraineAvatarStageViewController is made in code")
    }
}
#endif
