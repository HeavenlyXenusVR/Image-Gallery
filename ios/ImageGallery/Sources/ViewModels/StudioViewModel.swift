import Combine
import Foundation

@MainActor
final class StudioViewModel: ObservableObject {
    @Published var items: [MediaItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var isSelecting = false
    @Published var selectedIds: Set<Int> = []
    @Published var isBulkWorking = false

    private let api = GalleryAPIClient.shared

    func toggleSelectionMode() {
        isSelecting.toggle()
        if !isSelecting { selectedIds.removeAll() }
    }

    func toggleSelected(_ item: MediaItem) {
        if selectedIds.contains(item.id) {
            selectedIds.remove(item.id)
        } else {
            selectedIds.insert(item.id)
        }
    }

    func bulkSetVisibility(_ visibility: String) async {
        guard !selectedIds.isEmpty else { return }
        isBulkWorking = true
        defer { isBulkWorking = false }
        do {
            _ = try await api.bulkUpdateVisibility(ids: Array(selectedIds), visibility: visibility)
            await load()
            selectedIds.removeAll()
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    func bulkAddTag(_ tag: String) async {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedIds.isEmpty, !trimmed.isEmpty else { return }
        isBulkWorking = true
        defer { isBulkWorking = false }
        do {
            _ = try await api.bulkAddTag(ids: Array(selectedIds), tag: trimmed)
            await load()
            selectedIds.removeAll()
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    func bulkDelete() async {
        guard !selectedIds.isEmpty else { return }
        isBulkWorking = true
        defer { isBulkWorking = false }
        do {
            _ = try await api.bulkDeleteMedia(ids: Array(selectedIds))
            await load()
            selectedIds.removeAll()
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

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
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    func restore(_ item: MediaItem) async {
        do {
            let restored = try await api.restoreMedia(id: item.id)
            replace(restored)
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    private func replace(_ item: MediaItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        }
    }
}
