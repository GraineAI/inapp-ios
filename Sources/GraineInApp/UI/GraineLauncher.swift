#if os(iOS)
import Combine
import SwiftUI

/**
 * THE LAUNCHER — the floating button, drawn in the brand's design.
 *
 * A tap places the call, mounting the engine first if nothing has; during the
 * call it is the end button, so a launcher on its own is a complete voice UI.
 * Pass `action` to open your own UI instead, and the button only draws. It
 * draws the button and nothing else: place it where it belongs.
 *
 *     RootView()
 *         .overlay(alignment: .bottomTrailing) { GraineLauncher().padding(20) }
 *
 * With a design, it is contract/DESIGN.md's launcher: 56 points (a pill is 56
 * high and as wide as its label), filled with the accent, the design's glyph
 * in `onAccent` at 46% of its height — or the brand's logo when the brand chose
 * it, else the first letter of the name — in the design's shape (a squircle's
 * corners continuous, the way iOS draws its own icons), with the floating
 * shadow, or the solid offset and an outline in the text colour. Without a
 * design: a round accent button with the logo or the first letter, as the
 * React Native SDK's.
 *
 * The brand's logo is drawn WHOLE — fitted into the largest square the shape
 * holds, never cropped — on its plate: the accent, or white with a hairline
 * (a pill's label then in near-black). DESIGN.md "The brand's logo".
 */
public struct GraineLauncher: View {
    private let graine: GraineInApp?
    private let label: String?
    private let accent: Color?
    private let autoAttach: Bool
    private let action: (() -> Void)?

    /// - Parameters:
    ///   - graine: defaults to the instance `GraineInApp.configure` made. Nothing draws before that.
    ///   - label: a pill's words and the spoken label. Defaults to the dashboard's heading.
    ///   - accent: overrides the design's and the dashboard's accent.
    ///   - autoAttach: mount the engine in the key window when the button appears, so a tap is only a call away.
    ///   - action: what a tap does instead of placing the call.
    public init(
        graine: GraineInApp? = nil,
        label: String? = nil,
        accent: Color? = nil,
        autoAttach: Bool = true,
        action: (() -> Void)? = nil
    ) {
        self.graine = graine
        self.label = label
        self.accent = accent
        self.autoAttach = autoAttach
        self.action = action
    }

    public var body: some View {
        if let graine = graine ?? GraineInApp.current {
            GraineLauncherHost(
                graine: graine, voice: graine.voice, fonts: graine.fonts, label: label, accentOverride: accent,
                autoAttach: autoAttach, action: action
            )
        }
    }
}

struct GraineLauncherHost: View {
    let graine: GraineInApp
    @ObservedObject var voice: GraineVoice
    /// Observed so the pill's label is redrawn in the design's typeface when it lands.
    @ObservedObject var fonts: GraineFontStore
    let label: String?
    let accentOverride: Color?
    let autoAttach: Bool
    let action: (() -> Void)?

    @StateObject private var model: GraineAppearanceModel
    /// A logo that would not load: the launcher goes back to the letter on the accent until the logo changes.
    @State private var failedLogo: String? = nil
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let size = CGFloat(DesignRules.launcherSize)

    init(
        graine: GraineInApp, voice: GraineVoice, fonts: GraineFontStore, label: String?, accentOverride: Color?,
        autoAttach: Bool, action: (() -> Void)?
    ) {
        self.graine = graine
        _voice = ObservedObject(wrappedValue: voice)
        _fonts = ObservedObject(wrappedValue: fonts)
        self.label = label
        self.accentOverride = accentOverride
        self.autoAttach = autoAttach
        self.action = action
        _model = StateObject(wrappedValue: GraineAppearanceModel(graine: graine))
    }

    private var tokens: GraineThemeTokens? {
        model.design?.tokens(deviceDark: colorScheme == .dark)
    }

    private var dash: GraineNativeAppearance {
        Appearance.resolve(model.appearance, accent: Appearance.defaultAccent, heading: "Assistant", origin: graine.config.baseUrl)
    }

    /// In a call the button ends it — unless the app took the tap over.
    private var live: Bool {
        action == nil && (voice.connected || voice.connecting)
    }

    private var name: String { label ?? dash.heading }

    /// The logo the button shows, if it shows one: not during a call (it is the end button then), and not one that would not load.
    private func shownLogo(glyph: Bool) -> String? {
        guard !live, !glyph, let raw = dash.logoUrl, raw != failedLogo, URL(string: raw) != nil else { return nil }
        return raw
    }

    var body: some View {
        let t = tokens
        let animation = t?.motion.animation(reduceMotion: reduceMotion)
        return Button(action: tap) {
            if let t = t {
                designed(t)
            } else {
                legacy
            }
        }
        .buttonStyle(GraineLauncherPress(animation: animation))
        .animation(animation, value: live)
        .accessibilityLabel(live ? "End call" : name)
        .onAppear {
            if autoAttach && !voice.isAttached { voice.attach() }
        }
    }

    private func tap() {
        if let action = action {
            action()
        } else if live {
            voice.end()
        } else {
            if !voice.isAttached { voice.attach() }
            voice.start()
        }
    }

    // MARK: - With a design

    private func designed(_ t: GraineThemeTokens) -> some View {
        let c = t.colors
        let pill = t.shape.launcher == .pill
        let shape = GraineLauncherOutline(kind: t.shape.launcher, radius: t.shape.radius)
        // The brand's logo sits on its plate; a glyph, a letter or the hang-up always on the accent (or danger).
        let logo = shownLogo(glyph: t.icons.launcher != nil)
        let plate = DesignRules.logoPlateLook(
            logo != nil ? dash.logoPlate : .accent, accent: c.accent, border: c.border, borderWidth: t.shape.borderWidth
        )
        let onPlate = plate.outline != nil
        let fill: Color = live ? .graineHex(c.danger) : (onPlate ? .graineHex(plate.fill) : (accentOverride ?? .graineHex(c.accent)))
        let ink: Color = live ? .white : (accentOverride == nil ? .graineHex(c.onAccent, fallback: .white) : .white)
        let mark = size * CGFloat(DesignRules.launcherGlyphShare)
        // A pill's logo sits in its height, as a circle's does.
        let box = CGFloat(DesignRules.logoBox(pill ? .circle : t.shape.launcher, size: Double(size)))
        let hard = t.elevation.hardOffset
        let textColor = Color.graineHex(c.text)
        return HStack(spacing: 10) {
            designedMark(t, ink: ink, size: mark, logoBox: box)
            if pill {
                Text(live ? "End call" : name)
                    .font(GraineTypeface.font(
                        family: t.font.heading, size: t.font.scale.body, weight: t.font.weights.title,
                        names: graine.config.fonts, faces: fonts.faces
                    ))
                    // On the white plate the label is what reads on white, not what reads on the accent.
                    .foregroundColor(onPlate ? .graineHex(DesignRules.logoPlateLabel) : ink)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, pill ? size * 0.36 : 0)
        .frame(width: pill ? nil : size, height: size)
        .frame(minWidth: size)
        // A pill is as wide as its label, whatever width the app's layout offers it.
        .fixedSize(horizontal: pill, vertical: false)
        .background(shape.fill(fill))
        .overlay {
            // A hard offset keeps its own outline in the text colour; otherwise a white plate wears its hairline.
            if hard != nil {
                shape.stroke(textColor, lineWidth: CGFloat(t.shape.borderWidth))
            } else if let hairline = plate.outline, !live {
                shape.border(.graineHex(hairline.color), width: CGFloat(hairline.width))
            }
        }
        .background(GraineShadowLayer(shape: shape, shadow: t.elevation.floating, hardOffset: hard, hardColor: textColor))
        .contentShape(shape)
    }

    @ViewBuilder
    private func designedMark(_ t: GraineThemeTokens, ink: Color, size mark: CGFloat, logoBox box: CGFloat) -> some View {
        if live {
            // The SDK's own hang-up, in the design's icon style — the same drawing as the bar's end button.
            GraineIconView(name: .end, style: t.icons.style, stroke: t.icons.stroke, color: ink, size: mark)
        } else if let glyph = t.icons.launcher {
            GraineGlyphView(glyph: glyph, stroke: t.icons.stroke, color: ink, size: mark, fallback: logoOrLetter(ink: ink, logoBox: box, type: t.font))
        } else {
            logoOrLetter(ink: ink, logoBox: box, type: t.font)
        }
    }

    // MARK: - Without one

    private var legacy: some View {
        let accentHex = dash.accent
        let danger = Appearance.prefersDark(model.appearance, deviceIsDark: colorScheme == .dark)
            ? GraineBarPalette.dark.danger : GraineBarPalette.light.danger
        // The React Native classic launcher's plate: white with a light hairline, or the accent.
        let onPlate = shownLogo(glyph: false) != nil && dash.logoPlate == .white
        let fill: Color = live ? danger : (onPlate ? .graineHex(DesignRules.logoPlateWhite) : (accentOverride ?? .graineHex(accentHex)))
        let ink: Color = live || accentOverride != nil ? .white : .graineHex(Appearance.onAccent(accentHex), fallback: .white)
        return ZStack {
            Circle().fill(fill)
            if live {
                Image(systemName: "xmark")
                    .font(.system(size: size * 0.34, weight: .bold))
                    .foregroundColor(ink)
            } else {
                logoOrLetter(ink: ink, logoBox: CGFloat(DesignRules.logoBox(.circle, size: Double(size))), type: nil)
            }
        }
        .frame(width: size, height: size)
        .overlay {
            if onPlate { Circle().strokeBorder(Color.graineHex(GraineLauncherHost.classicHairline), lineWidth: 1) }
        }
        .shadow(color: Color.black.opacity(0.25), radius: 8, x: 0, y: 4)
        .contentShape(Circle())
    }

    /// The classic launcher's hairline around the white plate, as the React Native SDK draws it.
    static let classicHairline = "#E5E7EB"

    // MARK: - Logo, else a letter

    /// The name's first letter, in the design's heading face when there is one.
    private func letter(ink: Color, type: GraineThemeTokens.Typography?) -> some View {
        Text(String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased())
            .font(type.map {
                GraineTypeface.font(
                    family: $0.heading, size: Double(size) * 0.4, weight: $0.weights.title,
                    names: graine.config.fonts, faces: fonts.faces
                )
            } ?? .system(size: size * 0.4, weight: .bold))
            .foregroundColor(ink)
    }

    /**
     * The brand's logo, WHOLE: fitted into `box` — the largest square the
     * shape holds — proportions kept, never cropped (it was clipped to a
     * rounded square, which took a square logo's corners). While it loads,
     * nothing; if it cannot load, or there is none, the name's first letter.
     */
    @ViewBuilder
    private func logoOrLetter(ink: Color, logoBox box: CGFloat, type: GraineThemeTokens.Typography?) -> some View {
        if let raw = shownLogo(glyph: false), let url = URL(string: raw) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                        .frame(width: box, height: box)
                case .failure:
                    letter(ink: ink, type: type).onAppear { failedLogo = raw }
                default:
                    Color.clear.frame(width: box, height: box)
                }
            }
            .accessibilityHidden(true)
        } else {
            letter(ink: ink, type: type)
        }
    }
}

extension GraineLauncherOutline {
    /// An outline drawn inside the edge, as a CSS border is: twice the width, clipped to the shape.
    func border(_ color: Color, width: CGFloat) -> some View {
        stroke(color, lineWidth: width * 2).clipShape(self)
    }
}

/// The launcher's outline for each shape DESIGN.md names.
struct GraineLauncherOutline: Shape {
    let kind: GraineLauncherShape
    let radius: GraineThemeTokens.Radius

    func path(in rect: CGRect) -> Path {
        let corner = CGFloat(DesignRules.launcherCornerRadius(kind, size: Double(rect.height), radius: radius))
        switch kind {
        case .circle:
            return Circle().path(in: rect)
        case .squircle:
            // Continuous corners: the curvature eases in, as on the app icons around it.
            return RoundedRectangle(cornerRadius: corner, style: .continuous).path(in: rect)
        case .roundedSquare, .square, .pill:
            return RoundedRectangle(cornerRadius: corner, style: .circular).path(in: rect)
        }
    }
}

/// Pressed: a little smaller, in the design's motion — and only dimmed when there is no motion to use.
struct GraineLauncherPress: ButtonStyle {
    let animation: Animation?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && animation != nil ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(animation, value: configuration.isPressed)
    }
}
#endif
