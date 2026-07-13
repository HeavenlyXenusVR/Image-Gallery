import SwiftUI

struct SimilarMediaRail: View {
    let items: [MediaItem]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("More like this").font(.headline)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(items) { item in
                            NavigationLink(destination: MediaDetailView(mediaId: item.id)) {
                                MediaCard(item: item)
                                    .frame(width: 120)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}
