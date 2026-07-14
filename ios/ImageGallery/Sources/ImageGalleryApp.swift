import SwiftUI

@main
struct ImageGalleryApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var session = SessionStore()
    @StateObject private var biometricLock = BiometricLockService()
    @StateObject private var quickActionRouter = QuickActionRouter.shared
    @StateObject private var unreadCounts = UnreadCountsService()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(biometricLock)
                .environmentObject(quickActionRouter)
                .environmentObject(unreadCounts)
        }
    }
}

/// Top-level chooser between the auth flow and the signed-in app shell.
/// Mirrors the web app's `ctx.user` gate in `frontend/src/App.jsx`.
struct RootView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var biometricLock: BiometricLockService
    @EnvironmentObject private var unreadCounts: UnreadCountsService
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
            updatePolling()
        }
        .onChange(of: session.currentUser?.id) { _ in
            updatePolling()
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                Task {
                    await session.refreshCurrentUser()
                    await biometricLock.attemptUnlock()
                    await unreadCounts.refresh()
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

    private func updatePolling() {
        if session.currentUser != nil {
            unreadCounts.startPolling()
        } else {
            unreadCounts.stopPolling()
            unreadCounts.reset()
        }
    }
}
