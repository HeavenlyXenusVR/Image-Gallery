import SwiftUI
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

    func testGalleryUserDecodesUserSettingsAndIgnoresUnmappedKeys() throws {
        // The backend's user_settings object has ~40 keys (see DEFAULT_USER_SETTINGS
        // in lua/src/user_settings.lua); the app only models a handful, so this also
        // proves unrecognized keys (grid_density, watermark_text, ...) don't break decoding.
        let json = """
        {
          "id": 7,
          "username": "alice",
          "user_settings": {
            "theme_mode": "dark",
            "accent_color": "#ff8800",
            "profile_layout": "mosaic",
            "profile_avatar_shape": "rounded",
            "grid_density": "comfortable",
            "watermark_text": ""
          }
        }
        """
        let user = try makeDecoder().decode(GalleryUser.self, from: Data(json.utf8))
        XCTAssertEqual(user.userSettings?.themeMode, "dark")
        XCTAssertEqual(user.userSettings?.accentColor, "#ff8800")
        XCTAssertEqual(user.userSettings?.profileLayout, "mosaic")
        XCTAssertEqual(user.userSettings?.profileAvatarShape, "rounded")
        XCTAssertTrue(Appearance.isGridFirstLayout(user.userSettings?.profileLayout))
    }

    func testColorHexRoundTrip() {
        let color = Color(hex: "#37C9A7")
        XCTAssertEqual(color.toHexString(), "#37C9A7")
        // Malformed/missing values fall back to the app default rather than crashing.
        XCTAssertEqual(Color(hex: "not-a-color").toHexString(), Appearance.defaultAccentHex.uppercased())
        XCTAssertEqual(Color(hex: nil).toHexString(), Appearance.defaultAccentHex.uppercased())
    }
}
