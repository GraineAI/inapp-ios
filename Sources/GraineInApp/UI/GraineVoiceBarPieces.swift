#if os(iOS)
import SwiftUI
import UIKit

/*
 * THE VOICE BAR'S PIECES, drawn from the design's tokens exactly as
 * contract/DESIGN.md ("Voice bar") specifies and the Garage's phone preview
 * draws them: the surface every floating piece wears, the meter and the
 * caption card. GraineAgentBar assembles them; the numbers live in
 * Core/VoiceBar.swift. The chat window is GraineChatWindow.swift.
 */

// MARK: - The surface a floating piece wears

/**
 * Fill (translucent over a blur with `glass`), a `borderWidth` outline in
 * `border` drawn inside the edge as a CSS border is, and the shadow — or,
 * with `hardOffset`, a solid `colors.text` copy offset by {x, y}, never
 * blurred. Like a CSS box-shadow, no shadow ever shows through a translucent
 * surface: it is drawn only outside the outline.
 */
struct GraineDesignSurface: ViewModifier {
    let tokens: GraineThemeTokens
    /// The fill, #RRGGBB: `surface` for the bar and the caption, `background` for the chat window's page.
    let fill: String
    /// Whether `glass` applies — it frosts surfaces, never the chat window's page.
    let frosted: Bool
    let radius: Double
    let shadow: GraineThemeTokens.Shadow?

    func body(content: Content) -> some View {
        let t = tokens
        let shape = RoundedRectangle(cornerRadius: CGFloat(radius), style: .continuous)
        let glass = frosted ? t.glass : nil
        return content
            .background(GraineSurfaceFill(shape: shape, color: .graineHex(fill), glass: glass, scheme: t.scheme))
            .overlay(shape.strokeBorder(Color.graineHex(t.colors.border), lineWidth: CGFloat(t.shape.borderWidth)))
            .background(GraineShadowLayer(
                shape: shape, shadow: shadow,
                hardOffset: t.elevation.hardOffset, hardColor: .graineHex(t.colors.text),
                outsideOnly: glass != nil
            ))
    }
}

/// A caption or a chat window arriving: opacity 0 → 1 and 8 points of rise, in the design's motion (DESIGN.md "Arrivals").
extension AnyTransition {
    static var graineRise: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: CGFloat(VoiceBar.rise))), removal: .identity)
    }
}

// MARK: - The meter

/**
 * Four bars moving at the design's pace (Core/VoiceBar.swift VoiceMeter),
 * drawn from the clock rather than animated, like the loader: nothing runs
 * while it is off screen, and a Reduce Motion switched on mid-call stops it at
 * the next frame.
 */
struct GraineVoiceMeter: View {
    let color: Color
    /// The design's duration after Reduce Motion (Motion.effectiveDurationMs); 0 holds it still.
    let durationMs: Double
    @State private var began = Date()

    var body: some View {
        Group {
            if VoiceMeter.moves(durationMs: durationMs, reduceMotion: false) {
                let leg = VoiceMeter.legMs(durationMs: durationMs)
                TimelineView(.animation) { timeline in
                    bars { i in VoiceMeter.scale(bar: i, elapsedMs: timeline.date.timeIntervalSince(began) * 1000, legMs: leg) }
                }
            } else {
                bars { _ in 1 }
            }
        }
        .accessibilityHidden(true)
    }

    private func bars(_ scale: @escaping (Int) -> Double) -> some View {
        HStack(alignment: .bottom, spacing: CGFloat(VoiceMeter.barGap)) {
            ForEach(0..<VoiceMeter.heights.count, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: CGFloat(VoiceMeter.barWidth), height: CGFloat(VoiceMeter.barHeight(i)))
                    .scaleEffect(x: 1, y: CGFloat(scale(i)), anchor: .bottom)
            }
        }
        .frame(height: CGFloat(VoiceMeter.height), alignment: .bottom)
    }
}

// MARK: - The caption

/**
 * The latest line, 8 above the bar: `surface` (frosted with glass), outlined,
 * `radius.lg`, the card shadow or the hard offset, 12 × 8 inside. 13 points of
 * the body family at `weights.strong`, two lines at most, faint while it is
 * still arriving — and "YOU" over the customer's own lines, because captions
 * carry both sides and an unlabelled "Take me to privacy" reads as the agent
 * talking to itself. With window chrome it opens as a window: a 24-point
 * title bar, smaller lights, titled "captions".
 */
struct GraineCaptionCard: View {
    let tokens: GraineThemeTokens
    let type: GraineType
    let accent: Color
    let line: GraineCaption

    var body: some View {
        let t = tokens
        let strong = t.font.weights.strong
        let size = VoiceBar.Caption.size
        VStack(alignment: .leading, spacing: 2) {
            if line.role == .customer {
                Text("YOU")
                    .font(type.body(VoiceBar.Caption.youSize, strong))
                    .tracking(CGFloat(VoiceBar.Caption.youTracking))
                    .foregroundColor(accent)
                    .lineLimit(1)
            }
            Text(line.text)
                .font(type.body(size, strong))
                .tracking(type.bodyTracking(size))
                .lineSpacing(type.bodyLineSpacing(size: size, weight: strong, lineHeight: VoiceBar.Caption.lineHeight))
                .foregroundColor(.graineHex(t.colors.text))
                .lineLimit(VoiceBar.Caption.maxLines)
                .opacity(line.live ? VoiceBar.liveOpacity : 1)
        }
        .padding(.horizontal, CGFloat(VoiceBar.Caption.paddingH))
        .padding(.vertical, CGFloat(VoiceBar.Caption.paddingV))
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(GraineWindowed(bar: WindowChrome.titleBar(t, for: .caption), spoken: false))
        .modifier(GraineDesignSurface(tokens: t, fill: t.colors.surface, frosted: true, radius: t.shape.radius.lg, shadow: t.elevation.card))
        .accessibilityElement(children: .combine)
    }
}
#endif
