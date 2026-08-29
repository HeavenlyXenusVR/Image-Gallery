import Foundation

/// A 1:1 DM thread summary. Mirrors `M.message_threads` in `lua/src/routes.lua`.
struct MessageThread: Codable, Identifiable {
    var id: Int
    var userId: Int?
    var username: String?
    var displayName: String?
    var avatarUrl: String?
    var lastMessage: String?
    var lastMessageAt: String?
    var lastSenderId: Int?
    var unreadCount: Int?
}

struct DirectMessage: Codable, Identifiable {
    var id: Int
    var senderId: Int?
    var recipientId: Int?
    var body: String
    var createdAt: String?
}

/// A multi-member group thread. Mirrors `M.list_groups` in
/// `lua/src/routes.lua` — `displayName` is pre-computed server-side (the
/// thread's name, or a comma-joined list of the other members if unnamed).
struct GroupThread: Codable, Identifiable {
    var id: Int
    var name: String?
    var displayName: String?
    var createdBy: Int?
    var createdAt: String?
    var lastMessage: String?
    var lastMessageAt: String?
    var lastSenderId: Int?
    var members: [GalleryUser]?
}

struct ThreadMessage: Codable, Identifiable {
    var id: Int
    var threadId: Int?
    var senderId: Int?
    var body: String
    var username: String?
    var displayName: String?
    var createdAt: String?
}
