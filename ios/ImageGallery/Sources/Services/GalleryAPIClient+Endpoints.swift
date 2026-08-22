import Foundation

// Response envelopes matching the backend's actual JSON wrapper shapes.
struct MediaListResponse: Decodable { var media: [MediaItem] }
struct MediaResponse: Decodable { var media: MediaItem }
struct DuplicateMatch: Decodable, Identifiable { var id: Int; var title: String?; var thumbUrl: String?; var distance: Int? }
struct MediaUploadResponse: Decodable { var media: MediaItem; var possibleDuplicates: [DuplicateMatch]?; var possibleSiteDuplicates: [DuplicateMatch]? }
struct MediaDetailResponse: Decodable {
    var media: MediaItem
    var comments: [Comment]?
    var reactions: ReactionsSummary?
    var similar: [MediaItem]?
    var personalTags: [String]?
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
struct CollectionSuggestion: Decodable, Identifiable { var tag: String; var count: Int; var thumbUrl: String?; var id: String { tag } }
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
        let response: UserResponse = try await requestJSON("/api/me")
        return response.user
    }

    func verifyAge(birthdate: String) async throws -> GalleryUser {
        let response: UserResponse = try await requestJSON("/api/me/age-verification", body: AgeVerifyBody(birthdate: birthdate, confirmOver18: true))
        return response.user
    }

    /// Mirrors `SettingsUpdateRequest` on the backend (`app/schemas.py`) — only
    /// the subset of ~40 settings keys the iOS app edits. Omitted (nil) fields
    /// are sent as JSON null, which the backend already treats as "don't
    /// change this key" (it filters `value is not None` before applying), so
    /// this never clobbers settings the app doesn't have UI for.
    struct SettingsUpdateBody: Encodable {
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
        var galleryFont: String?
        var profileHeaderStyle: String?
        var openOriginalInNewTab: Bool?
        var profileHeroAlignment: String?
        var profileStatStyle: String?
        var profileNameStyle: String?
        var profileContentFocus: String?
        var profileFeaturedPanel: String?
        var profileSocialLayout: String?
        var profileCardStyle: String?
    }

    func updateSettings(_ body: SettingsUpdateBody) async throws -> GalleryUser {
        let response: UserResponse = try await requestJSON("/api/me/settings", method: "PATCH", body: body)
        return response.user
    }

    /// Mirrors `clean_profile_updates` on the backend (`user_settings.lua`)
    /// -- unlike `/api/me/settings`, this endpoint has NO partial-update
    /// filtering: every field is written unconditionally on every call, and
    /// an omitted boolean defaults to `true` (not "leave unchanged").
    /// Callers MUST populate every property from the current `GalleryUser`
    /// before editing, and send all of them back, or an untouched field
    /// silently resets.
    struct UpdateProfileBody: Encodable {
        var displayName: String
        var bio: String?
        var profileQuote: String?
        var websiteUrl: String?
        var locationLabel: String?
        var profileHeadline: String?
        var featuredTags: [String]
        var profileColor: String
        var publicProfile: Bool
        var showLikedCount: Bool
        var showCollections: Bool
        var showRecentUploads: Bool
        var showFriends: Bool
    }

    func updateProfile(_ body: UpdateProfileBody) async throws -> GalleryUser {
        let response: UserResponse = try await requestJSON("/api/me/profile", method: "PATCH", body: body)
        return response.user
    }
}

// MARK: - Feed / Discover

extension GalleryAPIClient {
    func listMedia(mediaKind: String? = nil, categoryId: Int? = nil, subcategoryId: Int? = nil, query: String? = nil, sort: String = "new", adult: String? = nil, limit: Int = 60, offset: Int = 0) async throws -> [MediaItem] {
        var params: [String: String] = ["sort": sort, "limit": String(limit), "offset": String(offset)]
        if let mediaKind { params["media_kind"] = mediaKind }
        if let categoryId { params["category_id"] = String(categoryId) }
        if let subcategoryId { params["subcategory_id"] = String(subcategoryId) }
        if let query, !query.isEmpty { params["q"] = query }
        if let adult { params["adult"] = adult }
        let response: MediaListResponse = try await requestJSON("/api/media", query: params, requiresAuth: false)
        return response.media
    }

    func mediaDetail(id: Int) async throws -> MediaDetailResponse {
        try await requestJSON("/api/media/\(id)", requiresAuth: false)
    }

    func trendingMedia(days: Int = 7, limit: Int = 30) async throws -> [MediaItem] {
        let response: MediaListResponse = try await requestJSON("/api/media/trending", query: ["days": String(days), "limit": String(limit)], requiresAuth: false)
        return response.media
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

    struct PersonalTagBody: Encodable { var tag: String }
    private struct PersonalTagsResponse: Decodable { var personalTags: [String] }

    /// Private, per-viewer organizational tags -- never shown to anyone else,
    /// existed on the backend since 2026-08-03 with no client anywhere until now.
    func addPersonalTag(mediaId: Int, tag: String) async throws -> [String] {
        let response: PersonalTagsResponse = try await requestJSON("/api/media/\(mediaId)/personal-tags", body: PersonalTagBody(tag: tag))
        return response.personalTags
    }

    func removePersonalTag(mediaId: Int, tag: String) async throws -> [String] {
        let encodedTag = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tag
        let response: PersonalTagsResponse = try await requestJSON("/api/media/\(mediaId)/personal-tags/\(encodedTag)", method: "DELETE", query: nil)
        return response.personalTags
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
        var checkSiteDuplicates: Bool = false
    }

    private func uploadForm(_ fields: UploadFields) -> [String: String] {
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
        if fields.checkSiteDuplicates { form["check_site_duplicates"] = "true" }
        return form
    }

    func uploadMedia(data: Data, fileName: String, mimeType: String, fields: UploadFields) async throws -> MediaUploadResponse {
        let file = MultipartFile(fieldName: "file", fileName: fileName, mimeType: mimeType, source: .data(data))
        return try await upload("/api/media", fields: uploadForm(fields), file: file)
    }

    /// Large-file variant — `fileURL` is streamed straight from disk into the
    /// multipart request body instead of being loaded into memory (see
    /// `GalleryAPIClient.upload`'s `.fileURL` case), so picking a multi-GB
    /// video for upload doesn't risk the app being killed for memory use.
    func uploadMedia(fileURL: URL, fileName: String, mimeType: String, fields: UploadFields) async throws -> MediaUploadResponse {
        let file = MultipartFile(fieldName: "file", fileName: fileName, mimeType: mimeType, source: .fileURL(fileURL))
        return try await upload("/api/media", fields: uploadForm(fields), file: file)
    }

    private struct UploadInitBody: Encodable { var totalSize: Int; var filename: String }
    private struct UploadInitResponse: Decodable { var sessionId: String; var chunkSize: Int }
    private struct ChunkAck: Decodable { var ok: Bool; var receivedBytes: Int }

    /// Splits large files into pieces before sending instead of one giant
    /// request -- this deployment's Cloudflare tunnel hard-413s any single
    /// request body over ~100MB regardless of the server's own configured
    /// upload limit (confirmed live: a 105MB request gets a Cloudflare
    /// error page before it ever reaches the app), which is what "network
    /// connection was lost" on big video uploads actually was. Mirrors
    /// `M.upload_chunk_init/_append/_finish` in routes.lua.
    func uploadMediaChunked(fileURL: URL, fileName: String, fields: UploadFields, onProgress: ((Double) -> Void)? = nil) async throws -> MediaUploadResponse {
        let totalSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? nil
        guard let totalSize, totalSize > 0 else {
            throw GalleryAPIError.http(status: 0, message: "Could not read the file to upload.")
        }

        let initResponse: UploadInitResponse = try await requestJSON(
            "/api/media/upload/init",
            body: UploadInitBody(totalSize: totalSize, filename: fileName)
        )

        let reader = try FileHandle(forReadingFrom: fileURL)
        defer { try? reader.close() }
        var index = 0
        var sentBytes = 0
        while let chunk = try reader.read(upToCount: initResponse.chunkSize), !chunk.isEmpty {
            let ack: ChunkAck = try await uploadChunkBytes(
                "/api/media/upload/chunk",
                query: ["session_id": initResponse.sessionId, "index": String(index)],
                data: chunk
            )
            sentBytes = ack.receivedBytes
            onProgress?(Double(sentBytes) / Double(totalSize))
            index += 1
        }

        var body = uploadForm(fields)
        body["session_id"] = initResponse.sessionId
        return try await requestJSON("/api/media/upload/finish", body: body)
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

    struct BulkResult: Decodable { var id: Int; var ok: Bool; var error: String? }
    struct BulkPatchBody: Encodable { var ids: [Int]; var patch: [String: JSONValue] }
    struct BulkDeleteBody: Encodable { var ids: [Int] }

    func bulkUpdateVisibility(ids: [Int], visibility: String) async throws -> [BulkResult] {
        struct Response: Decodable { var results: [BulkResult] }
        let response: Response = try await requestJSON("/api/media/bulk", body: BulkPatchBody(ids: ids, patch: ["visibility": .string(visibility)]))
        return response.results
    }

    func bulkAddTag(ids: [Int], tag: String) async throws -> [BulkResult] {
        struct Response: Decodable { var results: [BulkResult] }
        let response: Response = try await requestJSON("/api/media/bulk", body: BulkPatchBody(ids: ids, patch: ["add_tag": .string(tag)]))
        return response.results
    }

    func bulkDeleteMedia(ids: [Int]) async throws -> [BulkResult] {
        struct Response: Decodable { var results: [BulkResult] }
        let response: Response = try await requestJSON("/api/media/bulk-delete", body: BulkDeleteBody(ids: ids))
        return response.results
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

    func followers(userId: Int) async throws -> [GalleryUser] {
        let response: UsersResponse = try await requestJSON("/api/users/\(userId)/followers", requiresAuth: false)
        return response.users
    }

    func following(userId: Int) async throws -> [GalleryUser] {
        let response: UsersResponse = try await requestJSON("/api/users/\(userId)/following", requiresAuth: false)
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
        let file = MultipartFile(fieldName: "file", fileName: fileName, mimeType: mimeType, source: .data(data))
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

    func collectionSuggestions() async throws -> [CollectionSuggestion] {
        struct Response: Decodable { var suggestions: [CollectionSuggestion] }
        let response: Response = try await requestJSON("/api/collections/suggestions")
        return response.suggestions
    }

    func collectionDetail(id: Int) async throws -> CollectionDetailResponse {
        try await requestJSON("/api/collections/\(id)", requiresAuth: false)
    }

    func savedSearches() async throws -> [SavedSearch] {
        let response: SavedSearchesResponse = try await requestJSON("/api/saved-searches")
        return response.savedSearches
    }

    struct SavedSearchCreateBody: Encodable { var name: String; var filterJson: DiscoverFilterPayload }

    func createSavedSearch(name: String, filter: DiscoverFilterPayload) async throws -> SavedSearch {
        let response: SavedSearchResponse = try await requestJSON("/api/saved-searches", body: SavedSearchCreateBody(name: name, filterJson: filter))
        return response.savedSearch
    }

    func deleteSavedSearch(id: Int) async throws {
        try await requestVoid("/api/saved-searches/\(id)", method: "DELETE")
    }

    struct CollectionCreateBody: Encodable {
        var name: String
        var description: String?
        var isPublic: Bool
        var isSmart: Bool
        var filterJson: DiscoverFilterPayload
    }

    func createCollection(name: String, description: String?, isPublic: Bool, isSmart: Bool, filter: DiscoverFilterPayload) async throws -> CollectionSummary {
        struct Response: Decodable { var collection: CollectionSummary }
        let response: Response = try await requestJSON("/api/collections", body: CollectionCreateBody(name: name, description: description, isPublic: isPublic, isSmart: isSmart, filterJson: filter))
        return response.collection
    }
}

/// Mirrors `SMART_COLLECTION_FILTER_KEYS` in `app/db/feed_collections.py` —
/// the one filter shape shared by smart collections and saved searches.
struct DiscoverFilterPayload: Encodable {
    var mediaKind: String?
    var categoryId: Int?
    var subcategoryId: Int?
    var q: String?
    var uploader: String?
    var minSize: Int?
    var maxSize: Int?
    var dateFrom: String?
    var dateTo: String?
    var adult: String?
    var sort: String?
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

// MARK: - AI vision training status

struct AIVisionStatus: Decodable {
    var provider: String
    var aiEnabled: Bool
    var trainingExamplesLoadedLimit: Int?
    var trainingExamplesAvailable: Int
    var activeModel: String?
    var geminiKeyConfigured: Bool?
    var reachable: Bool?
    var reason: String?
}

extension GalleryAPIClient {
    private struct AIVisionStatusResponse: Decodable { var vision: AIVisionStatus }

    func aiVisionStatus() async throws -> AIVisionStatus {
        let response: AIVisionStatusResponse = try await requestJSON("/api/ai/vision/status")
        return response.vision
    }

    func exportAITrainingData() async throws -> Data {
        try await download("/api/ai/vision/training/export")
    }
}
