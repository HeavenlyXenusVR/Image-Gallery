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
        .statusBarHidden()
    }
}
