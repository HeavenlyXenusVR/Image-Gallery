import SwiftUI

struct ProfileView: View {
    @StateObject private var viewModel: ProfileViewModel
    @EnvironmentObject private var session: SessionStore

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Appearance.gridColumnMinWidth(session.currentUser?.userSettings?.gridDensity, default_: 100)), spacing: 8)]
    }

    init(username: String) {
        _viewModel = StateObject(wrappedValue: ProfileViewModel(username: username))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let user = viewModel.user {
                    profileContent(user)
                } else if viewModel.isLoading {
                    ProgressView().padding(.top, 80)
                } else if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .padding()
        }
        .navigationTitle(viewModel.user?.displayName ?? viewModel.username)
        .tint(Color(hex: viewModel.user?.userSettings?.accentColor))
        .toolbar {
            if viewModel.user?.friendStatus == "self" {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(destination: SettingsView()) {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(destination: FriendRequestsView()) {
                        Image(systemName: "person.badge.clock")
                    }
                    .accessibilityLabel("Friend requests")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(destination: EditProfileView()) {
                        Image(systemName: "pencil")
                    }
                    .accessibilityLabel("Edit profile")
                }
            } else if let user = viewModel.user {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: profileShareURL(username: user.username)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share profile")
                }
            }
        }
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
    }

    @ViewBuilder
    private func profileContent(_ user: GalleryUser) -> some View {
        if Appearance.isGridFirstLayout(user.userSettings?.profileLayout) {
            mediaSection
            headerSection(user)
            collectionsSection
            friendsSection
        } else {
            headerSection(user)
            mediaSection
            collectionsSection
            friendsSection
        }
    }

    @ViewBuilder
    private func headerSection(_ user: GalleryUser) -> some View {
        ProfileHeader(user: user)
        ProfileActionsView(viewModel: viewModel)
    }

    @ViewBuilder
    private var mediaSection: some View {
        if !viewModel.media.isEmpty {
            Text("Posts").font(.headline)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(viewModel.media) { item in
                    NavigationLink(destination: MediaDetailView(mediaId: item.id)) {
                        MediaCard(item: item)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var collectionsSection: some View {
        if !viewModel.collections.isEmpty {
            Text("Collections").font(.headline)
            ForEach(viewModel.collections) { collection in
                NavigationLink(destination: CollectionDetailView(collectionId: collection.id)) {
                    Label(collection.name, systemImage: "folder")
                }
            }
        }
    }

    @ViewBuilder
    private var friendsSection: some View {
        if !viewModel.friends.isEmpty {
            Text("Friends").font(.headline)
            ForEach(viewModel.friends) { friend in
                NavigationLink(destination: ProfileView(username: friend.username)) {
                    Label(friend.displayName ?? friend.username, systemImage: "person.crop.circle")
                }
            }
        }
    }

    /// Matches the web app's route (`frontend/src/App.jsx`: `/users/:username`,
    /// served under the GitHub Pages basename) so a shared link opens the
    /// same profile there for anyone without the app installed.
    private func profileShareURL(username: String) -> URL {
        let encoded = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? username
        return URL(string: "https://heavenlyxenusvr.github.io/Nyxframe/users/\(encoded)")
            ?? URL(string: "https://heavenlyxenusvr.github.io/Nyxframe/")!
    }
}

/// Split out of `ProfileView.body` to keep each individual view's expression
/// simple for the type-checker (see the CollectionsListView fix for why).
private struct ProfileHeader: View {
    let user: GalleryUser

    private var accent: Color { Color(hex: user.userSettings?.accentColor) }

    // accent_secondary is optional -- unlike accent_color, an unset/empty
    // value should mean "no second color" (single-color wash), not fall
    // back to re-deriving a default the way Color(hex:) does for the
    // primary accent.
    private var secondaryAccent: Color? {
        guard let hex = user.userSettings?.accentSecondary, !hex.isEmpty else { return nil }
        return Color(hex: hex)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                AvatarView(urlString: user.avatarUrl, fallbackInitial: String(user.username.prefix(1)), shape: AvatarShape(user.userSettings?.profileAvatarShape), size: 72)
                    .overlay(
                        RoundedRectangle(cornerRadius: 72 * AvatarShape(user.userSettings?.profileAvatarShape).cornerRadiusFraction)
                            .strokeBorder(accent.opacity(0.6), lineWidth: 2)
                    )
                VStack(alignment: .leading, spacing: 4) {
                    Text(user.displayName ?? user.username).font(.title3).bold()
                    Text("@\(user.username)").foregroundStyle(.secondary)
                    if user.discordVerifiedAt != nil {
                        Label("Discord Verified", systemImage: "checkmark.seal.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color(red: 0.345, green: 0.396, blue: 0.949))
                    }
                    if let bio = user.bio, !bio.isEmpty {
                        Text(bio).font(.footnote)
                    }
                    // The backend already nulls out created_at server-side
                    // for a non-owner viewer when profile_show_joined_date
                    // is off (routes.lua's decode_user) -- so a missing date
                    // here always means "hidden", never "unknown", and this
                    // row can just not render rather than needing its own
                    // separate owner/viewer check.
                    if let joined = DateFormatting.joined(user.createdAt) {
                        Label("Joined \(joined)", systemImage: "calendar")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 10) {
                statPill("Posts", user.mediaCount)
                // followerCount/followingCount are likewise already nil'd
                // server-side when the owner has profile_show_follow_counts
                // off -- hide the whole pill rather than showing a
                // misleading "0".
                if let followerCount = user.followerCount {
                    NavigationLink(destination: UserListView(userId: user.id, kind: .followers)) {
                        statPill("Followers", followerCount)
                    }
                }
                if let followingCount = user.followingCount {
                    NavigationLink(destination: UserListView(userId: user.id, kind: .following)) {
                        statPill("Following", followingCount)
                    }
                }
                statPill("Friends", user.friendCount)
            }
            .buttonStyle(.plain)
        }
        .padding(Metrics.Space.lg)
        .background(AccentWash(color: accent, secondaryColor: secondaryAccent))
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.Radius.lg, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func statPill(_ label: String, _ value: Int?) -> some View {
        VStack(spacing: 2) {
            Text("\(value ?? 0)").font(.subheadline).bold()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .softCard(radius: Metrics.Radius.sm)
    }
}
