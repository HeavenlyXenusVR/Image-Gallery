import AVFoundation
import AVKit
import SwiftUI

/// Wraps AVKit's `VideoPlayer` with an `AVURLAsset` built with the session's
/// Bearer token attached, so private/adult streaming endpoints
/// (`app/routers/media_streaming.py`) authenticate the same way `apiFetch`
/// does on the web.
struct AuthenticatedVideoPlayer: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .onDisappear { player.pause() }
            } else {
                Color.black.overlay(ProgressView())
            }
        }
        .onAppear {
            var headers: [String: String] = [:]
            if let token = GalleryAPIClient.shared.authToken {
                headers["Authorization"] = "Bearer \(token)"
            }
            // Using the literal key string rather than the `AVURLAssetHTTPHeaderFieldsKey`
            // symbol — it wasn't resolving in scope in CI even with AVFoundation
            // imported, and the options dictionary is untyped ([String: Any]) so the
            // literal (Apple's documented constant value) works identically.
            let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            let item = AVPlayerItem(asset: asset)
            player = AVPlayer(playerItem: item)
        }
    }
}
