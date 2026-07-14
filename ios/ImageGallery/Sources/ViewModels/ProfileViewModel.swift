import Combine
import Foundation

@MainActor
final class ProfileViewModel: ObservableObject {
    @Published var user: GalleryUser?
    @Published var media: [MediaItem] = []
    @Published var collections: [CollectionSummary] = []
    @Published var friends: [GalleryUser] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    let username: String
    private let api = GalleryAPIClient.shared

    init(username: String) {
        self.username = username
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let response = try await api.profilePage(username: username)
            user = response.user
            media = response.media ?? []
            collections = response.collections ?? []
            friends = response.friends ?? []
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setFollowing(_ following: Bool) async {
        guard let user else { return }
        do {
            try await api.setFollowing(userId: user.id, following: following)
            Haptics.light()
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendFriendRequest() async {
        guard let user else { return }
        do {
            try await api.sendFriendRequest(userId: user.id)
            Haptics.light()
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setBlock(kind: String, active: Bool) async {
        guard let user else { return }
        do {
            try await api.setBlock(userId: user.id, kind: kind, active: active)
            Haptics.warning()
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
