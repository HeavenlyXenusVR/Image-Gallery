import SwiftUI

struct UserSearchView: View {
    @State private var query = ""
    @State private var results: [GalleryUser] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            ForEach(results) { user in
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
        }
        .overlay {
            if isLoading { ProgressView() }
            else if results.isEmpty && !query.isEmpty && errorMessage == nil { ContentUnavailableCompat(title: "No users found", systemImage: "person.slash") }
        }
        .searchable(text: $query, prompt: "Search users")
        .onChange(of: query) { newValue in
            Task { await search(newValue) }
        }
        .navigationTitle("Find People")
    }

    private func search(_ text: String) async {
        guard !text.isEmpty else { results = []; errorMessage = nil; return }
        isLoading = true
        defer { isLoading = false }
        do {
            results = try await GalleryAPIClient.shared.searchUsers(query: text)
            errorMessage = nil
        } catch {
            errorMessage = "Search failed: \(error.localizedDescription)"
        }
    }
}
