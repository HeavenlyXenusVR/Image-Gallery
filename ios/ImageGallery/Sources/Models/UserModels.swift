import Foundation

/// The signed-in user, and any profile summary returned alongside media/comments.
/// Mirrors `_with_user_urls` on the backend.
struct GalleryUser: Codable, Identifiable, Hashable {
    var id: Int
    var username: String
    var displayName: String?
    var email: String?
    var bio: String?
    var profileHeadline: String?
    var profileQuote: String?
    var websiteUrl: String?
    var locationLabel: String?
    var featuredTags: [String]?
    var profileColor: String?
    var avatarUrl: String?
    var siteOwner: Bool?
    var publicProfile: Bool?
    var showLikedCount: Bool?
    var showCollections: Bool?
    var showRecentUploads: Bool?
    var showFriends: Bool?
    var ageVerifiedAt: String?
    var emailVerifiedAt: String?
    var createdAt: String?
    var isOnline: Bool?
    var followedByMe: Bool?
    var friendStatus: String?
    var followerCount: Int?
    var followingCount: Int?
    var friendCount: Int?
    var mediaCount: Int?
    var bannedAt: String?
    var banReason: String?

    static func == (lhs: GalleryUser, rhs: GalleryUser) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct ProfilePageResponse: Codable {
    var user: GalleryUser
    var media: [MediaItem]?
    var collections: [CollectionSummary]?
    var friends: [GalleryUser]?
}

struct FriendRequestItem: Codable, Identifiable {
    var id: Int
    var requesterId: Int?
    var addresseeId: Int?
    var status: String?
    var user: GalleryUser?
    var createdAt: String?
}

struct BlockEntry: Codable, Identifiable {
    var kind: String
    var createdAt: String?
    var user: GalleryUser

    var id: Int { user.id }
}

struct NotificationItem: Codable, Identifiable {
    var id: Int
    var kind: String
    var mediaId: Int?
    var preview: String?
    var readAt: String?
    var createdAt: String?
    var actorId: Int?
    var actorUsername: String?
    var actorDisplayName: String?
    var actorAvatarUrl: String?
    var mediaTitle: String?
    var mediaThumbUrl: String?
}

struct AuthResponse: Codable {
    var user: GalleryUser?
    var token: String?
    var needs2fa: Bool?
    var pendingToken: String?
}
