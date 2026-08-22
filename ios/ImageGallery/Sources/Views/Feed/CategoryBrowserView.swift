import SwiftUI

struct CategoryBrowserView: View {
    @State private var categories: [CategorySummary] = []
    @State private var isLoading = true

    var body: some View {
        List {
            ForEach(categories) { category in
                Section(category.name) {
                    NavigationLink(destination: CategoryMediaView(categoryId: category.id, title: category.name)) {
                        Label("All \(category.name)", systemImage: "square.grid.2x2")
                    }
                    ForEach(category.subcategories ?? []) { subcategory in
                        NavigationLink(destination: CategoryMediaView(categoryId: category.id, subcategoryId: subcategory.id, title: subcategory.name)) {
                            Text(subcategory.name)
                        }
                    }
                }
            }
        }
        .navigationTitle("Categories")
        .overlay {
            if isLoading { ProgressView() }
        }
        .task {
            isLoading = true
            categories = (try? await GalleryAPIClient.shared.categories()) ?? []
            isLoading = false
        }
    }
}

/// A single category's (or subcategory's) media grid — reuses `MediaCard`
/// and `FeedViewModel`'s pagination the same way `FeedView` does, just
/// pre-filtered and without the filter sheet/search/collections toolbar.
struct CategoryMediaView: View {
    let categoryId: Int
    var subcategoryId: Int?
    let title: String

    @StateObject private var viewModel = FeedViewModel()
    @EnvironmentObject private var session: SessionStore
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Appearance.gridColumnMinWidth(session.currentUser?.userSettings?.gridDensity)), spacing: 8)]
    }

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
                    .task { await viewModel.loadMoreIfNeeded(currentItem: item) }
                }
            }
            .padding(.horizontal)

            if viewModel.items.isEmpty && !viewModel.isLoading {
                ContentUnavailableCompat(title: "No media in \(title) yet", systemImage: "photo.on.rectangle.angled")
                    .padding(.top, 60)
            }
        }
        .navigationTitle(title)
        .refreshable { await viewModel.loadInitial() }
        .task {
            viewModel.categoryId = categoryId
            viewModel.subcategoryId = subcategoryId
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
