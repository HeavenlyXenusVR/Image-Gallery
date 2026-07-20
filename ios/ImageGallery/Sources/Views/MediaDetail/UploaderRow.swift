import SwiftUI

/// Avatar+name navigable card replacing the plain `Label` uploader link.
/// `media.userAvatarUrl` is already a full URL (populated by the backend's
/// `_with_urls` on the media detail response), unlike a comment's
/// `userAvatarPath` — no client-side reconstruction needed here.
struct UploaderRow: View {
    let media: MediaItem

    var body: some View {
        if let username = media.username {
            NavigationLink(destination: ProfileView(username: username)) {
                HStack(spacing: 10) {
                    AvatarView(urlString: media.userAvatarUrl, fallbackInitial: String((media.displayName ?? username).prefix(1)), size: 40)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(media.displayName ?? username).font(.subheadline.bold())
                        Text("@\(username)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }
}
