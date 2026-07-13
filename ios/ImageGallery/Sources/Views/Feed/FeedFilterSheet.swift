import SwiftUI

struct FeedFilterSheet: View {
    @ObservedObject var viewModel: FeedViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingSaveAlert = false
    @State private var alertName = ""
    @State private var isSavingAlert = false
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Search") {
                    TextField("Title, description, tags", text: $viewModel.query)
                }

                Section("Media kind") {
                    Picker("Kind", selection: Binding(
                        get: { viewModel.mediaKind ?? "" },
                        set: { viewModel.mediaKind = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("All").tag("")
                        Text("Images & GIFs").tag("image")
                        Text("Videos").tag("video")
                    }
                    .pickerStyle(.segmented)
                }

                Section("Sort") {
                    Picker("Sort", selection: $viewModel.sort) {
                        Text("Newest").tag("new")
                        Text("Popular").tag("popular")
                        Text("Views").tag("views")
                        Text("Downloads").tag("downloads")
                        Text("Oldest").tag("old")
                    }
                }

                Section {
                    Button {
                        alertName = viewModel.query.isEmpty ? "My saved search" : viewModel.query
                        showingSaveAlert = true
                    } label: {
                        Label("Save as alert", systemImage: "bell.badge")
                    }
                    .disabled(hasNoFilters)
                    if let saveError {
                        Text(saveError).font(.footnote).foregroundStyle(.red)
                    }
                } footer: {
                    Text("Get notified when a new upload matches this search.")
                }
            }
            .navigationTitle("Filters")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        dismiss()
                        Task { await viewModel.loadInitial() }
                    }
                }
            }
            .alert("Save search alert", isPresented: $showingSaveAlert) {
                TextField("Name", text: $alertName)
                Button("Cancel", role: .cancel) {}
                Button("Save") { Task { await saveAlert() } }
            } message: {
                Text("Name this saved search.")
            }
        }
    }

    private var hasNoFilters: Bool {
        viewModel.query.isEmpty && viewModel.mediaKind == nil && viewModel.categoryId == nil
    }

    private func saveAlert() async {
        isSavingAlert = true
        defer { isSavingAlert = false }
        let filter = DiscoverFilterPayload(
            mediaKind: viewModel.mediaKind,
            categoryId: viewModel.categoryId,
            subcategoryId: viewModel.subcategoryId,
            q: viewModel.query.isEmpty ? nil : viewModel.query,
            sort: viewModel.sort == "new" ? nil : viewModel.sort
        )
        do {
            _ = try await GalleryAPIClient.shared.createSavedSearch(name: alertName, filter: filter)
        } catch {
            saveError = error.localizedDescription
        }
    }
}
