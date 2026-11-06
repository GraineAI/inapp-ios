#if os(iOS)
import Combine
import UIKit

/*
 * THE AGENT'S FACE, FOR OBJECTIVE-C AND THE BRIDGES (Kotlin Multiplatform,
 * React Native, Flutter): its state as JSON, a view that draws it, and the
 * call screen's opt-in. Every selector is fixed: a bridge binds to it by name
 * and asks `respondsToSelector:` first, so an older SDK simply has no face.
 */
extension GraineObjC {
    /// `{"phase":"off"|"available"|"live","reason":…}` — GraineAvatar.shared.state.
    @objc(avatarStateJSON)
    public var avatarStateJSON: String {
        objcOnMainSync { AvatarWire.stateJSON(GraineAvatar.shared.state) }
    }

    /// `observer` hears `avatarStateJSON` at once and after every change, on the main thread, until the registration is stopped.
    @objc(observeAvatar:)
    public func observeAvatar(_ observer: @escaping (String) -> Void) -> GraineObjCRegistration {
        let box = AvatarObservation()
        objcOnMainSync {
            box.cancellable = GraineAvatar.shared.$state.removeDuplicates().sink { state in observer(AvatarWire.stateJSON(state)) }
        }
        return GraineObjCRegistration { DispatchQueue.main.async { box.cancellable?.cancel(); box.cancellable = nil } }
    }

    /// A new view that draws the agent's face (`GraineAvatarView`): place it where the face goes.
    @objc(avatarView)
    public func avatarView() -> UIView {
        objcOnMainSync { GraineAvatarView(frame: .zero) }
    }

    /// The SDK's call screen draws the agent's face (`GraineCalls.showsAvatar`).
    @objc(setShowsAvatarOnCallScreen:)
    public func setShowsAvatarOnCallScreen(_ on: Bool) {
        objcOnMainSync { graine.calls.showsAvatar = on }
    }
}

private final class AvatarObservation {
    var cancellable: AnyCancellable?
}
#endif
