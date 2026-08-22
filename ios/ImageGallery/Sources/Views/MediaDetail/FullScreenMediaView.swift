import SwiftUI

/// Edge-to-edge presentation of a single media item's image/video, reached
/// via the expand button on `MediaDetailView` — the inline viewer there is
/// capped to a modest height so the rest of the page stays reachable, which
/// left no way to see a photo/video at full quality/size.
struct FullScreenMediaView: View {
    let media: MediaItem
    /// Passed in from `MediaDetailView` so opening fullscreen doesn't spin up
    /// a second, disconnected `AVPlayer` -- both presentations play through
    /// this one controller.
    var videoController: VideoPlayerController?
    /// Previously missing entirely -- this view had no quality picker at
    /// all, so the expand button silently traded away the ability to
    /// change quality the moment you actually wanted the bigger view.
    /// Passed through from MediaDetailView rather than owned here, since
    /// both presentations share the one videoController and need to stay
    /// in sync about which rendition is playing.
    var qualityOptions: [(String, String)] = []
    var videoQuality: String = "original"
    var onQualityChange: ((String) -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            Group {
                if media.isVideo, let videoController {
                    AuthenticatedVideoPlayer(controller: videoController)
                } else if let urlString = media.url, let url = URL(string: urlString) {
                    ZoomableAsyncImage(url: url)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 4) {
                if media.isVideo, !qualityOptions.isEmpty, let onQualityChange {
                    VideoQualityMenu(options: qualityOptions, current: videoQuality, onSelect: onQualityChange)
                }
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.white, .black.opacity(0.5))
                }
                .padding()
                .accessibilityLabel("Close fullscreen")
            }
        }
        .statusBarHidden()
    }
}
