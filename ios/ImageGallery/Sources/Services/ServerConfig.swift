import Foundation

/// Server-driven limits fetched from `/api/health`, mirroring how
/// `frontend/src/config.js`'s `setRuntimeMaxUploadBytes` picks up
/// `max_upload_bytes` from the live-checks response instead of hardcoding a
/// client-side cap that can drift from the backend's real (admin-configurable)
/// value.
@MainActor
final class ServerConfig: ObservableObject {
    static let shared = ServerConfig()

    /// Matches the default in `lua/src/config.lua` until the real value loads.
    @Published private(set) var maxUploadBytes: Int = 700 * 1024 * 1024

    private struct HealthResponse: Decodable {
        var maxUploadBytes: Int?
    }

    func refresh() async {
        guard let response: HealthResponse = try? await GalleryAPIClient.shared.requestJSON("/api/health", requiresAuth: false) else { return }
        if let value = response.maxUploadBytes, value > 0 {
            maxUploadBytes = value
        }
    }
}
