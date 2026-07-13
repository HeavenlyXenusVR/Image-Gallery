import SwiftUI

struct UserSearchView: View {
    @State private var query = ""
    @State private var results: [GalleryUser] = []
    @State private var isLoading = false

    var body: some View {
        List {
            ForEach(results) { user in
                NavigationLink(destination: ProfileView(username: user.username)) {
                    VStack(alignment: .leading) {
                        Text(user.displayName ?? user.username).bold()
                        Text("@\(user.username)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .overlay {
            if isLoading { ProgressView() }
            else if results.isEmpty && !query.isEmpty { ContentUnavailableCompat(title: "No users found", systemImage: "person.slash") }
        }
        .searchable(text: $query, prompt: "Search users")
        .onChange(of: query) { newValue in
            Task { await search(newValue) }
        }
        .navigationTitle("Find People")
    }

    private func search(_ text: String) async {
        guard !text.isEmpty else { results = []; return }
        isLoading = true
        defer { isLoading = false }
        results = (try? await GalleryAPIClient.shared.searchUsers(query: text)) ?? []
    }
}
