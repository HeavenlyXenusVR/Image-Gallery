import SwiftUI

@main
struct ImageGalleryApp: App {
    @StateObject private var session = SessionStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
        }
    }
}

/// Top-level chooser between the auth flow and the signed-in app shell.
/// Mirrors the web app's `ctx.user` gate in `frontend/src/App.jsx`.
struct RootView: View {
    @EnvironmentObject private var session: SessionStore
    @AppStorage("theme_mode") private var themeMode = "system"
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if session.isBootstrapping {
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
            await session.bootstrap()
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                Task { await session.refreshCurrentUser() }
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
}
