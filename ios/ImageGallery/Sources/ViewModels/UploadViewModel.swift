import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class UploadViewModel: ObservableObject {
    @Published var pickerItem: PhotosPickerItem?
    @Published var pickedData: Data?
    @Published var pickedFileName = "upload"
    @Published var pickedMimeType = "image/jpeg"
    @Published var isVideo = false

    @Published var title = ""
    @Published var description = ""
    @Published var categoryName = ""
    @Published var tags = ""
    @Published var isAdult = false
    @Published var visibility = "public"
    @Published var commentsEnabled = true
    @Published var downloadsEnabled = true
    @Published var autoAI = true
    @Published var scheduleEnabled = false
    @Published var publishAt = Date().addingTimeInterval(3600)

    @Published var categories: [CategorySummary] = []
    @Published var isUploading = false
    @Published var errorMessage: String?
    @Published var uploadedMedia: MediaItem?

    private let api = GalleryAPIClient.shared

    func loadCategories() async {
        categories = (try? await api.categories()) ?? []
    }

    func handlePickerSelection() async {
        guard let pickerItem else { return }
        isVideo = pickerItem.supportedContentTypes.contains { $0.conforms(to: .movie) }
        if let data = try? await pickerItem.loadTransferable(type: Data.self) {
            pickedData = data
            pickedMimeType = isVideo ? "video/mp4" : "image/jpeg"
            pickedFileName = isVideo ? "upload.mp4" : "upload.jpg"
        }
    }

    func submit() async -> Bool {
        guard let pickedData else {
            errorMessage = "Choose a photo or video first."
            return false
        }
        isUploading = true
        errorMessage = nil
        defer { isUploading = false }

        var publishAtString: String?
        if scheduleEnabled {
            let formatter = ISO8601DateFormatter()
            publishAtString = formatter.string(from: publishAt)
        }

        let fields = GalleryAPIClient.UploadFields(
            title: title,
            description: description,
            categoryId: nil,
            categoryName: categoryName,
            tags: tags,
            isAdult: isAdult,
            visibility: visibility,
            commentsEnabled: commentsEnabled,
            downloadsEnabled: downloadsEnabled,
            autoAI: autoAI,
            publishAt: publishAtString
        )

        do {
            uploadedMedia = try await api.uploadMedia(data: pickedData, fileName: pickedFileName, mimeType: pickedMimeType, fields: fields)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func reset() {
        pickerItem = nil
        pickedData = nil
        title = ""
        description = ""
        categoryName = ""
        tags = ""
        isAdult = false
        scheduleEnabled = false
        uploadedMedia = nil
    }
}
