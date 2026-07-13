import Combine
import Foundation

@MainActor
final class StudioViewModel: ObservableObject {
    @Published var items: [MediaItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let api = GalleryAPIClient.shared

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            items = try await api.myMedia()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateVisibility(_ item: MediaItem, visibility: String) async {
        do {
            let updated = try await api.updateControls(mediaId: item.id, patch: .init(visibility: visibility, commentsEnabled: nil, downloadsEnabled: nil, pinned: nil))
            replace(updated)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func togglePinned(_ item: MediaItem) async {
        do {
            let updated = try await api.updateControls(mediaId: item.id, patch: .init(visibility: nil, commentsEnabled: nil, downloadsEnabled: nil, pinned: !(item.pinnedAt != nil)))
            replace(updated)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ item: MediaItem) async {
        do {
            try await api.deleteMedia(id: item.id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restore(_ item: MediaItem) async {
        do {
            let restored = try await api.restoreMedia(id: item.id)
            replace(restored)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func replace(_ item: MediaItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        }
    }
}
