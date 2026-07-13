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

    /// A conservative client-side sanity cap, well under the backend's own
    /// (server-configurable, default 500MB) limit. The upload path currently
    /// holds the picked file in memory twice — once as `pickedData`, again
    /// while the multipart body is assembled — so an oversized pick is
    /// rejected here up front rather than risking an out-of-memory crash
    /// partway through building the request.
    static let maxClientUploadBytes = 300 * 1024 * 1024

    func loadCategories() async {
        categories = (try? await api.categories()) ?? []
    }

    func handlePickerSelection() async {
        guard let pickerItem else { return }
        errorMessage = nil
        pickedData = nil
        isVideo = pickerItem.supportedContentTypes.contains { $0.conforms(to: .movie) }
        do {
            let data = try await pickerItem.loadTransferable(type: Data.self)
            guard let data else {
                errorMessage = "Could not read that file. Try picking it again."
                return
            }
            if data.count > Self.maxClientUploadBytes {
                let limitMB = Self.maxClientUploadBytes / (1024 * 1024)
                errorMessage = "That file is too large to upload from the app (over \(limitMB)MB). Try a shorter clip or a smaller export, or upload it from the web app instead."
                return
            }
            pickedData = data
            pickedMimeType = isVideo ? "video/mp4" : "image/jpeg"
            pickedFileName = isVideo ? "upload.mp4" : "upload.jpg"
        } catch {
            errorMessage = "Could not read that file: \(error.localizedDescription)"
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
            Haptics.success()
            return true
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
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
