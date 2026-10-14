import Foundation

/*
 * HOW BIG THE CHAT WINDOW OPENS — contract/DESIGN.md "Chat window" → Size.
 *
 * The brand chooses in the dashboard (Embed & Widgets → Appearance → Chat
 * window → Window size), which arrives as the design's `chat.size`; the app
 * may choose otherwise in `GraineConfig.chatSize`, and once more for one open
 * with `GraineChat.open(size:)`. What a size LOOKS like depends on the screen:
 * a phone gets a sheet or the whole screen, an iPad a panel in the corner. The
 * rule and the numbers are every Graine SDK's (sdk/inapp/theme.ts:
 * chatSizeOf, chatPresentation, CHAT_WINDOW), kept here free of UIKit so they
 * are tested on a Mac.
 */

/// How big the chat window opens.
public enum GraineChatSize: String, CaseIterable, Sendable {
    /// The window above the bar, as it has always been.
    case compact
    /// A sheet over most of a phone; a panel in the corner of an iPad.
    case large
    /// The whole screen.
    case full

    /// The design's word for a size; nil for anything else — absent, or a newer server's word.
    init?(wire: Any?) {
        guard let word = JSON.unwrap(wire) as? String else { return nil }
        self.init(rawValue: word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

enum ChatWindowLayout {
    /// Where a chat window goes: above the bar, up from the bottom, in the corner, or all of it.
    enum Presentation: Equatable {
        case window, sheet, panel, screen
    }

    /// What closing a sheet, a panel or a screen does: what the chevron does.
    enum Close: Equatable {
        /// Back to the call, where the agent offers both.
        case backToCall
        /// The chat was all there was: the bar closes.
        case closeBar
    }

    /// A sheet's top edge sits this share of the screen's height below the top safe area.
    static let sheetTop = 0.08
    /// A panel: this wide, and min(panelMaxHeight, panelHeight × the screen's height) tall.
    static let panelWidth = 420.0
    static let panelMaxHeight = 760.0
    static let panelHeight = 0.9
    /// In from the screen's edges (inside the safe area).
    static let panelInset = 24.0
    /// A window whose shorter side is at least this is a tablet's.
    static let tabletMinSide = 600.0

    /// The size to open at: the open's own, then the app's, then the design's, else compact.
    static func size(open: GraineChatSize?, config: GraineChatSize?, token: GraineChatSize?) -> GraineChatSize {
        open ?? config ?? token ?? .compact
    }

    /// How a size is drawn in a window this big (points).
    static func presentation(_ size: GraineChatSize, width: Double, height: Double) -> Presentation {
        switch size {
        case .compact: return .window
        case .large: return min(width, height) >= tabletMinSide ? .panel : .sheet
        case .full: return .screen
        }
    }

    /// A panel's size in a window this tall.
    static func panelSize(height: Double) -> (width: Double, height: Double) {
        let h = height.isFinite ? max(0, min(panelMaxHeight, panelHeight * height)) : 0
        return (panelWidth, h.rounded())
    }

    /// Where the bar draws its chat: nil while the customer is on the call.
    static func barPresentation(
        inChat: Bool, open: GraineChatSize?, config: GraineChatSize?, token: GraineChatSize?, width: Double, height: Double
    ) -> Presentation? {
        guard inChat else { return nil }
        return presentation(size(open: open, config: config, token: token), width: width, height: height)
    }

    static func close(canSwitch: Bool) -> Close {
        canSwitch ? .backToCall : .closeBar
    }
}
