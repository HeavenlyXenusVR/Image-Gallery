import UserNotifications

/// App icon badge count for unread notifications — purely local (no push
/// infrastructure exists server-side), just reflecting whatever
/// `/api/notifications/unread-count` last returned. Badge permission is
/// requested without alert/sound since this app has no push notifications.
enum BadgeService {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.badge]) { _, _ in }
    }

    static func setBadge(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(max(0, count))
    }
}
