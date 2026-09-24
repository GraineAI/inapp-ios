import Foundation

/**
 * WHERE THE BAR MAY SIT — as arithmetic, with no UIKit import.
 *
 * The bar is anchored to the bottom; the customer drags it up or down and the
 * result is an OFFSET added to that anchor. The offset is clamped so the bar
 * can never leave the screen: never below its anchor, never above the point
 * where its top would pass the top margin. A port of the React Native SDK's
 * placement-math.ts, pinned to the same test cases.
 *
 * Persistence is the host's: it knows where it keeps preferences, and this
 * package deliberately has no storage of its own. The bar reports the offset
 * when the customer lets go, and accepts one back at launch.
 */
enum PlacementMath {
    /// A drag that moved less than this, in points, is a tap — and the tap must still work.
    static let dragSlop: Double = 8

    struct Bounds {
        /// The height of the area the bar floats in.
        var windowHeight: Double
        /// Where the bar sits with no offset.
        var baseBottom: Double
        /// The bar's rendered height, as last measured. 0 before the first layout.
        var barHeight: Double
        /// Space to keep clear at the top — status bar, notch.
        var topMargin: Double = 48
    }

    /**
     * Clamp a proposed offset to what the screen allows. With no measurement
     * yet (barHeight 0) the upper bound assumes a bar of modest height, so a
     * drag before the first layout cannot fling it off-screen. A non-finite
     * offset is not a position anyone chose; the anchor is the only honest answer.
     */
    static func clampOffset(_ offset: Double, _ b: Bounds) -> Double {
        guard offset.isFinite else { return 0 }
        let height = b.barHeight > 0 ? b.barHeight : 64
        let maxOffset = max(0, b.windowHeight - b.topMargin - height - b.baseBottom)
        return JSON.jsRound(min(max(offset, 0), maxOffset))
    }

    /// The offset during a drag: where it started, plus how far the finger moved UP (dy grows downward).
    static func offsetDuringDrag(start: Double, dy: Double, _ b: Bounds) -> Double {
        clampOffset(start - dy, b)
    }

    /// A movement smaller than the slop, in both axes, is a tap.
    static func isTap(dx: Double, dy: Double) -> Bool {
        abs(dx) < dragSlop && abs(dy) < dragSlop
    }

    /**
     * How far above the bottom of its area the bar sits, keyboard included.
     *
     * The keyboard lifts the bar from wherever the customer left it — but only
     * as far as it has to. React Native adds the keyboard's height to the
     * dragged offset, which sends a bar the customer parked high up off the top
     * of the screen; here the bar rests at its offset unless the keyboard would
     * reach it, and then it sits the anchor's distance above the keyboard. So
     * the bar, and anything riding in it, is never under the keys.
     */
    static func bottomDistance(baseBottom: Double, offset: Double, keyboardLift: Double) -> Double {
        let resting = baseBottom + offset
        guard keyboardLift > 0 else { return resting }
        return max(resting, baseBottom + keyboardLift)
    }
}

/**
 * HOW FAR A BOTTOM-ANCHORED BAR MUST RISE TO STAY ABOVE THE KEYBOARD — the
 * keyboard's height minus whatever the window already moved (React Native's
 * keyboard-math.ts). On iOS the window never shrinks for the keyboard, so the
 * iOS bar measures the keyboard's actual overlap with its own area and passes
 * a shrink of 0 — which also means that if SwiftUI has already moved the area
 * up, the overlap is 0 and the bar is not lifted twice.
 */
enum KeyboardMath {
    static func liftFor(keyboardHeight: Double, windowShrink: Double) -> Double {
        guard keyboardHeight > 0 else { return 0 }
        let shrink = windowShrink > 0 ? windowShrink : 0
        return max(0, JSON.jsRound(keyboardHeight - shrink))
    }

    /**
     * How much of an area the keyboard covers from below: 0 when it is hidden,
     * off to one side (a floating iPad keyboard), or entirely below the area.
     * Rectangles are in one coordinate space, as (minX, minY, maxX, maxY).
     */
    static func overlap(
        areaMinX: Double, areaMaxX: Double, areaMaxY: Double,
        keyboardMinX: Double, keyboardMinY: Double, keyboardMaxX: Double, keyboardHeight: Double
    ) -> Double {
        guard keyboardHeight > 0 else { return 0 }
        guard keyboardMaxX > areaMinX && keyboardMinX < areaMaxX else { return 0 }
        return max(0, areaMaxY - keyboardMinY)
    }
}
