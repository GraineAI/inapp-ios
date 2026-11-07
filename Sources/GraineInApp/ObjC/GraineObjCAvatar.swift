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
            // Alive until the registration is STOPPED, not merely as long as the caller keeps the registration object:
            // Kotlin Multiplatform 0.15.0 and 0.15.1 drop it, and the subscription went with it — the app never heard the
            // face become available, so no avatar view was ever placed and the face never showed (7 Nov 2026).
            AvatarObservation.live.insert(box)
        }
        return GraineObjCRegistration {
            DispatchQueue.main.async {
                box.cancellable?.cancel()
                box.cancellable = nil
                AvatarObservation.live.remove(box)
            }
        }
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

private final class AvatarObservation: Hashable {
    /// Every observation not yet stopped (main thread): what keeps each one alive.
    static var live = Set<AvatarObservation>()
    var cancellable: AnyCancellable?
    static func == (a: AvatarObservation, b: AvatarObservation) -> Bool { a === b }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
#endif
