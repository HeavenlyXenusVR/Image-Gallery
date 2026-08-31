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
    private var rateObservation: NSKeyValueObservation?
    private var retryAttempt = 0
    private static let maxRetries = 2
    private var preflightTask: Task<Void, Never>?

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
        rateObservation?.invalidate()
        preflightTask?.cancel()
        var headers: [String: String] = [:]
        if let token = GalleryAPIClient.shared.authToken {
            headers["Authorization"] = "Bearer \(token)"
        }

        // The HLS playlist route 503s with "still starting up" while this
        // quality's variant is mid-transcode server-side (routes.lua's
        // serve_hls_playlist) -- completely routine right after picking a
        // quality that hasn't been requested yet. hls.js/Safari on web
        // already retry that transparently (see VideoPlayer.jsx), but
        // AVPlayer has no equivalent visibility: a non-2xx HTTP status on
        // the playlist fetch surfaces through AVFoundationErrorDomain, not
        // NSURLErrorDomain, so isTransientNetworkError below never
        // recognized it as retryable and the player just failed permanently
        // with an opaque "resource unavailable" -- on literally the very
        // first watch of any quality, not something rare. Preflight the
        // playlist with a plain URLSession request and retry through a 503
        // BEFORE ever handing the URL to AVPlayer, so by the time AVPlayer
        // sees it, the playlist genuinely exists.
        //
        // BUGFIX 2026-08-31: this used to cap at 6 attempts with a fixed
        // 500ms*attempt backoff -- 10.5s of total budget before giving up
        // and handing AVPlayer a URL that was STILL 503ing, which then sat
        // there indefinitely (AVPlayer doesn't reliably flip an HLS asset's
        // .status to .failed just because its playlist 503s -- it can just
        // stall with no error and no video, exactly the reported "the
        // player never succeeds to play" symptom). A cold transcode
        // routinely takes far longer than 10.5s (confirmed server-side this
        // same day: 30-85s even on the now-GPU-accelerated path, and
        // several minutes were observed before that) -- the server was
        // never actually failing, the client just stopped asking before it
        // finished. That's also why switching quality "fixed" it: the
        // server-side encode keeps running regardless of whether the app
        // is still polling, so by the time a quality switch fires a fresh
        // preflight, enough real time has usually passed for it to already
        // be ready. Now honors the server's own Retry-After header
        // (present on every 503 this route can return -- "still starting
        // up" says 3s, "busy" 5s, "gpu unavailable" 15s) instead of a fixed
        // schedule, and retries against a wall-clock deadline instead of an
        // attempt count -- 3 minutes, comfortably past every real cold-start
        // time observed, matching the order of magnitude of the web
        // player's own retry budget (hls.js: 40 retries at up to 3s backoff
        // each, ~112s) rather than inventing a shorter one for iOS alone.
        preflightTask = Task { [weak self] in
            guard let self else { return }
            var request = URLRequest(url: url)
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }

            let deadline = Date().addingTimeInterval(180)
            var resolvedURL: URL?
            while !Task.isCancelled {
                do {
                    let (_, response) = try await URLSession.shared.data(for: request)
                    let http = response as? HTTPURLResponse
                    let status = http?.statusCode ?? 200
                    if status == 503 && Date() < deadline {
                        let retryAfter = (http?.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init) ?? 3
                        try await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
                        continue
                    }
                    // A busy non-"original" quality gets a 302 to the
                    // original rendition server-side (routes.lua's
                    // serve_hls_playlist) -- URLSession follows it
                    // transparently here, but AVFoundation's own header
                    // propagation across an HTTP redirect is unreliable
                    // (the same limitation routes.lua's playlist rewriting
                    // already works around for segment requests -- see its
                    // "relying on AVURLAssetHTTPHeaderFieldsKey propagating"
                    // comment). Hand AVPlayer the already-resolved URL
                    // directly instead of the pre-redirect one, so it never
                    // has to replay that redirect (and its auth header)
                    // itself -- matters for private/adult-gated videos,
                    // where the redirect target needs the same Bearer token
                    // the original request carried.
                    resolvedURL = http?.url
                    break
                } catch {
                    break // Let AVPlayer's own load surface the real error for anything else.
                }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if let resolvedURL, resolvedURL != self.url {
                    self.url = resolvedURL
                }
                self.attachPlayer(headers: headers, autoplay: autoplay)
            }
        }
    }

    private func attachPlayer(headers: [String: String], autoplay: Bool) {
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
        // BackgroundMusicService observes this to duck/restore its own
        // volume -- rate (not play()/pause() call sites) so this also
        // catches play/pause triggered by AVKit's native transport controls,
        // not just our own startPlayback()/pause() methods.
        rateObservation = newPlayer.observe(\.rate, options: [.new]) { player, _ in
            NotificationCenter.default.post(name: .nyxframeVideoPlaybackChanged, object: nil, userInfo: ["playing": player.rate > 0])
        }
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
        rateObservation?.invalidate()
        preflightTask?.cancel()
        // Unconditional, not conditioned on prior playback state -- mirrors
        // web's identical unmount-safety comment on VideoPlayer.jsx: this
        // controller being deallocated mid-playback (navigating away) would
        // otherwise leave BackgroundMusicService permanently ducked with no
        // matching "stopped" rate change ever coming. A redundant post when
        // nothing was playing is a harmless no-op fade to the same volume.
        NotificationCenter.default.post(name: .nyxframeVideoPlaybackChanged, object: nil, userInfo: ["playing": false])
    }
}
