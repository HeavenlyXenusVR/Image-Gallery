import SwiftUI

struct MediaDetailView: View {
    @StateObject private var viewModel: MediaDetailViewModel
    @EnvironmentObject private var session: SessionStore
    @State private var showingReport = false
    @State private var showingAgeVerification = false
    @State private var showingFullScreen = false
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
                        onReport: { showingReport = true }
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
        .fullScreenCover(isPresented: $showingFullScreen) {
            if let media = viewModel.media {
                FullScreenMediaView(media: media, videoController: videoController)
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

    private func videoQualityURL(_ media: MediaItem, quality: String) -> URL? {
        guard let urlString = media.url, var components = URLComponents(string: urlString) else { return nil }
        var items = (components.queryItems ?? []).filter { $0.name != "quality" }
        if quality != "original" && !quality.isEmpty {
            items.append(URLQueryItem(name: "quality", value: quality))
        }
        components.queryItems = items.isEmpty ? nil : items
        return components.url
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

    @ViewBuilder
    private var qualityMenu: some View {
        Menu {
            ForEach(Self.qualityOptions, id: \.0) { value, label in
                Button {
                    if let media = viewModel.media { changeQuality(value, media: media) }
                } label: {
                    if videoQuality == value {
                        Label(label, systemImage: "checkmark")
                    } else {
                        Text(label)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3")
                Text(Self.qualityOptions.first { $0.0 == videoQuality }?.1 ?? "Original")
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .foregroundStyle(.white)
        }
        .padding(8)
        .accessibilityLabel("Video quality")
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
