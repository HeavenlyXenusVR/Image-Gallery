import SwiftUI

struct MediaCard: View {
    let item: MediaItem

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay(thumbnail)
            .overlay(alignment: .bottom) { scrim }
            .overlay(alignment: .bottom) { footer }
            .overlay(alignment: .topTrailing) { kindBadge }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.16), radius: 6, x: 0, y: 3)
    }

    // A dark gradient anchored to the bottom edge so the title/stat footer
    // stays legible over busy thumbnails without a solid overlay flattening
    // the whole card.
    private var scrim: some View {
        LinearGradient(
            colors: [.black.opacity(0.65), .black.opacity(0)],
            startPoint: .bottom,
            endPoint: .top
        )
        .frame(height: 56)
        .allowsHitTesting(false)
    }

    private var footer: some View {
        HStack(alignment: .lastTextBaseline, spacing: 6) {
            Text(item.title?.nilIfEmpty ?? "Untitled")
                .font(.caption)
                .fontWeight(.semibold)
                .lineLimit(1)
                .foregroundStyle(.white)
            Spacer(minLength: 4)
            if let likeCount = item.likeCount, likeCount > 0 {
                Label("\(likeCount)", systemImage: "heart.fill")
                    .labelStyle(.compactStat)
            }
        }
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var kindBadge: some View {
        if item.locked == true {
            badgeIcon("lock.fill")
        } else if item.isVideo {
            badgeIcon("play.fill")
        }
    }

    private func badgeIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.caption2)
            .padding(6)
            .background(.black.opacity(0.55), in: Circle())
            .foregroundStyle(.white)
            .padding(6)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if item.locked == true {
            Rectangle()
                .fill(.secondary.opacity(0.3))
                .overlay(Image(systemName: "eye.slash").foregroundStyle(.secondary))
        } else if let urlString = item.thumbUrl, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    Rectangle().fill(.secondary.opacity(0.2)).overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                default:
                    Rectangle().fill(.secondary.opacity(0.1))
                }
            }
        } else {
            Rectangle().fill(.secondary.opacity(0.2)).overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        }
    }
}

private struct CompactStatLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

private extension LabelStyle where Self == CompactStatLabelStyle {
    static var compactStat: CompactStatLabelStyle { CompactStatLabelStyle() }
}
