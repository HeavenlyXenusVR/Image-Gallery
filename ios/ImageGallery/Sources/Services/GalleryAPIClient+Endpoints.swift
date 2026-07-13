import Foundation

// Response envelopes matching the backend's actual JSON wrapper shapes.
struct MediaListResponse: Decodable { var media: [MediaItem] }
struct MediaResponse: Decodable { var media: MediaItem }
struct MediaDetailResponse: Decodable {
    var media: MediaItem
    var comments: [Comment]?
    var reactions: ReactionsSummary?
    var similar: [MediaItem]?
}
struct CommentResponse: Decodable { var comment: Comment }
struct ReactionsResponse: Decodable { var reactions: ReactionsSummary }
struct UserResponse: Decodable { var user: GalleryUser }
struct UsersResponse: Decodable { var users: [GalleryUser] }
struct FriendsResponse: Decodable { var friends: [GalleryUser] }
struct FriendRequestsResponse: Decodable { var incoming: [FriendRequestItem]; var outgoing: [FriendRequestItem] }
struct BlocksResponse: Decodable { var blocks: [BlockEntry] }
struct NotificationsResponse: Decodable { var notifications: [NotificationItem]; var unreadCount: Int? }
struct UnreadCountResponse: Decodable { var unreadCount: Int }
struct CollectionsResponse: Decodable { var collections: [CollectionSummary] }
struct CollectionDetailResponse: Decodable { var collection: CollectionSummary; var media: [MediaItem]? }
struct SavedSearchesResponse: Decodable { var savedSearches: [SavedSearch] }
struct SavedSearchResponse: Decodable { var savedSearch: SavedSearch }
struct CategoriesResponse: Decodable { var categories: [CategorySummary] }
struct TotpStatusResponse: Decodable { var enabled: Bool; var recoveryCodesRemaining: Int? }
struct TotpEnrollResponse: Decodable { var secret: String; var otpauthUrl: String? }
struct TotpConfirmResponse: Decodable { var enabled: Bool; var recoveryCodes: [String]? }

// MARK: - Auth

extension GalleryAPIClient {
    struct LoginBody: Encodable { var username: String; var password: String }
    struct RegisterBody: Encodable { var username: String; var password: String; var email: String?; var displayName: String? }
    struct TwoFactorBody: Encodable { var pendingToken: String; var code: String }
    struct AgeVerifyBody: Encodable { var birthdate: String; var confirmOver18: Bool }

    func login(username: String, password: String) async throws -> AuthResponse {
        try await requestJSON("/api/auth/login", body: LoginBody(username: username, password: password), requiresAuth: false)
    }

    func register(username: String, password: String, email: String?, displayName: String?) async throws -> AuthResponse {
        try await requestJSON("/api/auth/register", body: RegisterBody(username: username, password: password, email: email, displayName: displayName), requiresAuth: false)
    }

    func verifyTwoFactor(pendingToken: String, code: String) async throws -> AuthResponse {
        try await requestJSON("/api/auth/2fa/verify", body: TwoFactorBody(pendingToken: pendingToken, code: code), requiresAuth: false)
    }

    func logout() async {
        try? await requestVoid("/api/auth/logout", method: "POST")
        authToken = nil
    }

    func me() async throws -> GalleryUser {
        try await requestJSON("/api/me")
    }

    func verifyAge(birthdate: String) async throws -> GalleryUser {
        let response: UserResponse = try await requestJSON("/api/me/age-verification", body: AgeVerifyBody(birthdate: birthdate, confirmOver18: true))
        return response.user
    }
}

// MARK: - Feed / Discover

extension GalleryAPIClient {
    func listMedia(mediaKind: String? = nil, categoryId: Int? = nil, query: String? = nil, sort: String = "new", adult: String? = nil, limit: Int = 60, offset: Int = 0) async throws -> [MediaItem] {
        var params: [String: String] = ["sort": sort, "limit": String(limit), "offset": String(offset)]
        if let mediaKind { params["media_kind"] = mediaKind }
        if let categoryId { params["category_id"] = String(categoryId) }
        if let query, !query.isEmpty { params["q"] = query }
        if let adult { params["adult"] = adult }
        let response: MediaListResponse = try await requestJSON("/api/media", query: params, requiresAuth: false)
        return response.media
    }

    func mediaDetail(id: Int) async throws -> MediaDetailResponse {
        try await requestJSON("/api/media/\(id)", requiresAuth: false)
    }

    func categories() async throws -> [CategorySummary] {
        let response: CategoriesResponse = try await requestJSON("/api/categories", requiresAuth: false)
        return response.categories
    }
}

// MARK: - Media actions

extension GalleryAPIClient {
    struct LikeBody: Encodable { var liked: Bool }
    struct BookmarkBody: Encodable { var bookmarked: Bool }
    struct CommentBody: Encodable { var body: String; var parentCommentId: Int? }
    struct ReactionBody: Encodable { var emoji: String }
    struct ReportBody: Encodable { var reason: String; var details: String? }

    func setLiked(mediaId: Int, liked: Bool) async throws -> MediaItem {
        let response: MediaResponse = try await requestJSON("/api/media/\(mediaId)/like", body: LikeBody(liked: liked))
        return response.media
    }

    func setBookmarked(mediaId: Int, bookmarked: Bool) async throws -> MediaItem {
        let response: MediaResponse = try await requestJSON("/api/media/\(mediaId)/bookmark", body: BookmarkBody(bookmarked: bookmarked))
        return response.media
    }

    func addComment(mediaId: Int, body: String, parentCommentId: Int? = nil) async throws -> Comment {
        let response: CommentResponse = try await requestJSON("/api/media/\(mediaId)/comments", body: CommentBody(body: body, parentCommentId: parentCommentId))
        return response.comment
    }

    func deleteComment(id: Int) async throws {
        try await requestVoid("/api/comments/\(id)", method: "DELETE")
    }

    func react(mediaId: Int, emoji: String) async throws -> ReactionsSummary {
        let response: ReactionsResponse = try await requestJSON("/api/media/\(mediaId)/react", body: ReactionBody(emoji: emoji))
        return response.reactions
    }

    func reportMedia(mediaId: Int, reason: String, details: String?) async throws {
        _ = try await requestJSON("/api/media/\(mediaId)/report", body: ReportBody(reason: reason, details: details)) as UnreadCountResponseOrIgnore
    }
}

// MARK: - Upload / Studio

extension GalleryAPIClient {
    struct UploadFields {
        var title: String
        var description: String
        var categoryId: Int?
        var categoryName: String
        var tags: String
        var isAdult: Bool
        var visibility: String
        var commentsEnabled: Bool
        var downloadsEnabled: Bool
        var autoAI: Bool
        var publishAt: String?
    }

    func uploadMedia(data: Data, fileName: String, mimeType: String, fields: UploadFields) async throws -> MediaItem {
        var form: [String: String] = [
            "title": fields.title,
            "description": fields.description,
            "category_name": fields.categoryName,
            "tags": fields.tags,
            "is_adult": String(fields.isAdult),
            "visibility": fields.visibility,
            "comments_enabled": String(fields.commentsEnabled),
            "downloads_enabled": String(fields.downloadsEnabled),
            "auto_ai": String(fields.autoAI),
        ]
        if let categoryId = fields.categoryId { form["category_id"] = String(categoryId) }
        if let publishAt = fields.publishAt, !publishAt.isEmpty { form["publish_at"] = publishAt }
        let file = MultipartFile(fieldName: "file", fileName: fileName, mimeType: mimeType, data: data)
        let response: MediaResponse = try await upload("/api/media", fields: form, file: file)
        return response.media
    }

    func myMedia(includeDeleted: Bool = true) async throws -> [MediaItem] {
        let response: MediaListResponse = try await requestJSON("/api/me/media", query: ["include_deleted": String(includeDeleted)])
        return response.media
    }

    struct ControlsBody: Encodable {
        var visibility: String?
        var commentsEnabled: Bool?
        var downloadsEnabled: Bool?
        var pinned: Bool?
    }

    func updateControls(mediaId: Int, patch: ControlsBody) async throws -> MediaItem {
        let response: MediaResponse = try await requestJSON("/api/media/\(mediaId)/controls", method: "PATCH", body: patch)
        return response.media
    }

    func deleteMedia(id: Int) async throws {
        try await requestVoid("/api/media/\(id)", method: "DELETE")
    }

    func restoreMedia(id: Int) async throws -> MediaItem {
        let response: MediaResponse = try await requestJSON("/api/media/\(id)/restore", body: EmptyBody())
        return response.media
    }
}

// MARK: - Profiles / social

extension GalleryAPIClient {
    struct FollowBody: Encodable { var following: Bool }
    struct FriendActionBody: Encodable { var action: String }
    struct BlockBody: Encodable { var kind: String; var active: Bool }

    func publicProfile(username: String) async throws -> GalleryUser {
        let response: UserResponse = try await requestJSON("/api/users/\(username)", requiresAuth: false)
        return response.user
    }

    func profilePage(username: String) async throws -> ProfilePageResponse {
        try await requestJSON("/api/users/\(username)/profile", requiresAuth: false)
    }

    func searchUsers(query: String) async throws -> [GalleryUser] {
        let response: UsersResponse = try await requestJSON("/api/users/search", query: ["q": query, "limit": "30"], requiresAuth: false)
        return response.users
    }

    func setFollowing(userId: Int, following: Bool) async throws {
        try await requestJSON("/api/users/\(userId)/follow", body: FollowBody(following: following)) as UnreadCountResponseOrIgnore
    }

    func sendFriendRequest(userId: Int) async throws {
        _ = try await requestVoid("/api/users/\(userId)/friend-request", method: "POST")
    }

    func respondFriendRequest(requestId: Int, action: String) async throws {
        try await requestJSON("/api/friends/requests/\(requestId)", body: FriendActionBody(action: action)) as UnreadCountResponseOrIgnore
    }

    func friendRequests() async throws -> FriendRequestsResponse {
        try await requestJSON("/api/friends/requests")
    }

    func myFriends() async throws -> [GalleryUser] {
        let response: FriendsResponse = try await requestJSON("/api/me/friends")
        return response.friends
    }

    func setBlock(userId: Int, kind: String, active: Bool) async throws {
        try await requestJSON("/api/users/\(userId)/block", body: BlockBody(kind: kind, active: active)) as UnreadCountResponseOrIgnore
    }

    func myBlocks() async throws -> [BlockEntry] {
        let response: BlocksResponse = try await requestJSON("/api/me/blocks")
        return response.blocks
    }

    func uploadAvatar(data: Data, fileName: String, mimeType: String) async throws -> GalleryUser {
        let file = MultipartFile(fieldName: "file", fileName: fileName, mimeType: mimeType, data: data)
        let response: UserResponse = try await upload("/api/me/avatar", fields: [:], file: file)
        return response.user
    }
}

/// Some endpoints return small/irrelevant JSON bodies we don't need typed —
/// decode into a permissive placeholder rather than a full ack response.
struct UnreadCountResponseOrIgnore: Decodable {}

// MARK: - Notifications

extension GalleryAPIClient {
    func notifications(limit: Int = 30, offset: Int = 0) async throws -> NotificationsResponse {
        try await requestJSON("/api/notifications", query: ["limit": String(limit), "offset": String(offset)])
    }

    func unreadNotificationCount() async throws -> Int {
        let response: UnreadCountResponse = try await requestJSON("/api/notifications/unread-count")
        return response.unreadCount
    }

    func markNotificationRead(id: Int) async throws {
        _ = try await requestVoid("/api/notifications/\(id)/read", method: "POST")
    }

    func markAllNotificationsRead() async throws {
        _ = try await requestVoid("/api/notifications/read-all", method: "POST")
    }
}

// MARK: - Collections & saved searches

extension GalleryAPIClient {
    func collections(mine: Bool = false) async throws -> [CollectionSummary] {
        let response: CollectionsResponse = try await requestJSON("/api/collections", query: ["mine": String(mine)])
        return response.collections
    }

    func collectionDetail(id: Int) async throws -> CollectionDetailResponse {
        try await requestJSON("/api/collections/\(id)", requiresAuth: false)
    }

    func savedSearches() async throws -> [SavedSearch] {
        let response: SavedSearchesResponse = try await requestJSON("/api/saved-searches")
        return response.savedSearches
    }

    func deleteSavedSearch(id: Int) async throws {
        try await requestVoid("/api/saved-searches/\(id)", method: "DELETE")
    }
}

// MARK: - 2FA & data export

extension GalleryAPIClient {
    struct TotpConfirmBody: Encodable { var code: String }
    struct TotpDisableBody: Encodable { var password: String }

    func totpStatus() async throws -> TotpStatusResponse {
        try await requestJSON("/api/me/2fa/status")
    }

    func beginTotpEnrollment() async throws -> TotpEnrollResponse {
        try await requestJSON("/api/me/2fa/enroll", body: EmptyBody())
    }

    func confirmTotpEnrollment(code: String) async throws -> TotpConfirmResponse {
        try await requestJSON("/api/me/2fa/confirm", body: TotpConfirmBody(code: code))
    }

    func disableTotp(password: String) async throws {
        _ = try await requestJSON("/api/me/2fa/disable", body: TotpDisableBody(password: password)) as UnreadCountResponseOrIgnore
    }

    func exportMyData() async throws -> Data {
        try await download("/api/me/export")
    }
}
