#if os(iOS)
import SwiftUI
import UIKit

/**
 * TAPS, FOR THE AGENT — a recogniser on the app's window that only watches:
 * it never cancels, delays or competes for a touch, and recognises alongside
 * every recogniser the app has. A tap on a control with an accessibility
 * identifier (or a button's label) is recorded as `tap:<name>`; any other as
 * `tap:screen` with where it landed (TapRules). Only while a screen is set —
 * there is nothing to attach it to otherwise — and only with
 * `GraineConfig.captureTaps`. SwiftUI content carries no UIKit identifier: name
 * a SwiftUI control with `.graineTap("submit")`.
 */
final class GraineTapCapture: NSObject, UIGestureRecognizerDelegate {
    private weak var graine: GraineInApp?
    private weak var window: UIWindow?
    private var recognizer: UITapGestureRecognizer?
    private var recent: [Double] = []

    private static var shared: GraineTapCapture?

    /// The app's one recogniser (several agents share it: a tap is recorded once, for each of them). Main thread.
    static func process(for graine: GraineInApp) -> GraineTapCapture {
        if let existing = shared {
            if existing.graine == nil { existing.graine = graine }
            return existing
        }
        let made = GraineTapCapture(graine: graine)
        shared = made
        return made
    }

    init(graine: GraineInApp) {
        self.graine = graine
        super.init()
    }

    /// Watch this window's taps (the engine's, or the key window). Moving windows moves the recogniser.
    func attach(to window: UIWindow?) {
        guard let graine = graine, graine.config.captureTaps, let window = window, self.window !== window else { return }
        detach()
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.requiresExclusiveTouchType = false
        tap.delegate = self
        window.addGestureRecognizer(tap)
        recognizer = tap
        self.window = window
    }

    func detach() {
        if let tap = recognizer { tap.view?.removeGestureRecognizer(tap) }
        recognizer = nil
        window = nil
    }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        guard tap.state == .ended, let graine = graine, let window = window, graine.hasScreen else { return }
        let admitted = TapRules.admit(nowMs: GraineInApp.uptimeMs(), recent: recent)
        recent = admitted.recent
        guard admitted.allowed else { return }
        let point = tap.location(in: window)
        if let name = GraineTapCapture.name(of: window.hitTest(point, with: nil)) {
            graine.tap(name)
            return
        }
        // A moment later, so a control the app named itself (`graineTap`) is not also counted as a bare tap.
        let at = GraineInApp.uptimeMs()
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60)) { [weak graine] in
            guard let graine = graine, !graine.namedTapSince(at - TapRules.namedOverlapMs) else { return }
            graine.recordUnnamedTap(x: Int(point.x.rounded()), y: Int(point.y.rounded()))
        }
    }

    /// The nearest named control at the tap: an identifier anywhere up the chain, a label only on a button.
    static func name(of hit: UIView?) -> String? {
        var view = hit
        var depth = 0
        while let current = view, depth < 12, !(current is UIWindow) {
            if let id = TapRules.clean(current.accessibilityIdentifier) { return id }
            let isText = current is UITextField || current is UITextView || current is UISearchBar
            let isButton = current is UIControl || current.accessibilityTraits.contains(.button)
            if isButton && !isText, let label = TapRules.clean(current.accessibilityLabel) { return label }
            view = current.superview
            depth += 1
        }
        return nil
    }

    // MARK: Never in the app's way

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
        false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        false
    }
}

public extension View {
    /**
     * Name a control for the agent: a tap on it reaches the agent's context as
     * `tap:<name>` ("you tapped Pay twice"), without taking the tap from the
     * control. For SwiftUI, whose views carry no UIKit identifier.
     */
    func graineTap(_ name: String, graine: GraineInApp? = nil) -> some View {
        simultaneousGesture(TapGesture().onEnded {
            (graine ?? GraineInApp.current)?.tap(name)
        })
    }
}
#endif
