import SwiftUI

/// Renders a user's avatar respecting their `profile_avatar_shape` setting
/// (circle/rounded/square — same values the web app stores), so a profile
/// styled on web doesn't look reset to default here.
struct AvatarView: View {
    let urlString: String?
    let fallbackInitial: String
    var shape: AvatarShape = .circle
    var size: CGFloat = 44

    var body: some View {
        content
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * shape.cornerRadiusFraction))
    }

    @ViewBuilder
    private var content: some View {
        if let urlString, let url = URL(string: urlString) {
            CachedAsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(.secondary.opacity(0.2))
            .overlay(Text(fallbackInitial.uppercased()).font(.system(size: size * 0.4)))
    }
}
