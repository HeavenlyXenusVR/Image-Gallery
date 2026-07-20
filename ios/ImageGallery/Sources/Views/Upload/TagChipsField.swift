import SwiftUI

/// Chip editor over the comma-separated `tags` string `UploadViewModel`
/// already sends to the backend as-is — this view only changes how tags are
/// entered, not the wire format. A horizontal scrolling row rather than a
/// wrapping flow layout, matching the same idiom already used for category
/// chips and the duplicate-thumbnail rail.
struct TagChipsField: View {
    @Binding var tags: String
    @State private var newTag = ""

    private var tagList: [String] {
        tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tagList, id: \.self) { tag in
                    HStack(spacing: 4) {
                        Text(tag).font(.footnote.weight(.medium))
                        Button {
                            removeTag(tag)
                        } label: {
                            Image(systemName: "xmark.circle.fill").font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                }

                TextField("Add tag", text: $newTag)
                    .submitLabel(.done)
                    .onSubmit(commitNewTag)
                    .frame(minWidth: 90)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.secondary.opacity(0.1), in: Capsule())
            }
        }
    }

    private func commitNewTag() {
        let trimmed = newTag.trimmingCharacters(in: .whitespaces)
        newTag = ""
        guard !trimmed.isEmpty, !tagList.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        tags = (tagList + [trimmed]).joined(separator: ", ")
    }

    private func removeTag(_ tag: String) {
        tags = tagList.filter { $0 != tag }.joined(separator: ", ")
    }
}
