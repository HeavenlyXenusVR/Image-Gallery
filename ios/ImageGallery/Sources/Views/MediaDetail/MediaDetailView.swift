import SwiftUI

struct MediaDetailView: View {
    @StateObject private var viewModel: MediaDetailViewModel
    @EnvironmentObject private var session: SessionStore
    @State private var showingReport = false
    @State private var showingAgeVerification = false
    @State private var showingFullScreen = false

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
        .task { await viewModel.load() }
        .sheet(isPresented: $showingReport) { ReportSheet(viewModel: viewModel) }
        .sheet(isPresented: $showingAgeVerification, onDismiss: { Task { await viewModel.load() } }) { AgeVerificationView() }
        .fullScreenCover(isPresented: $showingFullScreen) {
            if let media = viewModel.media {
                FullScreenMediaView(media: media)
            }
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
            .background(.secondary.opacity(0.1))
            .cornerRadius(12)
        } else if media.isVideo, let urlString = media.url, let url = URL(string: urlString) {
            ZStack(alignment: .topTrailing) {
                AuthenticatedVideoPlayer(url: url)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
                expandButton
            }
        } else if let urlString = media.url, let url = URL(string: urlString) {
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
