#if os(iOS)
import SwiftUI

extension Color {
    /// "#rrggbb" or "#rgb" (the "#" optional) → a colour; anything unreadable → `fallback`.
    static func graineHex(_ hex: String?, fallback: Color = Color(red: 0.19, green: 0.55, blue: 0.91)) -> Color {
        guard let hex = hex, let c = Appearance.rgb(hex) else { return fallback }
        return Color(red: c.red, green: c.green, blue: c.blue)
    }
}

/// The bar's surfaces; the accent comes from the dashboard. Same sets as the React Native bar.
struct GraineBarPalette {
    let surface: Color
    let border: Color
    let text: Color
    let sub: Color
    let chip: Color
    let onAccent: Color
    let danger: Color

    static let dark = GraineBarPalette(
        surface: .graineHex("#17161A"),
        border: Color.white.opacity(0.09),
        text: .graineHex("#F2F3F5"),
        sub: .graineHex("#9AA0A6"),
        chip: Color.white.opacity(0.08),
        onAccent: .white,
        danger: .graineHex("#E5484D")
    )

    static let light = GraineBarPalette(
        surface: .white,
        border: Color.black.opacity(0.10),
        text: .graineHex("#16181C"),
        sub: .graineHex("#61666D"),
        chip: Color.black.opacity(0.05),
        onAccent: .white,
        danger: .graineHex("#D32F2F")
    )
}
#endif
