import CoreTransferable
import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Lets a picked video be received as a file on disk instead of `Data` —
/// `FileRepresentation` copies straight from the Photos library to a temp
/// file without ever materializing the whole video in memory, which is what
/// makes multi-GB video uploads possible at all on a memory-constrained
/// device. Images stay on the simpler `Data`-based path since they're
/// realistically never anywhere near this size.
struct PickedVideoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { file in
            SentTransferredFile(file.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("picked-\(UUID().uuidString)-\(received.file.lastPathComponent)")
            if FileManager.default.fileExists(atPath: copy.path) {
                try FileManager.default.removeItem(at: copy)
            }
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self(url: copy)
        }
    }
}

@MainActor
final class UploadViewModel: ObservableObject {
    @Published var pickerItem: PhotosPickerItem?
    @Published var pickedData: Data?
    /// Set instead of `pickedData` for videos — see `PickedVideoFile`.
    @Published var pickedFileURL: URL?
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
    /// Only meaningfully updated for chunked (large-video) uploads -- see
    /// `submit()`. Stays 0 for the ordinary single-request path.
    @Published var uploadProgress: Double = 0
    @Published var errorMessage: String?
    @Published var uploadedMedia: MediaItem?
    @Published var possibleDuplicates: [DuplicateMatch] = []
    @Published var isAnalyzing = false

    private let api = GalleryAPIClient.shared

    /// No independent client-side cap -- this just mirrors whatever the
    /// backend is actually configured to accept (`ServerConfig`, fetched from
    /// `/api/health`), the same way the web app's upload page reads
    /// `MAX_UPLOAD_BYTES` from live config instead of hardcoding its own
    /// number. Videos stream from disk (see `PickedVideoFile` and
    /// `GalleryAPIClient.upload`'s `.fileURL` case) rather than being held in
    /// memory, so raising this doesn't cost RAM.
    private var maxClientUploadBytes: Int { ServerConfig.shared.maxUploadBytes }

    func loadCategories() async {
        categories = (try? await api.categories()) ?? []
    }

    func handlePickerSelection() async {
        guard let pickerItem else { return }
        errorMessage = nil
        clearPickedFile()
        isVideo = pickerItem.supportedContentTypes.contains { $0.conforms(to: .movie) }
        do {
            if isVideo {
                guard let file = try await pickerItem.loadTransferable(type: PickedVideoFile.self) else {
                    errorMessage = "Could not read that file. Try picking it again."
                    return
                }
                let size = (try? FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? Int) ?? nil
                guard let fileSize = size else {
                    try? FileManager.default.removeItem(at: file.url)
                    errorMessage = "Could not read that file. Try picking it again."
                    return
                }
                if fileSize > maxClientUploadBytes {
                    try? FileManager.default.removeItem(at: file.url)
                    let limitMB = maxClientUploadBytes / (1024 * 1024)
                    errorMessage = "That file is too large to upload from the app (over \(limitMB)MB). Try a shorter clip or a smaller export, or upload it from the web app instead."
                    return
                }
                pickedFileURL = file.url
                pickedMimeType = "video/mp4"
                pickedFileName = "upload.mp4"
            } else {
                let data = try await pickerItem.loadTransferable(type: Data.self)
                guard let data else {
                    errorMessage = "Could not read that file. Try picking it again."
                    return
                }
                if data.count > maxClientUploadBytes {
                    let limitMB = maxClientUploadBytes / (1024 * 1024)
                    errorMessage = "That file is too large to upload from the app (over \(limitMB)MB). Try a shorter clip or a smaller export, or upload it from the web app instead."
                    return
                }
                pickedData = data
                pickedMimeType = "image/jpeg"
                pickedFileName = "upload.jpg"
            }
        } catch {
            errorMessage = "Could not read that file: \(error.localizedDescription)"
        }
    }

    /// Pre-submit AI autofill -- see `GalleryAPIClient.analyzeMedia`'s doc
    /// comment. Only fills fields the user hasn't already typed something
    /// into, same "current || suggestion" intent as web's analyze().
    func analyze() async {
        guard pickedData != nil || pickedFileURL != nil else {
            errorMessage = "Choose a photo or video first."
            return
        }
        isAnalyzing = true
        errorMessage = nil
        defer { isAnalyzing = false }
        do {
            let response: MediaAnalyzeResponse
            if let pickedFileURL {
                response = try await api.analyzeMedia(fileURL: pickedFileURL, fileName: pickedFileName, mimeType: pickedMimeType, titleHint: title, descriptionHint: description, tagsHint: tags)
            } else if let pickedData {
                response = try await api.analyzeMedia(data: pickedData, fileName: pickedFileName, mimeType: pickedMimeType, titleHint: title, descriptionHint: description, tagsHint: tags)
            } else {
                return
            }
            possibleDuplicates = response.possibleDuplicates ?? []
            guard let analysis = response.analysis else { return }
            if title.isEmpty { title = analysis.title ?? "" }
            if description.isEmpty { description = analysis.description ?? "" }
            if categoryName.isEmpty { categoryName = analysis.categoryName ?? "" }
            if tags.isEmpty, let suggestedTags = analysis.tags, !suggestedTags.isEmpty {
                tags = suggestedTags.joined(separator: ", ")
            }
            if analysis.isAdult == true { isAdult = true }
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    func submit() async -> Bool {
        guard pickedData != nil || pickedFileURL != nil else {
            errorMessage = "Choose a photo or video first."
            return false
        }
        isUploading = true
        uploadProgress = 0
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
            let response: MediaUploadResponse
            if let pickedFileURL {
                let size = (try? FileManager.default.attributesOfItem(atPath: pickedFileURL.path)[.size] as? Int) ?? nil
                // Comfortably under the ~100MB Cloudflare edge limit the
                // direct single-request path silently dies above (see
                // GalleryAPIClient+Endpoints.swift's uploadMediaChunked).
                if let size, size > 60 * 1024 * 1024 {
                    response = try await api.uploadMediaChunked(fileURL: pickedFileURL, fileName: pickedFileName, fields: fields) { [weak self] progress in
                        Task { @MainActor in self?.uploadProgress = progress }
                    }
                } else {
                    response = try await api.uploadMedia(fileURL: pickedFileURL, fileName: pickedFileName, mimeType: pickedMimeType, fields: fields)
                }
            } else if let pickedData {
                response = try await api.uploadMedia(data: pickedData, fileName: pickedFileName, mimeType: pickedMimeType, fields: fields)
            } else {
                return false
            }
            uploadedMedia = response.media
            possibleDuplicates = response.possibleDuplicates ?? []
            Haptics.success()
            return true
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
            Haptics.error()
            return false
        }
    }

    /// Removes any picked-video temp file so a "change file" tap or a reset
    /// doesn't leak temp files across selections.
    private func clearPickedFile() {
        pickedData = nil
        if let pickedFileURL {
            try? FileManager.default.removeItem(at: pickedFileURL)
        }
        pickedFileURL = nil
    }

    func reset() {
        pickerItem = nil
        clearPickedFile()
        title = ""
        description = ""
        categoryName = ""
        tags = ""
        isAdult = false
        scheduleEnabled = false
        uploadedMedia = nil
        possibleDuplicates = []
    }
}
