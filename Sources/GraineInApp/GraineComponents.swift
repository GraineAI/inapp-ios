import Combine
import Foundation

/**
 * THE COMPONENT THE AGENT DRAWS, AS STATE — what `GraineWidgetView` and the
 * bar read, for a component UI of your own: `GraineInApp.shared.components`.
 *
 *     @ObservedObject var components = GraineInApp.shared.components
 *
 *     if let widget = components.current {
 *         MyCard(widget)          // answer: graine.answerComponent(widgetId:data:summary:)
 *     } else if components.pending {
 *         MyLoader(kind: components.pendingKind)
 *     }
 *
 * Answer it with `GraineInApp.answerComponent(widgetId:data:summary:)`, close
 * it with `GraineInApp.dismissComponent(widgetId:)`, and put the last one
 * closed back with `reopenComponent()`. One at a time, whichever conversation
 * — the chat or a call — drew it. Main thread.
 */
public final class GraineComponents: ObservableObject {
    /**
     * The component the agent drew that nobody has answered or closed; nil
     * when there is none. Kept until then, so a view that mounts later draws
     * it; the next conversation starting forgets it.
     */
    @Published public private(set) var current: GraineWidget?

    /**
     * The agent asked for a component and its content is loading: draw a
     * loader until `current` arrives — at most 12 seconds, the runtime's own
     * wait. An answer, a close or a new conversation ends it too.
     */
    @Published public private(set) var pending = false

    /// The kind of the component on its way while `pending` ("" when the agent did not say) — for the loader's shape.
    @Published public private(set) var pendingKind = ""

    private let baseUrl: String
    private let scheduler: CallScheduler
    private var pendingTimer: CallTimer?

    init(baseUrl: String, scheduler: CallScheduler) {
        self.baseUrl = baseUrl
        self.scheduler = scheduler
    }

    /// The component the SDK keeps changed: arrived, answered, closed or forgotten. Any of them ends a loader. Main thread.
    func frameChanged(_ frame: [String: Any]?) {
        stopPending()
        if frame == nil && current == nil { return }
        current = frame.flatMap { GraineWidget(frame: $0, baseUrl: baseUrl) }
    }

    /// The agent asked for one (`widget_pending`): loading, with the kind it will be, for `WidgetRules.pendingWidgetMs` at most. Main thread.
    func pendingStarted(_ hint: [String: Any]) {
        pendingTimer?.cancel()
        let kind = JSON.string(hint["kind"])
        if pendingKind != kind { pendingKind = kind }
        if !pending { pending = true }
        pendingTimer = scheduler.after(Double(WidgetRules.pendingWidgetMs) / 1_000) { [weak self] in
            self?.pendingTimer = nil
            self?.stopPending()
        }
    }

    private func stopPending() {
        pendingTimer?.cancel()
        pendingTimer = nil
        if pending { pending = false }
        if !pendingKind.isEmpty { pendingKind = "" }
    }
}
