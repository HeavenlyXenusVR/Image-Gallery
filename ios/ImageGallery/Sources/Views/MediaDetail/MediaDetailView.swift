import SwiftUI
import UIKit

struct MediaDetailView: View {
    @StateObject private var viewModel: MediaDetailViewModel
    @EnvironmentObject private var session: SessionStore
    @State private var showingReport = false
    @State private var showingAgeVerification = false
    @State private var showingFullScreen = false
    @State private var originalURL: URL?
    @State private var showingOriginalInApp = false
    @State private var videoController: VideoPlayerController?
    @State private var videoQuality = "original"

    private static let qualityOptions: [(String, String)] = [
        ("original", "Original"),
        ("1080p", "1080p HD"),
        ("720p", "720p"),
        ("480p", "480p"),
        ("144p", "144p"),
    ]

    init(mediaId: Int) {
        _viewModel = StateObject(wrappedValue: MediaDetailViewModel(mediaId: mediaId))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let media = viewModel.media {
                    mediaViewer(media)

                    Text(media.title?.nilIfEmpty ?? "Untitled")
                        .font(.title2).bold()

                    UploaderRow(media: media)

                    if let description = media.description, !description.isEmpty {
                        Text(description)
                    }

                    MediaActionBar(
                        media: media,
                        isTogglingLike: viewModel.isTogglingLike,
                        isTogglingBookmark: viewModel.isTogglingBookmark,
                        onLike: { Task { await viewModel.toggleLike() } },
                        onBookmark: { Task { await viewModel.toggleBookmark() } },
                        onReport: { showingReport = true },
                        onOpenOriginal: { openOriginal(media) }
                    )

                    ReactionTray(reactions: viewModel.reactions) { emoji in
                        Task { await viewModel.react(emoji: emoji) }
                    }

                    if session.currentUser != nil {
                        PersonalTagsSection(viewModel: viewModel)
                    }

                    Divider()
                    CommentsSection(viewModel: viewModel)

                    Divider()
                    Label("More like this", systemImage: "square.grid.2x2").font(.headline)
                    SimilarMediaRail(items: viewModel.similar)
                } else if viewModel.isLoading {
                    ProgressView().padding(.top, 80)
                } else if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .padding()
        }
        .navigationTitle(viewModel.media?.title ?? "Media")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.load()
            setUpVideoControllerIfNeeded()
        }
        .sheet(isPresented: $showingReport) { ReportSheet(viewModel: viewModel) }
        .sheet(isPresented: $showingAgeVerification, onDismiss: { Task { await viewModel.load() } }) { AgeVerificationView() }
        // isPresented + a separately-stored URL, not .sheet(item:) -- URL
        // doesn't conform to Identifiable, and this matches the same
        // pattern StudioView/CollectionsListView already use for their own
        // "optional URL drives a sheet" cases (showingDownloadShare +
        // downloadURL).
        .sheet(isPresented: $showingOriginalInApp) {
            if let originalURL { InAppSafariView(url: originalURL) }
        }
        .fullScreenCover(isPresented: $showingFullScreen) {
            if let media = viewModel.media {
                FullScreenMediaView(
                    media: media,
                    videoController: videoController,
                    qualityOptions: Self.qualityOptions,
                    videoQuality: videoQuality,
                    onQualityChange: { changeQuality($0, media: media) }
                )
            }
        }
        .onChange(of: viewModel.media?.id) { _ in
            videoQuality = "original"
            videoController = nil
            setUpVideoControllerIfNeeded()
        }
        .onAppear { setUpVideoControllerIfNeeded() }
        .onDisappear { videoController?.pause() }
    }

    /// Real HLS instead of a single Range-served file: AVPlayer has native
    /// HLS support, so this is purely a URL swap. "original" points straight
    /// at that one rendition's own playlist (a fast `-c copy` remux, no
    /// re-encode -- see routes.lua's ensure_hls_variant), NOT the master
    /// playlist -- previously it did, and that's very likely why "original
    /// quality just loads forever" was reported: master.m3u8 hands AVPlayer
    /// genuine ABR across all 4 transcoded renditions, and on a cold
    /// connection/cache, AVPlayer has no bandwidth history to negotiate
    /// with, so it can end up waiting on a rendition that isn't ready yet
    /// (the backend's serve_hls_playlist 503s "still starting up" for up to
    /// 8s server-side while a transcode is in flight, and there's nothing
    /// here retrying that the way the native/hls.js error paths in
    /// VideoPlayer.jsx do). The web app hit this exact problem and
    /// deliberately reverted away from master.m3u8 for "original" -- see
    /// videoQualityUrl's comment in utils/media.js -- this brings iOS in
    /// line with that already-proven fix instead of independently
    /// rediscovering it.
    private func videoQualityURL(_ media: MediaItem, quality: String) -> URL? {
        guard let urlString = media.url, var components = URLComponents(string: urlString) else { return nil }
        let accessToken = (components.queryItems ?? []).first { $0.name == "access" }?.value
        guard components.path.hasSuffix("/file") else { return nil }
        let base = String(components.path.dropLast("/file".count))
        let rendition = (quality == "original" || quality.isEmpty || quality == "high") ? "original" : quality
        components.path = base + "/hls/\(rendition)/playlist.m3u8"
        components.queryItems = accessToken.map { [URLQueryItem(name: "access", value: $0)] }
        return components.url
    }

    // open_original_in_new_tab -- web's literal "new tab" framing doesn't
    // map 1:1 to iOS (there's no tab to stay on), so the natural
    // equivalent is "leave the app" (launch system Safari) vs. "stay in
    // the app" (an embedded SFSafariViewController sheet). This is the
    // one iOS action MediaActionBar never had at all before this -- there
    // was no "Open Original" anywhere in the app, unlike web's
    // MediaActionPanel.
    private func openOriginal(_ media: MediaItem) {
        guard let urlString = media.url, let url = URL(string: urlString) else { return }
        if session.currentUser?.userSettings?.openOriginalInNewTab == true {
            UIApplication.shared.open(url)
        } else {
            originalURL = url
            showingOriginalInApp = true
        }
    }

    private func setUpVideoControllerIfNeeded() {
        guard videoController == nil, let media = viewModel.media, media.isVideo else { return }
        guard let url = videoQualityURL(media, quality: videoQuality) else { return }
        videoController = VideoPlayerController(url: url)
    }

    private func changeQuality(_ quality: String, media: MediaItem) {
        guard quality != videoQuality else { return }
        videoQuality = quality
        guard let controller = videoController, let url = videoQualityURL(media, quality: quality) else { return }
        controller.setURL(url)
    }

    private var qualityMenu: some View {
        VideoQualityMenu(options: Self.qualityOptions, current: videoQuality) { value in
            if let media = viewModel.media { changeQuality(value, media: media) }
        }
    }

    @ViewBuilder
    private func mediaViewer(_ media: MediaItem) -> some View {
        if media.locked == true {
            VStack(spacing: 12) {
                Image(systemName: "lock.fill").font(.system(size: 36))
                Text("Age verification required for this 18+ post.")
                Button("Verify Age") { showingAgeVerification = true }
            }
            .frame(maxWidth: .infinity, minHeight: 220)
            .softCard()
        } else if media.isVideo, let player = videoController {
            ZStack(alignment: .topTrailing) {
                AuthenticatedVideoPlayer(controller: player)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.Radius.md, style: .continuous))
                    .cardShadow()
                HStack(spacing: 4) {
                    qualityMenu
                    expandButton
                }
            }
        } else if let urlString = media.previewUrl?.nilIfEmpty ?? media.url, let url = URL(string: urlString) {
            // `previewUrl` is a server-resized/recompressed WEBP (capped at
            // 1920px), not the raw original `url` — this inline viewer is
            // capped to 480pt tall anyway, so fetching the full multi-MB
            // original here just makes the first paint slow for no visible
            // benefit. `FullScreenMediaView` (reached via `expandButton`
            // below) still uses the true original for full quality once the
            // viewer explicitly asks for it.
            ZStack(alignment: .topTrailing) {
                ZoomableAsyncImage(url: url)
                // scaledToFit alone is safe from the grid-overlap class of bug
                // (single image, not competing with siblings for layout), but an
                // extreme portrait aspect ratio could still stretch to fill most
                // of the screen — cap it so the rest of the page stays reachable.
                .frame(maxHeight: 480)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
                expandButton
            }
        }
    }

    private var expandButton: some View {
        Button {
            showingFullScreen = true
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .padding(8)
                .background(.ultraThinMaterial, in: Circle())
                .foregroundStyle(.white)
        }
        .padding(8)
        .accessibilityLabel("View fullscreen")
    }
}
