import SwiftUI

/// Mirrors the web app's primary nav (`Shell.jsx`): Discover, Messages,
/// Studio, Upload, Profile. The owner-only Admin dashboard stays web-only
/// (see the iOS plan's deferred list).
///
/// Deliberately kept to 5 tabs, not 6. A 6th tab (Notifications used to be
/// its own tab) pushes iOS's TabView past its 5-visible-item limit, which
/// makes it auto-collapse the overflow into a system-generated "More" tab.
/// That "More" screen is itself navigation-based, and since every tab root
/// here is independently wrapped in its own NavigationStack (needed for
/// that tab's own push navigation), a tab reached through "More" ends up
/// nested inside two navigation controllers at once -- visibly two stacked
/// back-chevron buttons at the top of the screen instead of one, confirmed
/// live on device. Access to Notifications moved to a toolbar bell button
/// (see FeedView) instead, which avoids the 6th-tab overflow entirely
/// rather than patching around the double-nav-bar symptom.
struct RootTabView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var quickActionRouter: QuickActionRouter
    @EnvironmentObject private var unreadCounts: UnreadCountsService
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
            .badge(unreadCounts.messages)
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
                if let username = session.currentUser?.username {
                    ProfileView(username: username)
                } else {
                    ProgressView()
                }
            }
            .tabItem { Label("Profile", systemImage: "person.crop.circle") }
            .tag(4)
        }
        .onChange(of: quickActionRouter.pendingDestination) { destination in
            if let destination {
                selection = destination.rawValue
                quickActionRouter.pendingDestination = nil
            }
        }
    }
}
