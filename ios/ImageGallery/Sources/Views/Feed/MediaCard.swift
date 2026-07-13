import SwiftUI

struct MediaCard: View {
    let item: MediaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                // `Color.clear.aspectRatio(1, contentMode: .fit)` establishes a
                // hard, deterministic square size from the grid column's
                // proposed width (Color has no intrinsic size of its own, so
                // the modifier fully determines the result). Without this,
                // `thumbnail` alone had no concrete frame to resolve against —
                // AsyncImage's success-phase image reports its actual pixel
                // dimensions, so every card ended up a different size and the
                // whole grid overlapped itself instead of laying out in rows.
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(thumbnail)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                if item.locked == true {
                    Image(systemName: "lock.fill")
                        .padding(6)
                        .background(.black.opacity(0.6))
                        .foregroundStyle(.white)
                        .clipShape(Circle())
                        .padding(6)
                } else if item.isVideo {
                    Image(systemName: "play.fill")
                        .padding(6)
                        .background(.black.opacity(0.5))
                        .foregroundStyle(.white)
                        .clipShape(Circle())
                        .padding(6)
                }
            }

            Text(item.title?.isEmpty == false ? item.title! : "Untitled")
                .font(.caption)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if item.locked == true {
            Rectangle()
                .fill(.secondary.opacity(0.3))
                .overlay(Image(systemName: "eye.slash").foregroundStyle(.secondary))
        } else if let urlString = item.thumbUrl, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    Rectangle().fill(.secondary.opacity(0.2)).overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                default:
                    Rectangle().fill(.secondary.opacity(0.1))
                }
            }
        } else {
            Rectangle().fill(.secondary.opacity(0.2)).overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        }
    }
}
