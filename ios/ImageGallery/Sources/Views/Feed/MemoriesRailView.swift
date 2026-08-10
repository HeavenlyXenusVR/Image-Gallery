import SwiftUI

/// "On this day" -- mirrors DiscoverMemories on the web (frontend/src/
/// components/discover.jsx), which itself was the first UI anywhere (web or
/// iOS) for a backend endpoint that's existed since 2026-08-03. Same
/// self-contained-fetch shape as TrendingRailView; renders nothing when
/// there's nothing from today in a past year.
struct MemoriesRailView: View {
    @EnvironmentObject private var session: SessionStore
    @State private var items: [MediaItem] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Label("On this day", systemImage: "sparkles")
                        .font(.headline)
                        .foregroundStyle(.purple)
                        .padding(.horizontal)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(items) { item in
                                NavigationLink(destination: MediaDetailView(mediaId: item.id)) {
                                    MemoryCard(item: item)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
        }
        .task {
            guard !loaded, session.currentUser != nil else { return }
            loaded = true
            items = (try? await GalleryAPIClient.shared.memories()) ?? []
        }
    }
}

private struct MemoryCard: View {
    let item: MediaItem

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            thumbnail
                .frame(width: 132, height: 176)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            LinearGradient(colors: [.black.opacity(0.75), .black.opacity(0)], startPoint: .bottom, endPoint: .center)
                .frame(width: 132, height: 176)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .allowsHitTesting(false)

            if let yearsAgo = item.yearsAgo {
                Text("\(yearsAgo)y ago")
                    .font(.caption.bold())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            Text(item.title?.nilIfEmpty ?? "Untitled")
                .font(.caption)
                .fontWeight(.semibold)
                .lineLimit(1)
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
            AsyncImage(url: url) { phase in
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
