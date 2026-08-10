import Foundation

// Endpoints added across the Lua backend's "round 1-5 + Discord
// verification" pass (2026-08-10): following/liked feeds, creator
// leaderboard, creator analytics, password change, zip downloads, and
// Discord account verification. Kept in its own file (mirroring how
// +Messaging.swift is split out) rather than growing +Endpoints.swift
// further.

// MARK: - Following / Liked feeds

extension GalleryAPIClient {
    func followingFeed(limit: Int = 60, offset: Int = 0) async throws -> [MediaItem] {
        let response: MediaListResponse = try await requestJSON("/api/feed/following", query: ["limit": String(limit), "offset": String(offset)])
        return response.media
    }

    func likedFeed(limit: Int = 60, offset: Int = 0) async throws -> [MediaItem] {
        let response: MediaListResponse = try await requestJSON("/api/me/likes", query: ["limit": String(limit), "offset": String(offset)])
        return response.media
    }
}

// MARK: - Creator leaderboard

struct LeaderboardEntry: Decodable, Identifiable {
    var id: Int
    var username: String
    var displayName: String?
    var userAvatarUrl: String?
    var profileColor: String?
    var publicProfile: Bool?
    var totalViews: Int
    var totalLikes: Int
    var postCount: Int
}

extension GalleryAPIClient {
    /// `window`: "7d", "30d", or "all".
    func leaderboard(window: String = "30d") async throws -> [LeaderboardEntry] {
        struct Response: Decodable { var creators: [LeaderboardEntry] }
        let response: Response = try await requestJSON("/api/leaderboard", query: ["window": window], requiresAuth: false)
        return response.creators
    }
}

// MARK: - Creator analytics (Studio)

struct CreatorStatsTotals: Decodable {
    var totalViews: Int
    var totalLikes: Int
    var totalSaves: Int
}

struct CreatorStatsTopPost: Decodable, Identifiable {
    var id: Int
    var title: String?
    var thumbUrl: String?
    var views: Int
    var likeCount: Int
    var saveCount: Int
    var commentCount: Int
}

struct CreatorStatsDay: Decodable, Identifiable {
    var day: String
    var newViewers: Int
    var id: String { day }
}

struct CreatorStatsResponse: Decodable {
    var totals: CreatorStatsTotals
    var topPosts: [CreatorStatsTopPost]
    var dailyNewViewers: [CreatorStatsDay]
}

extension GalleryAPIClient {
    func creatorStats() async throws -> CreatorStatsResponse {
        try await requestJSON("/api/me/stats")
    }
}

// MARK: - Password change

extension GalleryAPIClient {
    struct PasswordChangeBody: Encodable { var oldPassword: String; var newPassword: String }

    func changePassword(oldPassword: String, newPassword: String) async throws {
        _ = try await requestJSON("/api/me/password", body: PasswordChangeBody(oldPassword: oldPassword, newPassword: newPassword)) as UnreadCountResponseOrIgnore
    }
}

// MARK: - Zip downloads

extension GalleryAPIClient {
    struct DownloadBatchBody: Encodable { var mediaIds: [Int] }

    func downloadMediaBatch(ids: [Int]) async throws -> Data {
        try await downloadPOST("/api/media/download-batch", body: DownloadBatchBody(mediaIds: ids))
    }

    func downloadCollection(id: Int) async throws -> Data {
        try await download("/api/collections/\(id)/download")
    }
}

// MARK: - Discord account verification

struct DiscordVerifyPending: Decodable {
    var method: String
    var expiresAt: String
}

struct DiscordVerifyStatus: Decodable {
    var verified: Bool
    var discordUsername: String?
    var discordUserId: String?
    var pending: DiscordVerifyPending?
    var dmAvailable: Bool?
}

extension GalleryAPIClient {
    struct DiscordVerifyStartBody: Encodable { var method: String; var discordUserId: String? }
    struct DiscordVerifyConfirmBody: Encodable { var code: String }

    func discordVerifyStatus() async throws -> DiscordVerifyStatus {
        try await requestJSON("/api/me/discord/verify/status")
    }

    struct DiscordVerifyStartResponse: Decodable { var ok: Bool; var method: String; var expiresInSeconds: Int }

    func discordVerifyStart(method: String, discordUserId: String? = nil) async throws -> DiscordVerifyStartResponse {
        try await requestJSON("/api/me/discord/verify/start", body: DiscordVerifyStartBody(method: method, discordUserId: discordUserId))
    }

    func discordVerifyConfirm(code: String) async throws -> GalleryUser {
        let response: UserResponse = try await requestJSON("/api/me/discord/verify/confirm", body: DiscordVerifyConfirmBody(code: code))
        return response.user
    }

    func discordUnlink() async throws -> GalleryUser {
        let response: UserResponse = try await requestJSON("/api/me/discord/unlink", body: EmptyBody())
        return response.user
    }
}
