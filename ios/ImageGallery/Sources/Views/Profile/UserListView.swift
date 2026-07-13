import SwiftUI

/// Reusable list for a profile's followers or following, reached by tapping
/// the corresponding stat on `ProfileView`.
struct UserListView: View {
    enum Kind {
        case followers
        case following

        var title: String {
            switch self {
            case .followers: return "Followers"
            case .following: return "Following"
            }
        }
    }

    let userId: Int
    let kind: Kind

    @State private var users: [GalleryUser] = []
    @State private var isLoading = true

    var body: some View {
        List {
            ForEach(users) { user in
                NavigationLink(destination: ProfileView(username: user.username)) {
                    VStack(alignment: .leading) {
                        Text(user.displayName ?? user.username).bold()
                        Text("@\(user.username)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if users.isEmpty && !isLoading {
                Text(kind == .followers ? "No followers yet" : "Not following anyone yet").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(kind.title)
        .overlay {
            if isLoading { ProgressView() }
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        switch kind {
        case .followers:
            users = (try? await GalleryAPIClient.shared.followers(userId: userId)) ?? []
        case .following:
            users = (try? await GalleryAPIClient.shared.following(userId: userId)) ?? []
        }
    }
}
