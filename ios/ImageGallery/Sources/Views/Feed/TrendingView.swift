import SwiftUI

struct TrendingView: View {
    @State private var items: [MediaItem] = []
    @State private var days = 7
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 8)]

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
