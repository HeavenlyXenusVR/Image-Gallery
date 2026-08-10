import SwiftUI

/// Following / Liked feeds — mirrors the web app's FeedPage.jsx (mode
/// "following"/"liked"), both newly wired up now that the backend actually
/// serves GET /api/feed/following and GET /api/me/likes. Kept as one screen
/// with a segmented switch rather than two, matching how TrendingView
/// already handles its own window switch inline.
struct FollowingLikedView: View {
    enum Mode: String, CaseIterable {
        case following = "Following"
        case liked = "Liked"
    }

    @State private var mode: Mode = .following
    @State private var items: [MediaItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 8)]

    var body: some View {
        ScrollView {
            Picker("Feed", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding()
            .onChange(of: mode) { _ in Task { await load() } }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).padding()
            }

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(items) { item in
                    NavigationLink(destination: MediaDetailView(mediaId: item.id)) {
                        MediaCard(item: item)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)

            if items.isEmpty && !isLoading {
                ContentUnavailableCompat(
                    title: mode == .following ? "No posts from people you follow yet" : "Nothing liked yet",
                    systemImage: mode == .following ? "person.2" : "heart"
                )
                .padding(.top, 60)
            }
        }
        .navigationTitle(mode.rawValue)
        .refreshable { await load() }
        .task { await load() }
        .overlay {
            if isLoading && items.isEmpty {
                ProgressView()
            }
        }
    }

    private func load() async {
        let requestedMode = mode
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let fetched = requestedMode == .following
                ? try await GalleryAPIClient.shared.followingFeed()
                : try await GalleryAPIClient.shared.likedFeed()
            guard requestedMode == mode else { return }
            items = fetched
        } catch {
            guard requestedMode == mode else { return }
            errorMessage = error.localizedDescription
        }
    }
}
