import SwiftUI

/// Placeholder tiles shown while the Discover grid's first page is loading,
/// standing in for `MediaCard` so the layout doesn't jump from an empty
/// scroll view to a populated grid.
struct SkeletonGridView: View {
    var columns: [GridItem]
    var count: Int = 12

    @State private var pulse = false

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(0..<count, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.secondary.opacity(pulse ? 0.18 : 0.08))
                    .aspectRatio(1, contentMode: .fit)
            }
        }
        .padding(.horizontal)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}
