#if os(iOS)
import Combine
import UIKit

/*
 * THE FACE STAGE, FOR OBJECTIVE-C AND THE BRIDGES (Kotlin Multiplatform,
 * React Native, Flutter): the stage's state as JSON (contract/PUBLIC-STATE.md
 * "The face stage"), its buttons as calls, and the SDK's own stage as a view
 * controller. Every selector is fixed: a bridge binds to it by name and asks
 * `respondsToSelector:` first, so an older SDK simply has no stage.
 */
extension GraineObjC {
    /**
     * `{"call","phase","status","live","startedAt" (ms or null),"caption" ({who,text,final} or null),
     * "muted","speaker","controls","enabled","endLabel","face" ({phase,reason}),"name","role",
     * "componentId","componentPending"}` — GraineInApp.stage.state.
     */
    @objc(stageStateJSON)
    public var stageStateJSON: String {
        objcOnMainSync { StageWire.json(graine.stage.state) }
    }

    /// `observer` hears `stageStateJSON` at once and after every change, on the main thread, until the registration is stopped.
    @objc(observeStage:)
    public func observeStage(_ observer: @escaping (String) -> Void) -> GraineObjCRegistration {
        let box = StageObservation()
        objcOnMainSync {
            box.cancellable = graine.stage.$state.removeDuplicates().sink { state in observer(StageWire.json(state)) }
            // Alive until the registration is stopped, not merely while the caller keeps the object (AvatarObservation).
            StageObservation.live.insert(box)
        }
        return GraineObjCRegistration {
            DispatchQueue.main.async {
                box.cancellable?.cancel()
                box.cancellable = nil
                StageObservation.live.remove(box)
            }
        }
    }

    /// The stage's Call button: the voice bar's call, or a native call (`setStageCalls:`).
    @objc(stageCall)
    public func stageCall() { onMain { [graine] in graine.stage.call() } }

    /// Take the native call that is ringing.
    @objc(stageAnswer)
    public func stageAnswer() { onMain { [graine] in graine.stage.answer() } }

    /// Hang up, cancel a call being placed, or decline a ring.
    @objc(stageEnd)
    public func stageEnd() { onMain { [graine] in graine.stage.end() } }

    @objc(stageSetMuted:)
    public func stageSetMuted(_ muted: Bool) { onMain { [graine] in graine.stage.setMuted(muted) } }

    /// The loudspeaker (YES) or the earpiece of the call the stage shows — with none, of the next one.
    @objc(stageSetSpeaker:)
    public func stageSetSpeaker(_ on: Bool) { onMain { [graine] in graine.stage.setSpeaker(on) } }

    /// The header's words; nil: the dashboard's.
    @objc(setStageName:role:)
    public func setStage(name: String?, role: String?) {
        objcOnMainSync {
            graine.stage.name = name
            graine.stage.role = role
        }
    }

    /// What the Call button places: "voice" (the default) or "native".
    @objc(setStageCalls:)
    public func setStageCalls(_ word: String) {
        objcOnMainSync { graine.stage.calls = GraineStageCalls(rawValue: word) ?? .voice }
    }

    /// Your chat: the chat button is drawn only with one (nil takes it away).
    @objc(setStageChat:)
    public func setStageChat(_ onChat: (() -> Void)?) {
        objcOnMainSync { graine.stage.onChat = onChat }
    }

    /**
     * The SDK's face stage (`GraineAvatarStage`) as a view controller, filling
     * its view. `calls`: "voice" (nil) or "native". `onChat`: your chat (nil:
     * no chat button).
     */
    @objc(avatarStageViewControllerWithName:role:calls:onChat:onClose:)
    public func avatarStageViewController(name: String?, role: String?, calls: String?, onChat: (() -> Void)?, onClose: (() -> Void)?) -> UIViewController {
        objcOnMainSync {
            GraineAvatarStageViewController(
                graine: graine, name: name, role: role,
                calls: calls.flatMap(GraineStageCalls.init(rawValue:)) ?? .voice, onChat: onChat, onClose: onClose
            )
        }
    }
}

/// The stage's state on the wire to a bridge.
enum StageWire {
    static func json(_ s: GraineStageState) -> String {
        var face: [String: Any] = ["phase": s.face.phase.rawValue]
        face["reason"] = s.face.reason ?? NSNull()
        var o: [String: Any] = [
            "call": s.call.rawValue,
            "phase": s.phase.rawValue,
            "status": s.status,
            "live": s.live,
            "muted": s.muted,
            "speaker": s.speaker,
            "controls": s.controls.map(\.rawValue),
            "enabled": s.enabled.map(\.rawValue),
            "endLabel": s.endLabel,
            "face": face,
            "name": s.name,
            "componentPending": s.componentPending,
        ]
        o["startedAt"] = GraineStage.ms(s.startedAt).map { NSNumber(value: $0.rounded()) } ?? NSNull()
        o["caption"] = s.caption.map { ["who": $0.who == .agent ? "agent" : "customer", "text": $0.text, "final": $0.final] as [String: Any] } ?? NSNull()
        o["role"] = s.role ?? NSNull()
        o["componentId"] = s.component?.id ?? NSNull()
        return JSON.string(from: o, sortedKeys: true) ?? "{}"
    }
}

private final class StageObservation: Hashable {
    /// Every observation not yet stopped (main thread): what keeps each one alive.
    static var live = Set<StageObservation>()
    var cancellable: AnyCancellable?
    static func == (a: StageObservation, b: StageObservation) -> Bool { a === b }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
#endif
