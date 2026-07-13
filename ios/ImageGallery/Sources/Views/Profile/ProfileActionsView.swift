import SwiftUI

struct ProfileActionsView: View {
    @ObservedObject var viewModel: ProfileViewModel

    var body: some View {
        if let user = viewModel.user, user.friendStatus != "self" {
            HStack(spacing: 10) {
                Button {
                    Task { await viewModel.setFollowing(!(user.followedByMe ?? false)) }
                } label: {
                    Text(user.followedByMe == true ? "Unfollow" : "Follow")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    Task { await viewModel.sendFriendRequest() }
                } label: {
                    Text(friendLabel(user.friendStatus))
                }
                .buttonStyle(.bordered)
                .disabled(["friends", "pending_out"].contains(user.friendStatus ?? ""))

                Menu {
                    Button("Mute") { Task { await viewModel.setBlock(kind: "mute", active: true) } }
                    Button("Block", role: .destructive) { Task { await viewModel.setBlock(kind: "block", active: true) } }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    private func friendLabel(_ status: String?) -> String {
        switch status {
        case "friends": return "Friends"
        case "pending_out": return "Requested"
        case "pending_in": return "Respond"
        default: return "Add Friend"
        }
    }
}
