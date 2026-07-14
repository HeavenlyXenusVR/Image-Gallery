import SwiftUI

struct CommentsSection: View {
    @ObservedObject var viewModel: MediaDetailViewModel
    @EnvironmentObject private var session: SessionStore
    @State private var commentBody = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Comments (\(viewModel.comments.count))").font(.headline)

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
                HStack {
                    TextField("Add a comment (@mention a username)", text: $commentBody)
                        .textFieldStyle(.roundedBorder)
                    Button("Post") {
                        let body = commentBody
                        commentBody = ""
                        Task { await viewModel.postComment(body: body) }
                    }
                    .disabled(commentBody.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            ForEach(viewModel.topLevelComments) { comment in
                VStack(alignment: .leading, spacing: 6) {
                    commentRow(comment)
                    ForEach(viewModel.replies(to: comment)) { reply in
                        commentRow(reply)
                            .padding(.leading, 28)
                    }
                }
            }

            if viewModel.comments.isEmpty {
                Text("No comments yet").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func commentRow(_ comment: Comment) -> some View {
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
        .padding(.vertical, 4)
    }
}
