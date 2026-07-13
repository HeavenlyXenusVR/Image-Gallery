import SwiftUI

/// Mirrors the web app's primary nav (`Shell.jsx`): Discover, Studio, Upload,
/// Notifications, Profile. Messages and the owner-only Admin dashboard are
/// intentionally out of scope for v1 (see the iOS plan's deferred list).
struct RootTabView: View {
    @EnvironmentObject private var session: SessionStore
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack {
                FeedView()
            }
            .tabItem { Label("Discover", systemImage: "square.grid.2x2") }
            .tag(0)

            NavigationStack {
                StudioView()
            }
            .tabItem { Label("Studio", systemImage: "photo.stack") }
            .tag(1)

            NavigationStack {
                UploadView()
            }
            .tabItem { Label("Upload", systemImage: "square.and.arrow.up") }
            .tag(2)

            NavigationStack {
                NotificationsView()
            }
            .tabItem { Label("Alerts", systemImage: "bell") }
            .tag(3)

            NavigationStack {
                if let username = session.currentUser?.username {
                    ProfileView(username: username)
                } else {
                    ProgressView()
                }
            }
            .tabItem { Label("Profile", systemImage: "person.crop.circle") }
            .tag(4)
        }
    }
}
