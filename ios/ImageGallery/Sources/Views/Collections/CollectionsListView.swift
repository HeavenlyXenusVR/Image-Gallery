import SwiftUI

struct CollectionsListView: View {
    @State private var collections: [CollectionSummary] = []
    @State private var isLoading = true
    @State private var showMineOnly = false

    var body: some View {
        List {
            ForEach(collections) { collection in
                CollectionRow(collection: collection)
            }
        }
        .navigationTitle("Collections")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Toggle("Mine", isOn: $showMineOnly).toggleStyle(.button)
            }
        }
        .overlay {
            if isLoading {
                ProgressView()
            } else if collections.isEmpty {
                ContentUnavailableCompat(title: "No collections yet", systemImage: "folder")
            }
        }
        .onChange(of: showMineOnly) { _ in
            Task { await load() }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        collections = (try? await GalleryAPIClient.shared.collections(mine: showMineOnly)) ?? []
    }
}

/// Split out of `CollectionsListView.body` — a single `var body` combining
/// this row's nested optionals with the list's own modifier chain was slow
/// enough to trip Swift's type-checker timeout ("unable to type-check this
/// expression in reasonable time").
private struct CollectionRow: View {
    let collection: CollectionSummary

    var body: some View {
        NavigationLink(destination: CollectionDetailView(collectionId: collection.id)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(collection.name).bold()
                if let description = collection.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if collection.isSmart == true {
                    Text("Smart collection")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }
}

struct CollectionDetailView: View {
    let collectionId: Int
    @State private var collection: CollectionSummary?
    @State private var media: [MediaItem] = []
    @State private var isLoading = true

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(media) { item in
                    NavigationLink(destination: MediaDetailView(mediaId: item.id)) {
                        MediaCard(item: item)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .navigationTitle(collection?.name ?? "Collection")
        .overlay {
            if isLoading {
                ProgressView()
            } else if media.isEmpty {
                ContentUnavailableCompat(title: "No media in this collection", systemImage: "folder")
            }
        }
        .task {
            isLoading = true
            defer { isLoading = false }
            if let response = try? await GalleryAPIClient.shared.collectionDetail(id: collectionId) {
                collection = response.collection
                media = response.media ?? []
            }
        }
    }
}
