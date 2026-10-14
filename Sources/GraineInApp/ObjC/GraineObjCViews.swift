#if os(iOS)
import SwiftUI
import UIKit

/*
 * THE SDK'S OWN SCREENS, AS VIEW CONTROLLERS — for an Objective-C app, and
 * for a bridge that hosts native views (Compose Multiplatform's
 * UIKitViewController in ai.graine:inapp-kmp-compose). Each draws in the
 * brand's design from the session, exactly as the SwiftUI views do.
 */
extension GraineObjC {
    /**
     * The chat as a screen. `onClose`: the header's close control (nil: no
     * close control — the navigation it sits in closes it). It connects when
     * it appears and hangs up when it goes.
     */
    @objc(chatViewControllerWithOnClose:)
    public func chatViewController(onClose: (() -> Void)?) -> UIViewController {
        host(GraineChatView(graine: graine, onClose: onClose))
    }

    /// The call screen for while the app is open: ringing, connecting, the call, ended, and a missed ring with Call back.
    @objc(callViewController)
    public func callViewController() -> UIViewController {
        host(GraineCallView(calls: graine.calls))
    }

    /**
     * The voice bar, filling the view it is given and drawn at its bottom.
     * `name`: the agent's name beside the status (nil: the dashboard's
     * heading). `onClose`: the user hung up, or closed the bar with no call.
     * It mounts the engine when it appears, if nothing has.
     */
    @objc(voiceBarViewControllerWithName:onClose:)
    public func voiceBarViewController(name: String?, onClose: (() -> Void)?) -> UIViewController {
        host(GraineAgentBar(graine: graine, name: name, bottomInset: 8, draggable: false, surface: .voice, onClose: onClose))
    }

    private func host<V: View>(_ view: V) -> UIViewController {
        let controller = UIHostingController(rootView: view)
        controller.view.backgroundColor = .clear
        return controller
    }
}
#endif
