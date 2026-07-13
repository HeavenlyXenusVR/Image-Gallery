import SwiftUI

struct FeedFilterSheet: View {
    @ObservedObject var viewModel: FeedViewModel
    @Environment(\.dismiss) private var dismiss

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
        }
    }
}
