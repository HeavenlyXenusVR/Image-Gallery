import Combine
import Foundation

/// App-wide unread counts for the Messages/Alerts tab badges — mirrors the
/// role `NotificationBell.jsx`'s 30s poll plays on the web app, since a tab
/// icon alone (unlike the web's badge-in-header) gives no hint that
/// something's waiting without opening the screen.
@MainActor
final class UnreadCountsService: ObservableObject {
    @Published var notifications = 0
    @Published var messages = 0

    private var pollTask: Task<Void, Never>?

    func refresh() async {
        guard GalleryAPIClient.shared.isAuthenticated else {
            notifications = 0
            messages = 0
            return
        }
        async let notifTask = GalleryAPIClient.shared.unreadNotificationCount()
        async let threadsTask = GalleryAPIClient.shared.messageThreads()
        notifications = (try? await notifTask) ?? notifications
        if let threads = try? await threadsTask {
            messages = threads.reduce(0) { $0 + ($1.unreadCount ?? 0) }
        }
        BadgeService.setBadge(notifications + messages)
    }

    /// Call once when the signed-in shell appears; cancels itself when the
    /// view disappears (see `stopPolling`). A plain 45s loop rather than a
    /// push subscription, matching this app's "no APNs infrastructure yet"
    /// reality noted elsewhere.
    func startPolling() {
        stopPolling()
        pollTask = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(nanoseconds: 45_000_000_000)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func reset() {
        notifications = 0
        messages = 0
        BadgeService.setBadge(0)
    }
}
