#if os(iOS)
import Combine
import SwiftUI
import UIKit

/**
 * THE CHAT, AS A SCREEN — a typed conversation with your agent, drawn by the
 * SDK in the brand's design: the header, one bubble per reply, a typing
 * bubble while the agent works on one, the components it draws (answered in
 * place), and the composer. It connects when it appears and hangs up when it
 * goes; a message typed while offline waits and is sent when the connection
 * is back.
 *
 *     NavigationLink("Ask our assistant") { GraineChatView() }
 *     .sheet(isPresented: $chatOpen) { GraineChatView(onClose: { chatOpen = false }) }
 *
 * A UIKit app presents `GraineChatViewController` instead. The agent sees the
 * screen your app last described and runs your actions, as on a call.
 */
public struct GraineChatView: View {
    private let graine: GraineInApp?
    private let accent: Color?
    private let onClose: (() -> Void)?

    /// - Parameters:
    ///   - graine: defaults to the instance `GraineInApp.configure` made. Nothing draws before that.
    ///   - accent: overrides the design's accent.
    ///   - onClose: the header's close control; without one it is not drawn — the navigation you put it in closes it.
    public init(graine: GraineInApp? = nil, accent: Color? = nil, onClose: (() -> Void)? = nil) {
        self.graine = graine
        self.accent = accent
        self.onClose = onClose
    }

    public var body: some View {
        if let graine = graine ?? GraineInApp.current {
            GraineChatScreen(graine: graine, chat: graine.chat, fonts: graine.fonts, accentOverride: accent, onClose: onClose)
        }
    }
}

struct GraineChatScreen: View {
    let graine: GraineInApp
    @ObservedObject var chat: GraineChat
    @ObservedObject var fonts: GraineFontStore
    let accentOverride: Color?
    let onClose: (() -> Void)?

    @StateObject private var model: GraineAppearanceModel
    @StateObject private var keyboard = GraineKeyboardObserver()
    @Environment(\.colorScheme) private var colorScheme

    init(graine: GraineInApp, chat: GraineChat, fonts: GraineFontStore, accentOverride: Color?, onClose: (() -> Void)?) {
        self.graine = graine
        _chat = ObservedObject(wrappedValue: chat)
        _fonts = ObservedObject(wrappedValue: fonts)
        self.accentOverride = accentOverride
        self.onClose = onClose
        _model = StateObject(wrappedValue: GraineAppearanceModel(graine: graine))
    }

    private var dash: GraineNativeAppearance {
        Appearance.resolve(model.appearance, accent: Appearance.defaultAccent, heading: "Assistant", origin: graine.config.baseUrl)
    }

    /// The brand's tokens; without a design (an older server), the SDK's classic look around the dashboard's accent.
    private var tokens: GraineThemeTokens {
        model.design?.tokens(deviceDark: colorScheme == .dark) ?? DesignTokens.classic(dark: colorScheme == .dark, accent: dash.accent)
    }

    var body: some View {
        let t = tokens
        let type = GraineType(font: t.font, names: graine.config.fonts, faces: fonts.faces)
        let accent = accentOverride ?? .graineHex(t.colors.accent)
        let onAccent: Color = accentOverride == nil ? .graineHex(t.colors.onAccent, fallback: .white) : .white
        VStack(spacing: 8) {
            GraineWidgetView(graine: graine, inBar: true)
                .padding(.horizontal, 12)
            GraineChatWindow(
                tokens: t, type: type, accent: accent, onAccent: onAccent,
                heading: dash.heading, logoUrl: dash.logoUrl, logoPlate: dash.logoPlate,
                turns: chat.turns, status: chat.status, typing: chat.typing, lifted: keyboard.frame != nil,
                fills: true, collapseLabel: "Close",
                upcoming: chat.upcomingCalls, cancelling: chat.cancelling, cancelFailed: chat.cancelFailed,
                callName: graine.sessionOrCached?.calls?.callName,
                bookable: graine.bookingAvailable,
                onSend: { chat.send($0) },
                onRetry: { chat.retry() },
                onCancelCall: { chat.cancelUpcomingCall(id: $0) },
                // The sheet books with scheduleCall, which refreshes the card.
                onBook: { Task { @MainActor in _ = await graine.presentBooking() } },
                // A refusal leaves the conversation as it was; nothing to say over it.
                onNewConversation: { Task { try? await chat.newConversation() } },
                onCollapse: { onClose?() }
            )
        }
        .background(Color.graineHex(t.colors.background).ignoresSafeArea())
        .onAppear {
            graine.tapCapture.attach(to: GraineVoice.keyWindow())
            // Connected while on screen — without asking a mounted bar to draw the chat a second time.
            chat.connectOpen()
        }
        .onDisappear { chat.closeConnection() }
    }
}

/**
 * The chat screen for a UIKit app: present it, or push it.
 *
 *     present(GraineChatViewController(), animated: true)
 *
 * Presented, its close control dismisses it; pushed, the navigation bar's back
 * button does, and the close control is not drawn.
 */
public final class GraineChatViewController: UIViewController {
    private let graine: GraineInApp?
    private var host: UIHostingController<AnyView>?

    /// - Parameter graine: defaults to the instance `GraineInApp.configure` made.
    public init(graine: GraineInApp? = nil) {
        self.graine = graine
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("GraineChatViewController is made in code: GraineChatViewController(graine:).")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        let presented = navigationController == nil
        let close: (() -> Void)? = presented ? { [weak self] in self?.dismiss(animated: true) } : nil
        let controller = UIHostingController(rootView: AnyView(GraineChatView(graine: graine, onClose: close)))
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        controller.view.backgroundColor = .clear
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        controller.didMove(toParent: self)
        host = controller
    }
}
#endif
