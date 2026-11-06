#if os(iOS)
import Combine
import SwiftUI
import UIKit

/// Told when the avatar views on screen change (GraineCalls, GraineVoice). Main thread.
protocol AvatarSurfaceListener: AnyObject {
    func avatarSurfaceChanged()
}

/**
 * THE AGENT'S FACE (avatar) — what the app sees, and where it is drawn.
 *
 * When the agent has a face (switched on in the dashboard) and the app shows
 * an avatar view (`GraineAvatarView`, or `GraineAvatarFace` in SwiftUI), the
 * face plays there during a call and carries the agent's voice in sync with
 * its lips; the call's own copy of the voice is silenced only while it does,
 * and comes back the moment the face stops. With no avatar view on screen
 * nothing is watched: the call is voice-only, exactly as before.
 *
 *   - the assistant bar's calls: the face is drawn by the call's own engine,
 *     in the avatar view's place;
 *   - the SDK's native calls (GraineCalls): the face needs the WebRTC module
 *     (`GraineInAppRTC`) and a call on WebRTC; otherwise `state.reason` is
 *     `unsupported` and the call stays voice-only.
 *
 * One call at a time, so one face at a time: `state` follows whichever call
 * has it. Main thread.
 */
public final class GraineAvatar: ObservableObject {
    public static let shared = GraineAvatar()

    /// The face of the call in progress: off, available (show your avatar view) or live (it carries the voice).
    @Published public private(set) var state: GraineAvatarState = .off

    /// Called on the main thread whenever `state` changes.
    public var onStateChange: ((GraineAvatarState) -> Void)?

    /// Whether an avatar view is on screen now.
    public private(set) var isShown = false

    private let slots = NSHashTable<GraineAvatarView>.weakObjects()
    private let listeners = NSHashTable<AnyObject>.weakObjects()
    private(set) weak var activeSlot: GraineAvatarView?

    // The sources: the native call's face, and each assistant-bar engine's.
    private var native: GraineAvatarState = .off
    private var nativeViewer: GraineAvatarViewer?
    private var engines: [ObjectIdentifier: (state: GraineAvatarState, at: Int)] = [:]
    private var lastOff: GraineAvatarState = .off
    private var tick = 0

    init() {}

    // MARK: - Slots

    func register(_ slot: GraineAvatarView) {
        slots.add(slot)
        slotsChanged()
    }

    func unregister(_ slot: GraineAvatarView) {
        slots.remove(slot)
        slotsChanged()
    }

    /// A slot moved, appeared, disappeared or resized.
    func slotsChanged() {
        let visible = slots.allObjects.filter { $0.isOnScreen }
        let next = visible.contains(where: { $0 === activeSlot }) ? activeSlot : visible.last
        let moved = next !== activeSlot
        activeSlot = next
        let shown = next != nil
        if moved { placeNativeVideo() }
        let changed = shown != isShown
        isShown = shown
        if changed || moved || shown {
            for case let l as AvatarSurfaceListener in listeners.allObjects { l.avatarSurfaceChanged() }
        }
    }

    func listen(_ listener: AvatarSurfaceListener) { listeners.add(listener) }
    func stopListening(_ listener: AvatarSurfaceListener) { listeners.remove(listener) }

    // MARK: - Sources

    /// The native call's face (GraineCalls).
    func nativeState(_ s: GraineAvatarState) {
        native = s
        if !s.showsFace { lastOff = s }
        recompute()
    }

    /// The viewer drawing the native call's face, while it is on screen; nil otherwise.
    func nativeViewer(_ viewer: GraineAvatarViewer?) {
        nativeViewer = viewer
        placeNativeVideo()
    }

    /// An assistant-bar engine's face, as its page reported it.
    func engineState(_ engine: AnyObject, _ s: GraineAvatarState) {
        tick += 1
        engines[ObjectIdentifier(engine)] = (s, tick)
        if !s.showsFace { lastOff = s }
        recompute()
    }

    func engineGone(_ engine: AnyObject) {
        engines.removeValue(forKey: ObjectIdentifier(engine))
        recompute()
    }

    private func recompute() {
        let next: GraineAvatarState
        if native.showsFace {
            next = native
        } else if let e = engines.values.filter({ $0.state.showsFace }).max(by: { $0.at < $1.at }) {
            next = e.state
        } else {
            next = lastOff
        }
        guard next != state else { return }
        state = next
        onStateChange?(next)
        for slot in slots.allObjects { slot.stateChanged() }
    }

    private func placeNativeVideo() {
        let view = nativeViewer?.videoView as? UIView
        for slot in slots.allObjects where slot !== activeSlot { slot.host(nil) }
        activeSlot?.host(view)
    }
}

/**
 * WHERE THE AGENT'S FACE IS DRAWN — place it in your layout (a square or
 * portrait area reads best) and the face plays here during calls whose agent
 * has one. Transparent when there is none: put your own picture of the agent
 * behind it. Hiding it, or taking it off screen, gives the voice back to the
 * call at once. One on screen at a time is used: the last one shown.
 */
public final class GraineAvatarView: UIView {
    private weak var hosted: UIView?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        backgroundColor = .clear
        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityLabel = "Agent"
        accessibilityTraits = .image
    }

    /// On screen: in a window, not hidden, visible, with an area.
    var isOnScreen: Bool {
        guard window != nil, !isHidden, alpha > 0.01, bounds.width >= 1, bounds.height >= 1 else { return false }
        var v: UIView? = superview
        while let s = v {
            if s.isHidden || s.alpha <= 0.01 { return false }
            v = s.superview
        }
        return true
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { GraineAvatar.shared.register(self) } else { GraineAvatar.shared.unregister(self) }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        hosted?.frame = bounds
        GraineAvatar.shared.slotsChanged()
    }

    public override var isHidden: Bool {
        didSet { if oldValue != isHidden { GraineAvatar.shared.slotsChanged() } }
    }

    public override var alpha: CGFloat {
        didSet { if (oldValue > 0.01) != (alpha > 0.01) { GraineAvatar.shared.slotsChanged() } }
    }

    /// The native face's video view, or nil.
    func host(_ view: UIView?) {
        if hosted === view { return }
        if let old = hosted, old.superview === self { old.removeFromSuperview() }
        hosted = view
        guard let view = view else { return }
        view.frame = bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.isUserInteractionEnabled = false
        addSubview(view)
    }

    func stateChanged() {
        accessibilityValue = GraineAvatar.shared.state.phase == .live ? "Speaking" : nil
    }

    /// Where this view is, in `container`'s coordinates (the assistant bar's engine is laid over it).
    func frame(in container: UIView) -> CGRect { convert(bounds, to: container) }
}

/**
 * THE AGENT'S FACE IN SWIFTUI — `GraineAvatarView` as a view.
 *
 *     ZStack {
 *         Image("agent").resizable().scaledToFill()   // drawn when there is no face
 *         GraineAvatarFace()
 *     }
 *     .frame(width: 220, height: 280)
 *     .clipShape(RoundedRectangle(cornerRadius: 24))
 */
public struct GraineAvatarFace: UIViewRepresentable {
    public init() {}

    public func makeUIView(context: Context) -> GraineAvatarView { GraineAvatarView(frame: .zero) }

    public func updateUIView(_ uiView: GraineAvatarView, context: Context) {}
}
#endif
