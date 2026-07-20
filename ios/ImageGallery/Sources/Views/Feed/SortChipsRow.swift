import SwiftUI

/// Quick sort switcher for the Discover feed, living inline above the grid
/// instead of buried in the filter sheet — the four orderings a browsing
/// session actually flips between often (the more niche ones like "Oldest"
/// stay in `FeedFilterSheet`).
struct SortChipsRow: View {
    @Binding var sort: String
    var onChange: () -> Void

    private let options: [(value: String, label: String, icon: String)] = [
        ("new", "Newest", "sparkles"),
        ("popular", "Popular", "heart.fill"),
        ("views", "Most viewed", "eye.fill"),
        ("downloads", "Downloaded", "arrow.down.circle.fill"),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options, id: \.value) { option in
                    Button {
                        guard sort != option.value else { return }
                        sort = option.value
                        onChange()
                    } label: {
                        Label(option.label, systemImage: option.icon)
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(sort == option.value ? AnyShapeStyle(Color.accentColor.opacity(0.16)) : AnyShapeStyle(Color.secondary.opacity(0.12)), in: Capsule())
                            .foregroundStyle(sort == option.value ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }
}
