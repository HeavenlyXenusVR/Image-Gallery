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
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            ForEach(users) { user in
                NavigationLink(destination: ProfileView(username: user.username)) {
                    HStack {
                        AvatarView(urlString: user.avatarUrl, fallbackInitial: String((user.displayName ?? user.username).prefix(1)), size: 40)
                        VStack(alignment: .leading) {
                            Text(user.displayName ?? user.username).bold()
                            Text("@\(user.username)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if users.isEmpty && !isLoading && errorMessage == nil {
                Text(kind == .followers ? "No followers yet" : "Not following anyone yet").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(kind.title)
        .overlay {
            if isLoading && users.isEmpty { ProgressView() }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            switch kind {
            case .followers:
                users = try await GalleryAPIClient.shared.followers(userId: userId)
            case .following:
                users = try await GalleryAPIClient.shared.following(userId: userId)
            }
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load \(kind.title.lowercased()): \(error.localizedDescription)"
        }
    }
}
