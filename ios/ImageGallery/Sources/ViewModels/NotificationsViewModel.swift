import Combine
import Foundation

@MainActor
final class NotificationsViewModel: ObservableObject {
    @Published var items: [NotificationItem] = []
    @Published var unreadCount = 0
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let api = GalleryAPIClient.shared

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let response = try await api.notifications()
            items = response.notifications
            unreadCount = response.unreadCount ?? 0
            BadgeService.setBadge(unreadCount)
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    func markRead(_ item: NotificationItem) async {
        guard item.readAt == nil else { return }
        do {
            try await api.markNotificationRead(id: item.id)
        } catch {
            errorMessage = "Couldn't mark as read: \(error.localizedDescription)"
            return
        }
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index].readAt = ISO8601DateFormatter().string(from: Date())
        }
        unreadCount = max(0, unreadCount - 1)
        BadgeService.setBadge(unreadCount)
    }

    func markAllRead() async {
        do {
            try await api.markAllNotificationsRead()
        } catch {
            errorMessage = "Couldn't mark all as read: \(error.localizedDescription)"
            return
        }
        await load()
    }

    func text(for item: NotificationItem) -> String {
        let name = item.actorDisplayName ?? item.actorUsername ?? "Someone"
        switch item.kind {
        case "follow": return "\(name) followed you."
        case "friend_request": return "\(name) sent you a friend request."
        case "friend_accept": return "\(name) accepted your friend request."
        case "comment": return "\(name) commented\(item.mediaTitle.map { " on \"\($0)\"" } ?? "")."
        case "reply": return "\(name) replied to your comment."
        case "mention": return "\(name) mentioned you in a comment."
        case "reaction": return "\(name) reacted to your post."
        case "message": return "\(name) sent you a message."
        case "saved_search": return item.preview ?? "A new post matches one of your saved searches."
        default: return "\(name) did something."
        }
    }
}
