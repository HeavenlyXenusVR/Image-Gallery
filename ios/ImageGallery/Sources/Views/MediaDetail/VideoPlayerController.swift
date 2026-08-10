import AVFoundation
import Foundation

/// Owns a single `AVPlayer` for one media item so the inline viewer
/// (`MediaDetailView`) and the fullscreen viewer (`FullScreenMediaView`) can
/// share the exact same playback session instead of each spinning up its own
/// `AuthenticatedVideoPlayer`/`AVPlayer` — previously the fullscreen button
/// created a second, fully independent player, leaving the original one
/// silently still playing behind it (no controls reached it, and it kept
/// running after the fullscreen sheet was dismissed).
@MainActor
final class VideoPlayerController: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var errorMessage: String?

    private var statusObservation: NSKeyValueObservation?
    private var retryAttempt = 0
    private static let maxRetries = 2

    /// Set (and playback restarted) whenever the quality selector picks a
    /// different rendition -- the URL, not the player, is the source of truth.
    private(set) var url: URL

    init(url: URL) {
        self.url = url
    }

    func setURL(_ newURL: URL) {
        guard newURL != url else { return }
        let wasPlaying = player?.timeControlStatus == .playing
        url = newURL
        retryAttempt = 0
        errorMessage = nil
        player = nil
        startPlayback(autoplay: wasPlaying)
    }

    func startIfNeeded() {
        guard player == nil, errorMessage == nil else { return }
        startPlayback(autoplay: true)
    }

    func pause() {
        player?.pause()
    }

    func retry() {
        retryAttempt = 0
        errorMessage = nil
        startPlayback(autoplay: true)
    }

    private func startPlayback(autoplay: Bool) {
        statusObservation?.invalidate()
        var headers: [String: String] = [:]
        if let token = GalleryAPIClient.shared.authToken {
            headers["Authorization"] = "Bearer \(token)"
        }
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = AVPlayerItem(asset: asset)
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            guard observedItem.status == .failed else { return }
            let failure = observedItem.error
            DispatchQueue.main.async {
                self?.handleFailure(failure)
            }
        }
        let newPlayer = AVPlayer(playerItem: item)
        player = newPlayer
        if autoplay { newPlayer.play() }
    }

    private func handleFailure(_ error: Error?) {
        guard isTransientNetworkError(error), retryAttempt < Self.maxRetries else {
            errorMessage = error?.localizedDescription ?? "Unknown error."
            return
        }
        retryAttempt += 1
        player = nil
        let delay = 0.5 * Double(retryAttempt)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.startPlayback(autoplay: true)
        }
    }

    private func isTransientNetworkError(_ error: Error?) -> Bool {
        guard let error else { return false }
        var current: NSError? = error as NSError
        while let candidate = current {
            if candidate.domain == NSURLErrorDomain {
                switch candidate.code {
                case NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet,
                     NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed,
                     NSURLErrorSecureConnectionFailed:
                    return true
                default:
                    return false
                }
            }
            current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    deinit {
        statusObservation?.invalidate()
    }
}
