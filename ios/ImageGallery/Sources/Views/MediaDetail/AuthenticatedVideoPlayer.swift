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
            let asset = AVURLAsset(url: url, options: [AVURLAssetHTTPHeaderFieldsKey: headers])
            let item = AVPlayerItem(asset: asset)
            player = AVPlayer(playerItem: item)
        }
    }
}
