import SwiftUI

struct GroupThreadView: View {
    @StateObject private var viewModel: GroupThreadViewModel
    @EnvironmentObject private var session: SessionStore
    @State private var draft = ""
    let title: String

    init(threadId: Int, title: String) {
        _viewModel = StateObject(wrappedValue: GroupThreadViewModel(threadId: threadId))
        self.title = title
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(viewModel.messages) { message in
                            MessageBubble(
                                body_: message.body,
                                senderLabel: message.displayName ?? message.username,
                                isMine: message.senderId == session.currentUser?.id
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
                Task { await viewModel.send(body) }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
        .overlay {
            if viewModel.isLoading && viewModel.messages.isEmpty {
                ProgressView()
            }
        }
    }
}
