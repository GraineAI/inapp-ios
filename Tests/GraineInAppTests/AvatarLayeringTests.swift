#if os(iOS)
import Foundation
import Testing
import UIKit
@testable import GraineInApp

/*
 * THE FACE DRAWS INSIDE THE AVATAR VIEW (0.15.4) — on the voice bar's calls the
 * engine's own view moves into the avatar view, under anything in it, while
 * the face shows; anything the app draws above the avatar view is drawn over
 * the face. It goes back to its resting place in the window when the face
 * stops or the avatar view leaves, and it never leaves the window. Runs on an
 * iOS simulator (UIKit): xcodebuild test -scheme GraineInApp -destination
 * 'platform=iOS Simulator,…' -only-testing:GraineInAppTests/AvatarLayeringTests
 */
@MainActor
@Suite(.serialized) struct AvatarLayeringTests {
    private func scene() -> (UIWindow, UIView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        root.view.frame = window.bounds
        return (window, root.view)
    }

    @Test func theFaceIsDrawnInsideTheAvatarViewUnderWhatTheAppDrawsAboveIt() throws {
        let (window, screen) = scene()
        let slot = GraineAvatarView(frame: screen.bounds)
        screen.addSubview(slot)
        let caption = UILabel(frame: CGRect(x: 20, y: 700, width: 350, height: 40))
        caption.text = "“Does 10 work for you?”"
        screen.addSubview(caption)
        let graine = GraineInApp(config: GraineConfig(baseUrl: "https://example.invalid", publishableKey: "pk_test"))
        let voice = graine.voice
        voice.attach(to: window)
        defer { voice.detach() }
        let host = try #require(voice.engineHostForTests)
        #expect(host.superview === window, "at rest: in the window it was attached to")
        #expect(host.alpha == 0)

        voice.faceFromPageForTests("available")
        #expect(host.superview === slot, "the face is drawn inside the avatar view")
        #expect(slot.subviews.first === host, "under anything else in it")
        #expect(host.frame == slot.bounds)
        #expect(host.alpha == 1)
        // The app's caption is above the avatar view, so it is drawn over the face.
        let order = screen.subviews
        #expect((order.firstIndex(of: slot) ?? .max) < (order.firstIndex(of: caption) ?? -1))
        #expect(host.window === window)

        // The avatar view leaves the screen: the engine is home first, and never out of the window.
        slot.removeFromSuperview()
        #expect(host.superview === window)
        #expect(host.window === window)
        #expect(host.alpha == 0)

        // Back on screen: inside it again.
        screen.insertSubview(slot, at: 0)
        slot.setNeedsLayout()
        slot.layoutIfNeeded()
        GraineAvatar.shared.slotsChanged()
        #expect(host.superview === slot)

        // The face stops: home, invisible.
        voice.faceFromPageForTests("off", reason: "ended")
        #expect(host.superview === window)
        #expect(host.alpha == 0)
    }

    @Test func aWholeScreenTakenAwayWithTheFaceOnItLeavesTheEngineInTheWindow() throws {
        let (window, screen) = scene()
        let card = UIView(frame: screen.bounds)
        screen.addSubview(card)
        let slot = GraineAvatarView(frame: CGRect(x: 0, y: 0, width: 220, height: 275))
        card.addSubview(slot)
        let graine = GraineInApp(config: GraineConfig(baseUrl: "https://example.invalid", publishableKey: "pk_test"))
        let voice = graine.voice
        voice.attach(to: window)
        defer { voice.detach() }
        let host = try #require(voice.engineHostForTests)
        voice.faceFromPageForTests("live")
        #expect(host.superview === slot)
        // A screen goes (a navigation pop, a full-screen presentation): the face's view with it — the engine does not.
        card.removeFromSuperview()
        #expect(host.superview === window)
        #expect(host.window === window)
        GraineAvatar.shared.slotsChanged()
        #expect(host.superview === window, "no avatar view on screen: the engine rests")
    }
}
#endif
