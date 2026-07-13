import SwiftUI

/// Mirrors the web app's primary nav (`Shell.jsx`): Discover, Messages,
/// Studio, Upload, Notifications, Profile. The owner-only Admin dashboard
/// stays web-only (see the iOS plan's deferred list). Six tabs means iOS
/// collapses the last two into a "More" tab — standard, well-understood
/// behavior, not a bug.
struct RootTabView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var quickActionRouter: QuickActionRouter
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack {
                FeedView()
            }
            .tabItem { Label("Discover", systemImage: "square.grid.2x2") }
            .tag(0)

            NavigationStack {
                MessagesView()
            }
            .tabItem { Label("Messages", systemImage: "message") }
            .tag(1)

            NavigationStack {
                StudioView()
            }
            .tabItem { Label("Studio", systemImage: "photo.stack") }
            .tag(2)

            NavigationStack {
                UploadView()
            }
            .tabItem { Label("Upload", systemImage: "square.and.arrow.up") }
            .tag(3)

            NavigationStack {
                NotificationsView()
            }
            .tabItem { Label("Alerts", systemImage: "bell") }
            .tag(4)

            NavigationStack {
                if let username = session.currentUser?.username {
                    ProfileView(username: username)
                } else {
                    ProgressView()
                }
            }
            .tabItem { Label("Profile", systemImage: "person.crop.circle") }
            .tag(5)
        }
        .onChange(of: quickActionRouter.pendingDestination) { destination in
            if let destination {
                selection = destination.rawValue
                quickActionRouter.pendingDestination = nil
            }
        }
    }
}
