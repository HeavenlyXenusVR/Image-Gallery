import Combine
import Foundation

/// App-wide session state: current user + auth token lifecycle. Mirrors the
/// role `ctx.user`/`ctx.setSessionUser`/`ctx.logout` play in the web app's
/// `App.jsx`.
@MainActor
final class SessionStore: ObservableObject {
    @Published var currentUser: GalleryUser?
    @Published var isBootstrapping = true
    @Published var lastError: String?

    private let api = GalleryAPIClient.shared

    /// Runs once at launch: resolve the backend origin, and if a token is
    /// already in the Keychain from a previous session, validate it against
    /// `/api/me` before showing the signed-in shell.
    func bootstrap() async {
        await LiveConfigService.shared.refresh()
        if api.isAuthenticated {
            do {
                currentUser = try await api.me()
            } catch {
                // Surface *why* — this is the only place a banned/suspended
                // account's session gets invalidated, and silently dropping
                // back to the login screen with no explanation would be
                // confusing (the backend's 403 detail already has the
                // human-readable ban reason/expiry).
                lastError = error.localizedDescription
                api.authToken = nil
                currentUser = nil
            }
        }
        isBootstrapping = false
    }

    func login(username: String, password: String) async throws -> AuthResponse {
        let response = try await api.login(username: username, password: password)
        if let token = response.token {
            api.authToken = token
            currentUser = response.user
        }
        return response
    }

    func register(username: String, password: String, email: String?, displayName: String?) async throws -> AuthResponse {
        let response = try await api.register(username: username, password: password, email: email, displayName: displayName)
        if let token = response.token {
            api.authToken = token
            currentUser = response.user
        }
        return response
    }

    func completeTwoFactor(pendingToken: String, code: String) async throws {
        let response = try await api.verifyTwoFactor(pendingToken: pendingToken, code: code)
        if let token = response.token {
            api.authToken = token
            currentUser = response.user
        }
    }

    func logout() async {
        await api.logout()
        currentUser = nil
        BadgeService.setBadge(0)
    }

    /// Called when the app returns to the foreground — picks up account
    /// changes made elsewhere (web settings, or a ban/unban) while backgrounded.
    /// Unlike `bootstrap()`, a failure here doesn't force a logout on its own:
    /// a transient network hiccup shouldn't kick a signed-in user out, but a
    /// ban's 403 still needs to end the session and explain why.
    func refreshCurrentUser() async {
        guard api.isAuthenticated else { return }
        do {
            currentUser = try await api.me()
        } catch let error as GalleryAPIError {
            if case .http(let status, let message) = error, status == 401 || status == 403 {
                lastError = message
                api.authToken = nil
                currentUser = nil
            }
        } catch {
            // Network/decoding hiccup — keep the existing session as-is.
        }
    }

    func setCurrentUser(_ user: GalleryUser) {
        currentUser = user
    }
}
