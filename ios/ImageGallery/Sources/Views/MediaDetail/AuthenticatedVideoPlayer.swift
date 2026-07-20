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
    @State private var errorMessage: String?
    @State private var statusObservation: NSKeyValueObservation?

    var body: some View {
        Group {
            if let errorMessage {
                // AVKit's own "can't play" glyph gives no indication of *why* —
                // surface the real AVPlayerItem error instead of leaving the
                // viewer to guess (network vs. auth vs. an unsupported codec
                // all look identical otherwise).
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.title2)
                    Text("Couldn't play this video").font(.subheadline.weight(.semibold))
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            } else if let player {
                VideoPlayer(player: player)
                    .onDisappear { player.pause() }
            } else {
                Color.black.overlay(ProgressView())
            }
        }
        .onAppear {
            guard player == nil else { return }
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
            statusObservation = item.observe(\.status, options: [.new]) { observedItem, _ in
                guard observedItem.status == .failed else { return }
                let description = observedItem.error?.localizedDescription ?? "Unknown error."
                DispatchQueue.main.async {
                    errorMessage = description
                }
            }
            player = AVPlayer(playerItem: item)
        }
        .onDisappear {
            statusObservation?.invalidate()
            statusObservation = nil
        }
    }
}
