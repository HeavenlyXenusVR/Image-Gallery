import SwiftUI

struct FriendRequestsView: View {
    @StateObject private var viewModel = FriendRequestsViewModel()

    var body: some View {
        List {
            Section("Incoming") {
                ForEach(viewModel.incoming) { request in
                    row(request) {
                        HStack {
                            Button("Accept") { Task { await viewModel.respond(request, action: "accept") } }
                                .buttonStyle(.borderedProminent)
                            Button("Decline", role: .destructive) { Task { await viewModel.respond(request, action: "decline") } }
                        }
                    }
                }
                if viewModel.incoming.isEmpty && !viewModel.isLoading {
                    Text("No incoming requests").foregroundStyle(.secondary)
                }
            }

            Section("Outgoing") {
                ForEach(viewModel.outgoing) { request in
                    row(request) {
                        Button("Cancel", role: .destructive) { Task { await viewModel.respond(request, action: "cancel") } }
                    }
                }
                if viewModel.outgoing.isEmpty && !viewModel.isLoading {
                    Text("No pending requests").foregroundStyle(.secondary)
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
        }
        .navigationTitle("Friend Requests")
        .refreshable { await viewModel.load() }
        .task { await viewModel.load() }
        .overlay {
            if viewModel.isLoading && viewModel.incoming.isEmpty && viewModel.outgoing.isEmpty {
                ProgressView()
            }
        }
    }

    @ViewBuilder
    private func row(_ request: FriendRequestItem, @ViewBuilder actions: () -> some View) -> some View {
        HStack {
            if let user = request.user {
                NavigationLink(destination: ProfileView(username: user.username)) {
                    VStack(alignment: .leading) {
                        Text(user.displayName ?? user.username).bold()
                        Text("@\(user.username)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            actions()
        }
        .disabled(viewModel.busyId == request.id)
    }
}
