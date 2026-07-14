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

                    if let username = media.username {
                        NavigationLink(destination: ProfileView(username: username)) {
                            Label(media.displayName ?? username, systemImage: "person.crop.circle")
                        }
                        .font(.footnote)
                    }

                    if let description = media.description, !description.isEmpty {
                        Text(description)
                    }

                    HStack(spacing: 16) {
                        statLabel(systemImage: "heart", value: media.likeCount)
                        statLabel(systemImage: "eye", value: media.views)
                        statLabel(systemImage: "arrow.down.circle", value: media.downloads)
                        statLabel(systemImage: "bubble.left", value: media.commentCount)
                        if let fileSize = media.fileSize {
                            Label(ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file), systemImage: "doc")
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    actionRow(media)

                    ReactionTray(reactions: viewModel.reactions) { emoji in
                        Task { await viewModel.react(emoji: emoji) }
                    }

                    Divider()
                    CommentsSection(viewModel: viewModel)

                    Divider()
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
                    .cornerRadius(12)
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
                .cornerRadius(12)
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
                .background(.black.opacity(0.5))
                .foregroundStyle(.white)
                .clipShape(Circle())
        }
        .padding(8)
        .accessibilityLabel("View fullscreen")
    }

    @ViewBuilder
    private func actionRow(_ media: MediaItem) -> some View {
        HStack(spacing: 20) {
            Button {
                Task { await viewModel.toggleLike() }
            } label: {
                Label(media.likedByMe == true ? "Liked" : "Like", systemImage: media.likedByMe == true ? "heart.fill" : "heart")
            }
            .disabled(viewModel.isTogglingLike)

            Button {
                Task { await viewModel.toggleBookmark() }
            } label: {
                Label(media.bookmarkedByMe == true ? "Saved" : "Save", systemImage: media.bookmarkedByMe == true ? "bookmark.fill" : "bookmark")
            }
            .disabled(viewModel.isTogglingBookmark)

            if let downloadUrl = media.downloadUrl, let url = URL(string: downloadUrl) {
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }

            Spacer()

            Menu {
                Button("Report", role: .destructive) { showingReport = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More options")
        }
        .buttonStyle(.plain)
    }

    private func statLabel(systemImage: String, value: Int?) -> some View {
        Label("\(value ?? 0)", systemImage: systemImage)
    }
}
