import SwiftUI

/// Full post editor, mirroring the web app's `MediaEditor` in
/// `frontend/src/components/media.jsx`.
///
/// Until now the iOS app could only change a post's visibility and pinned
/// state, and only from the Studio list -- title, description, tags and
/// category were frozen at upload time on both platforms even though
/// `PATCH /api/media/:id` has always supported editing them.
///
/// The endpoint REPLACES the post record rather than patching named fields,
/// so every control value the sheet doesn't edit is echoed back unchanged;
/// omitting `visibility` would reset the post to public and omitting
/// `isAdult` would silently un-mark an 18+ post. `publishAt` is deliberately
/// not sent: it is explicitly-only on the server, so leaving it out preserves
/// whatever schedule was set elsewhere.
struct MediaEditSheet: View {
    @ObservedObject var viewModel: MediaDetailViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var description = ""
    @State private var tags = ""
    @State private var categoryId = 0
    @State private var subcategoryIds: [Int] = []
    @State private var newSubcategory = ""
    @State private var isAdult = false
    @State private var categories: [CategorySummary] = []
    @State private var isSaving = false

    private var selectedCategory: CategorySummary? {
        categories.first { $0.id == categoryId }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Title", text: $title)
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(3...8)
                    TextField("Tags (comma separated)", text: $tags)
                        .textInputAutocapitalization(.never)
                }
                Section("Category") {
                    Picker("Category", selection: $categoryId) {
                        Text("Select a category").tag(0)
                        ForEach(categories) { category in
                            Text(category.name).tag(category.id)
                        }
                    }
                    if let subs = selectedCategory?.subcategories, !subs.isEmpty {
                        ForEach(subs) { sub in
                            Button {
                                if let index = subcategoryIds.firstIndex(of: sub.id) {
                                    subcategoryIds.remove(at: index)
                                } else if subcategoryIds.count < 3 {
                                    subcategoryIds.append(sub.id)
                                }
                            } label: {
                                HStack {
                                    Text(sub.name)
                                    Spacer()
                                    if subcategoryIds.contains(sub.id) {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    TextField("Or add a new subcategory", text: $newSubcategory)
                }
                Section {
                    Toggle("Mark as 18+", isOn: $isAdult)
                } footer: {
                    Text("18+ posts stay hidden from anyone who has not verified their age.")
                }
            }
            .navigationTitle("Edit Post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(isSaving || title.trimmingCharacters(in: .whitespaces).isEmpty || categoryId == 0)
                }
            }
            .task { await prepare() }
        }
    }

    private func prepare() async {
        guard let media = viewModel.media else { return }
        title = media.title ?? ""
        description = media.description ?? ""
        tags = (media.tags ?? []).joined(separator: ", ")
        categoryId = media.categoryId ?? 0
        subcategoryIds = media.subcategoryIds ?? []
        isAdult = media.isAdult ?? false
        categories = (try? await GalleryAPIClient.shared.categories()) ?? []
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let parsedTags = tags
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let newNames = newSubcategory.trimmingCharacters(in: .whitespaces)
        let ok = await viewModel.updatePost(
            title: title,
            description: description,
            tags: parsedTags,
            categoryId: categoryId,
            subcategoryIds: subcategoryIds,
            subcategoryNames: newNames.isEmpty ? [] : [newNames],
            isAdult: isAdult
        )
        if ok { dismiss() }
    }
}
