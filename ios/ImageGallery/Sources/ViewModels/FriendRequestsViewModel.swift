import Combine
import Foundation

@MainActor
final class FriendRequestsViewModel: ObservableObject {
    @Published var incoming: [FriendRequestItem] = []
    @Published var outgoing: [FriendRequestItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var busyId: Int?

    private let api = GalleryAPIClient.shared

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let response = try await api.friendRequests()
            incoming = response.incoming
            outgoing = response.outgoing
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func respond(_ request: FriendRequestItem, action: String) async {
        busyId = request.id
        defer { busyId = nil }
        do {
            _ = try await api.respondFriendRequest(requestId: request.id, action: action)
            incoming.removeAll { $0.id == request.id }
            outgoing.removeAll { $0.id == request.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
