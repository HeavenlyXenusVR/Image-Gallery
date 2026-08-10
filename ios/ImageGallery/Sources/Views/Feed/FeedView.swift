import SwiftUI

struct FeedView: View {
    @StateObject private var viewModel = FeedViewModel()
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var unreadCounts: UnreadCountsService
    @State private var showingFilters = false
    @FocusState private var searchFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                greeting

                searchField

                if !isFiltering {
                    TrendingRailView()
                }

                CategoryChipsRow(selectedCategoryId: $viewModel.categoryId) { categoryId in
                    viewModel.categoryId = categoryId
                    viewModel.subcategoryId = nil
                    Task { await viewModel.loadInitial() }
                }

                SortChipsRow(sort: $viewModel.sort) {
                    Task { await viewModel.loadInitial() }
                }

                resultsSection
            }
            .padding(.vertical, 12)
        }
        .navigationTitle("Discover")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink(destination: UserSearchView()) {
                    Image(systemName: "person.crop.circle.badge.plus")
                }
                .accessibilityLabel("Find people")
            }
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink(destination: CollectionsListView()) {
                    Image(systemName: "folder")
                }
                .accessibilityLabel("Collections")
            }
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink(destination: FollowingLikedView()) {
                    Image(systemName: "person.2")
                }
                .accessibilityLabel("Following and liked")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingFilters = true
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("More filters")
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(destination: NotificationsView()) {
                    Image(systemName: "bell")
                }
                .accessibilityLabel("Notifications")
                .overlay(alignment: .topTrailing) {
                    if unreadCounts.notifications > 0 {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                            .offset(x: 2, y: -2)
                    }
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
    }

    private var isFiltering: Bool {
        !viewModel.query.isEmpty || viewModel.categoryId != nil || viewModel.subcategoryId != nil
    }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(timeOfDayGreeting)
                .font(.title2).bold()
            Text("Here's what the archive's been up to.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    private var timeOfDayGreeting: String {
        let name = session.currentUser?.displayName?.nilIfEmpty ?? session.currentUser?.username ?? "there"
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning, \(name)"
        case 12..<17: return "Good afternoon, \(name)"
        case 17..<22: return "Good evening, \(name)"
        default: return "Still up, \(name)?"
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search wallpapers, memes, tags…", text: $viewModel.query)
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit { Task { await viewModel.loadInitial() } }
            if !viewModel.query.isEmpty {
                Button {
                    viewModel.query = ""
                    searchFocused = false
                    Task { await viewModel.loadInitial() }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .softCard()
        .padding(.horizontal)
    }

    @ViewBuilder
    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isFiltering ? "Results" : "Fresh uploads")
                .font(.headline)
                .padding(.horizontal)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage).foregroundStyle(.red).padding(.horizontal)
            }

            if viewModel.isLoading && viewModel.items.isEmpty {
                SkeletonGridView(columns: columns)
            } else if viewModel.items.isEmpty {
                ContentUnavailableCompat(title: "No media found", systemImage: "photo.on.rectangle.angled")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            } else {
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
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
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
