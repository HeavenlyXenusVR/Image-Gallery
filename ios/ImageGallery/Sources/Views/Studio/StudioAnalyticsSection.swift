import Charts
import SwiftUI

/// Real server-side creator analytics (GET /api/me/stats), distinct from
/// `StudioStatsHeader`'s pure client-side aggregation of already-loaded
/// items -- this adds a 30-day new-viewer chart and a top-posts table the
/// client-side totals alone can't produce. Mirrors the web app's
/// StudioPage.jsx analytics section (round 1). Uses the system Charts
/// framework (iOS 16+, matches this app's deployment target) rather than a
/// hand-rolled shape, unlike the web version's inline SVG bars.
struct StudioAnalyticsSection: View {
    @State private var stats: CreatorStatsResponse?
    @State private var isLoading = true

    var body: some View {
        Group {
            if let stats, !stats.dailyNewViewers.isEmpty || !stats.topPosts.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    if !stats.dailyNewViewers.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("New viewers, last 30 days").font(.subheadline.weight(.semibold))
                            Chart(stats.dailyNewViewers) { day in
                                BarMark(
                                    x: .value("Day", DateFormatting.parse(day.day) ?? Date(), unit: .day),
                                    y: .value("New viewers", day.newViewers)
                                )
                                .foregroundStyle(Color.accentColor)
                            }
                            .frame(height: 120)
                            .chartXAxis {
                                AxisMarks(values: .stride(by: .day, count: 7))
                            }
                        }
                        .padding(12)
                        .softCard()
                    }

                    if !stats.topPosts.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Top posts").font(.subheadline.weight(.semibold))
                            ForEach(stats.topPosts.prefix(10)) { post in
                                HStack(spacing: 10) {
                                    thumbnail(post.thumbUrl)
                                    Text(post.title?.nilIfEmpty ?? "Untitled")
                                        .font(.footnote)
                                        .lineLimit(1)
                                    Spacer()
                                    Text("\(post.views) views · \(post.likeCount) likes")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(12)
                        .softCard()
                    }
                }
            } else if isLoading {
                ProgressView().frame(maxWidth: .infinity).padding()
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private func thumbnail(_ urlString: String?) -> some View {
        if let urlString, let url = URL(string: urlString) {
            CachedAsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    Color.secondary.opacity(0.15)
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6).fill(.secondary.opacity(0.15)).frame(width: 32, height: 32)
        }
    }

    private func load() async {
        stats = try? await GalleryAPIClient.shared.creatorStats()
        isLoading = false
    }
}
