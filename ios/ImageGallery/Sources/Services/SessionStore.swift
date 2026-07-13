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
    }

    func refreshCurrentUser() async {
        guard api.isAuthenticated else { return }
        currentUser = try? await api.me()
    }

    func setCurrentUser(_ user: GalleryUser) {
        currentUser = user
    }
}
