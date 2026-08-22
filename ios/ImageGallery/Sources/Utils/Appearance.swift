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

    /// Maps `grid_density` ("compact"/"comfortable"/"wide", same three
    /// choices the web app's Settings page offers) to a `GridItem(.adaptive
    /// (minimum:))` column width. `default_` is what every media grid used
    /// unconditionally before this setting existed, so it stays the
    /// fallback for "comfortable" and anything unrecognized.
    static func gridColumnMinWidth(_ gridDensity: String?, default_: CGFloat = 110) -> CGFloat {
        switch gridDensity {
        case "compact": return max(70, default_ - 30)
        case "wide": return default_ + 40
        default: return default_
        }
    }

    /// `column_gap` -- exact pixel values web's COLUMN_GAP_MAP
    /// (frontend/src/utils/appearance.js) uses for `--media-grid-gap`.
    static func gridSpacing(_ columnGap: String?) -> CGFloat {
        switch columnGap {
        case "none": return 0
        case "tight": return 8
        case "wide": return 24
        default: return 14
        }
    }

    /// `card_aspect_ratio` -- "free" (the source image's own aspect ratio)
    /// has no native equivalent here without a masonry-style variable-height
    /// grid layout (LazyVGrid always sizes every cell in a row to the same
    /// height), so it falls back to square rather than attempting that.
    static func cardAspectRatio(_ value: String?) -> CGFloat {
        switch value {
        case "16:9": return 16.0 / 9.0
        case "4:3": return 4.0 / 3.0
        case "3:4": return 3.0 / 4.0
        default: return 1
        }
    }
}

/// `card_info_display` -- mirrors web's four `gallery-info-*` CSS modes
/// (frontend/src/styles.css). "overlay" drops the hover-fade-in web does
/// (`opacity 0 -> 1 on hover`) since there's no hover state on touch; it's
/// simply always visible here instead.
enum CardInfoDisplay: String {
    case below, overlay, minimal, hidden

    init(_ raw: String?) {
        self = CardInfoDisplay(rawValue: raw ?? "") ?? .below
    }
}

/// `media_border_style` -- mirrors web's four `gallery-border-*` CSS modes.
/// web's "soft" vs "crisp" distinction is a subtle corner-radius nuance
/// (rounded image corners vs. rounded card + square image corners); this
/// gives crisp a real, more clearly differentiated treatment (sharp corners
/// + a thin border) rather than reproducing a difference too subtle to
/// notice at card size.
enum MediaBorderStyle: String {
    case none, soft, crisp, glow, neon

    init(_ raw: String?) {
        self = MediaBorderStyle(rawValue: raw ?? "") ?? .none
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
