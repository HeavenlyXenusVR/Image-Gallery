import SwiftUI

struct NewGroupThreadView: View {
    @StateObject private var viewModel = NewGroupThreadViewModel()
    @Environment(\.dismiss) private var dismiss
    var onCreated: (GroupThread) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Group name (optional)") {
                    TextField("Name", text: $viewModel.name)
                }

                if !viewModel.selectedMembers.isEmpty {
                    Section("Selected") {
                        ForEach(viewModel.selectedMembers) { user in
                            HStack {
                                Text(user.displayName ?? user.username)
                                Spacer()
                                Button {
                                    viewModel.toggle(user)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                            }
                        }
                    }
                }

                Section("Add members") {
                    TextField("Search users", text: $viewModel.query)
                        .onChange(of: viewModel.query) { _ in
                            Task { await viewModel.search() }
                        }
                    ForEach(viewModel.searchResults) { user in
                        Button {
                            viewModel.toggle(user)
                        } label: {
                            HStack {
                                Text(user.displayName ?? user.username)
                                Spacer()
                                if viewModel.isSelected(user) {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }

                if let errorMessage = viewModel.errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Group")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task { await viewModel.create() }
                    }
                    .disabled(viewModel.selectedMembers.isEmpty || viewModel.isCreating)
                }
            }
            .onChange(of: viewModel.createdThread?.id) { newValue in
                if let thread = viewModel.createdThread, newValue != nil {
                    onCreated(thread)
                    dismiss()
                }
            }
        }
    }
}
