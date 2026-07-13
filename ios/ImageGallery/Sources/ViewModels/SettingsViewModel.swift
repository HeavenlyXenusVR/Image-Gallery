import Combine
import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var blocks: [BlockEntry] = []
    @Published var savedSearches: [SavedSearch] = []
    @Published var totp: TotpStatusResponse?
    @Published var errorMessage: String?
    @Published var isExporting = false

    private let api = GalleryAPIClient.shared

    func loadAll() async {
        async let blocksTask = api.myBlocks()
        async let searchesTask = api.savedSearches()
        async let totpTask = api.totpStatus()
        blocks = (try? await blocksTask) ?? []
        savedSearches = (try? await searchesTask) ?? []
        totp = try? await totpTask
    }

    func unblock(_ entry: BlockEntry) async {
        do {
            try await api.setBlock(userId: entry.user.id, kind: entry.kind, active: false)
            blocks.removeAll { $0.user.id == entry.user.id && $0.kind == entry.kind }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSavedSearch(_ search: SavedSearch) async {
        do {
            try await api.deleteSavedSearch(id: search.id)
            savedSearches.removeAll { $0.id == search.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func exportData() async -> URL? {
        isExporting = true
        defer { isExporting = false }
        do {
            let data = try await api.exportMyData()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("image-gallery-export.json")
            try data.write(to: url)
            return url
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}
