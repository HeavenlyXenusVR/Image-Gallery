import SwiftUI
import UIKit

/// Shared helpers for rendering account-level appearance settings
/// (`user_settings.accent_color`/`profile_layout`/`profile_avatar_shape`) —
/// mirrors what `frontend/src/utils/appearance.js` does for the web app, kept
/// deliberately small since iOS only supports a handful of these settings.
enum Appearance {
    static let defaultAccentHex = "#37c9a7"

    /// "spotlight" (the web default) and anything unrecognized render as the
    /// standard native layout; "mosaic" renders as the grid-first layout.
    /// Web supports four more layout names (magazine/stack/split/timeline)
    /// that don't have distinct native treatments yet — they fall back to
    /// standard rather than erroring.
    static func isGridFirstLayout(_ profileLayout: String?) -> Bool {
        profileLayout == "mosaic"
    }
}

enum AvatarShape: String {
    case circle
    case rounded
    case square

    init(_ raw: String?) {
        self = AvatarShape(rawValue: raw ?? "") ?? .circle
    }

    var cornerRadiusFraction: CGFloat {
        switch self {
        case .circle: return 0.5
        case .rounded: return 0.22
        case .square: return 0.06
        }
    }
}

extension Color {
    /// Accepts "#rrggbb", "rrggbb", or shorthand "#rgb" — the same formats
    /// the web app's color inputs produce. Falls back to the app's default
    /// accent on anything else so a malformed stored value never crashes
    /// rendering or shows a jarring color.
    init(hex: String?) {
        let cleaned = (hex ?? "").trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        var value: UInt64 = 0
        let normalized: String
        switch cleaned.count {
        case 3:
            normalized = cleaned.map { "\($0)\($0)" }.joined()
        case 6:
            normalized = cleaned
        default:
            self = Color(hex: Appearance.defaultAccentHex)
            return
        }
        guard Scanner(string: normalized).scanHexInt64(&value) else {
            self = Color(hex: Appearance.defaultAccentHex)
            return
        }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }

    /// Inverse of `init(hex:)`, for sending a `ColorPicker` selection back to
    /// the backend's `accent_color` string field.
    func toHexString() -> String {
        let uiColor = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}
