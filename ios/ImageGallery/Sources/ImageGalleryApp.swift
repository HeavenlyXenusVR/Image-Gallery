import SwiftUI

@main
struct ImageGalleryApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var session = SessionStore()
    @StateObject private var biometricLock = BiometricLockService()
    @StateObject private var quickActionRouter = QuickActionRouter.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(biometricLock)
                .environmentObject(quickActionRouter)
        }
    }
}

/// Top-level chooser between the auth flow and the signed-in app shell.
/// Mirrors the web app's `ctx.user` gate in `frontend/src/App.jsx`.
struct RootView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var biometricLock: BiometricLockService
    @AppStorage("theme_mode") private var themeMode = "system"
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if biometricLock.isEnabled && !biometricLock.isUnlocked {
                BiometricLockView()
            } else if session.isBootstrapping {
                ProgressView("Loading...")
            } else if session.currentUser != nil {
                RootTabView()
            } else {
                AuthContainerView()
            }
        }
        .preferredColorScheme(colorScheme)
        .tint(Color(hex: session.currentUser?.userSettings?.accentColor))
        .task {
            BadgeService.requestAuthorization()
            await session.bootstrap()
            await biometricLock.attemptUnlock()
            await refreshBadge()
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                Task {
                    await session.refreshCurrentUser()
                    await biometricLock.attemptUnlock()
                    await refreshBadge()
                }
            } else if newPhase == .background {
                biometricLock.lock()
            }
        }
    }

    private var colorScheme: ColorScheme? {
        switch themeMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    private func refreshBadge() async {
        guard session.currentUser != nil else {
            BadgeService.setBadge(0)
            return
        }
        if let count = try? await GalleryAPIClient.shared.unreadNotificationCount() {
            BadgeService.setBadge(count)
        }
    }
}
