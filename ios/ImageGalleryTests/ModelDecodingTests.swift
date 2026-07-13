import XCTest
@testable import ImageGallery

final class ModelDecodingTests: XCTestCase {
    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    func testMediaItemDecodesBackendShape() throws {
        let json = """
        {
          "id": 42,
          "title": "Sunset",
          "media_kind": "image",
          "url": "https://example.com/media/42",
          "thumb_url": "https://example.com/media/42/thumb",
          "is_adult": false,
          "liked_by_me": true,
          "like_count": 3,
          "user_id": 7,
          "username": "alice",
          "visibility": "public",
          "tags": ["sunset", "beach"]
        }
        """
        let item = try makeDecoder().decode(MediaItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.id, 42)
        XCTAssertEqual(item.mediaKind, "image")
        XCTAssertEqual(item.likedByMe, true)
        XCTAssertEqual(item.likeCount, 3)
        XCTAssertEqual(item.username, "alice")
        XCTAssertEqual(item.tags, ["sunset", "beach"])
        XCTAssertFalse(item.isVideo)
    }

    func testAuthResponseMapsNeeds2FA() throws {
        let json = """
        {"needs_2fa": true, "pending_token": "abc123"}
        """
        let response = try makeDecoder().decode(AuthResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.needs2fa, true)
        XCTAssertEqual(response.pendingToken, "abc123")
        XCTAssertNil(response.user)
    }

    func testReactionsSummaryDecodesCountsAndMyReaction() throws {
        let json = """
        {"counts": {"👍": 2, "🔥": 1}, "my_reaction": "👍"}
        """
        let summary = try makeDecoder().decode(ReactionsSummary.self, from: Data(json.utf8))
        XCTAssertEqual(summary.counts?["👍"], 2)
        XCTAssertEqual(summary.myReaction, "👍")
    }
}
