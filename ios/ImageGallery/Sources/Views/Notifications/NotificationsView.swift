import SwiftUI

struct NotificationsView: View {
    @StateObject private var viewModel = NotificationsViewModel()
    @EnvironmentObject private var unreadCounts: UnreadCountsService

    var body: some View {
        List {
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            if viewModel.isLoading && viewModel.items.isEmpty {
                SkeletonRowList()
            } else {
                ForEach(viewModel.items) { item in
                    NavigationLink(destination: destination(for: item)) {
                        NotificationRow(item: item, text: viewModel.text(for: item))
                    }
                    .onTapGesture {
                        Task {
                            await viewModel.markRead(item)
                            await unreadCounts.refresh()
                        }
                    }
                }
            }
        }
        .navigationTitle("Notifications")
        .toolbar {
            if viewModel.unreadCount > 0 {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Mark all read") {
                        Task {
                            await viewModel.markAllRead()
                            await unreadCounts.refresh()
                        }
                    }
                }
            }
        }
        .overlay {
            if viewModel.items.isEmpty && !viewModel.isLoading {
                ContentUnavailableCompat(title: "You're all caught up", systemImage: "bell.slash")
            }
        }
        .refreshable { await viewModel.load() }
        .task {
            await viewModel.load()
            await unreadCounts.refresh()
        }
    }

    @ViewBuilder
    private func destination(for item: NotificationItem) -> some View {
        if let mediaId = item.mediaId {
            MediaDetailView(mediaId: mediaId)
        } else if let username = item.actorUsername {
            ProfileView(username: username)
        } else {
            EmptyView()
        }
    }
}

/// Richer replacement for the old plain-text + unread-dot row — surfaces the
/// actor's avatar (previously fetched but never rendered here) with a
/// kind-colored badge, plus a media thumbnail preview when the notification
/// is about a specific post, matching the activity-feed pattern most social
/// apps use instead of a flat text list.
private struct NotificationRow: View {
    let item: NotificationItem
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                AvatarView(
                    urlString: item.actorAvatarUrl,
                    fallbackInitial: String((item.actorDisplayName ?? item.actorUsername ?? "?").prefix(1)),
                    size: 44
                )
                Image(systemName: kind.icon)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(kind.tint, in: Circle())
                    .overlay(Circle().strokeBorder(.background, lineWidth: 2))
                    .offset(x: 4, y: 4)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(text)
                    .font(.subheadline)
                    .fontWeight(item.readAt == nil ? .semibold : .regular)
                if item.createdAt != nil {
                    Text(DateFormatting.relative(item.createdAt)).font(.caption2).foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            if let thumbUrlString = item.mediaThumbUrl, let url = URL(string: thumbUrlString) {
                CachedAsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        Color.secondary.opacity(0.12)
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.Radius.sm, style: .continuous))
            } else if item.readAt == nil {
                Circle().fill(Color.accentColor).frame(width: 8, height: 8).padding(.top, 6)
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(item.readAt == nil ? Color.accentColor.opacity(0.06) : Color.clear)
    }

    private var kind: NotificationKindStyle { NotificationKindStyle(item.kind) }
}

private struct NotificationKindStyle {
    let icon: String
    let tint: Color

    init(_ kind: String) {
        switch kind {
        case "follow": icon = "person.fill.badge.plus"; tint = .blue
        case "friend_request": icon = "person.badge.clock.fill"; tint = .orange
        case "friend_accept": icon = "person.2.fill"; tint = .green
        case "comment": icon = "bubble.left.fill"; tint = .accentColor
        case "reply": icon = "arrowshape.turn.up.left.fill"; tint = .accentColor
        case "mention": icon = "at"; tint = .purple
        case "reaction": icon = "face.smiling.fill"; tint = .pink
        case "message": icon = "message.fill"; tint = .blue
        case "saved_search": icon = "magnifyingglass"; tint = .teal
        default: icon = "bell.fill"; tint = .secondary
        }
    }
}
