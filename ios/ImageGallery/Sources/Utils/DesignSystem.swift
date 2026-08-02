import SwiftUI

/// Shared visual language for the redesign pass — corner radii, spacing, and
/// a couple of reusable card/pill modifiers so every screen stops hand-rolling
/// its own `RoundedRectangle(cornerRadius: 14)` / `Color.secondary.opacity(0.12)`
/// with slightly different numbers. Intentionally small: this is a set of
/// tokens views opt into, not a full component library.
enum Metrics {
    enum Radius {
        static let sm: CGFloat = 10
        static let md: CGFloat = 16
        static let lg: CGFloat = 22
    }

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }
}

private struct SoftCardBackground: ViewModifier {
    var radius: CGFloat = Metrics.Radius.md
    var tinted: Bool = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(tinted ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(.thinMaterial))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }
}

private struct CardShadow: ViewModifier {
    func body(content: Content) -> some View {
        content.shadow(color: .black.opacity(0.14), radius: 10, x: 0, y: 4)
    }
}

extension View {
    /// A frosted "glass" card background + hairline border, replacing the
    /// ad-hoc `Color.secondary.opacity(0.1...0.15)` fills that were
    /// previously copy-pasted with slightly different values per view.
    func softCard(radius: CGFloat = Metrics.Radius.md, tinted: Bool = false) -> some View {
        modifier(SoftCardBackground(radius: radius, tinted: tinted))
    }

    /// Standard elevated-card drop shadow (media cards, floating panels).
    func cardShadow() -> some View {
        modifier(CardShadow())
    }
}

/// A soft diagonal wash behind profile/collection headers, tinted to the
/// given accent color so every profile still feels personalized (mirrors
/// `accent_color` driving the web app's profile hero) rather than a flat
/// system background.
struct AccentWash: View {
    var color: Color

    var body: some View {
        LinearGradient(
            colors: [color.opacity(0.35), color.opacity(0.05), .clear],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
