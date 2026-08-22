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
    var discordUserId: String?
    var discordUsername: String?
    var discordVerifiedAt: String?
    var userSettings: UserSettings?

    static func == (lhs: GalleryUser, rhs: GalleryUser) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The handful of `user_settings` keys (out of ~40 on the backend, see
/// `DEFAULT_USER_SETTINGS` in `app/db/_shared.py`) the iOS app reads and
/// writes. Decoding is lenient by design — extra keys in the JSON object are
/// simply ignored, so this stays forward-compatible as the web app's settings
/// schema grows. Values reuse the exact same strings the web app stores
/// (`profile_layout`, `profile_avatar_shape`) so switching a setting on
/// either client renders sensibly on the other.
struct UserSettings: Codable, Equatable {
    var themeMode: String?
    var accentColor: String?
    var accentSecondary: String?
    var profileLayout: String?
    var profileAvatarShape: String?
    var autoplayPreviews: Bool?
    var mutedPreviews: Bool?
    var blurVideoPreviews: Bool?
    var reduceMotion: Bool?
    var gridDensity: String?
    var defaultSort: String?
    var profileShowFollowCounts: Bool?
    var profileShowJoinedDate: Bool?
    var watermarkText: String?
    var discordWebhookUrl: String?
    var cardAspectRatio: String?
    var mediaBorderStyle: String?
    var cardInfoDisplay: String?
    var columnGap: String?
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
