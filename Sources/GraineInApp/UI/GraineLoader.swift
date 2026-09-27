#if os(iOS)
import Combine
import SwiftUI

/**
 * HOW WAITING LOOKS, drawn from the dashboard's Appearance → loader.
 *
 * The same five kinds as the React Native SDK's GraineLoader and the Android
 * GraineLoaderView — dots, pulse, ring, bars, and the brand's own logo
 * breathing ("mark", which is the pulse when no logo is uploaded) — at the
 * configured size and speed, in the accent unless a colour was chosen, with
 * the dashboard's words for the moment. Drawn from the timeline: nothing
 * animates while it is off screen.
 *
 *     GraineLoader(moment: "thinking")
 *
 * `moment` is "connecting", "reconnecting", "thinking" or "component".
 */
public struct GraineLoader: View {
    private let graine: GraineInApp?
    private let moment: String?
    private let label: String?
    private let size: CGFloat?
    private let stacked: Bool

    /// - Parameters:
    ///   - moment: which words to show, from Appearance. Omit for no label.
    ///   - label: overrides the moment's configured words.
    ///   - size: overrides the dashboard's size, in points.
    ///   - stacked: the words under the mark instead of beside it.
    public init(moment: String? = nil, label: String? = nil, size: CGFloat? = nil, stacked: Bool = false, graine: GraineInApp? = nil) {
        self.graine = graine
        self.moment = moment
        self.label = label
        self.size = size
        self.stacked = stacked
    }

    public var body: some View {
        if let graine = graine ?? GraineInApp.current {
            GraineLoaderHost(graine: graine, moment: moment, label: label, size: size, stacked: stacked)
        }
    }
}

/// Follows the session, so a loader drawn before the dashboard's appearance arrived takes it on when it does.
final class GraineAppearanceModel: ObservableObject, GraineListener {
    @Published var appearance: [String: Any] = [:]
    /// The brand's design; nil draws from `appearance`, as before designs.
    @Published var design: GraineDesign?

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
}

struct GraineLoaderHost: View {
    let graine: GraineInApp
    let moment: String?
    let label: String?
    let size: CGFloat?
    let stacked: Bool
    @StateObject private var model: GraineAppearanceModel
    @Environment(\.colorScheme) private var colorScheme

    init(graine: GraineInApp, moment: String?, label: String?, size: CGFloat?, stacked: Bool) {
        self.graine = graine
        self.moment = moment
        self.label = label
        self.size = size
        self.stacked = stacked
        _model = StateObject(wrappedValue: GraineAppearanceModel(graine: graine))
    }

    var body: some View {
        let look = Loaders.resolve(model.appearance["loader"])
        let dash = Appearance.resolve(model.appearance, accent: Appearance.defaultAccent, heading: "", origin: graine.config.baseUrl)
        let palette = Appearance.palette(model.appearance, deviceDark: colorScheme == .dark, accent: look.color ?? dash.accent)
        // The design draws the loader in its accent, on its border and muted text; a colour chosen for the loader still wins.
        let tokens = model.design?.tokens(deviceDark: colorScheme == .dark)
        return GraineLoaderLabel(
            look: look,
            color: Color.graineHex(look.color ?? tokens?.colors.accent ?? dash.accent),
            track: Color.graineHex(tokens?.colors.border ?? palette.border),
            textColor: Color.graineHex(tokens?.colors.textMuted ?? palette.muted),
            label: label ?? moment.flatMap { look.text.forMoment($0) },
            size: size,
            stacked: stacked,
            logoUrl: dash.logoUrl
        )
    }
}

/// The mark and its words, in a row (a status line) or stacked (a component on its way).
struct GraineLoaderLabel: View {
    let look: GraineLoaderLook
    let color: Color
    let track: Color
    let textColor: Color
    let label: String?
    var size: CGFloat? = nil
    var stacked: Bool = false
    var logoUrl: String? = nil

    var body: some View {
        let px = size ?? CGFloat(look.px)
        let words = label ?? ""
        let mark = GraineLoaderMark(look: look, color: color, track: track, size: px, logoUrl: logoUrl)
        let text = Text(words)
            .font(.system(size: max(12, CGFloat(JSON.jsRound(Double(px) * 0.65))), weight: .semibold))
            .foregroundColor(textColor)
            .lineLimit(1)
        return Group {
            if stacked {
                VStack(spacing: 8) {
                    mark
                    if !words.isEmpty { text }
                }
            } else {
                HStack(spacing: 10) {
                    mark
                    if !words.isEmpty { text }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(words.isEmpty ? "Loading" : words)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// One loader mark, animated by its keyframes (the React Native loader's, through Loaders.interpolate).
struct GraineLoaderMark: View {
    let look: GraineLoaderLook
    let color: Color
    let track: Color
    var size: CGFloat? = nil
    var logoUrl: String? = nil

    private var px: CGFloat { size ?? CGFloat(look.px) }

    var body: some View {
        TimelineView(.animation) { timeline in
            let period = max(look.periodMs, 1) / 1000
            let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
            mark(at: t)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func mark(at t: Double) -> some View {
        switch look.kind {
        case "pulse": pulse(t)
        case "ring": ring(t)
        case "bars": bars(t)
        case "mark": logo(t)
        default: dots(t)
        }
    }

    private func round(_ v: CGFloat) -> CGFloat { CGFloat(JSON.jsRound(Double(v))) }

    private func dots(_ t: Double) -> some View {
        let d = max(4, round(px * 0.32))
        let lit: [Double] = [0, 0.33, 0.66, 1]
        return HStack(spacing: round(d * 0.7)) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(color)
                    .frame(width: d, height: d)
                    .opacity(Loaders.interpolate(t, lit, [i == 0 ? 1 : 0.3, i == 1 ? 1 : 0.3, i == 2 ? 1 : 0.3, i == 0 ? 1 : 0.3]))
            }
        }
        .frame(height: px)
    }

    /// A dot with a ring breathing out of it.
    private func pulse(_ t: Double) -> some View {
        ZStack {
            Circle()
                .fill(color)
                .frame(width: px, height: px)
                .scaleEffect(Loaders.interpolate(t, [0, 1], [0.6, 1.4]))
                .opacity(Loaders.interpolate(t, [0, 1], [0.35, 0]))
            Circle()
                .fill(color)
                .frame(width: round(px * 0.5), height: round(px * 0.5))
        }
        .frame(width: px, height: px)
    }

    /// A track with its top quarter in colour, turning — the React Native ring is a border with a coloured top.
    private func ring(_ t: Double) -> some View {
        let w = max(2, round(px * 0.14))
        return ZStack {
            Circle().stroke(track, lineWidth: w)
            Circle()
                .trim(from: 0, to: 0.25)
                .stroke(color, style: StrokeStyle(lineWidth: w, lineCap: .butt))
                .rotationEffect(.degrees(-135 + 360 * t))
        }
        .frame(width: px, height: px)
    }

    private func bars(_ t: Double) -> some View {
        let w = max(3, round(px * 0.18))
        return HStack(spacing: round(w * 0.8)) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: w, height: px)
                    .scaleEffect(x: 1, y: Loaders.interpolate(t, [0, 0.5, 1], i == 1 ? [0.4, 1, 0.4] : [1, 0.4, 1]))
            }
        }
        .frame(height: px)
    }

    /// The brand mark: the dashboard's logo, breathing. With no logo uploaded it is the pulse.
    @ViewBuilder
    private func logo(_ t: Double) -> some View {
        if let url = logoUrl.flatMap({ URL(string: $0) }) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                } else {
                    Circle().fill(color).frame(width: round(px * 0.5), height: round(px * 0.5))
                }
            }
            .frame(width: px, height: px)
            .opacity(Loaders.interpolate(t, [0, 0.5, 1], [1, 0.45, 1]))
        } else {
            pulse(t)
        }
    }
}
#endif
