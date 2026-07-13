import SwiftUI

struct NewCollectionView: View {
    @Environment(\.dismiss) private var dismiss
    var onCreated: (CollectionSummary) -> Void

    @State private var name = ""
    @State private var description = ""
    @State private var isPublic = true
    @State private var isSmart = false
    @State private var mediaKind = ""
    @State private var query = ""
    @State private var sort = "new"
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Name", text: $name)
                    TextField("Description (optional)", text: $description, axis: .vertical)
                    Toggle("Public", isOn: $isPublic)
                }

                Section {
                    Toggle("Smart collection", isOn: $isSmart)
                } footer: {
                    Text("A smart collection automatically includes any post matching the filter below, instead of posts you add manually.")
                }

                if isSmart {
                    Section("Matches") {
                        TextField("Search text", text: $query)
                        Picker("Media kind", selection: $mediaKind) {
                            Text("Any").tag("")
                            Text("Images & GIFs").tag("image")
                            Text("Videos").tag("video")
                        }
                        Picker("Sort", selection: $sort) {
                            Text("Newest").tag("new")
                            Text("Popular").tag("popular")
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Collection")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
                }
            }
        }
    }

    private func create() async {
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }
        let filter = DiscoverFilterPayload(
            mediaKind: mediaKind.isEmpty ? nil : mediaKind,
            q: query.isEmpty ? nil : query,
            sort: sort == "new" ? nil : sort
        )
        do {
            let collection = try await GalleryAPIClient.shared.createCollection(
                name: name,
                description: description.isEmpty ? nil : description,
                isPublic: isPublic,
                isSmart: isSmart,
                filter: filter
            )
            onCreated(collection)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
