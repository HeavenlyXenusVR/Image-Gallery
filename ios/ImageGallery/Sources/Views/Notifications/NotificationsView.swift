import SwiftUI

struct NotificationsView: View {
    @StateObject private var viewModel = NotificationsViewModel()
    @EnvironmentObject private var unreadCounts: UnreadCountsService

    var body: some View {
        List {
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            ForEach(viewModel.items) { item in
                NavigationLink(destination: destination(for: item)) {
                    HStack(alignment: .top, spacing: 10) {
                        if item.readAt == nil {
                            Circle().fill(Color.accentColor).frame(width: 8, height: 8).padding(.top, 6)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(viewModel.text(for: item))
                            if item.createdAt != nil {
                                Text(DateFormatting.relative(item.createdAt)).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onTapGesture {
                    Task {
                        await viewModel.markRead(item)
                        await unreadCounts.refresh()
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
            if viewModel.isLoading && viewModel.items.isEmpty {
                ProgressView()
            } else if viewModel.items.isEmpty && !viewModel.isLoading {
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
