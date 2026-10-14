#if os(iOS)
import SwiftUI
import UIKit

/**
 * THE BIGGER CHAT WINDOWS the bar draws over the app — contract/DESIGN.md
 * "Chat window" → Size, where to put them decided by ChatWindowLayout:
 *
 *   sheet    up from the bottom of a phone, its top edge 8% of the screen
 *            below the top safe area, corners at the top only, the app dimmed
 *            behind it (a tap there closes it), a grab handle that closes it
 *            when dragged down or flung;
 *   panel    420 wide, min(760, 90% of the screen) tall, in an iPad's bottom
 *            corner 24 in from the safe area, the whole frame, no dimming;
 *   screen   all of it: the chat's own background to every edge, the header's
 *            fill behind the status bar.
 *
 * Drawn in the bar's own overlay rather than presented: a presented cover
 * takes the app's views out of the window (SwiftUI says they disappeared,
 * and the bar would hang up the chat it is showing), and the bar already
 * lives above the app at its root. Laid out from the key window's size and
 * safe areas, ignoring the safe area of whatever the app mounted the bar in.
 */
struct GraineBigChat<Content: View>: View {
    let presentation: ChatWindowLayout.Presentation
    let tokens: GraineThemeTokens
    /// The keyboard's height over the window's bottom edge; 0 while it is down.
    let keyboard: CGFloat
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var pull: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var window: UIWindow? { GraineVoice.keyWindow() }
    private var screen: CGSize { window?.bounds.size ?? UIScreen.main.bounds.size }
    private var safe: UIEdgeInsets { window?.safeAreaInsets ?? .zero }
    /// The composer above the keyboard, else above the home indicator.
    private var bottomPad: CGFloat { keyboard > 0 ? keyboard : safe.bottom }

    var body: some View {
        Group {
            switch presentation {
            case .sheet: sheet
            case .panel: panel
            default: fullScreen
            }
        }
        .ignoresSafeArea()
    }

    // MARK: Sheet

    private var sheet: some View {
        let top = safe.top + CGFloat(ChatWindowLayout.sheetTop) * screen.height
        let radius = CGFloat(tokens.shape.radius.xl)
        return ZStack(alignment: .bottom) {
            Color.graineHex(tokens.colors.scrim).opacity(0.4)
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
                .accessibilityLabel("Close the chat")
                .accessibilityAddTraits(.isButton)
            VStack(spacing: 0) {
                handle
                content()
                    .padding(.bottom, bottomPad)
            }
            .frame(width: screen.width, height: max(0, screen.height - top))
            .background(Color.graineHex(tokens.chat?.background ?? tokens.colors.background))
            .clipShape(GraineTopRounded(radius: radius))
            .modifier(SheetShadow(tokens: tokens))
            .offset(y: pull)
            // Only a drag that starts on the handle or the header pulls the sheet; the thread scrolls.
            .simultaneousGesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .local)
                    .onChanged { value in
                        guard value.startLocation.y < CGFloat(Self.handleStrip + VoiceBar.Chat.header) else { return }
                        pull = max(0, value.translation.height)
                    }
                    .onEnded { value in
                        guard value.startLocation.y < CGFloat(Self.handleStrip + VoiceBar.Chat.header) else { return }
                        let flung = value.predictedEndTranslation.height - value.translation.height > 120
                        if value.translation.height > CGFloat(Self.closeDrag) || flung {
                            pull = 0
                            onClose()
                        } else {
                            withAnimation(tokens.motion.animation(reduceMotion: reduceMotion)) { pull = 0 }
                        }
                    }
            )
            .accessibilityAddTraits(.isModal)
        }
        .frame(width: screen.width, height: screen.height)
    }

    /// The grab handle: a strip in the header's fill, a short bar in it.
    private var handle: some View {
        let windowed = tokens.chrome == .window
        let fill = windowed ? tokens.colors.surfaceRaised : (tokens.chat?.headerBackground ?? tokens.colors.surface)
        let bar = windowed ? tokens.colors.textMuted : (tokens.chat?.headerSubtext ?? tokens.colors.textMuted)
        return ZStack {
            Color.graineHex(fill)
            Capsule()
                .fill(Color.graineHex(bar).opacity(0.5))
                .frame(width: CGFloat(Self.handleWidth), height: CGFloat(Self.handleHeight))
        }
        .frame(height: CGFloat(Self.handleStrip))
        .accessibilityHidden(true)
    }

    // MARK: Panel

    private var panel: some View {
        let size = ChatWindowLayout.panelSize(height: Double(screen.height))
        let inset = CGFloat(ChatWindowLayout.panelInset)
        let room = max(0, screen.height - safe.top - safe.bottom - 2 * inset - keyboard)
        return content()
            .frame(width: CGFloat(size.width), height: min(CGFloat(size.height), room))
            .padding(.trailing, inset + safe.right)
            .padding(.bottom, inset + max(safe.bottom, keyboard))
            .frame(width: screen.width, height: screen.height, alignment: .bottomTrailing)
    }

    // MARK: Screen

    private var fullScreen: some View {
        let windowed = tokens.chrome == .window
        let headerFill = windowed ? tokens.colors.surfaceRaised : (tokens.chat?.headerBackground ?? tokens.colors.surface)
        return VStack(spacing: 0) {
            // The header's fill behind the status bar.
            Color.graineHex(headerFill).frame(height: safe.top)
            content()
                .padding(.bottom, bottomPad)
                .padding(.leading, safe.left)
                .padding(.trailing, safe.right)
        }
        .frame(width: screen.width, height: screen.height)
        .background(Color.graineHex(tokens.chat?.background ?? tokens.colors.background))
        .accessibilityAddTraits(.isModal)
    }

    static var handleStrip: Double { 16 }
    static var handleWidth: Double { 36 }
    static var handleHeight: Double { 5 }
    /// Dragged down this far (points), a sheet closes.
    static var closeDrag: Double { 80 }
}

/// The floating shadow, unless the design draws a hard offset — which has nowhere to show at the screen's edges.
private struct SheetShadow: ViewModifier {
    let tokens: GraineThemeTokens
    func body(content: Content) -> some View {
        if tokens.elevation.hardOffset == nil, let s = tokens.elevation.floating {
            content.shadow(color: Color.graineHex(s.color).opacity(s.opacity), radius: CGFloat(s.blur / 2), x: 0, y: CGFloat(s.y))
        } else {
            content
        }
    }
}

/// A rectangle with its top corners rounded: a sheet meets the bottom edge square.
struct GraineTopRounded: Shape {
    let radius: CGFloat
    func path(in rect: CGRect) -> Path {
        Path(UIBezierPath(
            roundedRect: rect, byRoundingCorners: [.topLeft, .topRight], cornerRadii: CGSize(width: radius, height: radius)
        ).cgPath)
    }
}
#endif
