import SwiftUI

struct FeedView: View {
    @StateObject private var viewModel = FeedViewModel()
    @State private var showingFilters = false

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 8)]

    var body: some View {
        ScrollView {
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage).foregroundStyle(.red).padding()
            }

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(viewModel.items) { item in
                    NavigationLink(destination: MediaDetailView(mediaId: item.id)) {
                        MediaCard(item: item)
                    }
                    .buttonStyle(.plain)
                    .task {
                        await viewModel.loadMoreIfNeeded(currentItem: item)
                    }
                }
            }
            .padding(.horizontal)

            if viewModel.isLoadingMore {
                ProgressView().padding()
            }

            if viewModel.items.isEmpty && !viewModel.isLoading {
                ContentUnavailableCompat(title: "No media found", systemImage: "photo.on.rectangle.angled")
                    .padding(.top, 60)
            }
        }
        .navigationTitle("Discover")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink(destination: UserSearchView()) {
                    Image(systemName: "person.crop.circle.badge.plus")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink(destination: CollectionsListView()) {
                    Image(systemName: "folder")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingFilters = true
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .sheet(isPresented: $showingFilters) {
            FeedFilterSheet(viewModel: viewModel)
        }
        .refreshable {
            await viewModel.loadInitial()
        }
        .task {
            if viewModel.items.isEmpty {
                await viewModel.loadInitial()
            }
        }
        .overlay {
            if viewModel.isLoading && viewModel.items.isEmpty {
                ProgressView()
            }
        }
    }
}

/// `ContentUnavailableView` is iOS 17+; this app's deployment target is iOS 16,
/// so a tiny compatibility shim covers the empty-state look on iOS 16 devices.
struct ContentUnavailableCompat: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 40)).foregroundStyle(.secondary)
            Text(title).foregroundStyle(.secondary)
        }
    }
}
