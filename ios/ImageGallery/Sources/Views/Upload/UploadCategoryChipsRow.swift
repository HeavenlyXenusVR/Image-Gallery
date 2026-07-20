import SwiftUI

/// Tappable chips over `UploadViewModel.categories` — previously fetched
/// (`loadCategories()`) but never shown anywhere, leaving category entry a
/// blind free-text field. Sits above the existing text field so typing a
/// brand-new category name still works; tapping a chip just fills it in.
struct UploadCategoryChipsRow: View {
    let categories: [CategorySummary]
    @Binding var selectedName: String

    var body: some View {
        if !categories.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(categories) { category in
                        let isSelected = selectedName.caseInsensitiveCompare(category.name) == .orderedSame
                        Button {
                            selectedName = isSelected ? "" : category.name
                        } label: {
                            Text(category.name)
                                .font(.footnote.weight(.medium))
                                .lineLimit(1)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary.opacity(0.12)), in: Capsule())
                                .foregroundStyle(isSelected ? Color.white : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
