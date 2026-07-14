import SwiftUI

struct DirectMessageThreadView: View {
    @StateObject private var viewModel: DirectMessageThreadViewModel
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var unreadCounts: UnreadCountsService
    @State private var draft = ""
    let displayName: String

    init(userId: Int, displayName: String) {
        _viewModel = StateObject(wrappedValue: DirectMessageThreadViewModel(userId: userId))
        self.displayName = displayName
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(viewModel.messages) { message in
                            MessageBubble(
                                body_: message.body,
                                senderLabel: nil,
                                isMine: message.senderId == session.currentUser?.id,
                                createdAt: message.createdAt
                            )
                            .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: viewModel.messages.count) { _ in
                    if let lastId = viewModel.messages.last?.id {
                        withAnimation { proxy.scrollTo(lastId, anchor: .bottom) }
                    }
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.red).padding(.horizontal)
            }

            Divider()
            MessageComposer(text: $draft, isSending: viewModel.isSending) {
                let body = draft
                draft = ""
                Task {
                    if !(await viewModel.send(body)) {
                        draft = body
                    }
                }
            }
        }
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.load()
            await unreadCounts.refresh()
        }
        // Lightweight "is this still fresh" poll while the conversation is
        // open — this app has no push infrastructure, so incoming messages
        // otherwise wouldn't appear until leaving and reopening the thread.
        // SwiftUI cancels `.task` automatically when the view disappears.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if Task.isCancelled { break }
                await viewModel.refreshSilently()
            }
        }
        .overlay {
            if viewModel.isLoading && viewModel.messages.isEmpty {
                ProgressView()
            }
        }
    }
}
