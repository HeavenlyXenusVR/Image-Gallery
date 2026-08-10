import SwiftUI

struct CollectionsListView: View {
    @State private var collections: [CollectionSummary] = []
    @State private var isLoading = true
    @State private var showMineOnly = false
    @State private var showingNewCollection = false
    @State private var errorMessage: String?
    @State private var suggestions: [CollectionSuggestion] = []
    @State private var creatingSuggestionTag: String?

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            if showMineOnly && !suggestions.isEmpty {
                Section("Suggested collections") {
                    ForEach(suggestions) { suggestion in
                        Button {
                            Task { await createSuggestedCollection(suggestion) }
                        } label: {
                            HStack {
                                if let urlString = suggestion.thumbUrl, let url = URL(string: urlString) {
                                    AsyncImage(url: url) { phase in
                                        if case .success(let image) = phase {
                                            image.resizable().scaledToFill()
                                        } else {
                                            Color.secondary.opacity(0.2)
                                        }
                                    }
                                    .frame(width: 36, height: 36)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(suggestion.tag.capitalized)
                                    Text("\(suggestion.count) posts").font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if creatingSuggestionTag == suggestion.tag {
                                    ProgressView()
                                } else {
                                    Image(systemName: "plus.circle")
                                }
                            }
                        }
                        .disabled(creatingSuggestionTag != nil)
                    }
                }
            }
            ForEach(collections) { collection in
                CollectionRow(collection: collection)
            }
        }
        .navigationTitle("Collections")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Toggle("Mine", isOn: $showMineOnly).toggleStyle(.button)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingNewCollection = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New collection")
            }
        }
        .sheet(isPresented: $showingNewCollection) {
            NewCollectionView { _ in
                Task { await load() }
            }
        }
        .overlay {
            if isLoading {
                ProgressView()
            } else if collections.isEmpty && errorMessage == nil {
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
        do {
            collections = try await GalleryAPIClient.shared.collections(mine: showMineOnly)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load collections: \(error.localizedDescription)"
        }
        if showMineOnly {
            suggestions = (try? await GalleryAPIClient.shared.collectionSuggestions()) ?? []
        } else {
            suggestions = []
        }
    }

    private func createSuggestedCollection(_ suggestion: CollectionSuggestion) async {
        creatingSuggestionTag = suggestion.tag
        defer { creatingSuggestionTag = nil }
        do {
            let filter = DiscoverFilterPayload(mediaKind: nil, categoryId: nil, subcategoryId: nil, q: suggestion.tag, uploader: nil, minSize: nil, maxSize: nil, dateFrom: nil, dateTo: nil, adult: nil, sort: nil)
            _ = try await GalleryAPIClient.shared.createCollection(name: suggestion.tag.capitalized, description: nil, isPublic: true, isSmart: true, filter: filter)
            suggestions.removeAll { $0.tag == suggestion.tag }
            await load()
            Haptics.success()
        } catch {
            errorMessage = "Couldn't create collection: \(error.localizedDescription)"
            Haptics.error()
        }
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
    @State private var errorMessage: String?
    @State private var isDownloading = false
    @State private var downloadURL: URL?
    @State private var showingDownloadShare = false

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]

    var body: some View {
        ScrollView {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).padding()
            }
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await downloadCollection() }
                } label: {
                    if isDownloading {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.down.circle")
                    }
                }
                .accessibilityLabel("Download collection")
                .disabled(isDownloading || media.isEmpty)
            }
        }
        .overlay {
            if isLoading {
                ProgressView()
            } else if media.isEmpty && errorMessage == nil {
                ContentUnavailableCompat(title: "No media in this collection", systemImage: "folder")
            }
        }
        .sheet(isPresented: $showingDownloadShare) {
            if let downloadURL {
                ShareSheet(activityItems: [downloadURL])
            }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await GalleryAPIClient.shared.collectionDetail(id: collectionId)
            collection = response.collection
            media = response.media ?? []
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load this collection: \(error.localizedDescription)"
        }
    }

    private func downloadCollection() async {
        isDownloading = true
        defer { isDownloading = false }
        do {
            let data = try await GalleryAPIClient.shared.downloadCollection(id: collectionId)
            let safeName = (collection?.name ?? "collection").replacingOccurrences(of: "[^A-Za-z0-9-_ ]", with: "", options: .regularExpression)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeName.isEmpty ? "collection" : safeName).zip")
            try data.write(to: url)
            downloadURL = url
            showingDownloadShare = true
            Haptics.success()
        } catch {
            errorMessage = "Couldn't download this collection: \(error.localizedDescription)"
            Haptics.error()
        }
    }
}
