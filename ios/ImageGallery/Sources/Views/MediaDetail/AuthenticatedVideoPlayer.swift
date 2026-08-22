import AVKit
import SwiftUI

/// Renders whatever `VideoPlayerController` is currently playing. The
/// controller (and its `AVPlayer`) is owned by the caller so the same
/// playback session can be shared across the inline and fullscreen
/// presentations of a video -- see `VideoPlayerController`.
struct AuthenticatedVideoPlayer: View {
    @ObservedObject var controller: VideoPlayerController

    var body: some View {
        Group {
            if let errorMessage = controller.errorMessage {
                // AVKit's own "can't play" glyph gives no indication of *why* —
                // surface the real AVPlayerItem error instead of leaving the
                // viewer to guess (network vs. auth vs. an unsupported codec
                // all look identical otherwise).
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.title2)
                    Text("Couldn't play this video").font(.subheadline.weight(.semibold))
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                    Button("Try Again") { controller.retry() }
                        .font(.footnote.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            } else if let player = controller.player {
                VideoPlayer(player: player)
                    .overlay(alignment: .topTrailing) { watermark }
            } else {
                Color.black.overlay(ProgressView())
            }
        }
        .onAppear { controller.startIfNeeded() }
    }

    /// Matches the web player's `.vp-watermark` (VideoPlayer.jsx): the same
    /// fixed brand mark regardless of the viewer's own accent-color
    /// customization, since this identifies the *site's* player, not the
    /// user's theme. Top-trailing, same as web -- AVKit's native transport
    /// controls sit bottom-center/tap-to-toggle, so this corner stays clear.
    private var watermark: some View {
        HStack(spacing: 6) {
            LinearGradient(
                colors: [Color(hex: "#37c9a7"), Color(hex: "#6ec7ff"), Color(hex: "#ffcf6a")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .frame(width: 20, height: 20)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text("Nyxframe")
                .font(.caption2.weight(.bold))
        }
        .padding(.vertical, 5)
        .padding(.leading, 5)
        .padding(.trailing, 10)
        .foregroundStyle(.white.opacity(0.82))
        .background(.black.opacity(0.5), in: Capsule())
        .padding(14)
        .allowsHitTesting(false)
    }
}
