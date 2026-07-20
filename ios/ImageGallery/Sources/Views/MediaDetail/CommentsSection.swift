import SwiftUI

struct CommentsSection: View {
    @ObservedObject var viewModel: MediaDetailViewModel
    @EnvironmentObject private var session: SessionStore
    @State private var commentBody = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Comments (\(viewModel.comments.count))", systemImage: "bubble.left.and.bubble.right.fill").font(.headline)

            if session.currentUser != nil, viewModel.media?.commentsEnabled != false {
                if let replyTarget = viewModel.replyTarget {
                    HStack {
                        Text("Replying to \(replyTarget.displayName ?? replyTarget.username ?? "user")")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { viewModel.replyTarget = nil }
                            .font(.footnote)
                    }
                }
                commentInputRow
            }

            ForEach(viewModel.topLevelComments) { comment in
                VStack(alignment: .leading, spacing: 6) {
                    commentRow(comment)
                    ForEach(viewModel.replies(to: comment)) { reply in
                        HStack(alignment: .top, spacing: 8) {
                            Rectangle().fill(Color.accentColor.opacity(0.3)).frame(width: 2)
                            commentRow(reply)
                        }
                        .padding(.leading, 20)
                    }
                }
            }

            if viewModel.comments.isEmpty {
                Text("No comments yet").foregroundStyle(.secondary)
            }
        }
    }

    private var commentInputRow: some View {
        HStack(spacing: 8) {
            AvatarView(
                urlString: session.currentUser?.avatarUrl,
                fallbackInitial: String((session.currentUser?.displayName ?? session.currentUser?.username ?? "U").prefix(1)),
                shape: AvatarShape(session.currentUser?.userSettings?.profileAvatarShape),
                size: 32
            )
            TextField("Add a comment (@mention a username)", text: $commentBody)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Button {
                let body = commentBody
                commentBody = ""
                Task { await viewModel.postComment(body: body) }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(commentBody.trimmingCharacters(in: .whitespaces).isEmpty ? AnyShapeStyle(Color.secondary.opacity(0.3)) : AnyShapeStyle(Color.accentColor), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(commentBody.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // `comment.userAvatarPath` is a raw storage path (the backend's
    // `list_comments` returns `u.avatar_path` straight through `_jsonable`,
    // not via `_with_urls`/`_avatar_url` the way `MediaItem.userAvatarUrl`
    // is) — it only tells us *whether* this commenter has a public avatar,
    // not where it lives. Reconstruct the real URL from the known route
    // instead of binding the path directly (which would just always
    // silently fall back to the initial-letter placeholder).
    private func avatarURL(for comment: Comment) -> String? {
        guard let path = comment.userAvatarPath, !path.isEmpty, let userId = comment.userId else { return nil }
        return "\(LiveConfigService.shared.currentOrigin)/api/users/\(userId)/avatar"
    }

    @ViewBuilder
    private func commentRow(_ comment: Comment) -> some View {
        HStack(alignment: .top, spacing: 8) {
            AvatarView(urlString: avatarURL(for: comment), fallbackInitial: String((comment.displayName ?? comment.username ?? "U").prefix(1)), size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(comment.displayName ?? comment.username ?? "User").font(.subheadline).bold()
                    if comment.createdAt != nil {
                        Text(DateFormatting.relative(comment.createdAt)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(comment.body)
                HStack(spacing: 12) {
                    if session.currentUser != nil, comment.parentCommentId == nil {
                        Button("Reply") { viewModel.replyTarget = comment }
                            .font(.footnote)
                    }
                    if let userId = session.currentUser?.id, userId == comment.userId || userId == viewModel.media?.userId {
                        Button("Delete", role: .destructive) {
                            Task { await viewModel.deleteComment(comment) }
                        }
                        .font(.footnote)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
