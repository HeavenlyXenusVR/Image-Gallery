import SwiftUI

struct DirectMessageThreadView: View {
    @StateObject private var viewModel: DirectMessageThreadViewModel
    @EnvironmentObject private var session: SessionStore
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
                            MessageBubble(body_: message.body, senderLabel: nil, isMine: message.senderId == session.currentUser?.id)
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
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
        .overlay {
            if viewModel.isLoading && viewModel.messages.isEmpty {
                ProgressView()
            }
        }
    }
}
