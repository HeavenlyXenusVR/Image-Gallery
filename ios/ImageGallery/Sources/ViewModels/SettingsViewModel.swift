import Combine
import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var blocks: [BlockEntry] = []
    @Published var savedSearches: [SavedSearch] = []
    @Published var totp: TotpStatusResponse?
    @Published var visionStatus: AIVisionStatus?
    @Published var errorMessage: String?
    @Published var isExporting = false
    @Published var isExportingTraining = false

    private let api = GalleryAPIClient.shared

    func loadAll() async {
        async let blocksTask = api.myBlocks()
        async let searchesTask = api.savedSearches()
        async let totpTask = api.totpStatus()
        async let visionTask = api.aiVisionStatus()
        blocks = (try? await blocksTask) ?? []
        savedSearches = (try? await searchesTask) ?? []
        totp = try? await totpTask
        visionStatus = try? await visionTask
    }

    func unblock(_ entry: BlockEntry) async {
        do {
            try await api.setBlock(userId: entry.user.id, kind: entry.kind, active: false)
            blocks.removeAll { $0.user.id == entry.user.id && $0.kind == entry.kind }
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    func deleteSavedSearch(_ search: SavedSearch) async {
        do {
            try await api.deleteSavedSearch(id: search.id)
            savedSearches.removeAll { $0.id == search.id }
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    func exportData() async -> URL? {
        isExporting = true
        defer { isExporting = false }
        do {
            let data = try await api.exportMyData()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("nyxframe-export.json")
            try data.write(to: url)
            return url
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
            return nil
        }
    }

    func exportTrainingData() async -> URL? {
        isExportingTraining = true
        defer { isExportingTraining = false }
        do {
            let data = try await api.exportAITrainingData()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("gallery-ai-vision-training.jsonl")
            try data.write(to: url)
            return url
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
            return nil
        }
    }
}
