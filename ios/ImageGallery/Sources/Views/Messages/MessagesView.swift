import SwiftUI

struct MessagesView: View {
    @StateObject private var viewModel = MessagesListViewModel()
    @State private var showingDirect = true
    @State private var showingNewGroup = false
    @State private var newlyCreatedThread: GroupThread?

    var body: some View {
        VStack(spacing: 0) {
            Picker("Kind", selection: $showingDirect) {
                Text("Direct").tag(true)
                Text("Groups").tag(false)
            }
            .pickerStyle(.segmented)
            .padding()

            List {
                jumpToNewThreadLink
                threadRows
            }
            .listStyle(.plain)
        }
        .navigationTitle("Messages")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingNewGroup = true
                } label: {
                    Image(systemName: "person.3.fill")
                }
            }
        }
        .sheet(isPresented: $showingNewGroup) {
            NewGroupThreadView { thread in
                newlyCreatedThread = thread
                showingDirect = false
                Task { await viewModel.load() }
            }
        }
        .refreshable { await viewModel.load() }
        .task { await viewModel.load() }
        .overlay {
            if viewModel.isLoading && viewModel.directThreads.isEmpty && viewModel.groupThreads.isEmpty {
                ProgressView()
            }
        }
    }

    /// Hidden programmatic-navigation link for "just created a group, jump
    /// straight into it" — `navigationDestination(item:)` is iOS 17+ only, so
    /// this uses the older (iOS 13+, still functional) isActive-based
    /// initializer to stay on iOS 16. Split out of `body` to keep each
    /// individual view's expression simple for the type-checker (see the
    /// CollectionsListView fix for why that matters).
    private var jumpToNewThreadLink: some View {
        NavigationLink(
            destination: Group {
                if let thread = newlyCreatedThread {
                    GroupThreadView(threadId: thread.id, title: thread.displayName ?? thread.name ?? "Group")
                }
            },
            isActive: Binding(
                get: { newlyCreatedThread != nil },
                set: { active in if !active { newlyCreatedThread = nil } }
            )
        ) { EmptyView() }
            .hidden()
    }

    @ViewBuilder
    private var threadRows: some View {
        if showingDirect {
            ForEach(viewModel.directThreads) { thread in
                NavigationLink(destination: DirectMessageThreadView(userId: thread.userId ?? thread.id, displayName: thread.displayName ?? thread.username ?? "User")) {
                    DirectThreadRow(thread: thread)
                }
            }
            if viewModel.directThreads.isEmpty && !viewModel.isLoading {
                EmptyMessagesState(text: "No conversations yet — start one from a profile.")
            }
        } else {
            ForEach(viewModel.groupThreads) { thread in
                NavigationLink(destination: GroupThreadView(threadId: thread.id, title: thread.displayName ?? thread.name ?? "Group")) {
                    GroupThreadRow(thread: thread)
                }
            }
            if viewModel.groupThreads.isEmpty && !viewModel.isLoading {
                EmptyMessagesState(text: "No group chats yet.")
            }
        }
    }
}

private struct DirectThreadRow: View {
    let thread: MessageThread

    var body: some View {
        HStack {
            AvatarView(urlString: thread.avatarUrl, fallbackInitial: String((thread.username ?? "?").prefix(1)), size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.displayName ?? thread.username ?? "User").bold()
                if let lastMessage = thread.lastMessage {
                    Text(lastMessage).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let unread = thread.unreadCount, unread > 0 {
                Text("\(unread)")
                    .font(.caption2).bold()
                    .padding(6)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(Circle())
            }
        }
    }
}

private struct GroupThreadRow: View {
    let thread: GroupThread

    var body: some View {
        HStack {
            Image(systemName: "person.3.fill")
                .frame(width: 44, height: 44)
                .background(.secondary.opacity(0.15))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.displayName ?? thread.name ?? "Group").bold()
                if let lastMessage = thread.lastMessage {
                    Text(lastMessage).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

private struct EmptyMessagesState: View {
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "message").font(.system(size: 36)).foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .listRowSeparator(.hidden)
    }
}
