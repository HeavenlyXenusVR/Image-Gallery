import SwiftUI

/// Private, per-viewer organizational tags -- mirrors the web app's
/// "Your private tags" box on MediaDetailPage.jsx. Existed on the backend
/// since 2026-08-03 with no client anywhere (web or iOS) until this pass.
struct PersonalTagsSection: View {
    @ObservedObject var viewModel: MediaDetailViewModel
    @State private var newTag = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Your private tags", systemImage: "tag")
                .font(.subheadline.weight(.semibold))
            Text("Only visible to you — for your own organizing, never shown to anyone else.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !viewModel.personalTags.isEmpty {
                FlowChips(tags: viewModel.personalTags) { tag in
                    Task { await viewModel.removePersonalTag(tag) }
                }
            }

            HStack {
                TextField("Add a private tag", text: $newTag)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    Task {
                        await viewModel.addPersonalTag(newTag)
                        newTag = ""
                    }
                }
                .disabled(newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .softCard()
    }
}

/// Simple wrapping chip row (SwiftUI has no built-in flow layout pre-iOS 16
/// `Layout` protocol usage elsewhere in this app, so this stays a plain
/// HStack-wrap via LazyVGrid-style flexible rows -- fine for the handful of
/// short tags this feature realistically holds).
private struct FlowChips: View {
    let tags: [String]
    let onRemove: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                HStack(spacing: 4) {
                    Text(tag).font(.caption)
                    Button {
                        onRemove(tag)
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.caption2)
                    }
                    .accessibilityLabel("Remove tag \(tag)")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.15), in: Capsule())
            }
        }
    }
}
