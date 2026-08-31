import SwiftUI

/// A ranked horizontal rail of the week's trending posts, shown above the
/// main Discover grid. Self-contained (own fetch + state) the same way
/// `TrendingView` is, so it doesn't entangle `FeedViewModel`'s pagination
/// with a second, differently-sorted request.
struct TrendingRailView: View {
    @State private var items: [MediaItem] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading || !items.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Trending this week", systemImage: "flame.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        Spacer()
                        NavigationLink("See all", destination: TrendingView())
                            .font(.footnote)
                    }
                    .padding(.horizontal)

                    ScrollView(.horizontal, showsIndicators: false) {
                        // LazyHStack -- see SimilarMediaRail's identical
                        // fix/comment (capped at 10 items here, but still
                        // avoids rendering off-screen cards' thumbnails
                        // eagerly on every appearance).
                        LazyHStack(spacing: 12) {
                            if isLoading {
                                ForEach(0..<4, id: \.self) { _ in
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(.secondary.opacity(0.12))
                                        .frame(width: 132, height: 176)
                                }
                            } else {
                                ForEach(Array(items.prefix(10).enumerated()), id: \.element.id) { index, item in
                                    NavigationLink(destination: MediaDetailView(mediaId: item.id)) {
                                        TrendingCard(item: item, rank: index + 1)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
        }
        .task {
            items = (try? await GalleryAPIClient.shared.trendingMedia(days: 7, limit: 10)) ?? []
            isLoading = false
        }
    }
}

private struct TrendingCard: View {
    let item: MediaItem
    let rank: Int

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            thumbnail
                .frame(width: 132, height: 176)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            LinearGradient(colors: [.black.opacity(0.75), .black.opacity(0)], startPoint: .bottom, endPoint: .center)
                .frame(width: 132, height: 176)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .allowsHitTesting(false)

            Text("#\(rank)")
                .font(.caption.bold())
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title?.nilIfEmpty ?? "Untitled")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                if let likeCount = item.likeCount, likeCount > 0 {
                    Label("\(likeCount)", systemImage: "heart.fill")
                        .font(.caption2)
                }
            }
            .foregroundStyle(.white)
            .padding(8)
        }
        .frame(width: 132, height: 176)
        .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 3)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if item.locked == true {
            Rectangle().fill(.secondary.opacity(0.3)).overlay(Image(systemName: "eye.slash").foregroundStyle(.secondary))
        } else if let urlString = item.thumbUrl, let url = URL(string: urlString) {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                case .failure: Rectangle().fill(.secondary.opacity(0.2)).overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                default: Rectangle().fill(.secondary.opacity(0.1))
                }
            }
        } else {
            Rectangle().fill(.secondary.opacity(0.2)).overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        }
    }
}
