import Foundation

/// Resolves the current backend origin. The web frontend solves "the
/// Cloudflare tunnel URL rotates" by fetching `live-config.json` from GitHub
/// Pages at request time with a whole retry/offline-poll system
/// (`frontend/src/api.js`); this is a deliberately simplified port for v1:
/// fetch once at launch (plus a manual "Refresh" in Settings), and let the
/// user override it entirely for local development.
final class LiveConfigService {
    static let shared = LiveConfigService()

    private static let overrideKey = "gallery_backend_url_override"
    private static let cachedKey = "gallery_backend_url_cached"
    private static let liveConfigURL = URL(string: "https://heavenlyxenusvr.github.io/Nyxframe/live-config.json")!

    private let defaults = UserDefaults.standard

    /// Manual override, e.g. "http://127.0.0.1:8788" for local development.
    /// Empty means "auto-discover via live-config.json".
    var manualOverride: String {
        get { defaults.string(forKey: Self.overrideKey) ?? "" }
        set { defaults.set(newValue, forKey: Self.overrideKey) }
    }

    private var cachedOrigin: String {
        get { defaults.string(forKey: Self.cachedKey) ?? "" }
        set { defaults.set(newValue, forKey: Self.cachedKey) }
    }

    /// Best-known origin right now, without making a network call.
    var currentOrigin: String {
        let override = manualOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty { return normalizeOrigin(override) }
        return cachedOrigin
    }

    /// Refreshes from live-config.json (ignored if a manual override is set)
    /// and returns the resolved origin.
    @discardableResult
    func refresh() async -> String {
        let override = manualOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty { return normalizeOrigin(override) }
        do {
            var request = URLRequest(url: Self.liveConfigURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 8
            let (data, _) = try await URLSession.shared.data(for: request)
            let config = try JSONDecoder().decode(LiveConfigPayload.self, from: data)
            let origin = normalizeOrigin(config.gallery_url ?? config.api_url ?? "")
            if !origin.isEmpty {
                cachedOrigin = origin
                return origin
            }
        } catch {
            // Network error or offline tunnel — fall back to whatever we last cached.
        }
        return cachedOrigin
    }

    private func normalizeOrigin(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }
}

private struct LiveConfigPayload: Decodable {
    let gallery_url: String?
    let api_url: String?
}
