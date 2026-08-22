import SwiftUI

/// Unifies the old separate stats-row + action-row into one pill-button
/// bar, with view/download/file-size counts demoted to a lighter caption
/// line underneath (comment count stays visible via the Comments section
/// header below, so isn't duplicated here).
struct MediaActionBar: View {
    let media: MediaItem
    let isTogglingLike: Bool
    let isTogglingBookmark: Bool
    let onLike: () -> Void
    let onBookmark: () -> Void
    let onReport: () -> Void
    let onOpenOriginal: () -> Void

    @State private var likeBounce = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                pillButton(
                    icon: media.likedByMe == true ? "heart.fill" : "heart",
                    text: "\(media.likeCount ?? 0)",
                    active: media.likedByMe == true,
                    action: onLike
                )
                .scaleEffect(likeBounce ? 1.18 : 1.0)
                .disabled(isTogglingLike)

                pillButton(
                    icon: media.bookmarkedByMe == true ? "bookmark.fill" : "bookmark",
                    text: nil,
                    active: media.bookmarkedByMe == true,
                    action: onBookmark
                )
                .disabled(isTogglingBookmark)

                if let downloadUrl = media.downloadUrl, let url = URL(string: downloadUrl) {
                    ShareLink(item: url) { iconLabel("square.and.arrow.up") }
                }

                Spacer()

                Menu {
                    Button("Open Original", action: onOpenOriginal)
                    Button("Report", role: .destructive, action: onReport)
                } label: {
                    iconLabel("ellipsis")
                }
                .accessibilityLabel("More options")
            }

            HStack(spacing: 14) {
                Label("\(media.views ?? 0)", systemImage: "eye")
                Label("\(media.downloads ?? 0)", systemImage: "arrow.down.circle")
                if let fileSize = media.fileSize {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .onChange(of: media.likedByMe) { _ in
            withAnimation(.spring(response: 0.22, dampingFraction: 0.4)) { likeBounce = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                withAnimation(.spring(response: 0.22, dampingFraction: 0.6)) { likeBounce = false }
            }
        }
    }

    private func pillButton(icon: String, text: String?, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                if let text {
                    Text(text).font(.footnote.weight(.semibold))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(active ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(Color.secondary.opacity(0.12)), in: Capsule())
            .foregroundStyle(active ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func iconLabel(_ icon: String) -> some View {
        Image(systemName: icon)
            .padding(10)
            .background(Color.secondary.opacity(0.12), in: Circle())
            .foregroundStyle(Color.primary)
    }
}
