import SwiftUI

/// Horizontal category picker for the Discover feed — an "All" chip plus one
/// per top-level category, ending in a "More" chip that opens the full
/// `CategoryBrowserView` (which also lists subcategories). Selecting a chip
/// here only ever sets `categoryId`; picking a specific subcategory still
/// requires drilling into "More", same as before this component existed.
struct CategoryChipsRow: View {
    @Binding var selectedCategoryId: Int?
    var onSelect: (Int?) -> Void

    @State private var categories: [CategorySummary] = []

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "All", isSelected: selectedCategoryId == nil) {
                    onSelect(nil)
                }
                ForEach(categories) { category in
                    chip(title: category.name, isSelected: selectedCategoryId == category.id) {
                        onSelect(category.id)
                    }
                }
                NavigationLink(destination: CategoryBrowserView()) {
                    Label("More", systemImage: "square.grid.3x3")
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.secondary.opacity(0.12), in: Capsule())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
        }
        .task {
            if categories.isEmpty {
                categories = (try? await GalleryAPIClient.shared.categories()) ?? []
            }
        }
    }

    private func chip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
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
