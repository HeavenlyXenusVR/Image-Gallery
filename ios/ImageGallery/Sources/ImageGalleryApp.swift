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
        .modifier(GalleryFontDesign(galleryFont: session.currentUser?.userSettings?.galleryFont))
        // reduce_motion: nils out the animation on every transaction that
        // flows through this point in the tree, including ones descendant
        // views set with explicit withAnimation(...) calls -- the
        // documented way to suppress animations app-wide from one place
        // instead of threading a flag through all 8 files that currently
        // call withAnimation/.animation individually.
        .transaction { transaction in
            if session.currentUser?.userSettings?.reduceMotion == true {
                transaction.animation = nil
            }
        }
        .task {
            BadgeService.requestAuthorization()
            await session.bootstrap()
            await biometricLock.attemptUnlock()
            updatePolling()
            await ServerConfig.shared.refresh()
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

/// `gallery_font` -- mirrors web's FONT_MAP (frontend/src/utils/
/// appearance.js): serif/mono/rounded/system map directly onto SwiftUI's
/// `Font.Design` cases. `.fontDesign(_:)` is iOS 16.1+ but this app's
/// deployment target is 16.0, so it's gated behind `#available` -- on 16.0
/// itself this is a no-op (system font design), not a crash or build error.
private struct GalleryFontDesign: ViewModifier {
    let galleryFont: String?

    func body(content: Content) -> some View {
        if #available(iOS 16.1, *) {
            content.fontDesign(design)
        } else {
            content
        }
    }

    @available(iOS 16.1, *)
    private var design: Font.Design {
        switch galleryFont {
        case "serif": return .serif
        case "mono": return .monospaced
        case "rounded": return .rounded
        default: return .default
        }
    }
}
