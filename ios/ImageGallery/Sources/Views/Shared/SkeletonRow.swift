import SwiftUI

/// List-row counterpart to `SkeletonGridView` — a pulsing avatar + two text
/// bars, standing in for a thread/notification row while its first page
/// loads. Reused by MessagesView/NotificationsView so a cold launch shows a
/// shaped placeholder instead of a single centered spinner.
struct SkeletonRow: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(.secondary.opacity(pulse ? 0.2 : 0.1))
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: Metrics.Radius.sm, style: .continuous)
                    .fill(.secondary.opacity(pulse ? 0.2 : 0.1))
                    .frame(width: 140, height: 12)
                RoundedRectangle(cornerRadius: Metrics.Radius.sm, style: .continuous)
                    .fill(.secondary.opacity(pulse ? 0.16 : 0.08))
                    .frame(width: 200, height: 10)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

struct SkeletonRowList: View {
    var count: Int = 6

    var body: some View {
        ForEach(0..<count, id: \.self) { _ in
            SkeletonRow()
                .listRowSeparator(.hidden)
        }
    }
}
