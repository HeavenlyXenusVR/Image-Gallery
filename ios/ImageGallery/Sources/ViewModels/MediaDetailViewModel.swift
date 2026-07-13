import Combine
import Foundation

@MainActor
final class MediaDetailViewModel: ObservableObject {
    @Published var media: MediaItem?
    @Published var comments: [Comment] = []
    @Published var reactions = ReactionsSummary(counts: [:], myReaction: nil)
    @Published var similar: [MediaItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var replyTarget: Comment?

    let mediaId: Int
    private let api = GalleryAPIClient.shared

    init(mediaId: Int) {
        self.mediaId = mediaId
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let detail = try await api.mediaDetail(id: mediaId)
            media = detail.media
            comments = detail.comments ?? []
            reactions = detail.reactions ?? ReactionsSummary(counts: [:], myReaction: nil)
            similar = detail.similar ?? []
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleLike() async {
        guard let media else { return }
        do {
            self.media = try await api.setLiked(mediaId: media.id, liked: !(media.likedByMe ?? false))
            Haptics.light()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleBookmark() async {
        guard let media else { return }
        do {
            self.media = try await api.setBookmarked(mediaId: media.id, bookmarked: !(media.bookmarkedByMe ?? false))
            Haptics.light()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func react(emoji: String) async {
        guard let media else { return }
        do {
            reactions = try await api.react(mediaId: media.id, emoji: emoji)
            Haptics.light()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func postComment(body: String) async {
        guard let media, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            let comment = try await api.addComment(mediaId: media.id, body: body, parentCommentId: replyTarget?.id)
            comments.append(comment)
            replyTarget = nil
            Haptics.light()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteComment(_ comment: Comment) async {
        do {
            try await api.deleteComment(id: comment.id)
            comments.removeAll { $0.id == comment.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func report(reason: String, details: String?) async {
        guard let media else { return }
        do {
            try await api.reportMedia(mediaId: media.id, reason: reason, details: details)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Top-level comments with their replies nested, mirroring the web app's
    /// `MediaDetailPage.jsx` comment-threading logic.
    var topLevelComments: [Comment] {
        comments.filter { $0.parentCommentId == nil }
    }

    func replies(to comment: Comment) -> [Comment] {
        comments.filter { $0.parentCommentId == comment.id }
    }
}
