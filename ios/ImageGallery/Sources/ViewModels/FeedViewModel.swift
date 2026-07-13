import Combine
import Foundation

@MainActor
final class FeedViewModel: ObservableObject {
    @Published var items: [MediaItem] = []
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var errorMessage: String?
    @Published var query = ""
    @Published var mediaKind: String? // nil, "image", "video"
    @Published var sort = "new"
    @Published var categoryId: Int?

    private let api = GalleryAPIClient.shared
    private var offset = 0
    private let pageSize = 60
    private var reachedEnd = false

    func loadInitial() async {
        offset = 0
        reachedEnd = false
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            items = try await api.listMedia(mediaKind: mediaKind, categoryId: categoryId, query: query, sort: sort, limit: pageSize, offset: 0)
            offset = items.count
            reachedEnd = items.count < pageSize
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMoreIfNeeded(currentItem item: MediaItem) async {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        guard index >= items.count - 6, !reachedEnd, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let next = try await api.listMedia(mediaKind: mediaKind, categoryId: categoryId, query: query, sort: sort, limit: pageSize, offset: offset)
            items.append(contentsOf: next)
            offset += next.count
            reachedEnd = next.count < pageSize
        } catch {
            // Non-fatal — keep whatever's already loaded on screen.
        }
    }
}
