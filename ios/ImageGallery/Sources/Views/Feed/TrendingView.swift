import SwiftUI

struct TrendingView: View {
    @State private var items: [MediaItem] = []
    @State private var days = 7
    @State private var isLoading = true
    @State private var errorMessage: String?
    @EnvironmentObject private var session: SessionStore

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Appearance.gridColumnMinWidth(session.currentUser?.userSettings?.gridDensity)), spacing: 8)]
    }

    var body: some View {
        ScrollView {
            Picker("Window", selection: $days) {
                Text("24 hours").tag(1)
                Text("7 days").tag(7)
                Text("30 days").tag(30)
            }
            .pickerStyle(.segmented)
            .padding()
            .onChange(of: days) { _ in
                Task { await load() }
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).padding()
            }

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(items) { item in
                    NavigationLink(destination: MediaDetailView(mediaId: item.id)) {
                        MediaCard(item: item)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)

            if items.isEmpty && !isLoading {
                ContentUnavailableCompat(title: "Nothing trending yet", systemImage: "flame")
                    .padding(.top, 60)
            }

            LeaderboardSection()
                .padding(.top, 8)
        }
        .navigationTitle("Trending")
        .refreshable { await load() }
        .task { await load() }
        .overlay {
            if isLoading && items.isEmpty {
                ProgressView()
            }
        }
    }

    private func load() async {
        let requestedDays = days
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let fetched = try await GalleryAPIClient.shared.trendingMedia(days: requestedDays)
            // Discard a response for a window the user has since changed away
            // from — rapid segment taps could otherwise let an older request
            // land after a newer one and show the wrong window's results.
            guard requestedDays == days else { return }
            items = fetched
        } catch {
            guard requestedDays == days else { return }
            errorMessage = error.localizedDescription
        }
    }
}

/// "Top creators" ranking, shown below the trending grid — same relationship
/// the web app's TrendingPage.jsx has (a Leaderboard section under the
/// trending posts). Self-contained fetch/state, same pattern as
/// `TrendingRailView`.
private struct LeaderboardSection: View {
    @State private var entries: [LeaderboardEntry] = []
    @State private var window = "30d"
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Top creators", systemImage: "trophy.fill")
                    .font(.headline)
                    .foregroundStyle(.yellow)
                Spacer()
                Picker("Window", selection: $window) {
                    Text("7d").tag("7d")
                    Text("30d").tag("30d")
                    Text("All").tag("all")
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .onChange(of: window) { _ in Task { await load() } }
            }
            .padding(.horizontal)

            if isLoading {
                ProgressView().frame(maxWidth: .infinity).padding()
            } else if entries.isEmpty {
                Text("No creator activity in this window yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        NavigationLink(destination: ProfileView(username: entry.username)) {
                            HStack(spacing: 10) {
                                Text("\(index + 1)")
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20, alignment: .trailing)
                                AvatarView(urlString: entry.userAvatarUrl, fallbackInitial: String(entry.username.prefix(1)), shape: .circle, size: 28)
                                Text(entry.displayName ?? entry.username)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(entry.totalViews) views · \(entry.totalLikes) likes")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        let requestedWindow = window
        isLoading = true
        do {
            let fetched = try await GalleryAPIClient.shared.leaderboard(window: requestedWindow)
            guard requestedWindow == window else { return }
            entries = fetched
        } catch {
            guard requestedWindow == window else { return }
            entries = []
        }
        isLoading = false
    }
}
