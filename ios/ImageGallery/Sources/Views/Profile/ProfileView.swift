import SwiftUI

struct ProfileView: View {
    @StateObject private var viewModel: ProfileViewModel
    @EnvironmentObject private var session: SessionStore

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]

    init(username: String) {
        _viewModel = StateObject(wrappedValue: ProfileViewModel(username: username))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let user = viewModel.user {
                    header(user)
                    ProfileActionsView(viewModel: viewModel)

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

                    if !viewModel.collections.isEmpty {
                        Text("Collections").font(.headline)
                        ForEach(viewModel.collections) { collection in
                            NavigationLink(destination: CollectionDetailView(collectionId: collection.id)) {
                                Label(collection.name, systemImage: "folder")
                            }
                        }
                    }

                    if !viewModel.friends.isEmpty {
                        Text("Friends").font(.headline)
                        ForEach(viewModel.friends) { friend in
                            NavigationLink(destination: ProfileView(username: friend.username)) {
                                Label(friend.displayName ?? friend.username, systemImage: "person.crop.circle")
                            }
                        }
                    }
                } else if viewModel.isLoading {
                    ProgressView().padding(.top, 80)
                } else if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .padding()
        }
        .navigationTitle(viewModel.user?.displayName ?? viewModel.username)
        .toolbar {
            if viewModel.user?.friendStatus == "self" {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(destination: SettingsView()) {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
    }

    @ViewBuilder
    private func header(_ user: GalleryUser) -> some View {
        HStack(spacing: 12) {
            avatar(user)
            VStack(alignment: .leading, spacing: 4) {
                Text(user.displayName ?? user.username).font(.title3).bold()
                Text("@\(user.username)").foregroundStyle(.secondary)
                if let bio = user.bio, !bio.isEmpty {
                    Text(bio).font(.footnote)
                }
            }
        }

        HStack(spacing: 20) {
            statColumn("Posts", user.mediaCount)
            statColumn("Followers", user.followerCount)
            statColumn("Following", user.followingCount)
            statColumn("Friends", user.friendCount)
        }
    }

    @ViewBuilder
    private func avatar(_ user: GalleryUser) -> some View {
        if let urlString = user.avatarUrl, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    Circle().fill(.secondary.opacity(0.2))
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(Circle())
        } else {
            Circle().fill(.secondary.opacity(0.2)).frame(width: 64, height: 64)
                .overlay(Text(String(user.username.prefix(1)).uppercased()))
        }
    }

    private func statColumn(_ label: String, _ value: Int?) -> some View {
        VStack {
            Text("\(value ?? 0)").bold()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
