import SwiftUI

/// Small "creator dashboard" strip above the Studio grid — pure client-side
/// aggregation of the already-loaded `viewModel.items`, no extra API calls.
struct StudioStatsHeader: View {
    let items: [MediaItem]

    private var activeItems: [MediaItem] { items.filter { $0.deletedAt == nil } }
    private var publicCount: Int { activeItems.filter { ($0.visibility ?? "public") == "public" }.count }
    private var totalViews: Int { activeItems.reduce(0) { $0 + ($1.views ?? 0) } }
    private var totalLikes: Int { activeItems.reduce(0) { $0 + ($1.likeCount ?? 0) } }

    var body: some View {
        HStack(spacing: 10) {
            tile(value: activeItems.count, label: "Posts", icon: "photo.stack")
            tile(value: publicCount, label: "Public", icon: "globe")
            tile(value: totalViews, label: "Views", icon: "eye")
            tile(value: totalLikes, label: "Likes", icon: "heart")
        }
    }

    private func tile(value: Int, label: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icon).foregroundStyle(Color.accentColor)
            Text("\(value)").font(.title3.bold())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .softCard()
    }
}
