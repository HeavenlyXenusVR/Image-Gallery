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
            } else {
                Color.black.overlay(ProgressView())
            }
        }
        .onAppear { controller.startIfNeeded() }
    }
}
