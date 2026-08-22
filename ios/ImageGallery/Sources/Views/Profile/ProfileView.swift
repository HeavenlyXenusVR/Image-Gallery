import SwiftUI

struct ProfileView: View {
    @StateObject private var viewModel: ProfileViewModel
    @EnvironmentObject private var session: SessionStore

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Appearance.gridColumnMinWidth(session.currentUser?.userSettings?.gridDensity, default_: 100)), spacing: Appearance.gridSpacing(session.currentUser?.userSettings?.columnGap))]
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
            LazyVGrid(columns: columns, spacing: Appearance.gridSpacing(session.currentUser?.userSettings?.columnGap)) {
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

    // "center" stacks the avatar above the text and centers everything,
    // mirroring .profile-align-center's `justify-items: center; text-align:
    // center`. "start"/"split" both keep the side-by-side layout -- web's
    // own CSS difference between them (`align-items: start` vs. the grid's
    // default) is subtle enough at this scale to not warrant two distinct
    // native layouts.
    private var isCenterAligned: Bool { user.userSettings?.profileHeroAlignment == "center" }

    var body: some View {
        VStack(alignment: isCenterAligned ? .center : .leading, spacing: 14) {
            if isCenterAligned {
                VStack(spacing: 10) {
                    avatarView
                    identityBlock(centered: true)
                }
                .frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 14) {
                    avatarView
                    identityBlock(centered: false)
                }
            }

            statsRow
        }
        .padding(Metrics.Space.lg)
        .background(AccentWash(color: accent, secondaryColor: secondaryAccent))
        .modifier(ProfileHeaderBackground(style: user.userSettings?.profileHeaderStyle))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.Radius.lg, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var avatarView: some View {
        AvatarView(urlString: user.avatarUrl, fallbackInitial: String(user.username.prefix(1)), shape: AvatarShape(user.userSettings?.profileAvatarShape), size: 72)
            .overlay(
                RoundedRectangle(cornerRadius: 72 * AvatarShape(user.userSettings?.profileAvatarShape).cornerRadiusFraction)
                    .strokeBorder(accent.opacity(0.6), lineWidth: 2)
            )
    }

    private func identityBlock(centered: Bool) -> some View {
        VStack(alignment: centered ? .center : .leading, spacing: 4) {
            ProfileName(text: user.displayName ?? user.username, style: user.userSettings?.profileNameStyle, accent: accent, secondaryAccent: secondaryAccent)
            Text("@\(user.username)").foregroundStyle(.secondary)
            if user.discordVerifiedAt != nil {
                Label("Discord Verified", systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(red: 0.345, green: 0.396, blue: 0.949))
            }
            if let bio = user.bio, !bio.isEmpty {
                Text(bio).font(.footnote)
                    .multilineTextAlignment(centered ? .center : .leading)
            }
            // The backend already nulls out created_at server-side for a
            // non-owner viewer when profile_show_joined_date is off
            // (routes.lua's decode_user) -- so a missing date here always
            // means "hidden", never "unknown", and this row can just not
            // render rather than needing its own separate owner/viewer
            // check.
            if let joined = DateFormatting.joined(user.createdAt) {
                Label("Joined \(joined)", systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private struct StatEntry {
        let label: String
        let value: Int?
        let kind: UserListView.Kind?
    }

    // followerCount/followingCount are already nil'd server-side when the
    // owner has profile_show_follow_counts off -- hide the whole pill
    // rather than showing a misleading "0".
    @ViewBuilder
    private var statsRow: some View {
        let entries: [StatEntry] = [
            StatEntry(label: "Posts", value: user.mediaCount, kind: nil),
            StatEntry(label: "Followers", value: user.followerCount, kind: .followers),
            StatEntry(label: "Following", value: user.followingCount, kind: .following),
            StatEntry(label: "Friends", value: user.friendCount, kind: nil),
        ]
        switch user.userSettings?.profileStatStyle {
        case "ribbon":
            HStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                    if index > 0 { Divider().frame(height: 24) }
                    statLink(entry, style: .ribbon)
                }
            }
            .softCard(radius: Metrics.Radius.sm)
        case "minimal":
            HStack(spacing: 16) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    statLink(entry, style: .minimal)
                }
            }
        default:
            HStack(spacing: 10) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    statLink(entry, style: .tiles)
                }
            }
        }
    }

    private enum StatStyle { case tiles, ribbon, minimal }

    @ViewBuilder
    private func statLink(_ entry: StatEntry, style: StatStyle) -> some View {
        if entry.kind == nil {
            statPill(entry.label, entry.value, style: style)
        } else if let value = entry.value, let kind = entry.kind {
            NavigationLink(destination: UserListView(userId: user.id, kind: kind)) {
                statPill(entry.label, value, style: style)
            }
            .buttonStyle(.plain)
        }
    }

    private func statPill(_ label: String, _ value: Int?, style: StatStyle) -> some View {
        Group {
            switch style {
            case .tiles:
                VStack(spacing: 2) {
                    Text("\(value ?? 0)").font(.subheadline).bold()
                    Text(label).font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .softCard(radius: Metrics.Radius.sm)
            case .ribbon:
                VStack(spacing: 2) {
                    Text("\(value ?? 0)").font(.subheadline).bold()
                    Text(label).font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            case .minimal:
                HStack(spacing: 4) {
                    Text("\(value ?? 0)").font(.footnote).bold()
                    Text(label).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// `profile_name_style` -- mirrors web's three class-based h2 treatments
/// (gradient/glow/outline) plus the plain default ("display"). Outline has
/// no real SwiftUI Text-stroke equivalent (web uses `-webkit-text-stroke`),
/// so it's approximated with bold accent-colored text rather than a true
/// hollow stroke.
private struct ProfileName: View {
    let text: String
    let style: String?
    let accent: Color
    let secondaryAccent: Color?

    var body: some View {
        switch style {
        case "gradient":
            Text(text).font(.title3).bold()
                .foregroundStyle(LinearGradient(colors: [accent, secondaryAccent ?? Color(hex: "#6ec7ff")], startPoint: .topLeading, endPoint: .bottomTrailing))
        case "glow":
            Text(text).font(.title3).bold()
                .shadow(color: accent.opacity(0.5), radius: 10)
        case "outline":
            Text(text).font(.title3).bold()
                .foregroundStyle(accent)
        default:
            Text(text).font(.title3).bold()
        }
    }
}

/// `profile_header_style` -- the AccentWash gradient (already applied
/// underneath by ProfileHeader) stays constant across all five modes; this
/// only changes what sits on top of it, mirroring web's solid/glass/blur/
/// transparent/gradient header treatments.
private struct ProfileHeaderBackground: ViewModifier {
    let style: String?

    func body(content: Content) -> some View {
        switch style {
        case "solid":
            content.background(Color(uiColor: .secondarySystemBackground))
        case "blur":
            content.background(.ultraThinMaterial)
        case "transparent", "gradient":
            content
        default:
            content.background(.thinMaterial)
        }
    }
}
